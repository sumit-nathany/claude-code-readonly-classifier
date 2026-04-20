#!/usr/bin/env bash
#
# check-deps.sh — SessionStart hook. Verifies that jq and shfmt are
# installed. If either is missing, prints a clear one-time warning
# with the right install command for the user's OS / package manager.
#
# Caches the "deps OK" result in ${CLAUDE_PLUGIN_DATA}/deps-ok so the
# check is a single stat() after the first successful session.

set -uo pipefail

DATA_DIR="${CLAUDE_PLUGIN_DATA:-$HOME/.claude/plugins/data/readonly-bash-classifier}"
STAMP="$DATA_DIR/deps-ok"

# Fast path: if we've already verified deps in a prior session, exit silently.
[[ -f "$STAMP" ]] && exit 0

missing=()
command -v jq    >/dev/null 2>&1 || missing+=(jq)
command -v shfmt >/dev/null 2>&1 || missing+=(shfmt)

if (( ${#missing[@]} == 0 )); then
  mkdir -p "$DATA_DIR" 2>/dev/null && : > "$STAMP"
  exit 0
fi

# Pick the install hint most likely to work on this machine.
install_hint=""
case "$(uname -s)" in
  Darwin)
    if command -v brew >/dev/null 2>&1; then
      install_hint="brew install ${missing[*]}"
    else
      install_hint="Install Homebrew from https://brew.sh, then: brew install ${missing[*]}"
    fi
    ;;
  Linux)
    if   command -v apt-get >/dev/null 2>&1; then install_hint="sudo apt-get install -y ${missing[*]}"
    elif command -v dnf     >/dev/null 2>&1; then install_hint="sudo dnf install -y ${missing[*]}"
    elif command -v pacman  >/dev/null 2>&1; then install_hint="sudo pacman -S --needed ${missing[*]}"
    elif command -v apk     >/dev/null 2>&1; then install_hint="sudo apk add ${missing[*]}"
    elif command -v brew    >/dev/null 2>&1; then install_hint="brew install ${missing[*]}"
    else                                           install_hint="Install ${missing[*]} via your system's package manager"
    fi
    ;;
  *)
    install_hint="Install ${missing[*]} via your system's package manager"
    ;;
esac

# Emit a SessionStart additionalContext block. Claude Code surfaces this
# in the session so the user sees it on first run.
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "⚠️  readonly-bash-classifier plugin: missing required dependencies: ${missing[*]}\n\nInstall with:\n  $install_hint\n\nUntil these are installed, every Bash command will fall through to the normal permission prompt (plugin stays inactive — safe, just not useful)."
  }
}
EOF
