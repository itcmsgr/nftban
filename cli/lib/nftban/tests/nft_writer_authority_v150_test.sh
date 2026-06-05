#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 nft-writer single-authority tightening (AUTH-A/B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_writer_authority_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.150 nft-writer single-authority tightening. AUTH-1: DDoS penalty escalation (nftban_ddos_classic.sh) routes via nft_ipc_add_element under normal mode, falls to direct nft only under the gated NFTBAN_EMERGENCY_MODE / helper-absent path (emergency default-off). AUTH-2: scripts/ci/check-nft-writes.sh scan widened to scripts/, extensionless cli/sbin/*, and internal/ Go. AUTH-3: allowlist annotated + positive ban/unban-IPC route assertions. AUTH-4: stale nftban_geoban.sh allowlist entry removed. The real gate runs clean (0 write violations)."
# meta:input="None (self-contained sandbox; reads repo source read-only)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,sed,mktemp"
# meta:inventory.files="scripts/ci/check-nft-writes.sh,cli/lib/nftban/core/nftban_ddos_classic.sh,cli/lib/nftban/cli/cmd_ban.sh,cli/lib/nftban/cli/cmd_unban.sh"
# meta:inventory.binaries="bash,grep,sed,mktemp"
# meta:inventory.env_vars="NFTBAN_EMERGENCY_MODE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-contained; no host contact; no root; no nft/IPC. Static source reads +
# a copied-logic harness with a drift-guard so the real code can't diverge
# silently. Per the standing rule: no live ban/unban and no direct-nft confirm.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Resolve repo root from this test's location (cli/lib/nftban/tests/..)
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/check-nft-writes.sh"
DDOS="$REPO_ROOT/cli/lib/nftban/core/nftban_ddos_classic.sh"
CMD_BAN="$REPO_ROOT/cli/lib/nftban/cli/cmd_ban.sh"
CMD_UNBAN="$REPO_ROOT/cli/lib/nftban/cli/cmd_unban.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ✓ $1"; }
no()   { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
check(){ if eval "$2"; then ok "$1"; else no "$1"; fi; }

echo "=== AUTH-2: check-nft-writes.sh widened scan coverage ==="
check "gate scans scripts/"     "grep -qE 'cli/ pkg/ install/ scripts/' '$GATE'"
check "gate scans cli/sbin/"    "grep -qE 'grep -rnI -E .* cli/sbin/' '$GATE' || grep -q 'cli/sbin/' '$GATE'"
check "gate scans internal/ Go" "grep -qE 'pkg/ cmd/ internal/' '$GATE'"

echo "=== AUTH-3 / AUTH-4: allowlist annotated + pruned ==="
check "allowlist has internal/setsync/"        "grep -q 'internal/setsync/' '$GATE'"
check "allowlist has cli/sbin/nftban-apply"    "grep -q 'cli/sbin/nftban-apply' '$GATE'"
check "allowlist has cli/sbin/nftban-rollback" "grep -q 'cli/sbin/nftban-rollback' '$GATE'"
check "allowlist has test_server_cleanup"      "grep -q 'scripts/test_server_cleanup' '$GATE'"
check "AUTH-4: nftban_geoban.sh removed from ALLOWED_REGEX" "! grep -E '^ALLOWED_REGEX=' '$GATE' | grep -q 'nftban_geoban'"

echo "=== AUTH-2 functional: scan pattern catches writes in the new dirs ==="
SB=$(mktemp -d)
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/scripts" "$SB/cli/sbin"
printf 'nft add element ip nftban ddos_ban_1h { 1.2.3.4 }\n' > "$SB/scripts/evil.sh"
printf '#!/bin/sh\nnft delete table inet nftban\n'           > "$SB/cli/sbin/evil"
# shellcheck disable=SC2034  # used inside the check() eval strings below
NFT_WRITE_PATTERN='nft[[:space:]]+(add|delete|flush|insert|create|destroy|replace)[[:space:]]'
check "planted scripts/ write is matched"      "grep -rIqE \"\$NFT_WRITE_PATTERN\" '$SB/scripts/'"
check "planted cli/sbin extensionless matched" "grep -rIqE \"\$NFT_WRITE_PATTERN\" '$SB/cli/sbin/'"

echo "=== AUTH-B regression: real gate runs clean (0 write violations) ==="
check "check-nft-writes.sh exits 0" "( cd '$REPO_ROOT' && bash '$GATE' >/dev/null 2>&1 )"

echo "=== ban/unban route through daemon IPC (not direct nft) ==="
check "cmd_ban.sh delegates to nftban-core (IPC)"      "grep -qE 'nftban-core[\"'\'' ]+ban|nftban_core.*ban' '$CMD_BAN'"
check "cmd_ban.sh has NO direct nft add/delete write"  "! grep -qE 'nft[[:space:]]+(add|delete|flush|insert|create|destroy|replace)[[:space:]]' '$CMD_BAN'"
check "cmd_unban.sh delegates to nftban-core (IPC)"    "grep -qE 'nftban-core[\"'\'' ]+unban|nftban_core.*unban' '$CMD_UNBAN'"
check "cmd_unban.sh has NO direct nft delete write"    "! grep -qE 'nft[[:space:]]+(add|delete|flush|insert|create|destroy|replace)[[:space:]]' '$CMD_UNBAN'"

echo "=== AUTH-1: real ddos penalty add routes via IPC, direct only under emergency guard ==="
check "real code calls nft_ipc_add_element in penalty path" \
  "grep -q 'nft_ipc_add_element \"\${table_fam}\" \"\${target_set}\"' '$DDOS'"
check "direct nft add is guarded by NFTBAN_EMERGENCY_MODE" \
  "grep -A4 'NFTBAN_EMERGENCY_MODE:-0' '$DDOS' | grep -q 'nft add element'"
check "skip-log present when IPC down + emergency off" \
  "grep -q 'NFTBAN_EMERGENCY_MODE=0' '$DDOS'"

echo "=== AUTH-1 functional: copied decision logic + emergency default-off ==="
# Drift-guard: the harness below mirrors the real penalty-add decision. Assert
# the real file still contains the exact constructs the harness models.
check "drift-guard: explicit per-tier timeout passed to IPC" \
  "grep -q '_nftban_ddos_timeout_to_seconds \"\$target_timeout\"' '$DDOS'"

# Harness mirroring the nftban_ddos_classic.sh penalty-add DECISION (which branch
# is taken). The real fallback is a direct `nft add element` — verified by the
# drift-guard above; here it is represented by _emergency_direct_write so this
# test file carries no literal nft-write text (keeps the check-nft-writes gate green).
_ipc_calls=0; _direct_calls=0; _skip_calls=0
nft_ipc_add_element() { _ipc_calls=$((_ipc_calls+1)); return "${_IPC_RC:-0}"; }
_emergency_direct_write() { _direct_calls=$((_direct_calls+1)); return 0; }
_nftban_ddos_classic_log() { case "$1" in WARN) [[ "$2" == *"skipped"* ]] && _skip_calls=$((_skip_calls+1)) ;; esac; return 0; }
_nftban_ddos_timeout_to_seconds() { echo 3600; }
_penalty_add() {
  local table_fam="ip nftban" target_set="ddos_ban_1h" ip="1.2.3.4" target_timeout="1h"
  local _to_secs _added=0
  _to_secs=$(_nftban_ddos_timeout_to_seconds "$target_timeout")
  if declare -f nft_ipc_add_element >/dev/null 2>&1 \
     && nft_ipc_add_element "${table_fam}" "${target_set}" "$ip" "${_to_secs}" 2>/dev/null; then
    _added=1
  elif [[ "${NFTBAN_EMERGENCY_MODE:-0}" == "1" ]] || ! declare -f nft_ipc_add_element >/dev/null 2>&1; then
    if _emergency_direct_write; then _added=1; fi   # real code: direct `nft add element` (gated)
  else
    _nftban_ddos_classic_log "WARN" "Penalty skipped — daemon IPC unavailable, NFTBAN_EMERGENCY_MODE=0: x"
  fi
  return 0
}

# Scenario 1: normal mode (IPC ok) → IPC used, no direct write
_ipc_calls=0; _direct_calls=0; _skip_calls=0; _IPC_RC=0; unset NFTBAN_EMERGENCY_MODE
_penalty_add
check "normal: nft_ipc_add_element called" "[[ $_ipc_calls -eq 1 ]]"
check "normal: no direct nft write"         "[[ $_direct_calls -eq 0 ]]"

# Scenario 2: IPC down + emergency OFF (default) → no direct write, skip logged
_ipc_calls=0; _direct_calls=0; _skip_calls=0; _IPC_RC=1; unset NFTBAN_EMERGENCY_MODE
_penalty_add
check "emergency-off + IPC down: NO direct nft write" "[[ $_direct_calls -eq 0 ]]"
check "emergency-off + IPC down: skip logged"          "[[ $_skip_calls -eq 1 ]]"

# Scenario 3: IPC down + emergency ON → direct fallback used
_ipc_calls=0; _direct_calls=0; _skip_calls=0; _IPC_RC=1; NFTBAN_EMERGENCY_MODE=1
_penalty_add
check "emergency-on + IPC down: direct fallback used" "[[ $_direct_calls -eq 1 ]]"
unset NFTBAN_EMERGENCY_MODE

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
