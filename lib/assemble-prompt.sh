#!/usr/bin/env bash
# Assembles system prompt files for agent execution.
# Sources agent definition + relevant rules + project config into a temp file.

assemble_system_prompt() {
    local agent_name="$1"    # e.g., "planner", "code-reviewer"
    local rules_name="$2"    # e.g., "code-structure", "" for none
    local repo_path="$3"

    local prompt_file
    prompt_file="$(mktemp)"

    # 1. Agent definition
    local agent_file="$PLATFORM_DIR/agents/${agent_name}.md"
    if [[ -f "$agent_file" ]]; then
        echo "# Agent Definition" >> "$prompt_file"
        echo "" >> "$prompt_file"
        cat "$agent_file" >> "$prompt_file"
        echo "" >> "$prompt_file"
    else
        echo "Error: agent definition not found: $agent_file" >&2
        return 1
    fi

    # 2. Rules (if specified)
    if [[ -n "$rules_name" ]]; then
        local rules_file="$PLATFORM_DIR/rules/${rules_name}.md"
        if [[ -f "$rules_file" ]]; then
            echo "---" >> "$prompt_file"
            echo "# Standards Reference" >> "$prompt_file"
            echo "" >> "$prompt_file"
            cat "$rules_file" >> "$prompt_file"
            echo "" >> "$prompt_file"
        fi
    fi

    # 3. Project config (.agents/config.yml)
    local config_file="$repo_path/.agents/config.yml"
    if [[ -f "$config_file" ]]; then
        echo "---" >> "$prompt_file"
        echo "# Project Configuration" >> "$prompt_file"
        echo "" >> "$prompt_file"
        echo '```yaml' >> "$prompt_file"
        cat "$config_file" >> "$prompt_file"
        echo '```' >> "$prompt_file"
        echo "" >> "$prompt_file"
    fi

    echo "$prompt_file"
}

# Get a value from the project's .agents/config.yml
# Falls back to a default if not found.
get_project_config() {
    local repo_path="$1"
    local key="$2"
    local default="$3"

    local config_file="$repo_path/.agents/config.yml"
    if [[ -f "$config_file" ]] && command -v yq &>/dev/null; then
        local val
        val="$(yq -r "$key // \"\"" "$config_file" 2>/dev/null)"
        if [[ -n "$val" && "$val" != "null" ]]; then
            echo "$val"
            return
        fi
    fi
    echo "$default"
}

# Get budget from config or use default
get_budget() {
    local repo_path="$1"
    local override="$2"

    if [[ -n "$override" ]]; then
        echo "$override"
    else
        get_project_config "$repo_path" ".budget_per_agent_usd" "5.00"
    fi
}
