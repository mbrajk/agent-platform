#!/usr/bin/env bash
# Build/Test agent: checks out PR branch, runs build/lint/test, posts results.

run_build_test_agent() {
    local repo_path="$1"
    local pr_num="$2"

    echo "Running build/test on PR #${pr_num} in ${repo_path}..." >&2

    cd "$repo_path"

    # Checkout the PR branch
    gh pr checkout "$pr_num"

    # Read commands from project config
    local install_cmd build_cmd lint_cmd typecheck_cmd test_cmd dev_cmd
    install_cmd="$(get_project_config "$repo_path" '.commands.install' '')"
    build_cmd="$(get_project_config "$repo_path" '.commands.build' '')"
    lint_cmd="$(get_project_config "$repo_path" '.commands.lint' '')"
    typecheck_cmd="$(get_project_config "$repo_path" '.commands.typecheck' '')"
    test_cmd="$(get_project_config "$repo_path" '.commands.test' '')"
    dev_cmd="$(get_project_config "$repo_path" '.commands.dev_server' '')"

    local server_port
    server_port="$(get_project_config "$repo_path" '.server.port' '3000')"
    local health_endpoint
    health_endpoint="$(get_project_config "$repo_path" '.server.health_endpoint' '/')"

    # Assemble system prompt
    local system_prompt_file
    system_prompt_file="$(assemble_system_prompt "build-test" "" "$repo_path")"

    local budget
    budget="$(get_budget "$repo_path" "$BUDGET")"

    local user_prompt="$(cat <<EOF
Run the build and test verification for this project. Execute each step and report results.

## Commands to run (skip any that are empty):
- Install: ${install_cmd:-"(not configured)"}
- Build: ${build_cmd:-"(not configured)"}
- Lint: ${lint_cmd:-"(not configured)"}
- Type check: ${typecheck_cmd:-"(not configured)"}
- Test: ${test_cmd:-"(not configured)"}

## Smoke test (if dev server is configured):
- Dev server: ${dev_cmd:-"(not configured)"}
- Port: ${server_port}
- Health endpoint: ${health_endpoint}

Run each configured command. If a command fails, capture the error output (truncated to the relevant part — not 500 lines of webpack noise).

At the end, output a summary table and a JSON verdict:
\`\`\`json
{"verdict": "pass|fail", "build": "pass|fail|skip", "lint": "pass|fail|skip", "typecheck": "pass|fail|skip", "tests": "pass|fail|skip", "smoke": "pass|fail|skip"}
\`\`\`
EOF
)"

    # Invoke Claude (read + execute, no file edits)
    local result
    result="$(invoke_claude \
        "$repo_path" \
        "$system_prompt_file" \
        "$user_prompt" \
        "Read,Glob,Grep,Bash(*)" \
        5 \
        "$budget"
    )"

    local exit_code=$?
    rm -f "$system_prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        echo "Error: build-test agent failed" >&2
        post_pr_review "$repo_path" "$pr_num" "Build/test agent encountered an error and could not complete verification." "COMMENT"
        return 1
    fi

    # Extract verdict
    local verdict
    verdict="$(echo "$result" | grep -oE '"verdict"[[:space:]]*:[[:space:]]*"(pass|fail)"' | grep -oE '(pass|fail)' | tail -1)"
    verdict="${verdict:-fail}"

    local gh_action
    if [[ "$verdict" == "pass" ]]; then
        gh_action="APPROVE"
    else
        gh_action="REQUEST_CHANGES"
    fi

    post_pr_review "$repo_path" "$pr_num" "$result" "$gh_action"

    echo "Build/test complete: ${verdict}" >&2
    [[ "$verdict" == "fail" ]] && return 1
    return 0
}
