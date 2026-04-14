#!/usr/bin/env bash
# Invokes Claude Code CLI with assembled prompt and captures output.
#
# Uses --output-format stream-json --verbose so every tool call and assistant
# message streams live. The raw stream is captured to a tempfile for final
# result extraction; a human-readable view is piped to stderr so workflow
# logs (gh run watch) show Claude's activity in real time.

# Formats Claude's JSONL stream into readable one-line summaries on stdout.
# Invalid / non-JSON lines pass through unchanged.
format_claude_stream() {
    while IFS= read -r line; do
        if [[ "$line" =~ ^\{ ]]; then
            echo "$line" | jq -r '
                if .type == "system" then
                    "[claude] session \((.session_id // "")[0:8])... model=\(.model // "?")"
                elif .type == "assistant" then
                    (.message.content // [] | map(
                        if .type == "text" then
                            "[claude] \((.text // "") | gsub("\n";" ") | .[0:500])"
                        elif .type == "tool_use" then
                            "[tool ]  \(.name) \((.input // {}) | tostring | .[0:200])"
                        else empty end
                    ) | .[])
                elif .type == "user" then
                    (.message.content // [] | map(
                        if .type == "tool_result" then
                            "[rslt ]  \(
                                if (.content | type) == "array"
                                then (.content | map(select(.type=="text") | .text) | join(" "))
                                else (.content // "" | tostring)
                                end | gsub("\n";" ") | .[0:300]
                            )"
                        else empty end
                    ) | .[])
                elif .type == "result" then
                    "[done ]  duration=\(.duration_ms // 0)ms cost=$\(.total_cost_usd // 0) tokens_in=\(.usage.input_tokens // 0) tokens_out=\(.usage.output_tokens // 0) turns=\(.num_turns // 0)"
                else empty end
            ' 2>/dev/null || echo "$line"
        else
            echo "$line"
        fi
    done
}

invoke_claude() {
    local repo_path="$1"
    local system_prompt_file="$2"
    local user_prompt="$3"
    local allowed_tools="$4"
    local max_turns="$5"
    local budget="$6"
    local model="${7:-sonnet}"
    local settings_file="${8:-}"  # Optional: path to settings JSON (e.g., MCP config)

    local -a cmd=(claude)
    # In CI: skip permission prompts (container provides isolation)
    if [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ]]; then
        cmd+=(--dangerously-skip-permissions)
    fi
    cmd+=(
        -p "$user_prompt"
        --append-system-prompt-file "$system_prompt_file"
        --allowedTools "$allowed_tools"
        --max-turns "$max_turns"
        --output-format stream-json
        --verbose
        --model "$model"
    )

    if [[ -n "$budget" && "$budget" != "0" ]]; then
        cmd+=(--max-budget-usd "$budget")
    fi

    if [[ -n "$settings_file" && -f "$settings_file" ]]; then
        cmd+=(--settings "$settings_file")
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

    local raw_file
    raw_file="$(mktemp)"

    # Run Claude. Raw stream → tempfile. Formatted view → stderr (live in logs).
    # pipefail so we can recover Claude's exit code from PIPESTATUS.
    set -o pipefail
    (cd "$repo_path" && "${cmd[@]}") 2> >(tee -a "$raw_file" >&2) \
        | tee -a "$raw_file" \
        | format_claude_stream >&2
    local exit_code=${PIPESTATUS[0]}
    set +o pipefail

    # Extract the final result event (stream-json emits a line with type="result")
    local result_line
    result_line="$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$raw_file" | tail -1)"

    if [[ -n "$result_line" ]] && echo "$result_line" | jq -e '.result' &>/dev/null; then
        echo "$result_line" | jq -r '.result'
        local input_tokens output_tokens cost
        input_tokens="$(echo "$result_line" | jq -r '.usage.input_tokens // "?"')"
        output_tokens="$(echo "$result_line" | jq -r '.usage.output_tokens // "?"')"
        cost="$(echo "$result_line" | jq -r '.total_cost_usd // "?"')"
        echo "Tokens: ${input_tokens} in / ${output_tokens} out · Cost: \$${cost}" >&2
        rm -f "$raw_file"
        return 0
    else
        echo "Error: no result event in Claude stream (exit ${exit_code})" >&2
        echo "--- Last 2KB of stream ---" >&2
        tail -c 2000 "$raw_file" >&2
        rm -f "$raw_file"
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
