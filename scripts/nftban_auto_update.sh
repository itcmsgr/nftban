#!/usr/bin/env bash
# nftban auto-update wrapper

set -euo pipefail

# --- Config ------------------------------------------------------------------
AUTO_FLAGS=(--assume-yes --quiet)   # add your init's update flags here (e.g., --update)
BRANCH="${NFTBAN_BRANCH:-main}"     # override with env if needed

# --- Helpers -----------------------------------------------------------------
log() { printf '[nftban-auto-update] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

has() { command -v "$1" >/dev/null 2>&1; }

# Compare two semantic-ish versions: returns 0 if $1 < $2
ver_lt() {
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

# Get init path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATES=(
  "$SCRIPT_DIR/nftban_init.sh"
  "$SCRIPT_DIR/../nftban_init.sh"
  "$SCRIPT_DIR/../scripts/nftban_init.sh"
  "/usr/local/bin/nftban_init.sh"
  "/usr/local/bin/nftban-init"
  "/usr/local/bin/nftban"
)
INIT=""
for c in "${CANDIDATES[@]}"; do
  [[ -x "$c" ]] && INIT="$c" && break
done
if [[ -z "$INIT" ]]; then
  if has nftban_init.sh; then INIT="$(command -v nftban_init.sh)"
  elif has nftban-init; then INIT="$(command -v nftban-init)"
  elif has nftban; then INIT="$(command -v nftban)"
  else die "Could not locate nftban init script."; fi
fi

# Ensure root
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "Re-executing with sudo..."
  exec sudo -E -- "$INIT" "${AUTO_FLAGS[@]}" "$@"
fi

# Prevent overlap
LOCK_FILE="/var/lock/nftban-auto-update.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another auto-update is running. Exiting."
  exit 0
fi

# --- Determine repo root and whether this is a git checkout -------------------
REPO_ROOT="$SCRIPT_DIR/.."
if [[ -d "$REPO_ROOT/.git" ]]; then
  IS_GIT=1
elif [[ -d "$SCRIPT_DIR/.git" ]]; then
  REPO_ROOT="$SCRIPT_DIR"
  IS_GIT=1
else
  IS_GIT=0
fi

proceed_update=1  # default to proceed; we may set to 0 to skip

if [[ "$IS_GIT" -eq 1 ]] && has git; then
  pushd "$REPO_ROOT" >/dev/null
  cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "$BRANCH")"
  remote_branch="origin/$cur_branch"
  log "Git detected at $REPO_ROOT (branch: $cur_branch). Fetching..."
  git fetch --quiet --all || true

  if git rev-parse --verify -q "$remote_branch" >/dev/null; then
    ahead_behind="$(git rev-list --left-right --count "HEAD...$remote_branch" 2>/dev/null || echo "0	0")"
    behind="$(echo "$ahead_behind" | awk '{print $2}')"
    if [[ "${behind:-0}" -eq 0 ]]; then
      log "Up to date with $remote_branch. Skipping update."
      proceed_update=0
    else
      log "Remote has $behind new commit(s). Proceeding with update."
      proceed_update=1
    fi
  else
    log "Remote branch $remote_branch not found. Proceeding with update."
    proceed_update=1
  fi
  popd >/dev/null
else
  # Non-git install: try local version only (no remote metadata available here)
  local_ver=""
  if "$INIT" --version >/dev/null 2>&1; then
    local_ver="$("$INIT" --version 2>/dev/null | head -n1 | sed 's/[^0-9.]*\([0-9.]*\).*/\1/')"
  elif "$INIT" --print-version >/dev/null 2>/dev/null; then
    local_ver="$("$INIT" --print-version 2>/dev/null | head -n1)"
  fi
  if [[ -z "$local_ver" ]]; then
    if [[ -f "$REPO_ROOT/VERSION" ]]; then
      local_ver="$(head -n1 "$REPO_ROOT/VERSION" | tr -d ' \r')"
    elif [[ -f "$REPO_ROOT/scripts/VERSION" ]]; then
      local_ver="$(head -n1 "$REPO_ROOT/scripts/VERSION" | tr -d ' \r')"
    fi
  fi
  if [[ -n "$local_ver" ]]; then
    log "Non-git install detected. Local version: $local_ver (will proceed; init may no-op)."
  else
    log "Non-git install detected. No local version found (will proceed; init may no-op)."
  fi
  proceed_update=1
fi

[[ "$proceed_update" -eq 0 ]] && exit 0

log "Launching init for unattended update: $INIT ${AUTO_FLAGS[*]} $*"
exec "$INIT" "${AUTO_FLAGS[@]}" "$@"
