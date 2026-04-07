#!/usr/bin/env bash
set -euo pipefail

# Agent Platform Runner
# Usage:
#   ./run-agent.sh plan           --repo /path/to/repo --issue 42
#   ./run-agent.sh implement      --repo /path/to/repo --issue 42
#   ./run-agent.sh review-code    --repo /path/to/repo --pr 15
#   ./run-agent.sh review-ux      --repo /path/to/repo --pr 15
#   ./run-agent.sh review-security --repo /path/to/repo --pr 15
#   ./run-agent.sh build-test     --repo /path/to/repo --pr 15

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/assemble-prompt.sh
source "$PLATFORM_DIR/lib/assemble-prompt.sh"
# shellcheck source=lib/run-claude.sh
source "$PLATFORM_DIR/lib/run-claude.sh"

usage() {
    echo "Usage: $0 <agent> --repo <path> [--issue <num>] [--pr <num>]"
    echo ""
    echo "Agents:"
    echo "  plan              Plan implementation for an issue"
    echo "  implement         Implement an approved plan"
    echo "  review-code       Review PR for code structure"
    echo "  review-ux         Review PR for UX/accessibility"
    echo "  review-security   Review PR for security"
    echo "  build-test        Run build and test verification"
    echo ""
    echo "Options:"
    echo "  --repo <path>     Path to the target repository (required)"
    echo "  --issue <num>     GitHub issue number (for plan/implement)"
    echo "  --pr <num>        GitHub PR number (for review/build-test)"
    echo "  --dry-run         Print assembled prompt without executing"
    echo "  --budget <usd>    Max budget in USD (default: from config or 5.00)"
    exit 1
}

# Parse arguments
AGENT=""
REPO=""
ISSUE=""
PR=""
DRY_RUN=false
BUDGET=""

[[ $# -eq 0 ]] && usage
AGENT="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)    REPO="$2"; shift 2 ;;
        --issue)   ISSUE="$2"; shift 2 ;;
        --pr)      PR="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --budget)  BUDGET="$2"; shift 2 ;;
        *)         echo "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$REPO" ]] && { echo "Error: --repo is required"; usage; }
[[ ! -d "$REPO" ]] && { echo "Error: repo path does not exist: $REPO"; exit 1; }
REPO="$(cd "$REPO" && pwd)"

# Dispatch to agent-specific handler
case "$AGENT" in
    plan)
        [[ -z "$ISSUE" ]] && { echo "Error: --issue is required for plan"; usage; }
        source "$PLATFORM_DIR/lib/agents/plan.sh"
        run_plan_agent "$REPO" "$ISSUE"
        ;;
    implement)
        [[ -z "$ISSUE" ]] && { echo "Error: --issue is required for implement"; usage; }
        source "$PLATFORM_DIR/lib/agents/implement.sh"
        run_implement_agent "$REPO" "$ISSUE"
        ;;
    review-code)
        [[ -z "$PR" ]] && { echo "Error: --pr is required for review-code"; usage; }
        source "$PLATFORM_DIR/lib/agents/review.sh"
        run_review_agent "$REPO" "$PR" "code-reviewer" "code-structure"
        ;;
    review-ux)
        [[ -z "$PR" ]] && { echo "Error: --pr is required for review-ux"; usage; }
        source "$PLATFORM_DIR/lib/agents/review.sh"
        run_review_agent "$REPO" "$PR" "ux-reviewer" "ux-standards"
        ;;
    review-security)
        [[ -z "$PR" ]] && { echo "Error: --pr is required for review-security"; usage; }
        source "$PLATFORM_DIR/lib/agents/review.sh"
        run_review_agent "$REPO" "$PR" "security-analyst" "security-standards"
        ;;
    build-test)
        [[ -z "$PR" ]] && { echo "Error: --pr is required for build-test"; usage; }
        source "$PLATFORM_DIR/lib/agents/build-test.sh"
        run_build_test_agent "$REPO" "$PR"
        ;;
    *)
        echo "Unknown agent: $AGENT"
        usage
        ;;
esac
