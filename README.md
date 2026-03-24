# gha-workflow-skills

Cross-tool agent skills for GitHub Actions workflow automation. Works with
Claude Code, Gemini CLI, Codex CLI, Google Antigravity, Cursor, and any tool
supporting the SKILL.md format.

## Install

```bash
npx skills add timothyfroehlich/gha-workflow-skills
```

## What's Included

### `gha-ready-to-review`

End-to-end workflow for getting a PR from "just pushed" to "ready for human
review":

1. **Monitor CI** -- watch GitHub Actions runs until complete
2. **Handle review comments** -- fetch, address, reply to, and resolve threads
3. **Label ready** -- verify CI green + reviews clean, apply label

Includes dual-path instructions: MCP-primary (GitHub MCP Server) with
`gh` CLI fallback for maximum compatibility.

### `monitor-gh-actions.sh`

Smart CI monitor script bundled with the skill:

- **SHA-aware**: waits for runs matching the current HEAD SHA (safe after `git push`)
- **Progressive output**: writes results to a file as events happen
- **Parallel watching**: monitors multiple runs simultaneously via `gh run watch`
- **Graceful replacement**: if you push again and restart, old instance exits cleanly
- **Dual output**: writes to both stdout and file (works foreground or backgrounded)

```bash
# Foreground (blocking):
./monitor-gh-actions.sh 1096 --output /tmp/ci.md

# Background (async):
./monitor-gh-actions.sh 1096 --output /tmp/ci.md &
cat /tmp/ci.md  # check status anytime
```

## Requirements

- `gh` (GitHub CLI) authenticated with repo access
- `jq` for JSON processing
- For MCP paths: GitHub MCP Server v0.32.0+

## License

MIT
