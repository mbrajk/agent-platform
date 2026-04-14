#!/usr/bin/env bash
# Implementer agent: reads an approved plan, writes code, opens a PR, then verifies.
#
# Flow (push-first):
#   1. Claude writes code only (no bash, no verification)
#   2. Script commits, pushes, opens draft PR immediately
#   3. Script runs verification (install/typecheck/test/build) with per-step timeouts
#   4. Script comments on PR with verification report + labels accordingly
#
# Rationale: if step 3 hangs or fails, work is already on a draft PR — never orphaned.

run_implement_agent() {
    local repo_path="$1"
    local issue_num="$2"

    echo "Implementing issue #${issue_num} in ${repo_path}..." >&2

    # Fetch issue content + comments (plan is in comments)
    local issue_json
    issue_json="$(cd "$repo_path" && gh issue view "$issue_num" --json title,body,comments)"
    local title body comments
    title="$(echo "$issue_json" | jq -r '.title')"
    body="$(echo "$issue_json" | jq -r '.body // ""')"
    comments="$(echo "$issue_json" | jq -r '[.comments[] | select(.body | contains("Implementation Plan"))] | last | .body // ""')"

    if [[ -z "$comments" || "$comments" == "null" ]]; then
        echo "Error: no approved plan found in issue #${issue_num} comments" >&2
        return 1
    fi

    # Create branch
    local slug
    slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40)"
    local branch_prefix base_branch branch
    branch_prefix="$(get_project_config "$repo_path" '.branching.prefix' 'agent/')"
    base_branch="$(get_project_config "$repo_path" '.branching.base' 'main')"
    branch="${branch_prefix}${issue_num}-${slug}"

    cd "$repo_path"

    git config user.name "agent-platform[bot]" 2>/dev/null || true
    git config user.email "agent-platform[bot]@users.noreply.github.com" 2>/dev/null || true

    git checkout "$base_branch"
    git pull origin "$base_branch"
    git checkout -b "$branch" 2>/dev/null || git checkout "$branch"

    # Assemble system prompt
    local system_prompt_file
    system_prompt_file="$(assemble_system_prompt "implementer" "code-structure" "$repo_path")"

    local budget
    budget="$(get_budget "$repo_path" "$BUDGET")"

    # Claude gets Read/Glob/Grep/Edit/Write ONLY — no Bash. Verification runs in the
    # script, not in Claude's turn, so a hanging test or build can never orphan work.
    local user_prompt="$(cat <<EOF
You are implementing the following GitHub issue. An approved plan is provided below — follow it closely.

## Issue #${issue_num}: ${title}

${body}

## Approved Implementation Plan

${comments}

---

Instructions:
1. Read each file before modifying it
2. Write tests first based on acceptance criteria (if any in the plan)
3. Implement the changes

IMPORTANT — do NOT run any commands:
- Do NOT run npm, npx, node, python, pip, or any Bash command
- Do NOT run tests, the build, or typecheck yourself
- Do NOT run any git commands, create commits, push, or create PRs
- Do NOT modify test configuration files (vitest.config.ts, jest.config.js, etc.) — if you need a test-environment change, add a setup file instead

Verification (install / typecheck / test / build) runs AFTER your changes are pushed, in a controlled environment. You do not need to verify anything yourself. Focus on writing correct code that matches the plan.

When done, output a brief summary of what you changed.
EOF
)"

    # Restricted toolset — no Bash.
    local result
    result="$(invoke_claude \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "Read,Glob,Grep,Edit,Write" \
        50 \
        "$budget" \
        "sonnet"
    )"

    local claude_exit=$?
    rm -f "$system_prompt_file"

    # ---- Push-first: commit and open a draft PR BEFORE verifying ----
    cd "$repo_path"

    git add -A
    if git diff --cached --quiet; then
        echo "No changes made by agent" >&2
        post_issue_comment "$repo_path" "$issue_num" "## No Changes

The implementer agent completed but made no file changes."
        return 1
    fi

    local commit_msg="Implement #${issue_num}: ${title}"
    if [[ $claude_exit -ne 0 ]]; then
        commit_msg="Partial (#${issue_num}): ${title} — agent exit ${claude_exit}"
    fi
    git commit -m "$commit_msg"
    git push -u origin "$branch"

    local pr_body
    pr_body="$(cat <<EOF
## Summary
Closes #${issue_num}

${result}

---
*Automated by agent-platform. Code is pushed; verification runs next and will post a comment with results.*
EOF
)"

    local pr_url
    pr_url="$(gh pr create \
        --base "$base_branch" \
        --head "$branch" \
        --title "$title" \
        --body "$pr_body" \
        --label "agent-pr" \
        --draft 2>/dev/null)"

    # If PR already exists on this branch (rerun), reuse it.
    if [[ -z "$pr_url" ]]; then
        pr_url="$(gh pr list --head "$branch" --json url --jq '.[0].url')"
    fi

    echo "PR: $pr_url" >&2

    post_issue_comment "$repo_path" "$issue_num" "## Code Pushed — Verifying

PR: ${pr_url}

Verification (install / typecheck / test / build) running now; report will appear as a PR comment."
    add_label "$repo_path" "$issue_num" "in-progress"
    remove_label "$repo_path" "$issue_num" "approved"

    # If Claude bailed, flag but don't attempt verification
    if [[ $claude_exit -ne 0 ]]; then
        gh pr comment "$pr_url" --body "⚠️ Implementer agent did not complete normally (exit ${claude_exit}). Code on branch represents partial work — review before running verification locally."
        gh pr edit "$pr_url" --add-label "changes-requested" 2>/dev/null || true
        return 1
    fi

    # ---- Verification phase (outside Claude, with per-step timeouts) ----
    local install_cmd typecheck_cmd test_cmd build_cmd
    install_cmd="$(get_project_config "$repo_path" '.commands.install' 'npm install')"
    typecheck_cmd="$(get_project_config "$repo_path" '.commands.typecheck' '')"
    test_cmd="$(get_project_config "$repo_path" '.commands.test' '')"
    build_cmd="$(get_project_config "$repo_path" '.commands.build' '')"

    local verify_log="/tmp/verify-${issue_num}-$$.log"
    : > "$verify_log"

    local verify_status="passed"
    local verify_failed_step=""

    run_verify_step() {
        local name="$1" cmd="$2" to="$3"
        if [[ -z "$cmd" ]]; then
            echo "--- ${name}: skipped (no command configured) ---" >> "$verify_log"
            return 0
        fi
        echo "--- ${name} (timeout ${to}s): ${cmd} ---" >> "$verify_log"
        if timeout "$to" bash -c "$cmd" >> "$verify_log" 2>&1; then
            echo "--- ${name} OK ---" >> "$verify_log"
            return 0
        fi
        local code=$?
        if [[ $code -eq 124 ]]; then
            echo "--- ${name} TIMED OUT after ${to}s ---" >> "$verify_log"
        else
            echo "--- ${name} FAILED (exit ${code}) ---" >> "$verify_log"
        fi
        verify_status="failed"
        verify_failed_step="$name"
        return 1
    }

    run_verify_step "install"   "$install_cmd"   180 && \
    run_verify_step "typecheck" "$typecheck_cmd"  60 && \
    run_verify_step "test"      "$test_cmd"      180 && \
    run_verify_step "build"     "$build_cmd"     180

    local log_excerpt
    log_excerpt="$(tail -c 6000 "$verify_log")"

    if [[ "$verify_status" == "passed" ]]; then
        gh pr comment "$pr_url" --body "## Verification passed

All steps succeeded.

<details><summary>Log</summary>

\`\`\`
${log_excerpt}
\`\`\`

</details>"
    else
        gh pr edit "$pr_url" --add-label "changes-requested" 2>/dev/null || true
        gh pr comment "$pr_url" --body "## Verification failed at **${verify_failed_step}**

The code is pushed, but \`${verify_failed_step}\` did not pass. A human (or a follow-up agent run) can iterate from here.

<details><summary>Log (last 6 KB)</summary>

\`\`\`
${log_excerpt}
\`\`\`

</details>"
    fi

    rm -f "$verify_log"
    echo "$pr_url"
}
