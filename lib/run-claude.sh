#!/usr/bin/env bash
# Invokes Claude Code CLI with assembled prompt and captures output.

invoke_claude() {
    local repo_path="$1"
    local system_prompt_file="$2"
    local user_prompt="$3"
    local allowed_tools="$4"
    local max_turns="$5"
    local budget="$6"

    # Use --bare when ANTHROPIC_API_KEY is set (CI), regular auth otherwise (local)
    local -a cmd=(claude)
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        cmd+=(--bare)
    fi
    cmd+=(
        -p "$user_prompt"
        --append-system-prompt-file "$system_prompt_file"
        --allowedTools "$allowed_tools"
        --max-turns "$max_turns"
        --output-format json
        --model opus
    )

    if [[ -n "$budget" && "$budget" != "0" ]]; then
        cmd+=(--max-budget-usd "$budget")
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== DRY RUN ===" >&2
        echo "Working directory: $repo_path" >&2
        echo "System prompt file: $system_prompt_file" >&2
        echo "User prompt: $user_prompt" >&2
        echo "Allowed tools: $allowed_tools" >&2
        echo "Max turns: $max_turns" >&2
        echo "Budget: $budget" >&2
        echo "" >&2
        echo "--- System Prompt ---" >&2
        cat "$system_prompt_file" >&2
        echo "" >&2
        echo "--- Command ---" >&2
        echo "${cmd[*]}" >&2
        return 0
    fi

    echo "Running agent in $repo_path..." >&2

    local output
    output="$(cd "$repo_path" && "${cmd[@]}" 2>&1)" || true

    # Try to extract the result from JSON output
    if echo "$output" | jq -e '.result' &>/dev/null; then
        echo "$output" | jq -r '.result'
        # Log usage to stderr
        local input_tokens output_tokens
        input_tokens="$(echo "$output" | jq -r '.usage.input_tokens // "?"')"
        output_tokens="$(echo "$output" | jq -r '.usage.output_tokens // "?"')"
        echo "Tokens: ${input_tokens} in / ${output_tokens} out" >&2
        return 0
    else
        # Non-JSON output — probably an error
        echo "$output" >&2
        return 1
    fi
}

# Post a comment on a GitHub issue
post_issue_comment() {
    local repo_path="$1"
    local issue_num="$2"
    local body="$3"

    cd "$repo_path"
    gh issue comment "$issue_num" --body "$body"
}

# Post a PR review
post_pr_review() {
    local repo_path="$1"
    local pr_num="$2"
    local body="$3"
    local action="$4"  # "APPROVE", "REQUEST_CHANGES", "COMMENT"

    cd "$repo_path"
    local gh_action
    gh_action="$(echo "$action" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    # Fall back to comment if review fails (e.g., can't request changes on own PR)
    gh pr review "$pr_num" --body "$body" --"$gh_action" 2>/dev/null || \
        gh pr comment "$pr_num" --body "**[${action}]**"$'\n\n'"$body"
}

# Add a label to an issue
add_label() {
    local repo_path="$1"
    local issue_num="$2"
    local label="$3"

    cd "$repo_path"
    gh issue edit "$issue_num" --add-label "$label" 2>/dev/null || \
        gh pr edit "$issue_num" --add-label "$label" 2>/dev/null || true
}

# Remove a label from an issue
remove_label() {
    local repo_path="$1"
    local issue_num="$2"
    local label="$3"

    cd "$repo_path"
    gh issue edit "$issue_num" --remove-label "$label" 2>/dev/null || \
        gh pr edit "$issue_num" --remove-label "$label" 2>/dev/null || true
}
