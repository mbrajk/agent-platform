#!/usr/bin/env bash
# Implementer agent: reads an approved plan, writes code, opens a PR, then verifies.
#
# Flow:
#   1. Create branch
#   2. Invoke Claude with full toolset, wrapped in a 15-minute hard timeout
#      (so no hang — test, build, or otherwise — can stall the pipeline).
#      Claude iterates normally: write → test → fix → test → build → etc.
#   3. Regardless of Claude's exit (success / timeout / error), commit + push +
#      open a draft PR with whatever is on disk. Work is never orphaned.
#   4. Run canonical verification (install / typecheck / test / build) with
#      per-step timeouts; post results as a PR comment.
#
# The only behavior forbidden to Claude is modifying test-config files
# (vitest.config.ts, jest.config.js) — platform-level caps stay authoritative.

# Hard cap on the Claude session. Claude runs tests and builds freely within
# this window; if anything hangs, the wrapping `timeout` kills the whole
# session and execution continues from the push step.
AGENT_SESSION_TIMEOUT_SECONDS=900

run_implement_agent() {
    local repo_path="$1"
    local issue_num="$2"

    echo "Implementing issue #${issue_num} in ${repo_path}..." >&2

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

    local system_prompt_file
    system_prompt_file="$(assemble_system_prompt "implementer" "code-structure" "$repo_path")"

    local budget
    budget="$(get_budget "$repo_path" "$BUDGET")"

    local build_cmd
    build_cmd="$(get_project_config "$repo_path" '.commands.build' '')"

    # If a PR already exists for this branch (iteration run), pull its review comments
    # and inline code-review comments so Claude sees what to fix this round.
    local review_feedback=""
    local existing_pr_num
    existing_pr_num="$(cd "$repo_path" && gh pr list --head "$branch" --json number --jq '.[0].number' 2>/dev/null)"
    if [[ -n "$existing_pr_num" ]]; then
        echo "Existing PR #${existing_pr_num} found on branch ${branch} — fetching review feedback" >&2
        local pr_comments pr_reviews pr_review_comments
        pr_comments="$(cd "$repo_path" && gh pr view "$existing_pr_num" --json comments --jq '[.comments[] | "### Comment by \(.author.login)\n\n\(.body)"] | join("\n\n---\n\n")' 2>/dev/null)"
        pr_reviews="$(cd "$repo_path" && gh pr view "$existing_pr_num" --json reviews --jq '[.reviews[] | select(.body != "") | "### Review by \(.author.login) (\(.state))\n\n\(.body)"] | join("\n\n---\n\n")' 2>/dev/null)"
        pr_review_comments="$(cd "$repo_path" && gh api "repos/:owner/:repo/pulls/${existing_pr_num}/comments" --jq '[.[] | "### Inline comment by \(.user.login) on `\(.path)` line \(.line // .original_line)\n\n\(.body)"] | join("\n\n---\n\n")' 2>/dev/null)"

        if [[ -n "$pr_comments" || -n "$pr_reviews" || -n "$pr_review_comments" ]]; then
            review_feedback="$(cat <<FEEDBACK

## Prior Review Feedback on PR #${existing_pr_num}

You have previously pushed code to this branch. Reviewers left the following feedback. Address each point and re-run tests/build.

${pr_reviews:+### Reviews

${pr_reviews}

}${pr_review_comments:+### Inline code comments

${pr_review_comments}

}${pr_comments:+### PR comments

${pr_comments}

}
---
FEEDBACK
)"
        fi
    fi

    # Full toolset restored. Claude iterates normally — write, test, fix, build.
    # The only forbidden edit is test-config files; platform-level caps stay authoritative.
    local user_prompt="$(cat <<EOF
You are implementing the following GitHub issue. An approved plan is provided below — follow it closely.

## Issue #${issue_num}: ${title}

${body}

## Approved Implementation Plan

${comments}
${review_feedback}
---

Pre-setup: dependencies have already been installed by the CI runner before
your session started. \`node_modules/\` is present. You do NOT need to run
\`npm install\` unless the plan requires adding a new dependency. If you add
a new dep, append it to package.json and run \`npm install <pkg>\` — the rest
of the tree is already there.

Implement the plan step by step:
1. Read each file before modifying it
2. Write tests first based on acceptance criteria (if any in the plan)
3. Implement the changes
4. Run the build to verify: ${build_cmd:+\`${build_cmd}\`}
5. Fix any build errors
6. Run tests and iterate until they pass

Constraints:
- Do NOT modify any file under \`.github/workflows/\`. The default GITHUB_TOKEN
  cannot push workflow-file changes, so any edit there causes the push to fail
  entirely. If the plan seems to require a workflow change, flag it in your
  summary instead of editing.
- Do NOT modify test configuration files (vitest.config.ts, jest.config.js, etc.).
  If you need a test-environment change, add a setup file instead.
- Do NOT run any git commands. Do NOT create commits. Do NOT push. Do NOT create PRs.
- For verbose commands (npm install, test, build), use the agent-bash wrapper to
  keep your context window clean. The wrapper elides successful output so you
  don't burn tokens on install logs, while keeping FULL output on failure.
  Path: \`.agent-platform/lib/agent-bash.sh\`. Examples:

      .agent-platform/lib/agent-bash.sh install 180 -- npm install
      .agent-platform/lib/agent-bash.sh test    180 -- npm test
      .agent-platform/lib/agent-bash.sh build   180 -- npm run build
      .agent-platform/lib/agent-bash.sh tsc      60 -- npx tsc --noEmit

  Short commands (ls, cat of a small file, a one-off node expression) can run
  directly via Bash without the wrapper. Use judgement.
- When running long commands directly without the wrapper, pass a sensible
  \`timeout\` to the Bash tool (120000 ms for tests, 180000 ms for builds).
  Never retry the same timed-out command with a longer timeout.

When done, output a brief summary of what you changed.
EOF
)"

    # Wrap the Claude invocation in a hard session timeout. If it exceeds
    # AGENT_SESSION_TIMEOUT_SECONDS, SIGTERM the process group (kills Claude and
    # any child npm/node/test processes); execution falls through to the push step.
    local result_file
    result_file="$(mktemp)"

    # setsid puts Claude in its own process group so `kill -- -$pgid` reliably
    # kills all descendants. Falls back to plain bash if setsid is missing.
    local launcher=(bash -c)
    if command -v setsid >/dev/null 2>&1; then
        launcher=(setsid bash -c)
    fi

    "${launcher[@]}" "invoke_claude \"\$@\" > \"$result_file\"" _ \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "Read,Glob,Grep,Edit,Write,Bash(npm *),Bash(npx *),Bash(node *),Bash(python *),Bash(pip *)" \
        50 \
        "$budget" \
        "sonnet" &
    local claude_pid=$!

    local elapsed=0
    while kill -0 "$claude_pid" 2>/dev/null; do
        if (( elapsed >= AGENT_SESSION_TIMEOUT_SECONDS )); then
            echo "Session exceeded ${AGENT_SESSION_TIMEOUT_SECONDS}s — terminating." >&2
            # With setsid the pgid equals claude_pid, so kill -- -pgid kills the tree.
            kill -TERM -- "-$claude_pid" 2>/dev/null || kill -TERM "$claude_pid" 2>/dev/null || true
            sleep 10
            kill -KILL -- "-$claude_pid" 2>/dev/null || kill -KILL "$claude_pid" 2>/dev/null || true
            # Clean up any straggling claude children in case the pgid trick failed.
            pkill -KILL -P "$claude_pid" 2>/dev/null || true
            break
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done

    # Capture Claude's exit code without letting errexit kill us here — a non-zero
    # exit is expected when we terminate the session, and we must continue to the
    # push step so work isn't orphaned.
    local claude_exit=0
    wait "$claude_pid" 2>/dev/null || claude_exit=$?
    local result
    result="$(cat "$result_file" 2>/dev/null || true)"
    rm -f "$result_file"
    rm -f "$system_prompt_file"

    local session_status="completed"
    if [[ $claude_exit -eq 124 ]]; then
        session_status="timed-out (${AGENT_SESSION_TIMEOUT_SECONDS}s)"
    elif [[ $claude_exit -ne 0 ]]; then
        session_status="errored (exit ${claude_exit})"
    fi

    # ---- Push-first: always commit + push + open draft PR ----
    cd "$repo_path"

    git add -A
    if git diff --cached --quiet; then
        echo "No changes made by agent (session ${session_status})" >&2
        post_issue_comment "$repo_path" "$issue_num" "## No Changes

The implementer agent ${session_status} and produced no file changes."
        return 1
    fi

    local commit_msg="Implement #${issue_num}: ${title}"
    if [[ $claude_exit -ne 0 ]]; then
        commit_msg="Partial (#${issue_num}): ${title} — session ${session_status}"
    fi
    git commit -m "$commit_msg"
    git push -u origin "$branch"

    local pr_body
    pr_body="$(cat <<EOF
## Summary
Closes #${issue_num}

${result}

---
*Automated by agent-platform. Session ${session_status}. Verification running; see comments for results.*
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

    if [[ -z "$pr_url" ]]; then
        pr_url="$(gh pr list --head "$branch" --json url --jq '.[0].url')"
    fi

    echo "PR: $pr_url" >&2

    post_issue_comment "$repo_path" "$issue_num" "## Code Pushed — Verifying

PR: ${pr_url}

Session ${session_status}. Verification (install / typecheck / test / build) running now."
    add_label "$repo_path" "$issue_num" "in-progress"
    remove_label "$repo_path" "$issue_num" "approved"

    if [[ $claude_exit -ne 0 ]]; then
        gh pr comment "$pr_url" --body "⚠️ Implementer session ended as **${session_status}**. Code represents partial work — review before relying on it. Verification still runs below." 2>/dev/null || true
        gh pr edit "$pr_url" --add-label "changes-requested" 2>/dev/null || true
    fi

    # ---- Verification phase (script-controlled, per-step timeouts) ----
    local install_cmd typecheck_cmd test_cmd
    install_cmd="$(get_project_config "$repo_path" '.commands.install' 'npm install')"
    typecheck_cmd="$(get_project_config "$repo_path" '.commands.typecheck' '')"
    test_cmd="$(get_project_config "$repo_path" '.commands.test' '')"

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

The code is pushed, but \`${verify_failed_step}\` did not pass. Re-approve the issue to iterate (Claude will see this comment on the PR), or fix locally.

<details><summary>Log (last 6 KB)</summary>

\`\`\`
${log_excerpt}
\`\`\`

</details>"
    fi

    rm -f "$verify_log"
    echo "$pr_url"
}
