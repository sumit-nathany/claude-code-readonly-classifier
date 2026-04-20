# readonly-bash-classifier

A Claude Code plugin that auto-approves read-only bash commands, replacing static `Bash(...)` permission patterns with an AST-based classifier.

**Current version:** 1.1.0 — parses every command into an AST via [`shfmt`](https://github.com/mvdan/sh) and inspects every simple command in the tree, including those hidden inside pipes, `&&`/`||`/`;` chains, subshells, command substitution, process substitution, and control-flow bodies. A 115-case test suite (positive + negative-safety + adversarial-input) guards against regressions. See [`bin/test.sh`](bin/test.sh).

## The Problem

Claude Code prompts for permission on every Bash command not in your `allow` list. The typical workaround — adding 30+ `Bash(pattern*)` rules to `settings.json` — is incomplete, fragile, and unmaintainable:

- **Pipe chains not handled** — `git log --oneline | head -10` needs both allowed separately
- **Env var prefixes break matching** — `GH_HOST=foo gh pr list` doesn't match `Bash(gh pr list*)`
- **Ambiguous subcommands over-allow** — `Bash(git branch*)` allows both `git branch -a` (list) and `git branch -D feat` (delete)
- **Git global flags ignored** — `git -C /path log` doesn't match `Bash(git log*)`
- **Control flow, subshells, substitutions** — impossible to express with prefix patterns

## How It Works

Installs a `PreToolUse` hook that runs before every Bash command. The classifier:

1. **Parses the command into an AST** using `shfmt -tojson`.
2. **Walks every `CallExpr`** (simple command) in the tree — including those inside pipes, `&&`/`||`/`;` chains, subshells, command substitution (`$(...)`, backticks), and control-flow bodies (`if/for/while/case`).
3. **Inspects all redirects** anywhere in the tree. Any write redirect (`>` or `>>`) to a target that isn't `/dev/null` → not read-only.
4. **Classifies each simple command** against an opinionated read-only taxonomy:
   - ~80 known read-only commands (ls, cat, grep, find, jq, curl, awk, etc.)
   - Git subcommand + flag awareness (`git branch -a` = allow, `git branch -D feat` = prompt)
   - gh subcommand awareness (pr view = allow, pr create = prompt)
   - `tee`/`xargs` with file/command args → prompt
5. **All-or-nothing**: every simple command must be read-only for the whole command to auto-approve. Otherwise falls through to the normal permission prompt.

If the command fails to parse, the classifier stays silent — the default permission flow handles it.

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

### Compound command examples

| Command | Decision |
|---|---|
| `ls \| grep foo \| wc -l` | allow |
| `git log --oneline \| head` | allow |
| `ls && rm file` | prompt (second segment writes) |
| `cat $(find . -name "*.md")` | allow |
| `if git diff --quiet; then echo clean; fi` | allow |
| `echo data > file.txt` | prompt (write redirect) |
| `echo data > /dev/null` | allow |
| `"ls \| pipe inside string"` | allow (string contents not parsed as separator) |

## How This Differs From Auto Mode

Claude Code's Auto Mode uses an LLM classifier to decide which actions are safe to auto-run. It is not a blanket "approve everything" switch — but it is probabilistic. Anthropic's own [launch post](https://www.anthropic.com/engineering/claude-code-auto-mode) documents a **17% false-negative rate on real overeager actions**: roughly 1 in 6 genuinely dangerous commands that the classifier should have blocked, it approved and let run. Auto Mode also auto-approves all in-project file writes without calling the classifier at all.

This plugin is deterministic and narrower by design:

|   | Auto Mode | This plugin |
|---|---|---|
| Decision model | LLM classifier, per action | Static taxonomy in `is-readonly.sh` |
| Auto-approves writes? | Yes — in-project writes bypass the classifier; other writes evaluated by LLM | Never. Any write → prompt |
| Approves shell commands? | Classifier decides (17% FN rate on dangerous actions) | Only if every simple command in the AST is in the read-only taxonomy |
| Unknown / novel command | Classifier guesses | Prompts |
| Auditable by reading the code? | Classifier is an LLM | Flat shell script + a jq pipeline |

**The niche:** if you're tired of approving `ls` and `git diff` dozens of times a day, but you don't want an LLM deciding on your behalf whether a write is safe, this plugin is the middle ground. It auto-approves *only* the provably safe bulk (reads, queries, lookups). Anything that can change state — any write, any destructive op, any unknown command — falls through to Claude Code's normal permission flow.

**The two compose.** If you run Auto Mode, install this plugin too — it handles the read-only bulk deterministically (faster, no classifier latency), so Auto Mode's classifier only fires for commands that might actually do something. If you don't run Auto Mode, this plugin gives you most of Auto Mode's ergonomic benefit without the LLM trust surface.

## Prior Art

[`oryband/claude-code-auto-approve`](https://github.com/oryband/claude-code-auto-approve) independently arrived at the same AST-parsing approach (shfmt + jq) for compound Bash commands. The key difference: oryband's plugin delegates the actual per-command decision to your existing `permissions.allow` / `permissions.deny` lists (you maintain the allowlist, it handles the parsing). This plugin ships an opinionated built-in taxonomy — no allowlist required. Pick whichever matches how you want to work.

## Installation

### Quick install (copy-paste both lines into Claude Code)

```
/plugin marketplace add sumit-nathany/claude-code-readonly-classifier
/plugin install readonly-bash-classifier@readonly-bash-tools
```

The first command registers this repo as a marketplace; the second installs the plugin from it. Both together are needed because Claude Code does not currently support true one-click install from arbitrary GitHub repos — the only single-command install path is via the official Anthropic marketplace, which requires review (submission to that marketplace is planned).

### Local development / testing

```bash
claude --plugin-dir /path/to/readonly-classifier-plugin
```

### After installing

Remove any `Bash(...)` patterns from `permissions.allow` in `settings.json` — the plugin handles all of that now.

## Requirements

- `jq` — `brew install jq` / `apt install jq`
- `shfmt` — `brew install shfmt` / `apt install shfmt` (or see [shfmt releases](https://github.com/mvdan/sh/releases))

## Testing

A fixture-based test suite covers 115 cases, split between:

- **Positive cases** (~55): read-only commands that MUST auto-approve — regression guard against becoming too strict.
- **Negative safety cases** (~54): destructive or ambiguous commands that MUST prompt, including destructive commands hidden inside pipes, `&&`/`||`/`;` chains, subshells `$(...)`, process substitution `<(...)`, and control-flow bodies.
- **Adversarial input** (~10): malformed bash, invalid JSON stdin, missing fields — must fall through silently, never crash.

Run:

```bash
bin/test.sh
```

Please re-run after any change to `bin/is-readonly.sh`. The test script exits non-zero on any failure.

## Customizing

Edit `bin/is-readonly.sh`:

- **Add read-only commands**: `READONLY_CMDS` array
- **Add always-readonly git subcommands**: `GIT_ALWAYS_READONLY` array
- **Add dangerous base commands**: `DANGEROUS_BASE_CMDS` array
- **Add read-only gh patterns**: `READONLY_GH_PATTERNS` array

## What this does NOT cover

MCP tools (Atlassian, Gmail, Slack, etc.) and built-in Claude Code tools (Read, Grep, Glob) are a different tool type and still need static `permissions.allow` entries. A separate MCP-focused plugin is planned.

## License

MIT
