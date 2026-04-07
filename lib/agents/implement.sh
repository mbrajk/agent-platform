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

    # Create branch
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

Implement the plan step by step. After writing all code, run the build command to verify:
${build_cmd:+Build command: \`${build_cmd}\`}

Commit your changes with clear, descriptive messages. Do not include AI attribution in commits.

When done, output a summary of what you changed for the PR description.
EOF
)"

    # Invoke Claude (full write access)
    local result
    result="$(invoke_claude \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "Read,Glob,Grep,Edit,Write,Bash(git *),Bash(npm *),Bash(pip *),Bash(python *),Bash(cd *)" \
        30 \
        "$budget"
    )"

    local exit_code=$?
    rm -f "$system_prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: implementer agent failed" >&2
        # Push whatever we have so the failure is visible
        git push origin "$branch" 2>/dev/null || true
        return 1
    fi

    # Push and create PR
    git push -u origin "$branch"

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
    add_label "$repo_path" "$issue_num" "in-progress"
    remove_label "$repo_path" "$issue_num" "approved"

    echo "$pr_url"
}
