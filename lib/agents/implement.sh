#!/usr/bin/env bash
# Implementer agent: reads an approved plan, writes code, creates a PR.
# Claude handles: reading files, writing files, running build.
# Script handles: branch creation, git add/commit, push, PR creation.

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

    # Create branch (deterministic — script handles git)
    local slug
    slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40)"
    local branch_prefix
    branch_prefix="$(get_project_config "$repo_path" '.branching.prefix' 'agent/')"
    local base_branch
    base_branch="$(get_project_config "$repo_path" '.branching.base' 'main')"
    local branch="${branch_prefix}${issue_num}-${slug}"

    cd "$repo_path"
    git checkout "$base_branch"
    git pull origin "$base_branch"
    git checkout -b "$branch"

    # Assemble system prompt
    local system_prompt_file
    system_prompt_file="$(assemble_system_prompt "implementer" "code-structure" "$repo_path")"

    local budget
    budget="$(get_budget "$repo_path" "$BUDGET")"

    local build_cmd
    build_cmd="$(get_project_config "$repo_path" '.commands.build' '')"

    # Claude only writes files and runs build — no git, no gh
    local user_prompt="$(cat <<EOF
You are implementing the following GitHub issue. An approved plan is provided below — follow it closely.

## Issue #${issue_num}: ${title}

${body}

## Approved Implementation Plan

${comments}

---

Implement the plan step by step:
1. Read each file before modifying it
2. Write tests first based on acceptance criteria (if any in the plan)
3. Implement the changes
4. Run the build to verify: ${build_cmd:+\`${build_cmd}\`}
5. Fix any build errors

Do NOT run any git commands. Do NOT create commits. Do NOT push. Do NOT create PRs.
Just write the code and verify it builds.

When done, output a brief summary of what you changed.
EOF
)"

    # Claude: read, write, and build only
    local result
    result="$(invoke_claude \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "Read,Glob,Grep,Edit,Write,Bash(npm *),Bash(npx *),Bash(node *),Bash(python *),Bash(pip *)" \
        30 \
        "$budget"
    )"

    local exit_code=$?
    rm -f "$system_prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: implementer agent failed" >&2
        post_issue_comment "$repo_path" "$issue_num" "## Implementation Failed

The implementer agent encountered an error. Check the workflow logs for details."
        return 1
    fi

    # Script handles all git/gh operations (deterministic)
    cd "$repo_path"

    # Stage and commit all changes
    git add -A
    if git diff --cached --quiet; then
        echo "No changes made by agent" >&2
        post_issue_comment "$repo_path" "$issue_num" "## No Changes

The implementer agent completed but made no file changes."
        return 1
    fi

    git commit -m "Implement #${issue_num}: ${title}"

    # Push branch
    git push -u origin "$branch"

    # Create draft PR
    local pr_body="$(cat <<EOF
## Summary
Closes #${issue_num}

${result}

---
*Automated by agent-platform*
EOF
)"

    local pr_url
    pr_url="$(gh pr create \
        --base "$base_branch" \
        --head "$branch" \
        --title "$title" \
        --body "$pr_body" \
        --label "agent-pr" \
        --draft)"

    echo "PR created: $pr_url" >&2

    # Update issue labels
    post_issue_comment "$repo_path" "$issue_num" "## Implementation Complete

PR created: ${pr_url}

${result}"
    add_label "$repo_path" "$issue_num" "in-progress"
    remove_label "$repo_path" "$issue_num" "approved"

    echo "$pr_url"
}
