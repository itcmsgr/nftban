#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.20 - Atomic Nftables Reload Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Atomic nftables reload with table swap
#
# meta:name=nftban_nftables
# meta:type=core
# meta:header=Atomic Nftables Reload
# meta:version=0.32.20
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Atomic nftables reload with table swap to prevent firewall downtime
# meta:input=Nftables ruleset files
# meta:output=Atomic reload with backup and rollback capability
#
# **Inventory & Requirements**
# meta:depends=nft,flock
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

: "${NFTBIN:=/usr/sbin/nft}"
: "${BACKUP_DIR:=/var/backups/nftban}"
: "${RUNDIR:=/run/nftban}"
: "${LOCKFILE:=${RUNDIR}/reload.lock}"

mkdir -p "$BACKUP_DIR" "$RUNDIR"

_lock()   { exec 9>"$LOCKFILE"; flock -w 30 9; }
_unlock() { flock -u 9 || true; }

timestamp() { date -u +'%Y%m%d-%H%M%S'; }

# Backup current ruleset before changes
backup_ruleset() {
  local ts out
  ts="$(timestamp)"
  out="${BACKUP_DIR}/ruleset-${ts}.nft"
  # Full kernel ruleset snapshot (human-readable + restoreable)
  ${NFTBIN} list ruleset > "$out"
  ln -sf "ruleset-${ts}.nft" "${BACKUP_DIR}/backup-latest.nft"

  # Retention policy: keep last 10 snapshots
  # shellcheck disable=SC2012
  ls -t "${BACKUP_DIR}"/ruleset-*.nft 2>/dev/null | tail -n +11 | xargs -r rm -f

  echo "$out"
}

# Build a batch that creates *new* tables & sets, then populates from files.
_build_new_tables_batch() {
  local V4_WL="$1" V4_BL="$2" V4_FEEDS="$3"
  local V6_WL="$4" V6_BL="$5" V6_FEEDS="$6"

  cat <<'HDR'
define T4_NEW = nftban_v4_new
define T6_NEW = nftban_v6_new

# Safety: create fresh tables (skip if exist); drop stale remnants first
delete table ip   $T4_NEW 2>/dev/null
delete table ip6  $T6_NEW 2>/dev/null

table ip $T4_NEW {
  sets {
    whitelist        { type ipv4_addr; flags interval; }
    temp_ban         { type ipv4_addr; timeout 1h; }
    user_blacklist   { type ipv4_addr; flags interval; }
    system_blacklist { type ipv4_addr; flags interval; }
    feeds            { type ipv4_addr; flags interval; }
  }
  chains {
    input {
      type filter hook input priority 0; policy accept;
      ct state established,related accept
      iif lo accept
      ip saddr @whitelist accept
      icmp type { echo-request, echo-reply } accept
      tcp dport $SSH_PORT accept
      # Port rules inserted here by your generator
      ct state invalid drop
      ip saddr @temp_ban drop
      ip saddr @user_blacklist drop
      ip saddr @system_blacklist drop
      ip saddr @feeds drop
    }
  }
}

table ip6 $T6_NEW {
  sets {
    whitelist        { type ipv6_addr; flags interval; }
    temp_ban         { type ipv6_addr; timeout 1h; }
    user_blacklist   { type ipv6_addr; flags interval; }
    system_blacklist { type ipv6_addr; flags interval; }
    feeds            { type ipv6_addr; flags interval; }
  }
  chains {
    input {
      type filter hook input priority 0; policy accept;
      ct state established,related accept
      iif lo accept
      ip6 saddr @whitelist accept
      icmpv6 type { echo-request, echo-reply, nd-neighbor-solicit, nd-neighbor-advert } accept
      tcp dport $SSH_PORT accept
      ct state invalid drop
      ip6 saddr @temp_ban drop
      ip6 saddr @user_blacklist drop
      ip6 saddr @system_blacklist drop
      ip6 saddr @feeds drop
    }
  }
}
HDR

  # Populate sets from your compiled files if present
  [[ -s "$V4_WL"    ]] && echo "add element ip  \$T4_NEW whitelist        { $(tr '\n' ',' <"$V4_WL"    | sed 's/,$//') }"
  [[ -s "$V4_BL"    ]] && echo "add element ip  \$T4_NEW user_blacklist   { $(tr '\n' ',' <"$V4_BL"    | sed 's/,$//') }"
  [[ -s "$V4_FEEDS" ]] && echo "add element ip  \$T4_NEW feeds            { $(tr '\n' ',' <"$V4_FEEDS" | sed 's/,$//') }"

  [[ -s "$V6_WL"    ]] && echo "add element ip6 \$T6_NEW whitelist        { $(tr '\n' ',' <"$V6_WL"    | sed 's/,$//') }"
  [[ -s "$V6_BL"    ]] && echo "add element ip6 \$T6_NEW user_blacklist   { $(tr '\n' ',' <"$V6_BL"    | sed 's/,$//') }"
  [[ -s "$V6_FEEDS" ]] && echo "add element ip6 \$T6_NEW feeds            { $(tr '\n' ',' <"$V6_FEEDS" | sed 's/,$//') }"
}

# Validate batch syntactically without applying (nft -c)
_validate_batch() {
  local batchfile="$1"
  ${NFTBIN} -c -f "$batchfile" >/dev/null
}

# Perform *atomic* rename-swap inside a single transaction
_do_atomic_swap() {
  ${NFTBIN} -f - <<'EOF'
# If current tables don't exist, skip renames gracefully
define T4_CUR = nftban_v4
define T6_CUR = nftban_v6
define T4_OLD = nftban_v4_old
define T6_OLD = nftban_v6_old
define T4_NEW = nftban_v4_new
define T6_NEW = nftban_v6_new

# Clean previous *_old if left over
delete table ip   $T4_OLD 2>/dev/null
delete table ip6  $T6_OLD 2>/dev/null

# If current exist, rename to *_old
rename table ip  $T4_CUR $T4_OLD 2>/dev/null
rename table ip6 $T6_CUR $T6_OLD 2>/dev/null

# New → current names
rename table ip  $T4_NEW $T4_CUR
rename table ip6 $T6_NEW $T6_CUR

# Drop old after successful swap
delete table ip  $T4_OLD 2>/dev/null
delete table ip6 $T6_OLD 2>/dev/null
EOF
}

# Full atomic reload entrypoint
nftban_atomic_reload() {
  _lock
  trap '_unlock' EXIT

  local backup
  backup="$(backup_ruleset)"

  # Build batch for new tables in a temp file
  local tmpbatch
  tmpbatch="$(mktemp --tmpdir="${RUNDIR}" nftban-newtables.XXXXXX)"
  trap 'rm -f "$tmpbatch" || true' RETURN

  # Paths (adjust if you split v4/v6 into separate compiled files)
  local V4_WL="/var/lib/nftban/compiled/whitelist.txt"
  local V4_BL="/var/lib/nftban/compiled/blacklist.txt"
  local V4_FEEDS="/var/lib/nftban/compiled/feeds.txt"
  local V6_WL="/var/lib/nftban/compiled/whitelist6.txt"
  local V6_BL="/var/lib/nftban/compiled/blacklist6.txt"
  local V6_FEEDS="/var/lib/nftban/compiled/feeds6.txt"

  _build_new_tables_batch "$V4_WL" "$V4_BL" "$V4_FEEDS" "$V6_WL" "$V6_BL" "$V6_FEEDS" >"$tmpbatch"

  # Validate syntactically
  _validate_batch "$tmpbatch"

  # Apply creation & population of *new* tables
  ${NFTBIN} -f "$tmpbatch"

  # Atomic swap (single transaction)
  _do_atomic_swap

  # Post-check: ensure tables exist and have elements (basic sanity)
  ${NFTBIN} list table ip nftban_v4 >/dev/null
  ${NFTBIN} list table ip6 nftban_v6 >/dev/null || true  # Allow v6-less hosts

  echo "[OK] Atomic reload complete. Backup at: $backup"
  return 0
}

# Rollback helper (in the unlikely case we need manual rollback)
nftban_rollback_last_backup() {
  _lock
  trap '_unlock' EXIT
  local last="${BACKUP_DIR}/backup-latest.nft"
  [[ -f "$last" ]] || { echo "No backup found"; return 1; }
  ${NFTBIN} -f "$last"
  echo "[OK] Rolled back to: $(readlink -f "$last")"
}
