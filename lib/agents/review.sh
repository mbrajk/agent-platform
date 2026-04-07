#!/usr/bin/env bash
# Review agent: reads a PR diff, reviews against standards, posts review.
# Shared by code-reviewer, ux-reviewer, and security-analyst.

run_review_agent() {
    local repo_path="$1"
    local pr_num="$2"
    local agent_name="$3"     # "code-reviewer", "ux-reviewer", "security-analyst"
    local rules_name="$4"     # "code-structure", "ux-standards", "security-standards"

    echo "Running ${agent_name} on PR #${pr_num} in ${repo_path}..." >&2

    cd "$repo_path"

    # Fetch PR info
    local pr_json
    pr_json="$(gh pr view "$pr_num" --json title,body,files,additions,deletions)"
    local pr_title pr_files additions deletions
    pr_title="$(echo "$pr_json" | jq -r '.title')"
    pr_files="$(echo "$pr_json" | jq -r '[.files[].path] | join(", ")')"
    additions="$(echo "$pr_json" | jq -r '.additions')"
    deletions="$(echo "$pr_json" | jq -r '.deletions')"

    # Fetch the diff
    local diff
    diff="$(gh pr diff "$pr_num")"

    # For UX reviewer: skip if no frontend files changed
    if [[ "$agent_name" == "ux-reviewer" ]]; then
        local has_ui_files
        has_ui_files="$(echo "$pr_json" | jq '[.files[].path | select(test("\\.(tsx|jsx|css|scss|html|vue|svelte)$"))] | length')"
        if [[ "$has_ui_files" == "0" ]]; then
            echo "No UI files changed — skipping UX review" >&2
            post_pr_review "$repo_path" "$pr_num" "No UI files changed in this PR. UX review not applicable." "APPROVE"
            return 0
        fi
    fi

    # Assemble system prompt
    local system_prompt_file
    system_prompt_file="$(assemble_system_prompt "$agent_name" "$rules_name" "$repo_path")"

    local budget
    budget="$(get_budget "$repo_path" "$BUDGET")"

    local user_prompt="$(cat <<EOF
Review the following pull request.

## PR #${pr_num}: ${pr_title}
**Files changed:** ${pr_files}
**Size:** +${additions} -${deletions} lines

## Diff

\`\`\`diff
${diff}
\`\`\`

---

Review this PR against the standards in your instructions. For each file in the diff, read the full file (not just the diff) to understand context.

At the end of your review, output a JSON verdict:
\`\`\`json
{"verdict": "approve|request_changes|comment", "blocking_issues": 0, "warnings": 0, "suggestions": 0}
\`\`\`

If verdict is "approve", the PR passes this gate.
If verdict is "request_changes", list the specific blocking issues that must be fixed.
EOF
)"

    # UX reviewer with screenshots: enable Chrome MCP + extra tools/turns/budget
    local allowed_tools="Read,Glob,Grep"
    local turns=10
    local settings_file=""

    if [[ "$agent_name" == "ux-reviewer" ]]; then
        local screenshots_enabled
        screenshots_enabled="$(get_project_config "$repo_path" '.agents.ux_reviewer.screenshots | length' '0')"
        if [[ "$screenshots_enabled" != "0" && "$screenshots_enabled" != "null" ]]; then
            settings_file="$PLATFORM_DIR/config/mcp-chrome.json"
            # Add browser tools + bash for starting dev server
            allowed_tools="Read,Glob,Grep,Bash(*),mcp__chrome-devtools__*"
            turns=20
            # Append screenshot instructions to prompt
            local screenshot_urls
            screenshot_urls="$(get_project_config "$repo_path" '.agents.ux_reviewer.screenshots' '')"
            local dev_cmd
            dev_cmd="$(get_project_config "$repo_path" '.commands.dev_server' '')"
            user_prompt="${user_prompt}

## Visual Review
${dev_cmd:+Start the dev server with: \`${dev_cmd}\`}
Then use the Chrome DevTools tools to:
1. Navigate to each page that was affected by this PR
2. Take screenshots at 375px (mobile) and 1440px (desktop) widths
3. Check for visual regressions, overflow, alignment issues, contrast
4. Include the screenshots in your review (describe what you see)
5. Stop the dev server when done"
        fi
    fi

    # Invoke Claude
    local result
    result="$(invoke_claude \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "$allowed_tools" \
        "$turns" \
        "$budget" \
        "$settings_file"
    )"

    local exit_code=$?
    rm -f "$system_prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: ${agent_name} failed" >&2
        post_pr_review "$repo_path" "$pr_num" "Review agent (${agent_name}) encountered an error and could not complete the review." "COMMENT"
        return 1
    fi

    # Extract verdict
    local verdict
    verdict="$(echo "$result" | grep -oE '"verdict"[[:space:]]*:[[:space:]]*"(approve|request_changes|comment)"' | grep -oE '(approve|request_changes|comment)' | tail -1)"
    verdict="${verdict:-comment}"

    # Map verdict to GH review action
    local gh_action
    case "$verdict" in
        approve)          gh_action="APPROVE" ;;
        request_changes)  gh_action="REQUEST_CHANGES" ;;
        *)                gh_action="COMMENT" ;;
    esac

    post_pr_review "$repo_path" "$pr_num" "$result" "$gh_action"

    echo "${agent_name} review complete: ${verdict}" >&2

    # Return non-zero if changes requested (for workflow gate logic)
    [[ "$verdict" == "request_changes" ]] && return 1
    return 0
}
