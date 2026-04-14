#!/usr/bin/env bash
# agent-bash: a thin wrapper for agents to use when running verbose commands.
# Purpose: keep noisy tool output (npm install, vite build, test runs) out of
# Claude's context window unless the command fails.
#
# Usage:
#   agent-bash <label> <timeout-seconds> -- <command...>
#
# Behavior:
#   - Runs the command with the given timeout.
#   - On success (exit 0):
#       Prints "[<label>] OK (<duration>s, <N> lines elided)" plus the FIRST 5
#       and LAST 5 lines of output. Claude sees a bounded summary.
#   - On failure (non-zero):
#       Prints the FULL output so Claude has everything it needs to debug.
#   - On timeout (exit 124):
#       Prints "[<label>] TIMED OUT after <timeout>s" plus the last 40 lines.
#
# Agents are instructed (via system prompt) to prefer this wrapper over raw
# `npm test`/`npm run build`/`npm install` so the tokens spent in Claude's
# context are on signal, not log noise.

set -u

LABEL="${1:-cmd}"
shift || true
TO="${1:-120}"
shift || true

# Expect `--` separator before the actual command for clarity, but don't require it.
if [[ "${1:-}" == "--" ]]; then
    shift
fi

if [[ $# -eq 0 ]]; then
    echo "agent-bash: usage: agent-bash <label> <timeout-seconds> -- <command...>" >&2
    exit 2
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

START=$(date +%s)
timeout "$TO" "$@" >"$TMP" 2>&1
CODE=$?
END=$(date +%s)
DUR=$((END - START))

LINES=$(wc -l < "$TMP" 2>/dev/null || echo 0)

if [[ $CODE -eq 0 ]]; then
    echo "[${LABEL}] OK (${DUR}s, ${LINES} lines — eliding middle)"
    if (( LINES <= 20 )); then
        cat "$TMP"
    else
        head -n 5 "$TMP"
        echo "... ($((LINES - 10)) lines elided) ..."
        tail -n 5 "$TMP"
    fi
    exit 0
fi

if [[ $CODE -eq 124 ]]; then
    echo "[${LABEL}] TIMED OUT after ${TO}s — last 40 lines of output:"
    tail -n 40 "$TMP"
    exit 124
fi

echo "[${LABEL}] FAILED (exit ${CODE}, ${DUR}s, ${LINES} lines):"
cat "$TMP"
exit "$CODE"
