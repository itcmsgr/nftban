#!/usr/bin/env bash
# nftban auto-update wrapper (Option A)
# Place this file at: <REPO_ROOT>/scripts/nftban_auto_update.sh
# It simply invokes your existing init script with safe defaults for unattended updates.

set -euo pipefail

# --- Config ------------------------------------------------------------------
# Extra flags to pass to init during auto-update. Adjust to match your init's CLI.
# Common safe flags: --assume-yes, --quiet
AUTO_FLAGS=(--assume-yes --quiet)

# --- Helpers -----------------------------------------------------------------
die() { echo "[ERROR] $*" >&2; exit 1; }
log() { echo "[nftban-auto-update] $*"; }

# Determine our directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try a few likely locations for the init script
CANDIDATES=(
  "$SCRIPT_DIR/nftban_init.sh"
  "$SCRIPT_DIR/../nftban_init.sh"
  "$SCRIPT_DIR/../scripts/nftban_init.sh"
  "/usr/local/bin/nftban_init.sh"
  "/usr/local/bin/nftban-init"
  "/usr/local/bin/nftban"   # in case the init exposes a CLI alias
)

INIT=""
for c in "${CANDIDATES[@]}"; do
  if [[ -x "$c" ]]; then INIT="$c"; break; fi
done
if [[ -z "$INIT" ]]; then
  # last resort: look on PATH
  if command -v nftban_init.sh >/dev/null 2>&1; then INIT="$(command -v nftban_init.sh)"
  elif command -v nftban-init >/dev/null 2>&1; then INIT="$(command -v nftban-init)"
  elif command -v nftban >/dev/null 2>&1; then INIT="$(command -v nftban)"
  else
    die "Could not locate nftban_init.sh (searched common paths and PATH)."
  fi
fi

# Ensure root (most installers need it)
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  log "Re-executing with sudo..."
  exec sudo -E -- "$INIT" "${AUTO_FLAGS[@]}" "$@"
fi

# Prevent overlapping runs (cron, systemd timers)
LOCK_FILE="/var/lock/nftban-auto-update.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Another auto-update is running. Exiting."
  exit 0
fi

# Run the update. Rely on your init's default flow (usually GitHub).
# If your init exposes a dedicated flag for update (e.g., --update or --upgrade),
# you can add it into AUTO_FLAGS above.
log "Launching init for unattended update: $INIT ${AUTO_FLAGS[*]} $*"
exec "$INIT" "${AUTO_FLAGS[@]}" "$@"
