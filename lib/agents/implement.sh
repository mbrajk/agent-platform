#!/usr/bin/env bash
# Implementer agent: reads an approved plan, writes code, creates a PR.

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
    # Get the most recent comment that contains "Implementation Plan" (the approved plan)
    comments="$(echo "$issue_json" | jq -r '[.comments[] | select(.body | contains("Implementation Plan"))] | last | .body // ""')"

    if [[ -z "$comments" || "$comments" == "null" ]]; then
        echo "Error: no approved plan found in issue #${issue_num} comments" >&2
        return 1
    fi

    # Determine branch name
    local slug
    slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | head -c 40)"
    local branch_prefix
    branch_prefix="$(get_project_config "$repo_path" '.branching.prefix' 'agent/')"
    local base_branch
    base_branch="$(get_project_config "$repo_path" '.branching.base' 'main')"
    local branch="${branch_prefix}${issue_num}-${slug}"

    cd "$repo_path"

    # Assemble system prompt: implementer agent + code-structure rules
    local system_prompt_file
    system_prompt_file="$(assemble_system_prompt "implementer" "code-structure" "$repo_path")"

    local budget
    budget="$(get_budget "$repo_path" "$BUDGET")"

    # Build commands info from config
    local build_cmd
    build_cmd="$(get_project_config "$repo_path" '.commands.build' '')"

    local user_prompt="$(cat <<EOF
You are implementing the following GitHub issue. An approved plan is provided below — follow it closely.

## Issue #${issue_num}: ${title}

${body}

## Approved Implementation Plan

${comments}

---

## Instructions

1. Create and switch to branch: ${branch} (from ${base_branch})
2. Write tests first based on the acceptance criteria in the plan
3. Implement the plan step by step
4. Run the build command to verify: ${build_cmd:+\`${build_cmd}\`}
5. Commit your changes with clear, descriptive messages (no AI attribution)
6. Push the branch: git push -u origin ${branch}
7. Create a draft PR: gh pr create --base ${base_branch} --head ${branch} --title "${title}" --label "agent-pr" --draft --body "Closes #${issue_num}"

Do all of these steps. The PR creation is the final step — do not skip it.
EOF
)"

    # Invoke Claude (full write access including git push and gh pr create)
    local result
    result="$(invoke_claude \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "Read,Glob,Grep,Edit,Write,Bash(*)" \
        30 \
        "$budget"
    )"

    local exit_code=$?
    rm -f "$system_prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: implementer agent failed" >&2
        return 1
    fi

    # Post summary to issue
    post_issue_comment "$repo_path" "$issue_num" "## Implementation Complete

${result}"

    add_label "$repo_path" "$issue_num" "in-progress"
    remove_label "$repo_path" "$issue_num" "approved"

    echo "Implementation complete for issue #${issue_num}" >&2
}
