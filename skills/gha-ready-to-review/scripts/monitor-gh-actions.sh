#!/usr/bin/env bash
# monitor-gh-actions.sh
# Smart CI monitor for GitHub Actions with progressive file output.
#
# Watches all workflow runs for a PR's HEAD SHA until completion. Outputs to
# both stdout and a file so agents can run it in foreground (blocking) or
# background (async with file polling).
#
# Features:
#   - SHA-aware: waits for runs matching the current HEAD SHA (no stale runs)
#   - Graceful replacement: if another instance overwrites the file header with
#     a new SHA, this instance exits silently
#   - Progressive output: writes run results and review comments as they arrive
#   - Proper exit codes: 0=green, 1=failures, 2=error
#
# Usage:
#   monitor-gh-actions.sh <PR_NUMBER> [options]
#     --output <path>    Output file (default: /tmp/gha-monitor-<PR>.md)
#     --sha <sha>        Expected HEAD SHA (default: derived from PR)
#
# Examples:
#   # Foreground (blocking, see output live, get exit code):
#   ./monitor-gh-actions.sh 1096
#
#   # Background (async, read file later):
#   ./monitor-gh-actions.sh 1096 --output /tmp/agent/ci.md &
#
# Dependencies: gh (GitHub CLI), jq

set -euo pipefail

# --- Argument parsing ---

PR_NUMBER=""
OUTPUT_FILE=""
EXPECTED_SHA=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --sha)
            EXPECTED_SHA="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            if [[ -z "$PR_NUMBER" ]] && [[ "$1" =~ ^[0-9]+$ ]]; then
                PR_NUMBER="$1"
                shift
            else
                echo "Error: unknown argument '$1'" >&2
                echo "Usage: $0 <PR_NUMBER> [--output <path>] [--sha <sha>]" >&2
                exit 2
            fi
            ;;
    esac
done

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number is required." >&2
    echo "Usage: $0 <PR_NUMBER> [--output <path>] [--sha <sha>]" >&2
    exit 2
fi

OUTPUT_FILE="${OUTPUT_FILE:-/tmp/gha-monitor-${PR_NUMBER}.md}"

# --- Resolve repo context ---

REPO_INFO=$(gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"' 2>/dev/null) || {
    echo "Error: could not determine repo context. Run from within a git repo." >&2
    exit 2
}
OWNER="${REPO_INFO%%/*}"
REPO="${REPO_INFO##*/}"

# --- Resolve expected SHA ---

if [[ -z "$EXPECTED_SHA" ]]; then
    EXPECTED_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid --jq '.headRefOid' 2>/dev/null) || {
        echo "Error: could not fetch HEAD SHA for PR #${PR_NUMBER}." >&2
        exit 2
    }
fi

BRANCH=$(gh pr view "$PR_NUMBER" --json headRefName --jq '.headRefName' 2>/dev/null) || {
    echo "Error: could not fetch branch for PR #${PR_NUMBER}." >&2
    exit 2
}

# --- Output helpers ---
# Everything written to the file also goes to stdout (tee pattern).

emit() {
    # Write a line to both the file and stdout.
    local line="$1"
    echo "$line" >> "$OUTPUT_FILE"
    echo "$line"
}

check_replaced() {
    # Check if another instance has taken over by comparing the SHA in the file
    # header. If the SHA has changed, exit silently.
    if [[ -f "$OUTPUT_FILE" ]]; then
        local file_sha
        file_sha=$(sed -n 's/^SHA: //p' "$OUTPUT_FILE" 2>/dev/null | head -1)
        if [[ -n "$file_sha" ]] && [[ "$file_sha" != "$EXPECTED_SHA" ]]; then
            # Another instance with a different SHA has taken over.
            exit 0
        fi
    fi
}

# --- Initialize output file ---
# Overwrite the file with the new header. This is what signals replacement
# to any previously running instance.

cat > "$OUTPUT_FILE" <<EOF
# CI Monitor: PR #${PR_NUMBER} (${BRANCH})
SHA: ${EXPECTED_SHA}
Started: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

# Also print the header to stdout
cat "$OUTPUT_FILE"

# --- Wait for runs matching our SHA ---

emit ""
emit "Waiting for GitHub Actions runs for SHA ${EXPECTED_SHA:0:12}..."

MAX_WAIT=120  # seconds
WAITED=0
ACTIVE_RUNS=""

while [[ -z "$ACTIVE_RUNS" ]]; do
    check_replaced

    ACTIVE_RUNS=$(gh run list --limit 50 --branch "$BRANCH" \
        --json databaseId,headSha,status,name \
        --jq "[.[] | select(.headSha == \"${EXPECTED_SHA}\")] | .[].databaseId" 2>/dev/null) || true

    if [[ -z "$ACTIVE_RUNS" ]]; then
        if [[ $WAITED -ge $MAX_WAIT ]]; then
            emit "Error: no runs found for SHA ${EXPECTED_SHA:0:12} after ${MAX_WAIT}s."
            exit 2
        fi
        sleep 3
        WAITED=$((WAITED + 3))
    fi
done

RUN_COUNT=$(echo "$ACTIVE_RUNS" | wc -l | tr -d ' ')
emit "Monitoring: ${RUN_COUNT} run(s)"
emit ""

# --- Watch runs in parallel ---

FAILED_RUNS=()
PASSED_RUNS=()

# Create a temp directory for per-run status files
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

declare -a WATCH_PIDS
declare -a WATCH_RUN_IDS
declare -a WATCH_RUN_NAMES

for RUN_ID in $ACTIVE_RUNS; do
    RUN_NAME=$(gh run view "$RUN_ID" --json name --jq '.name' 2>/dev/null || echo "Unknown")
    WATCH_RUN_NAMES+=("$RUN_NAME")
    WATCH_RUN_IDS+=("$RUN_ID")

    # Launch a background watcher that writes status to a temp file on completion
    (
        if gh run watch "$RUN_ID" --exit-status > /dev/null 2>&1; then
            echo "SUCCESS" > "${WORK_DIR}/${RUN_ID}.status"
        else
            echo "FAILED" > "${WORK_DIR}/${RUN_ID}.status"
        fi
    ) &
    WATCH_PIDS+=("$!")
done

# Poll for completions and write results progressively as each run finishes
REMAINING=${#WATCH_PIDS[@]}

while [[ $REMAINING -gt 0 ]]; do
    check_replaced
    sleep 5

    for i in "${!WATCH_PIDS[@]}"; do
        PID="${WATCH_PIDS[$i]}"
        RUN_ID="${WATCH_RUN_IDS[$i]}"
        RUN_NAME="${WATCH_RUN_NAMES[$i]}"

        # Skip already-reported runs (PID cleared)
        [[ -z "$PID" ]] && continue

        # Check if this watcher is still running
        if kill -0 "$PID" 2>/dev/null; then
            continue
        fi

        # Watcher finished — collect result
        wait "$PID" 2>/dev/null || true
        STATUS=$(cat "${WORK_DIR}/${RUN_ID}.status" 2>/dev/null || echo "UNKNOWN")

        emit "## Run ${RUN_ID} -- ${RUN_NAME}"

        if [[ "$STATUS" == "SUCCESS" ]]; then
            PASSED_RUNS+=("$RUN_ID")
            emit "Status: SUCCESS"
            emit "Completed: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        else
            FAILED_RUNS+=("$RUN_ID")
            emit "Status: FAILED"
            emit "Completed: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

            # Get failed job logs (last 10 lines per failed job)
            FAILED_JOBS=$(gh api "repos/${OWNER}/${REPO}/actions/runs/${RUN_ID}/jobs" \
                --jq '[.jobs[] | select(.conclusion == "failure") | {id: .id, name: .name}]' 2>/dev/null) || FAILED_JOBS="[]"

            echo "$FAILED_JOBS" | jq -c '.[]' 2>/dev/null | while read -r job; do
                JOB_ID=$(echo "$job" | jq -r '.id')
                JOB_NAME=$(echo "$job" | jq -r '.name')
                emit "### Failed: ${JOB_NAME}"

                LOGS=$(gh api "repos/${OWNER}/${REPO}/actions/jobs/${JOB_ID}/logs" 2>/dev/null | tail -10) || LOGS="(could not fetch logs)"
                emit '```'
                emit "$LOGS"
                emit '```'
            done
        fi

        emit ""

        # Mark this run as reported
        WATCH_PIDS[i]=""
        REMAINING=$((REMAINING - 1))
    done
done

# --- Check review comments ---

check_replaced

emit "## Review Comments"

# shellcheck disable=SC2016
REVIEW_DATA=$(gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            isResolved
            comments(first: 1) {
              nodes {
                author { login }
                body
                path
                line: originalStartLine
              }
            }
          }
        }
      }
    }
  }' -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" 2>/dev/null) || {
    emit "Warning: could not fetch review threads."
    REVIEW_DATA=""
}

UNRESOLVED_COUNT=0
if [[ -n "$REVIEW_DATA" ]]; then
    UNRESOLVED_THREADS=$(echo "$REVIEW_DATA" | jq -c '
        [.data.repository.pullRequest.reviewThreads.nodes[]
         | select(.isResolved == false)
         | .comments.nodes[0]
         | select(. != null)
         | {author: .author.login, path: .path, line: .line, body: .body}]')
    UNRESOLVED_COUNT=$(echo "$UNRESOLVED_THREADS" | jq 'length')

    if [[ "$UNRESOLVED_COUNT" -gt 0 ]]; then
        emit "Status: ${UNRESOLVED_COUNT} unresolved comment(s)"
        emit ""
        echo "$UNRESOLVED_THREADS" | jq -c '.[]' | while read -r thread; do
            T_PATH=$(echo "$thread" | jq -r '.path // "unknown"')
            T_LINE=$(echo "$thread" | jq -r '.line // "N/A"')
            T_AUTHOR=$(echo "$thread" | jq -r '.author // "unknown"')
            T_BODY=$(echo "$thread" | jq -r '.body' | head -3)
            emit "### ${T_PATH}:${T_LINE} (${T_AUTHOR})"
            emit "> ${T_BODY}"
            emit ""
        done
    else
        emit "Status: No unresolved comments"
    fi
else
    emit "Status: Could not check"
fi

emit ""

# --- Summary ---

TOTAL=$((${#PASSED_RUNS[@]} + ${#FAILED_RUNS[@]}))
PASS_COUNT=${#PASSED_RUNS[@]}
FAIL_COUNT=${#FAILED_RUNS[@]}

emit "---"

if [[ $FAIL_COUNT -eq 0 ]] && [[ $UNRESOLVED_COUNT -eq 0 ]]; then
    emit "CI: ${PASS_COUNT}/${TOTAL} passed | Review: clean"
    exit 0
elif [[ $FAIL_COUNT -eq 0 ]]; then
    emit "CI: ${PASS_COUNT}/${TOTAL} passed | Review: ${UNRESOLVED_COUNT} unresolved"
    exit 1
else
    emit "CI: ${PASS_COUNT}/${TOTAL} passed, ${FAIL_COUNT} failed | Review: ${UNRESOLVED_COUNT} unresolved"
    exit 1
fi
