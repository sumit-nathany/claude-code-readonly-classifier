#!/usr/bin/env bash
#
# is-readonly-command.sh
# Classifies a bash command as read-only or not.
# Reads JSON from stdin (Claude Code hook format), extracts the command,
# and outputs a JSON permission decision.
#
# If read-only: auto-approve via permissionDecision
# If uncertain: no output (fall through to normal permission prompt)

set -euo pipefail

COMMAND=$(jq -r '.tool_input.command // empty' 2>/dev/null)
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
  echo printf true false test expr bc dc jq yq xmllint
  man info help
  # java / build reads
  java javac mvn gradle
  # python reads
  python python3 pip pip3
  # node reads
  node npm npx yarn bun bunx pnpm
)

# ── Git subcommands: always read-only (no flags change this) ───────────
GIT_ALWAYS_READONLY=(
  log diff status show blame describe shortlog
  rev-parse rev-list name-rev
  ls-files ls-tree ls-remote cat-file diff-tree diff-files
  for-each-ref show-ref count-objects fsck verify-pack
  grep reflog
)

# ── Git subcommands: read-only ONLY with specific flags ────────────────
# These need flag-level inspection because some flags mutate state.

# git branch: read-only when listing (no args, -a, -r, -v, -vv, --list, --contains, --merged, etc.)
#             NOT read-only when: -d, -D, --delete, -m, -M, --move, -c, -C, --copy, or bare name (create)
GIT_BRANCH_WRITE_FLAGS="-d -D --delete -m -M --move -c -C --copy --set-upstream-to --unset-upstream --edit-description"

# git tag: read-only when listing (no args, -l, --list, -n, --contains, etc.)
#          NOT read-only when: -d, --delete, -a, -s, -f, or bare name (create)
GIT_TAG_WRITE_FLAGS="-d --delete -a --annotate -s --sign -f --force"

# git remote: read-only when listing (no args, -v, show, get-url)
#             NOT read-only when: add, remove, rename, set-url, set-head, prune
GIT_REMOTE_WRITE_SUBCMDS="add remove rm rename set-url set-head prune set-branches update"

# git stash: only 'stash list' and 'stash show' are read-only
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

# ── Dangerous patterns that are NEVER read-only ────────────────────────
DANGEROUS_PATTERNS=(
  "rm " "rm	" "rmdir " "mv " "cp " "ln "
  "chmod " "chown " "chgrp "
  "mkdir " "touch "
  "tee " "truncate "
  "kill " "killall " "pkill "
  "reboot" "shutdown" "halt"
  "dd " "mkfs" "mount " "umount"
  "docker run" "docker exec" "docker rm" "docker stop" "docker kill"
  "kubectl delete" "kubectl apply" "kubectl create" "kubectl patch"
  "git push" "git commit" "git merge" "git rebase" "git reset"
  "git checkout" "git switch" "git restore" "git clean" "git rm"
  "git mv" "git add" "git cherry-pick" "git revert" "git pull"
  "gh pr create" "gh pr merge" "gh pr close" "gh pr edit"
  "gh pr review" "gh pr ready" "gh pr comment"
  "gh issue create" "gh issue close" "gh issue edit"
  "gh issue comment" "gh issue delete"
  "gh release create" "gh release delete" "gh release edit"
  "gh repo create" "gh repo delete" "gh repo edit"
  "> " ">> "
)

# ── Helper: extract git subcommand, skipping global flags ──────────────
# Handles: git -C <path> subcmd, git --no-pager subcmd, git -c key=val subcmd
extract_git_subcmd_and_args() {
  local seg="$1"
  local words=()
  read -ra words <<< "$seg"

  local i=1  # skip "git" at index 0
  while (( i < ${#words[@]} )); do
    case "${words[$i]}" in
      -C|--git-dir|--work-tree|-c)
        (( i += 2 ))  # skip flag + its argument
        ;;
      --no-pager|--no-optional-locks|--literal-pathspecs)
        (( i += 1 ))  # skip single flag
        ;;
      -*)
        # Unknown global flag — skip it
        (( i += 1 ))
        ;;
      *)
        # This is the subcommand
        echo "${words[@]:$i}"
        return
        ;;
    esac
  done
  echo ""
}

# ── Helper: check if any word matches a flag list ──────────────────────
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

# ── Helper: check if a single simple command is read-only ──────────────
is_segment_readonly() {
  local seg="$1"

  # Strip leading whitespace and env var assignments (FOO=bar cmd ...)
  seg=$(echo "$seg" | sed 's/^[[:space:]]*//')
  while [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
    seg=$(echo "$seg" | sed 's/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]*//')
  done

  # Extract the base command (first word)
  local base
  base=$(echo "$seg" | awk '{print $1}')
  [[ -z "$base" ]] && return 0

  # Check for dangerous patterns first
  for pattern in "${DANGEROUS_PATTERNS[@]}"; do
    if [[ "$seg" == *"$pattern"* ]]; then
      return 1
    fi
  done

  # Check for output redirection to files (not /dev/null, not stderr)
  if echo "$seg" | grep -qE '(^|[^2&])[>]' 2>/dev/null; then
    if ! echo "$seg" | grep -qE '>[>]?\s*/dev/null' 2>/dev/null; then
      return 1
    fi
  fi

  # ── git special handling ──
  if [[ "$base" == "git" ]]; then
    local subcmd_and_args
    subcmd_and_args=$(extract_git_subcmd_and_args "$seg")
    [[ -z "$subcmd_and_args" ]] && return 0  # bare "git" is safe

    local subcmd
    subcmd=$(echo "$subcmd_and_args" | awk '{print $1}')
    local subcmd_args=""
    local word_count
    word_count=$(echo "$subcmd_and_args" | wc -w | tr -d ' ')
    if (( word_count > 1 )); then
      subcmd_args=$(echo "$subcmd_and_args" | cut -d' ' -f2-)
    fi

    # Always read-only subcommands
    for ro in "${GIT_ALWAYS_READONLY[@]}"; do
      [[ "$subcmd" == "$ro" ]] && return 0
    done

    # git branch — read-only only if no write flags and no bare branch name (create)
    if [[ "$subcmd" == "branch" ]]; then
      local branch_write_flags
      read -ra branch_write_flags <<< "$GIT_BRANCH_WRITE_FLAGS"
      if has_any_flag "$subcmd_args" "${branch_write_flags[@]}"; then
        return 1
      fi
      # Check for bare branch name creation: `git branch <name>`
      # Read-only flags that consume the NEXT word as their argument:
      local branch_flags_with_arg="--contains --no-contains --merged --no-merged --points-at --sort --format -u --set-upstream-to"
      local skip_next=false
      for word in $subcmd_args; do
        if [[ "$skip_next" == true ]]; then
          skip_next=false
          continue
        fi
        case "$word" in
          --contains|--no-contains|--merged|--no-merged|--points-at|--sort|--format)
            skip_next=true  # next word is the flag's argument, not a branch name
            continue
            ;;
          -*) continue ;;  # other flags are ok
          *) return 1 ;;   # bare word = branch name = creating a branch
        esac
      done
      return 0
    fi

    # git tag — read-only only if no write flags and no bare tag name (create)
    if [[ "$subcmd" == "tag" ]]; then
      local tag_write_flags
      read -ra tag_write_flags <<< "$GIT_TAG_WRITE_FLAGS"
      if has_any_flag "$subcmd_args" "${tag_write_flags[@]}"; then
        return 1
      fi
      # Read-only forms: git tag, git tag -l, git tag --list, git tag -n, git tag --contains
      # If there's a bare word that isn't after -l/--list, it could be creating a tag
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
            # Bare word: if previous was a filter flag, this is its argument (ok)
            if [[ "$prev_was_list" == true ]]; then
              prev_was_list=false
              continue
            fi
            return 1  # bare word without context = creating a tag
            ;;
        esac
      done
      return 0
    fi

    # git remote — read-only only for listing / show / get-url
    if [[ "$subcmd" == "remote" ]]; then
      local remote_subcmd
      remote_subcmd=$(echo "$subcmd_args" | awk '{print $1}')
      # No subcommand (bare `git remote`) or `-v` = listing = read-only
      [[ -z "$remote_subcmd" || "$remote_subcmd" == "-v" || "$remote_subcmd" == "--verbose" ]] && return 0
      # Explicit read-only subcmds
      [[ "$remote_subcmd" == "show" || "$remote_subcmd" == "get-url" ]] && return 0
      # Everything else is a write subcmd
      return 1
    fi

    # git stash — only 'list' and 'show' are read-only
    if [[ "$subcmd" == "stash" ]]; then
      local stash_subcmd
      stash_subcmd=$(echo "$subcmd_args" | awk '{print $1}')
      for ro in $GIT_STASH_READONLY_SUBCMDS; do
        [[ "$stash_subcmd" == "$ro" ]] && return 0
      done
      return 1  # bare `git stash` = stash push = not read-only
    fi

    # git config — read-only only with --get, --get-all, --list, -l
    if [[ "$subcmd" == "config" ]]; then
      if echo "$subcmd_args" | grep -qE '\-\-(get|get-all|get-regexp|list)|-l' 2>/dev/null; then
        return 0
      fi
      return 1
    fi

    # git fetch — read-only (downloads but doesn't modify working tree)
    if [[ "$subcmd" == "fetch" ]]; then
      return 0
    fi

    # Unrecognized git subcommand — not read-only
    return 1
  fi

  # ── gh special handling ──
  if [[ "$base" == "gh" ]]; then
    for pattern in "${READONLY_GH_PATTERNS[@]}"; do
      if [[ "$seg" == *"$pattern"* ]]; then
        return 0
      fi
    done
    return 1
  fi

  # Check against the known read-only commands
  for cmd in "${READONLY_CMDS[@]}"; do
    if [[ "$base" == "$cmd" ]]; then
      return 0
    fi
  done

  # Not recognized — not read-only
  return 1
}

# ── Main: split on pipes and check every segment ──────────────────────

# Split on |, &&, ;, || and check each segment
SEGMENTS=$(echo "$COMMAND" | sed 's/[|][ ]*[|]/\n/g; s/[|]/\n/g; s/&&/\n/g; s/;/\n/g')

ALL_READONLY=true
while IFS= read -r segment; do
  segment=$(echo "$segment" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$segment" ]] && continue

  if ! is_segment_readonly "$segment"; then
    ALL_READONLY=false
    break
  fi
done <<< "$SEGMENTS"

if [[ "$ALL_READONLY" == "true" ]]; then
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Read-only command auto-approved"}}'
fi

# If not read-only, output nothing — falls through to normal permission flow
