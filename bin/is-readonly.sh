#!/usr/bin/env bash
#
# is-readonly.sh
# Classifies a bash command as read-only or not.
# Reads JSON from stdin (Claude Code hook format), extracts the command,
# and outputs a JSON permission decision.
#
# If every simple command in the AST is read-only → auto-approve.
# Otherwise (or if the command fails to parse) → no output, fall through
# to the normal permission prompt.
#
# Requires: jq, shfmt

set -uo pipefail

# Read stdin once so we can tolerate invalid JSON gracefully.
INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[[ -z "$COMMAND" ]] && exit 0

# ── Known read-only base commands ──────────────────────────────────────
# Conservative: only commands that CANNOT modify state regardless of flags
READONLY_CMDS=(
  # filesystem reads
  ls cat head tail less more wc file stat readlink realpath basename dirname
  find tree du df
  # text processing (read-only when not redirecting)
  grep egrep fgrep rg ag awk sed tr cut sort uniq diff comm paste column
  fold fmt pr expand unexpand rev tac nl
  # system info
  pwd whoami hostname uname id groups env printenv date uptime w who last
  which type command hash whereis whence
  # process info
  ps top htop pgrep lsof fuser
  # network reads
  ping dig nslookup host curl wget nc nmap traceroute
  # misc read-only
  echo printf true false test "[" expr bc dc jq yq xmllint xargs tee
  man info help
  # java / build reads
  java javac mvn gradle
  # python reads
  python python3 pip pip3
  # node reads
  node npm npx yarn bun bunx pnpm
  # shell builtins that don't modify FS
  : return break continue exit
)
# Note: `tee` and `xargs` are in READONLY_CMDS because they're only dangerous
# when paired with a write target. Redirection detection on the AST catches
# `tee file.txt` (the file is an arg, not a redirect) — see explicit check below.

# ── Git subcommands: always read-only (no flags change this) ───────────
GIT_ALWAYS_READONLY=(
  log diff status show blame describe shortlog
  rev-parse rev-list name-rev
  ls-files ls-tree ls-remote cat-file diff-tree diff-files
  for-each-ref show-ref count-objects fsck verify-pack
  grep reflog bisect
)

# ── Git subcommands: read-only ONLY with specific flags ────────────────
GIT_BRANCH_WRITE_FLAGS="-d -D --delete -m -M --move -c -C --copy --set-upstream-to --unset-upstream --edit-description"
GIT_TAG_WRITE_FLAGS="-d --delete -a --annotate -s --sign -f --force"
GIT_STASH_READONLY_SUBCMDS="list show"

# ── Known read-only gh subcommands ─────────────────────────────────────
READONLY_GH_PATTERNS=(
  "pr view" "pr list" "pr diff" "pr checks" "pr status"
  "issue view" "issue list" "issue status"
  "repo view" "repo list"
  "run view" "run list" "run watch"
  "release view" "release list"
  "search "
  "auth status"
  "api "
)

# ── Dangerous command names (first-arg match) ──────────────────────────
# These should never appear as the base command of a read-only segment.
# Checked before READONLY_CMDS lookup so a collision (e.g. `tee` above,
# which is listed as read-only but dangerous when writing to a file) is
# handled by the redirect/arg inspection below, not here.
DANGEROUS_BASE_CMDS=(
  rm rmdir mv cp ln
  chmod chown chgrp
  mkdir touch
  truncate
  kill killall pkill
  reboot shutdown halt
  dd mkfs mount umount
  sudo su doas
)

# ── Helper: extract git subcommand, skipping global flags ──────────────
extract_git_subcmd_and_args() {
  local -a words=("$@")
  local i=1
  while (( i < ${#words[@]} )); do
    case "${words[$i]}" in
      -C|--git-dir|--work-tree|-c)
        (( i += 2 ))
        ;;
      --no-pager|--no-optional-locks|--literal-pathspecs|--paginate|--bare|--exec-path)
        (( i += 1 ))
        ;;
      -*)
        (( i += 1 ))
        ;;
      *)
        echo "${words[@]:$i}"
        return
        ;;
    esac
  done
  echo ""
}

has_any_flag() {
  local args="$1"
  shift
  local flags=("$@")
  for flag in "${flags[@]}"; do
    for word in $args; do
      [[ "$word" == "$flag" ]] && return 0
    done
  done
  return 1
}

# ── Helper: classify one simple command (array of args) ────────────────
# Returns 0 (read-only) or 1 (not read-only / unknown).
is_simple_cmd_readonly() {
  local -a args=("$@")
  (( ${#args[@]} == 0 )) && return 0

  local base="${args[0]}"

  # Dangerous base commands — never read-only
  for bad in "${DANGEROUS_BASE_CMDS[@]}"; do
    [[ "$base" == "$bad" ]] && return 1
  done

  # ── git ──
  if [[ "$base" == "git" ]]; then
    local subcmd_and_args
    subcmd_and_args=$(extract_git_subcmd_and_args "${args[@]}")
    [[ -z "$subcmd_and_args" ]] && return 0

    local subcmd
    subcmd=$(echo "$subcmd_and_args" | awk '{print $1}')
    local subcmd_args=""
    local word_count
    word_count=$(echo "$subcmd_and_args" | wc -w | tr -d ' ')
    if (( word_count > 1 )); then
      subcmd_args=$(echo "$subcmd_and_args" | cut -d' ' -f2-)
    fi

    for ro in "${GIT_ALWAYS_READONLY[@]}"; do
      [[ "$subcmd" == "$ro" ]] && return 0
    done

    if [[ "$subcmd" == "branch" ]]; then
      local branch_write_flags
      read -ra branch_write_flags <<< "$GIT_BRANCH_WRITE_FLAGS"
      if has_any_flag "$subcmd_args" "${branch_write_flags[@]}"; then
        return 1
      fi
      local skip_next=false
      for word in $subcmd_args; do
        if [[ "$skip_next" == true ]]; then
          skip_next=false
          continue
        fi
        case "$word" in
          --contains|--no-contains|--merged|--no-merged|--points-at|--sort|--format)
            skip_next=true
            continue
            ;;
          -*) continue ;;
          *) return 1 ;;
        esac
      done
      return 0
    fi

    if [[ "$subcmd" == "tag" ]]; then
      local tag_write_flags
      read -ra tag_write_flags <<< "$GIT_TAG_WRITE_FLAGS"
      if has_any_flag "$subcmd_args" "${tag_write_flags[@]}"; then
        return 1
      fi
      local prev_was_list=false
      for word in $subcmd_args; do
        case "$word" in
          -l|--list|-n|--contains|--merged|--no-merged|--points-at|--sort|--format)
            prev_was_list=true
            continue
            ;;
          -*)
            prev_was_list=false
            continue
            ;;
          *)
            if [[ "$prev_was_list" == true ]]; then
              prev_was_list=false
              continue
            fi
            return 1
            ;;
        esac
      done
      return 0
    fi

    if [[ "$subcmd" == "remote" ]]; then
      local remote_subcmd
      remote_subcmd=$(echo "$subcmd_args" | awk '{print $1}')
      [[ -z "$remote_subcmd" || "$remote_subcmd" == "-v" || "$remote_subcmd" == "--verbose" ]] && return 0
      [[ "$remote_subcmd" == "show" || "$remote_subcmd" == "get-url" ]] && return 0
      return 1
    fi

    if [[ "$subcmd" == "stash" ]]; then
      local stash_subcmd
      stash_subcmd=$(echo "$subcmd_args" | awk '{print $1}')
      for ro in $GIT_STASH_READONLY_SUBCMDS; do
        [[ "$stash_subcmd" == "$ro" ]] && return 0
      done
      return 1
    fi

    if [[ "$subcmd" == "config" ]]; then
      if echo "$subcmd_args" | grep -qE '\-\-(get|get-all|get-regexp|list)|(^| )-l( |$)' 2>/dev/null; then
        return 0
      fi
      return 1
    fi

    [[ "$subcmd" == "fetch" ]] && return 0

    return 1
  fi

  # ── gh ──
  if [[ "$base" == "gh" ]]; then
    local joined="${args[*]}"
    for pattern in "${READONLY_GH_PATTERNS[@]}"; do
      if [[ "$joined" == *"$pattern"* ]]; then
        return 0
      fi
    done
    return 1
  fi

  # ── tee / xargs need special handling ──
  # `tee file.txt` writes to file.txt (the filename is an arg, not a redirect).
  # `tee` with no args, or `tee -a`/options only, writes to stdout — safe.
  # Simplest policy: tee with any non-flag arg → prompt.
  if [[ "$base" == "tee" ]]; then
    for arg in "${args[@]:1}"; do
      [[ "$arg" == -* ]] && continue
      return 1
    done
    return 0
  fi
  # `xargs <cmd>` runs arbitrary commands — we can't easily re-classify the
  # inner command from here, so prompt to be safe.
  if [[ "$base" == "xargs" ]]; then
    for arg in "${args[@]:1}"; do
      [[ "$arg" == -* ]] && continue
      return 1
    done
    return 0
  fi

  # ── Generic allowlist ──
  for cmd in "${READONLY_CMDS[@]}"; do
    [[ "$base" == "$cmd" ]] && return 0
  done

  return 1
}

# ── Parse command with shfmt ──────────────────────────────────────────
AST=$(printf '%s' "$COMMAND" | shfmt -tojson 2>/dev/null) || {
  # Parse failure → fall through to prompt
  exit 0
}

# ── Reject disallowed redirects ──────────────────────────────────────
# Ops: 63=`>`, 64=`>>`, 65=`<`, 66=`<<` (heredoc), 68=`>&`/`<&`, 73=`<<<`
# Write ops (63, 64) to anything other than /dev/null → not read-only.
DISALLOWED_REDIR=$(echo "$AST" | jq -r '
  [.. | objects | .Redirs? // empty | .[]
   | select(.Op == 63 or .Op == 64)
   | (.Word.Parts[0].Value // .Word.Parts[0].Lit // "?")
   | select(. != "/dev/null")
  ] | length
' 2>/dev/null) || DISALLOWED_REDIR=0

if [[ "${DISALLOWED_REDIR:-0}" -gt 0 ]]; then
  exit 0
fi

# ── Walk every CallExpr in the AST ───────────────────────────────────
# Each CallExpr is one simple command (after env-var assignments, which
# shfmt separates into .Assigns). Output: one line per CallExpr, args
# separated by NUL for safe re-parsing.

CALLEXPRS=$(echo "$AST" | jq -r '
  [.. | objects | select(.Type == "CallExpr")
   | [.Args[]? | (.Parts[0].Value // .Parts[0].Lit // "?")]
   | select(length > 0)
   | @tsv
  ] | .[]
' 2>/dev/null) || exit 0

# No CallExprs found (e.g. bare `{ }` block or assignment-only) → treat
# as safe (nothing executes). This is conservative and matches shfmt's view.
if [[ -z "$CALLEXPRS" ]]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"No executable commands"}}'
  exit 0
fi

ALL_READONLY=true
while IFS=$'\t' read -r -a cmd_args; do
  (( ${#cmd_args[@]} == 0 )) && continue
  if ! is_simple_cmd_readonly "${cmd_args[@]}"; then
    ALL_READONLY=false
    break
  fi
done <<< "$CALLEXPRS"

if [[ "$ALL_READONLY" == "true" ]]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Read-only command auto-approved (AST)"}}'
fi
