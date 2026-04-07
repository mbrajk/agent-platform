#!/usr/bin/env bash
# Planner agent: reads an issue, explores the codebase, posts an implementation plan.

run_plan_agent() {
    local repo_path="$1"
    local issue_num="$2"

    echo "Planning issue #${issue_num} in ${repo_path}..." >&2

    # Fetch issue content
    local issue_json
    issue_json="$(cd "$repo_path" && gh issue view "$issue_num" --json title,body,labels)"
    local title body
    title="$(echo "$issue_json" | jq -r '.title')"
    body="$(echo "$issue_json" | jq -r '.body // ""')"

    # Assemble system prompt: planner agent + code-structure rules (for awareness)
    local system_prompt_file
    system_prompt_file="$(assemble_system_prompt "planner" "code-structure" "$repo_path")"

    local budget
    budget="$(get_budget "$repo_path" "$BUDGET")"

    # Build the user prompt
    local user_prompt="$(cat <<EOF
You are planning the implementation for the following GitHub issue.

## Issue #${issue_num}: ${title}

${body}

---

Explore the codebase thoroughly, then post your implementation plan following the format defined in your agent instructions. Be specific — reference exact file paths, function names, and line numbers.

After writing the plan, output a single JSON block at the very end with your assessment:
\`\`\`json
{"complexity": "small|medium|large", "plan_summary": "one line summary"}
\`\`\`
EOF
)"

    # Invoke Claude (read-only tools only)
    local result
    result="$(invoke_claude \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "Read,Glob,Grep" \
        20 \
        "$budget"
    )"

    local exit_code=$?
    rm -f "$system_prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: planner agent failed" >&2
        return 1
    fi

    # Post the plan as an issue comment
    post_issue_comment "$repo_path" "$issue_num" "$result"

    # Extract complexity and add labels
    local complexity
    complexity="$(echo "$result" | grep -oE '"complexity"[[:space:]]*:[[:space:]]*"(small|medium|large)"' | grep -oE '(small|medium|large)' | tail -1)"

    if [[ -n "$complexity" ]]; then
        add_label "$repo_path" "$issue_num" "complexity:${complexity}"
    fi
    add_label "$repo_path" "$issue_num" "planned"
    remove_label "$repo_path" "$issue_num" "ready"

    # Auto-approve small tasks if configured
    local auto_approve
    auto_approve="$(get_project_config "$repo_path" '.agents.planner.auto_approve_complexity[]' '')"
    if [[ "$auto_approve" == *"$complexity"* && -n "$complexity" ]]; then
        echo "Auto-approving ${complexity} complexity task" >&2
        add_label "$repo_path" "$issue_num" "approved"
    fi

    echo "Plan posted for issue #${issue_num} (complexity: ${complexity:-unknown})" >&2
}
