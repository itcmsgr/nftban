#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan spool cursor identity + bounded reclamation (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_spool_cursor_identity_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="botscan"
# meta:ta.id="botscan_spool_cursor_identity_v1229_10_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-spool-lifecycle"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="90"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.229.10 — v1.209.3 relocated the BotScan spool /run/nftban/botscan -> /var/lib/nftban/botscan/spool. Cursor identity was derived from the ABSOLUTE PATH in BOTH the reader (nftban_http_read_incremental) and the reaper, so the relocation renamed every cursor key at once; the new lookup found nothing, a missing cursor was read as offset 0, the completion predicate off>=size could never become true, no completed spool object was ever reclaimed, the spool grew monotonically to its 1 GiB cap and collector backpressure latched permanently (measured fleet-wide 2026-08-25: 8/8 hosts carry old-key cursors, 6/8 carry zero current-key cursors; srv3 and srv4 latched at cap). Locks the canonical fix: ONE logical spool subject -> ONE canonical cursor identity -> SAME identity used by reader and reaper, with a bounded exact-and-unambiguous legacy migration that preserves the cursor value and never replays payload. Also locks that a MISSING cursor is UNKNOWN authority and NOT offset zero, that a CONFLICT keeps and reports, that empty spool objects are reclaimable without a cursor, and that deletion is namespace/type gated and never age-authorized."
# meta:inventory.files="cli/lib/nftban/lib/nftban_http_logs.sh,cli/lib/nftban/core/nftban_botscan.sh"
# meta:inventory.binaries="bash,stat,mktemp"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export NFTBAN_DATA_DIR="$TMP/data"
SPOOL="$NFTBAN_DATA_DIR/botscan/spool"
OFF="$NFTBAN_DATA_DIR/botscan/proc-offsets"
mkdir -p "$SPOOL" "$OFF"
export NFTBAN_HTTP_LOG_OFFSET_DIR="$OFF"
export BOTSCAN_SPOOL_DIR="$SPOOL"
export BOTSCAN_LOG_FILE="$TMP/botscan.log"

# shellcheck disable=SC1090
source "$SD/../lib/nftban_http_logs.sh" 2>/dev/null || { echo "cannot source http_logs"; exit 1; }
# Extract only the reaper/reclaim block — avoid pulling the whole module.
sed -n '/^: "${BOTSCAN_SPOOL_CURSOR_NS/,/^nftban_botscan_reclaim_spool() {/p' "$SD/../core/nftban_botscan.sh" | sed '$d' > "$TMP/reap.sh"
sed -n '/^nftban_botscan_reclaim_spool() {/,/^}/p' "$SD/../core/nftban_botscan.sh" >> "$TMP/reap.sh"
# shellcheck disable=SC1090
source "$TMP/reap.sh" 2>/dev/null || { echo "cannot source reaper"; exit 1; }
# The sourced module enables `set -e`; a reaper returning 1 means KEPT, which is a
# normal outcome, not an error. Restore the test's own shell discipline.
set +e

mk(){ printf '%*s' "$2" '' > "$SPOOL/$1"; }                     # spool file of N bytes
cur(){ printf '%s\n' "$2" > "$OFF/_botscan_spool_$1"; }          # canonical cursor
leg(){ printf '%s\n' "$2" > "$OFF/_run_nftban_botscan_$1"; }     # legacy cursor (old path)

echo "=== BotScan spool cursor identity + bounded reclamation (v1.229.10) ==="
echo ""

# --- P1 below cap, unconsumed file is KEPT -----------------------------------
mk _var_log_a.log 100; cur _var_log_a.log "1:10"
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_a.log" "$SPOOL" "$OFF" || true
[[ -f "$SPOOL/_var_log_a.log" ]] && ok "P1 partially-consumed object is KEPT" || no "P1 unread payload deleted"

# --- P2 completed object is reclaimed ----------------------------------------
mk _var_log_b.log 100; cur _var_log_b.log "1:100"
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_b.log" "$SPOOL" "$OFF" || true
[[ ! -f "$SPOOL/_var_log_b.log" ]] && ok "P2 proven-completed object is reclaimed" || no "P2 completed object not reclaimed"

# --- P3 empty object reclaimable WITHOUT any cursor --------------------------
mk _var_log_c.log 0
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_c.log" "$SPOOL" "$OFF" || true
[[ ! -f "$SPOOL/_var_log_c.log" ]] && ok "P3 empty object reclaimed with no cursor (scanner's -s never enumerates it)" || no "P3 empty object still latched"

# --- P4 LEGACY CURSOR MIGRATION (the owner-required arm) ---------------------
mk _var_log_d.log 500; leg _var_log_d.log "7:500"
[[ ! -f "$OFF/_botscan_spool__var_log_d.log" ]] || no "P4 precondition: canonical must be absent"
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_d.log" "$SPOOL" "$OFF" || true
[[ ! -f "$SPOOL/_var_log_d.log" ]] \
  && ok "P4 legacy cursor recognised via migration -> object became eligible" \
  || no "P4 legacy cursor NOT migrated — object stayed latched"
[[ ! -f "$OFF/_run_nftban_botscan__var_log_d.log" ]] \
  && ok "P4b legacy cursor retired after promotion (no second producer)" \
  || no "P4b legacy cursor still present — split authority remains"

# value preservation, checked without deleting
mk _var_log_e.log 900; leg _var_log_e.log "9:400"
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_e.log" "$SPOOL" "$OFF" || true
if [[ -f "$SPOOL/_var_log_e.log" ]] && [[ "$(cat "$OFF/_botscan_spool__var_log_e.log" 2>/dev/null)" == "9:400" ]]; then
    ok "P4c migration preserves the cursor value EXACTLY (400/900 -> kept, no replay)"
else
    no "P4c migration lost or altered the cursor value"
fi

# --- N1 no-cursor MUST NOT be treated as offset 0 ----------------------------
mk _var_log_f.log 100
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_f.log" "$SPOOL" "$OFF" || true
[[ -f "$SPOOL/_var_log_f.log" ]] \
  && ok "N1 missing cursor = UNKNOWN authority -> KEEP (a missing cursor is NOT offset 0)" \
  || no "N1 deleted an object with no completion authority"

# --- N2 outside the BotScan spool namespace MUST NOT be deleted --------------
OUT="$TMP/real_access.log"; printf 'x' > "$OUT"; cur _real "0:1"
nftban_botscan_reap_consumed_spool "$OUT" "$SPOOL" "$OFF" || true
[[ -f "$OUT" ]] && ok "N2 object outside the spool namespace is never deleted" || no "N2 DELETED A FILE OUTSIDE THE SPOOL"

# --- N3 symlink / wrong type MUST NOT be deleted -----------------------------
ln -sf "$OUT" "$SPOOL/_var_log_link.log" 2>/dev/null
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_link.log" "$SPOOL" "$OFF" || true
[[ -L "$SPOOL/_var_log_link.log" ]] && ok "N3 symlink is never reclaimed" || no "N3 symlink was deleted"
mkdir -p "$SPOOL/_var_log_dir.log"
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_dir.log" "$SPOOL" "$OFF" || true
[[ -d "$SPOOL/_var_log_dir.log" ]] && ok "N3b directory is never reclaimed" || no "N3b directory was deleted"
printf 'x' > "$SPOOL/not-a-spool-name"
nftban_botscan_reap_consumed_spool "$SPOOL/not-a-spool-name" "$SPOOL" "$OFF" || true
[[ -f "$SPOOL/not-a-spool-name" ]] && ok "N3c unexpected basename shape is never reclaimed" || no "N3c deleted an unexpected object"

# --- N5 conflicting authorities -> KEEP + report -----------------------------
mk _var_log_g.log 100; cur _var_log_g.log "1:100"; leg _var_log_g.log "1:20"
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_g.log" "$SPOOL" "$OFF" || true
[[ -f "$SPOOL/_var_log_g.log" ]] \
  && ok "N5 conflicting cursors -> KEEP (never pick the value that authorizes deletion)" \
  || no "N5 deleted on conflicting authority"
grep -q "CURSOR_CONFLICT" "$BOTSCAN_LOG_FILE" 2>/dev/null \
  && ok "N5b the conflict is reported, not silent" || no "N5b conflict not reported"

# --- N6 an unrelated old-key cursor must NOT migrate into this subject -------
mk _var_log_h.log 100; printf '1:100\n' > "$OFF/_run_nftban_botscan__var_log_SOMETHING_ELSE.log"
nftban_botscan_reap_consumed_spool "$SPOOL/_var_log_h.log" "$SPOOL" "$OFF" || true
[[ -f "$SPOOL/_var_log_h.log" ]] \
  && ok "N6 unrelated legacy cursor does NOT migrate into this subject" \
  || no "N6 migrated a foreign cursor — deleted unread payload"

# --- N7 REGRESSION GUARD: identity must not revert to path-only --------------
if grep -qE 'key="\$\(nftban_http_cursor_key "\$file"\)"' "$SD/../lib/nftban_http_logs.sh"; then
    ok "N7 the READER consumes the shared cursor identity (not its own path derivation)"
else
    no "N7 reader reverted to a private path-derived identity — split authority returns"
fi
if grep -q 'nftban_http_cursor_resolve' "$SD/../core/nftban_botscan.sh"; then
    ok "N7b the REAPER consumes the same shared resolver" || true
else
    no "N7b reaper does not use the shared resolver"
fi

# --- N4 the cap must remain a cap --------------------------------------------
if grep -qE 'SPOOL_TOTAL_MAX_BYTES="\$\{BOTSCAN_SPOOL_TOTAL_MAX_BYTES:-1073741824\}"' "$SD/../../../sbin/nftban-botscan-collector" 2>/dev/null; then
    ok "N4 the 1 GiB total-dir cap is unchanged (fix does not convert bounded -> unbounded)"
else
    no "N4 the spool cap value changed — moving the failure point is not fixing the mechanism"
fi

# --- forward progress: the sweep retires work so the bound stops being a latch
rm -f "$SPOOL"/* 2>/dev/null; rm -rf "$SPOOL/_var_log_dir.log" 2>/dev/null; rm -f "$OFF"/* 2>/dev/null
mk _var_log_p.log 10; cur _var_log_p.log "1:10"      # completed
mk _var_log_q.log 0                                   # empty
mk _var_log_r.log 50; cur _var_log_r.log "1:5"        # unread -> must survive
out="$(nftban_botscan_reclaim_spool "$SPOOL" "$OFF")" || true
if [[ "${out%% *}" == "2" ]] && [[ -f "$SPOOL/_var_log_r.log" ]]; then
    ok "FORWARD PROGRESS: sweep retired 2 (completed+empty), kept the unread object"
else
    no "FORWARD PROGRESS: sweep result unexpected (got '$out')"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "botscan spool cursor identity PASSED"
