#!/usr/bin/env bash
set -euo pipefail

# Onboard a project into the agent-platform pipeline.
# Usage: ./onboard-project.sh <repo> [--repo-path <local-path>]
#
# Examples:
#   ./onboard-project.sh mbrajk/my-project
#   ./onboard-project.sh mbrajk/my-project --repo-path /path/to/local/clone

PLATFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <owner/repo> [--repo-path <local-path>]"
    echo ""
    echo "Onboards a GitHub repo into the agent-platform pipeline."
    echo "Sets up workflow, labels, secrets, and runner registration."
    exit 1
}

[[ $# -eq 0 ]] && usage

REPO="$1"; shift
REPO_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-path) REPO_PATH="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

echo "=== Agent Platform: Onboard Project ==="
echo "Repository: $REPO"
echo ""

# -----------------------------------------------------------------------
# 1. Create GitHub labels
# -----------------------------------------------------------------------
echo "--- Creating labels ---"

declare -A LABELS=(
    ["ready"]="0E8A16:Ready for agent planning"
    ["planned"]="1D76DB:Implementation plan posted"
    ["approved"]="5319E7:Plan approved, ready to implement"
    ["in-progress"]="FBCA04:Agent is implementing"
    ["agent-pr"]="FBCA04:PR created by agent"
    ["changes-requested"]="D93F0B:Review agent requested changes"
    ["ready-for-review"]="0E8A16:All gates passed, ready for human review"
    ["needs-info"]="D4C5F9:Issue needs clarification"
    ["complexity:small"]="C2E0C6:Small complexity (1-3 files)"
    ["complexity:medium"]="FEF2C0:Medium complexity (3-8 files)"
    ["complexity:large"]="F9D0C4:Large complexity (8+ files)"
)

for label in "${!LABELS[@]}"; do
    IFS=':' read -r color desc <<< "${LABELS[$label]}"
    if gh label create "$label" --repo "$REPO" --color "$color" --description "$desc" 2>/dev/null; then
        echo "  Created: $label"
    else
        echo "  Exists:  $label"
    fi
done

# -----------------------------------------------------------------------
# 2. Set secrets
# -----------------------------------------------------------------------
echo ""
echo "--- Setting secrets ---"

# Check if CLAUDE_CODE_OAUTH_TOKEN is already set
if gh secret list --repo "$REPO" 2>/dev/null | grep -q "CLAUDE_CODE_OAUTH_TOKEN"; then
    echo "  CLAUDE_CODE_OAUTH_TOKEN already set."
    read -rp "  Overwrite? (y/N): " overwrite
    if [[ "$overwrite" =~ ^[Yy]$ ]]; then
        read -rsp "  Paste your Claude OAuth token (hidden): " token
        echo ""
        echo "$token" | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$REPO"
        echo "  Updated CLAUDE_CODE_OAUTH_TOKEN"
    fi
else
    read -rsp "  Paste your Claude OAuth token (hidden): " token
    echo ""
    echo "$token" | gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo "$REPO"
    echo "  Set CLAUDE_CODE_OAUTH_TOKEN"
fi

# -----------------------------------------------------------------------
# 3. Copy workflow file
# -----------------------------------------------------------------------
echo ""
echo "--- Setting up workflow ---"

if [[ -z "$REPO_PATH" ]]; then
    # Clone temporarily
    TMPDIR="$(mktemp -d)"
    echo "  Cloning $REPO..."
    gh repo clone "$REPO" "$TMPDIR/repo" -- --depth 1 2>/dev/null
    REPO_PATH="$TMPDIR/repo"
    CLONED=true
else
    CLONED=false
fi

mkdir -p "$REPO_PATH/.github/workflows"
mkdir -p "$REPO_PATH/.agents"

# Copy pipeline workflow
cp "$PLATFORM_DIR/templates/new-project/github-workflows/agent-pipeline.yml" \
   "$REPO_PATH/.github/workflows/agent-pipeline.yml"
echo "  Copied .github/workflows/agent-pipeline.yml"

# Copy agents config template if none exists
if [[ ! -f "$REPO_PATH/.agents/config.yml" ]]; then
    cp "$PLATFORM_DIR/templates/new-project/agents-config.yml" \
       "$REPO_PATH/.agents/config.yml"
    echo "  Copied .agents/config.yml (template — edit with your project details)"
else
    echo "  .agents/config.yml already exists, skipping"
fi

# Create CLAUDE.md if none exists
if [[ ! -f "$REPO_PATH/CLAUDE.md" ]]; then
    cat > "$REPO_PATH/CLAUDE.md" <<'CLAUDEMD'
## Overview
<!-- Describe what this project does -->

## Tech Stack
<!-- e.g., TypeScript + React, Python + FastAPI, etc. -->

## Architecture
<!-- Key files and how they relate -->

## Running
```bash
# How to install, build, and run
```
CLAUDEMD
    echo "  Created CLAUDE.md (template — fill in project details)"
else
    echo "  CLAUDE.md already exists, skipping"
fi

# Commit and push
cd "$REPO_PATH"
git add .github/workflows/agent-pipeline.yml .agents/config.yml CLAUDE.md 2>/dev/null || true
if git diff --cached --quiet 2>/dev/null; then
    echo "  No new files to commit"
else
    git commit -m "Onboard to agent-platform pipeline" 2>/dev/null
    git push 2>/dev/null
    echo "  Committed and pushed"
fi

if [[ "$CLONED" == "true" ]]; then
    rm -rf "$TMPDIR"
fi

# -----------------------------------------------------------------------
# 4. Register runner
# -----------------------------------------------------------------------
echo ""
echo "--- Runner registration ---"

# Check if a self-hosted runner already exists for this repo
RUNNER_COUNT=$(gh api "repos/$REPO/actions/runners" --jq '.total_count' 2>/dev/null || echo "0")

if [[ "$RUNNER_COUNT" -gt 0 ]]; then
    echo "  Runner already registered for $REPO"
    gh api "repos/$REPO/actions/runners" --jq '.runners[] | "  - \(.name) (\(.status))"' 2>/dev/null
else
    echo "  No runner registered. Registering..."
    RUNNER_TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq '.token')

    # Check if Docker is available
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        RUNNER_NAME="agent-$(echo "$REPO" | tr '/' '-')"

        # Stop existing container with same name
        docker rm -f "$RUNNER_NAME" 2>/dev/null || true

        docker run -d --name "$RUNNER_NAME" \
            --user root \
            agent-platform \
            bash -c "
                mkdir -p /tmp/runner /home/agent && cd /tmp/runner &&
                curl -sL https://github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz | tar xz &&
                export RUNNER_ALLOW_RUNASROOT=1 &&
                ./config.sh --url https://github.com/$REPO --token $RUNNER_TOKEN --name $RUNNER_NAME --unattended &&
                chown -R agent:agent /tmp/runner /home/agent /workspace &&
                su agent -c 'cd /tmp/runner && ./run.sh'
            "

        echo "  Waiting for runner to connect..."
        sleep 20

        STATUS=$(docker logs "$RUNNER_NAME" 2>&1 | tail -1)
        if echo "$STATUS" | grep -q "Listening for Jobs"; then
            echo "  Runner '$RUNNER_NAME' is online and listening"
        else
            echo "  Runner may still be starting. Check: docker logs $RUNNER_NAME"
        fi
    else
        echo "  Docker not available. Register manually:"
        echo "  Token: $RUNNER_TOKEN"
        echo "  URL: https://github.com/$REPO"
    fi
fi

# -----------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------
echo ""
echo "=== Onboarding complete ==="
echo ""
echo "Next steps:"
echo "  1. Edit .agents/config.yml with your project's build commands and stack"
echo "  2. Fill in CLAUDE.md with your project's architecture and key files"
echo "  3. Create an issue, label it 'ready', and watch the pipeline run"
echo ""
echo "Pipeline: issue -> 'ready' label -> plan -> 'approved' label -> implement -> review gates -> PR"
