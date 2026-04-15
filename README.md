# readonly-bash-classifier

A Claude Code plugin that auto-approves read-only bash commands, replacing static `Bash(...)` permission patterns with a smart classifier.

## The Problem

Claude Code prompts for permission on every Bash command not in your `allow` list. The typical workaround — adding 30+ `Bash(pattern*)` rules to `settings.json` — is incomplete, fragile, and unmaintainable:

- **Pipe chains not handled** — `git log --oneline | head -10` needs both allowed separately
- **Env var prefixes break matching** — `GH_HOST=foo gh pr list` doesn't match `Bash(gh pr list*)`
- **Ambiguous subcommands over-allow** — `Bash(git branch*)` allows both `git branch -a` (list) and `git branch -D feat` (delete)
- **Git global flags ignored** — `git -C /path log` doesn't match `Bash(git log*)`
- **Per-directory settings don't compose** — every project needs its own config

## What This Plugin Does

Installs a `PreToolUse` hook that runs a classifier before every Bash command:

- **Read-only** → auto-approved silently
- **Uncertain** → falls through to normal permission prompt

The classifier:
- Recognizes **~80 read-only commands** (ls, cat, grep, find, jq, curl, awk, etc.)
- Parses **git subcommand + flags** (`git branch -a` = allow, `git branch -D feat` = prompt)
- Parses **gh subcommands** (pr view = allow, pr create = prompt)
- Handles **pipe chains** — checks every segment of `cmd1 | cmd2 | cmd3`
- Strips **env var prefixes** — `FOO=bar cmd` correctly identifies `cmd`
- Detects **output redirections** — `echo x > file.txt` = prompt
- Detects **dangerous patterns** — rm, mv, docker run, kubectl apply, etc.

### Git flag-level parsing

| Command | Decision | Why |
|---|---|---|
| `git branch` | allow | Listing branches |
| `git branch -a` | allow | Listing all branches |
| `git branch -D feature` | prompt | Deleting a branch |
| `git branch new-feature` | prompt | Creating a branch |
| `git branch --contains abc` | allow | Filtering branches |
| `git tag -l` | allow | Listing tags |
| `git tag v1.0` | prompt | Creating a tag |
| `git remote -v` | allow | Listing remotes |
| `git remote add foo url` | prompt | Adding a remote |
| `git stash list` | allow | Listing stashes |
| `git stash` | prompt | Pushing to stash |
| `git config --list` | allow | Reading config |
| `git config key value` | prompt | Writing config |
| `git fetch --all` | allow | Downloads only |
| `git -C /path log` | allow | Skips -C flag correctly |

## Installation

### From marketplace

```
/plugin marketplace add sumit-nathany/claude-code-readonly-classifier
/plugin install readonly-bash-classifier@readonly-bash-tools
```

### For local development / testing

```bash
claude --plugin-dir /path/to/readonly-classifier-plugin
```

### After installing

Remove any `Bash(...)` patterns from your `permissions.allow` in `settings.json` — the plugin handles all of that now.

## Requirements

- `jq` must be installed (`brew install jq` / `apt install jq`)

## Customizing

Edit `bin/is-readonly.sh`:

- **Add read-only commands**: `READONLY_CMDS` array
- **Add always-readonly git subcommands**: `GIT_ALWAYS_READONLY` array
- **Add dangerous patterns**: `DANGEROUS_PATTERNS` array
- **Add read-only gh patterns**: `READONLY_GH_PATTERNS` array

## What this does NOT cover

MCP tools (Atlassian, Gmail, Slack, etc.) and built-in Claude Code tools (Read, Grep, Glob) are a different tool type and still need static `permissions.allow` entries. See the [companion guide](https://github.com/sumit-nathany/claude-code-readonly-classifier/blob/main/GUIDE.md) for a full reference list.

## License

MIT
