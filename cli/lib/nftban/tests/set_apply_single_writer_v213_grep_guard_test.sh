#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.213.0 - SET_APPLY_SINGLE_WRITER (Design A) static grep-guard
# =============================================================================
# meta:name="set_apply_single_writer_v213_grep_guard_test"
# meta:type="test"
# meta:version="1.213.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Static drift-guard: feeds/geoban/trust normal path routes through nft_ipc_sync_or_apply (FULL sync), no longer invokes nft_ipc_apply_ruleset as the PRIMARY writer (only the shared fallback in nft_ipc.sh does); no quick-sync on that path; no new daemon reject-guard; SchemaVersionCurrent stays 1.84.0; VERSION stays 1.212.0"
# meta:input="None (reads repo source read-only)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_feeds.sh,cli/lib/nftban/core/nftban_geoban.sh,cli/lib/nftban/core/nftban_trust.sh,cli/lib/nftban/lib/nft_ipc.sh,cmd/nftband/daemon_handlers_sync.go,internal/validator/types.go,VERSION"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"

FEEDS="$REPO_ROOT/cli/lib/nftban/core/nftban_feeds.sh"
GEOBAN="$REPO_ROOT/cli/lib/nftban/core/nftban_geoban.sh"
TRUST="$REPO_ROOT/cli/lib/nftban/core/nftban_trust.sh"
IPC="$REPO_ROOT/cli/lib/nftban/lib/nft_ipc.sh"
SYNC_GO="$REPO_ROOT/cmd/nftband/daemon_handlers_sync.go"
ELEM_GO="$REPO_ROOT/cmd/nftband/daemon_handlers_elements.go"
TYPES_GO="$REPO_ROOT/internal/validator/types.go"
VER="$REPO_ROOT/VERSION"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== set_apply_single_writer_v213_grep_guard ==="

# --- shared helper exists + is exported --------------------------------------
echo "--- nft_ipc.sh: shared FULL-sync helper ---"
if grep -q '^nft_ipc_sync()' "$IPC"; then ok "nft_ipc_sync defined"; else bad "nft_ipc_sync missing"; fi
if grep -q '^nft_ipc_sync_or_apply()' "$IPC"; then ok "nft_ipc_sync_or_apply defined"; else bad "nft_ipc_sync_or_apply missing"; fi
if grep -q 'export -f nft_ipc_sync$' "$IPC" && grep -q 'export -f nft_ipc_sync_or_apply$' "$IPC"; then
    ok "both helpers exported"
else
    bad "helpers not exported"
fi
# FULL sync only (quick=false), never quick=true on this path
if grep -q '"quick":false' "$IPC" && ! grep -q '"quick":true' "$IPC"; then
    ok "nft_ipc_sync forces quick:false and never quick:true"
else
    bad "nft_ipc_sync does not force a FULL (quick:false) sync"
fi
# fallback path + visible WARN live inside the shared helper
if grep -q 'nft_ipc_apply_ruleset "\$fallback_file"' "$IPC" \
   && grep -qi '\[WARN\] .*sync IPC failed, fell back to legacy additive apply' "$IPC"; then
    ok "sync-or-apply keeps the legacy additive apply as fallback with a visible WARN"
else
    bad "sync-or-apply fallback/WARN missing"
fi

# --- each module routes through the FULL-sync helper -------------------------
echo "--- feeds/geoban/trust: normal path uses nft_ipc_sync_or_apply ---"
for f in "$FEEDS" "$GEOBAN" "$TRUST"; do
    name="$(basename "$f")"
    if grep -q 'nft_ipc_sync_or_apply' "$f"; then
        ok "$name routes normal-path writes through nft_ipc_sync_or_apply"
    else
        bad "$name does NOT use nft_ipc_sync_or_apply"
    fi
done

# --- no module INVOKES apply_ruleset as the PRIMARY writer -------------------
# (type -t availability checks and comments are allowed; a primary invocation
#  passes a file variable: nft_ipc_apply_ruleset "$...")
echo "--- no primary additive apply in the modules (fallback lives in nft_ipc.sh) ---"
for f in "$FEEDS" "$GEOBAN" "$TRUST"; do
    name="$(basename "$f")"
    if grep -qE 'nft_ipc_apply_ruleset[[:space:]]+"\$' "$f"; then
        bad "$name still invokes nft_ipc_apply_ruleset as a primary writer"
    else
        ok "$name has no primary nft_ipc_apply_ruleset invocation"
    fi
done

# --- no quick-sync on the module path ---------------------------------------
echo "--- no quick sync on the converted path ---"
for f in "$FEEDS" "$GEOBAN" "$TRUST"; do
    name="$(basename "$f")"
    if grep -q '"quick":true' "$f"; then
        bad "$name sends a quick sync (would skip feeds/geoban/whitelist reconcile)"
    else
        ok "$name never requests a quick sync"
    fi
done

# --- daemon: comment corrected, NO new reject-guard (mixed-version safe) -----
echo "--- daemon: phased writer comment + no reject-guard ---"
if grep -qi 'STILL ACCEPTS the legacy' "$SYNC_GO" \
   && grep -qi 'DEFERRED to a phased' "$SYNC_GO"; then
    ok "daemon_handlers_sync.go comment states the phased contract (accepts legacy; reject-guard deferred)"
else
    bad "daemon_handlers_sync.go comment not corrected to the phased contract"
fi
if [[ -f "$ELEM_GO" ]] && grep -qiE 'reject.*(blacklist|whitelist)_(ipv4|ipv6)|(blacklist|whitelist)_(ipv4|ipv6).*reject' "$ELEM_GO"; then
    bad "a daemon reject-guard for blacklist/whitelist apply was added (must be deferred)"
else
    ok "no daemon blacklist/whitelist reject-guard added"
fi

# --- schema + version pinned -------------------------------------------------
echo "--- schema + version pinned ---"
if grep -q 'SchemaVersionCurrent = "1.84.0"' "$TYPES_GO"; then
    ok "SchemaVersionCurrent stays 1.84.0"
else
    bad "SchemaVersionCurrent changed"
fi
if [[ "$(tr -d '[:space:]' < "$VER")" == "1.212.0" ]]; then
    ok "VERSION stays 1.212.0"
else
    bad "VERSION changed (got $(cat "$VER"))"
fi

echo ""
echo "=== set_apply_single_writer_v213_grep_guard: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
