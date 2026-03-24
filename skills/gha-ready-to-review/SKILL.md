---
name: gha-ready-to-review
description: Get a PR ready for human review. Monitors CI, addresses automated
  review comments, resolves threads, and labels when ready. Use after pushing
  code or when asked to prepare a PR for review.
---

# GHA Ready to Review

End-to-end workflow for getting a PR from "just pushed" to "ready for human review."

## Workflow Overview

1. **Monitor CI** -- watch GitHub Actions runs until all complete
2. **Handle review comments** -- fetch, address, reply to, and resolve PR review threads
3. **Label ready** -- verify CI green + reviews clean, apply label

## Step 1: Monitor CI

Choose the pattern that matches your capabilities.

### Pattern A: Monitor Script (background -- preferred)

Best for tools that support backgrounding shell commands (Claude Code, etc.).
The script watches CI via streaming connections (most API-efficient) and writes
progressive status to a file.

```bash
# Start monitoring in background; read the file to check status
MONITOR_FILE="/tmp/gha-monitor-<PR>.md"
<skill_path>/scripts/monitor-gh-actions.sh <PR> --output "$MONITOR_FILE" &

# ... do other work (address review comments, etc.) ...

# Check status anytime by reading the file:
cat "$MONITOR_FILE"
```

The script:
- Waits for runs matching the current HEAD SHA (safe after git push)
- Watches all runs in parallel
- Writes results progressively (successes, failures with logs, review comments)
- Exits with code 0 (all green), 1 (failures), or 2 (error)
- If you push again and restart, the old instance exits gracefully

### Pattern B: Monitor Script (foreground -- blocking)

Simpler but blocks until CI completes.

```bash
<skill_path>/scripts/monitor-gh-actions.sh <PR> --output "$MONITOR_FILE"
# Exit code tells you the result: 0=green, 1=failures
```

### Pattern C: MCP Polling (no shell needed)

For tools without shell execution. Poll the GitHub MCP server periodically.

1. Get current run status:
   ```
   actions_list(method: "list_workflow_runs", owner: "<owner>", repo: "<repo>",
     workflow_runs_filter: {branch: "<branch>", status: "in_progress"})
   ```

2. If runs are still in progress, wait ~60 seconds and check again.

3. When completed, check results:
   ```
   pull_request_read(method: "get_check_runs", owner: "<owner>", repo: "<repo>",
     pullNumber: <PR>)
   ```

4. If failures, get logs:
   ```
   get_job_logs(owner: "<owner>", repo: "<repo>", run_id: <run_id>,
     failed_only: true, return_content: true, tail_lines: 50)
   ```

## Step 2: Handle Review Comments

After CI runs (or while waiting), check for and address review comments.

### Fetch review threads

**MCP (preferred):**
```
pull_request_read(method: "get_review_comments", owner: "<owner>", repo: "<repo>",
  pullNumber: <PR>)
```

Returns threads with `isResolved`, `isOutdated`, `isCollapsed` metadata and
their associated comments. Filter to unresolved threads.

**Shell fallback:**
```bash
gh api graphql -f query='
  query($owner: String!, $repo: String!, $pr: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $pr) {
        reviewThreads(first: 100) {
          nodes {
            id
            isResolved
            comments(first: 1) {
              nodes { author { login } body path line: originalStartLine }
            }
          }
        }
      }
    }
  }' -f owner="<owner>" -f repo="<repo>" -F pr=<PR>
```

### Address each comment

For each unresolved review thread:

1. **Read the comment** -- understand what it's asking
2. **Fix the code** if the comment is valid
3. **Reply** to the thread explaining what you did (or why you disagree)
4. **Resolve** the thread

### Reply to a comment

**MCP (preferred):**
```
add_reply_to_pull_request_comment(owner: "<owner>", repo: "<repo>",
  pullNumber: <PR>, commentId: <id>, body: "Fixed: <description>")
```

**Shell fallback:**
```bash
gh api "repos/<owner>/<repo>/pulls/<PR>/comments/<commentId>/replies" \
  -f body="Fixed: <description>"
```

### Resolve a thread

**MCP (preferred):**
```
pull_request_review_write(method: "resolve_thread", owner: "<owner>",
  repo: "<repo>", pullNumber: <PR>, threadId: "PRRT_<node_id>")
```

**Shell fallback:**
```bash
gh api graphql -f query='
  mutation($threadId: ID!) {
    resolveReviewThread(input: {threadId: $threadId}) {
      thread { isResolved }
    }
  }' -f threadId="PRRT_<node_id>"
```

### Rules for handling review comments

- Every comment gets a reply -- no silent fixes or silent ignores
- Keep replies to one sentence
- If a comment is wrong, say why (helps future reviews)
- Evaluate critically -- not all automated suggestions are correct

## Step 3: Label Ready

Once CI is green and all review threads are resolved, label the PR.

### Verify CI status

**MCP:**
```
pull_request_read(method: "get_check_runs", owner: "<owner>", repo: "<repo>",
  pullNumber: <PR>)
```
Check that all check runs have `conclusion: "success"` (ignoring skipped/cancelled).

**Shell:**
```bash
gh pr checks <PR> --json name,state \
  --jq '[.[] | select(.state != "SUCCESS" and .state != "SKIPPED" and .state != "CANCELLED")] | length'
# Should be 0
```

### Verify reviews clean

**MCP:**
```
pull_request_read(method: "get_review_comments", owner: "<owner>", repo: "<repo>",
  pullNumber: <PR>)
```
Filter to unresolved threads. Count should be 0.

**Shell:**
```bash
gh api graphql -f query='...' --jq '[... | select(.isResolved == false)] | length'
# Should be 0
```

### Apply label

```bash
gh pr edit <PR> --add-label "ready-for-review"
```

Note: Adding labels is not available via the GitHub MCP server as of v0.32.0.
Use `gh pr edit` directly.

## Script Reference

### monitor-gh-actions.sh

Located at `scripts/monitor-gh-actions.sh` relative to this skill.

```
Usage: monitor-gh-actions.sh <PR_NUMBER> [options]
  --output <path>    Output file (default: /tmp/gha-monitor-<PR>.md)
  --sha <sha>        Expected HEAD SHA (default: derived from PR)

Exit codes:
  0  All CI passed, reviews clean
  1  CI failures or unresolved review comments
  2  Script error (API unreachable, invalid PR, etc.)
```

**Dependencies:** `gh` (GitHub CLI), `jq`

## Requirements

- GitHub CLI (`gh`) authenticated with repo access
- For MCP paths: GitHub MCP Server v0.32.0+ (for `get_check_runs`, `resolve_thread`)
- For shell paths: `jq` for JSON processing
