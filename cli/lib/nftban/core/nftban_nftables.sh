#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Atomic Nftables Reload Module [DEPRECATED]
# =============================================================================
# ⚠️  **DEPRECATED v0.6.2** - This module uses OLD architecture (v0.5.x)
# ⚠️  Use: nftban-sync (Go binary) for atomic reloads in v0.6+
# ⚠️  Reason: Uses old v0.5.x split architecture (ip nftban_v4 + ip6 nftban_v6)
# ⚠️          instead of v0.7.3 dual-table (ip nftban + ip6 nftban)
#
# SPDX-License-Identifier: MPL-2.0
# Purpose: [DEPRECATED] Atomic nftables reload with table swap
#
# meta:name=nftban_nftables
# meta:type=core
# meta:header=[DEPRECATED] Atomic Nftables Reload
# meta:version=1.0.0
# meta:deprecated=true
# meta:deprecated_since=0.6.2
# meta:replacement=nftban-sync (Go binary at cmd/nftban-sync)
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=[DEPRECATED] Use nftban-sync instead
# meta:input=N/A (deprecated)
# meta:output=ERROR message directing to nftban-sync
#
# **Inventory & Requirements**
# meta:depends=nft,flock
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
# meta:deprecated_date=2025-11-19
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "⚠️  DEPRECATED: nftban_nftables.sh uses OLD architecture" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
echo "" >&2
echo "This module uses incompatible table structure:" >&2
echo "  OLD: table ip nftban_v4 + table ip6 nftban_v6" >&2
echo "  NEW: table ip nftban + table ip6 nftban" >&2
echo "" >&2
echo "Running this script will BREAK your firewall!" >&2
echo "" >&2
echo "✅ Use instead: nftban sync" >&2
echo "" >&2
echo "Examples:" >&2
echo "  nftban sync               # Full atomic reload" >&2
echo "  nftban sync --dry-run     # Validate only" >&2
echo "" >&2
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
exit 1

# Original code preserved below but disabled
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
  local V4_WL="${NFTBAN_DATA_DIR}/compiled/whitelist.txt"
  local V4_BL="${NFTBAN_DATA_DIR}/compiled/blacklist.txt"
  local V4_FEEDS="${NFTBAN_DATA_DIR}/compiled/feeds.txt"
  local V6_WL="${NFTBAN_DATA_DIR}/compiled/whitelist6.txt"
  local V6_BL="${NFTBAN_DATA_DIR}/compiled/blacklist6.txt"
  local V6_FEEDS="${NFTBAN_DATA_DIR}/compiled/feeds6.txt"

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
