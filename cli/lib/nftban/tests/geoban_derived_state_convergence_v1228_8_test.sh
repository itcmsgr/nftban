#!/usr/bin/env bash
# =============================================================================
# NFTBan - GeoBan/feeds derived-state convergence truth (v1.228.8 PR2 Step 0)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="geoban_derived_state_convergence_v1228_8_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="PR2 Step 0 controls. (A) ATTRIBUTION regression for the v1.228.7 GeoBan defect: with a country configured and the retired GEOIP_BINARY empty, the OLD direct invocation exits 127 for every country while the FIXED path routes through the guarded fetch authority. (B) No unguarded retired-binary invocation survives in nftban_geoban.sh. (C) The rebuild/reset lanes no longer call `nftban geoban sync` (not a dispatch verb - it hit the unknown-command branch and was swallowed) or `nftban-core feeds sync` (short-circuits on unchanged config mtime and returns SUCCESS without restoring). (D) Both reconcile authorities propagate their result instead of being swallowed by || true. (E) zero-country configuration stays a valid no-op."
# meta:ta.id="geoban_derived_state_convergence_v1228_8_test"
# meta:ta.owner="geoban"
# meta:ta.module="derived-state-convergence"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
GEOBAN="$LIB/core/nftban_geoban.sh"
FIREWALL="$LIB/cli/cmd_firewall.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== A. ATTRIBUTION — reproduce the exact v1.228.7 failure, then prove the fix ==="
# The regression: v1.228.7 retired the standalone geoip binary and set
# GEOIP_BINARY="". nftban_geoban_update invoked it DIRECTLY, without the
# soft-check its siblings use, so the command was empty.
GEOIP_BINARY=""
rc=0; "${GEOIP_BINARY}" geoban fetch GR --action ban >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 127 ]]; then
    ok "OLD form reproduces the defect: empty GEOIP_BINARY -> rc=127 per country"
else
    bad "OLD form did not reproduce rc=127 (got $rc) — attribution control is vacuous"
fi

# The fix: that call site now routes through the guarded fetch authority, which
# soft-checks the binary and falls back to the bash IPDENY path.
if grep -qF 'if nftban_geoban_fetch_country "${cc}" "${action}"; then' "$GEOBAN"; then
    ok "FIXED form calls the guarded fetch authority in the update loop"
else
    bad "update loop does not call nftban_geoban_fetch_country"
fi

echo "=== B. no UNGUARDED retired-binary invocation survives ==="
unguarded=0
while IFS=: read -r ln _; do
    [[ -z "$ln" ]] && continue
    # a call is guarded when a soft-check appears in the 3 preceding lines
    if [[ "$(sed -n "$((ln-3)),${ln}p" "$GEOBAN" | grep -c 'check_binary_soft')" -eq 0 ]]; then
        unguarded=$((unguarded+1)); echo "      unguarded at line $ln"
    fi
done < <(grep -n '"\${GEOIP_BINARY}" geoban' "$GEOBAN" || true)
if [[ "$unguarded" -eq 0 ]]; then
    ok "every retired-binary invocation sits behind a soft-check with a bash fallback"
else
    bad "$unguarded unguarded retired-binary invocation(s) remain"
fi

echo "=== C. convergence lanes no longer call non-restoring interfaces ==="
# GUARD SUBJECT == GUARD INPUT: assert against CODE, not prose. The fix's own
# comments name the removed interfaces to explain why they were removed; a
# raw-source grep would let those comments fail an assertion about code (and,
# worse, would let a reworded comment satisfy it). Strip comment lines first.
code_only() { grep -vE '^[[:space:]]*#' "$1"; }
if [[ "$(code_only "$FIREWALL" | grep -c 'geoban sync' || true)" -eq 0 ]]; then
    ok "no 'nftban geoban sync' call (it was never a dispatch verb)"
else
    bad "'nftban geoban sync' still present — a call to a nonexistent interface"
fi
if [[ "$(code_only "$FIREWALL" | grep -c 'feeds sync' || true)" -eq 0 ]]; then
    ok "no 'feeds sync' call (it short-circuits on unchanged config and restores nothing)"
else
    bad "'feeds sync' still present — reports success without restoring after a rebuild"
fi
# `sync` really is absent from the geoban dispatch — proves C1 is not cosmetic.
if ! grep -qE '^\s+ban\|unban\|whitelist\|unwhitelist\|list\|update\|status\|refresh\)' "$LIB/cli/cmd_geoban.sh"; then
    bad "geoban dispatch line not found — cannot verify the verb set"
elif [[ "$(grep -E '^\s+ban\|unban\|whitelist\|unwhitelist\|list\|update\|status\|refresh\)' "$LIB/cli/cmd_geoban.sh" | grep -c 'sync' || true)" -gt 0 ]]; then
    bad "'sync' IS a geoban verb — the premise of this fix is wrong"
else
    ok "confirmed: 'sync' is absent from the geoban dispatch verb set"
fi

echo "=== D. reconcile authorities exist and PROPAGATE their result ==="
for fn in _nftban_reconcile_feeds _nftban_reconcile_geoban; do
    # match the DEFINITION, tolerant of formatting: the claim is "this function
    # exists", not "it is written on one line with one space".
    if grep -qE "^${fn}\\(\\)[[:space:]]*\\{" "$FIREWALL"; then
        ok "$fn defined"
    else
        bad "$fn missing"
    fi
done
# The old lanes swallowed everything with `2>/dev/null || true`, so a failed
# restore was indistinguishable from a successful one. The new callers must
# branch on the result.
# v1.229.12: this asserted two EXACT sentences ("... FAILED or unavailable (state
# NOT reconciled)"). Those were deliberately removed because they COLLAPSED a
# proven failure and an undetermined result into one message, and could not say
# DISABLED at all. Asserting the literal would now force the weaker wording back.
# The property is asserted instead, and more strictly than before.
_rp="$(sed -n '/^_fw_recover_producer()/,/^}/p' "$FIREWALL")"
if [[ -z "$_rp" ]]; then
    bad "no single recovery reporting contract found — each call site may report differently"
else
    ok "one reporting contract exists for every recovery call site"
    _miss=""
    for tok in DISABLED SYNCED PARTIAL FAILED UNAVAILABLE; do
        grep -q "$tok" <<<"$_rp" || _miss="$_miss $tok"
    done
    [[ -z "$_miss" ]] && ok "all five result states are distinguishable (never collapsed)" \
                      || bad "recovery reporting cannot express:$_miss"
    # FAILED and UNAVAILABLE must be SEPARATE branches, not one shared message.
    if [[ "$(grep -c 'FAILED' <<<"$_rp")" -ge 1 && "$(grep -c 'UNAVAILABLE' <<<"$_rp")" -ge 1 ]] \
       && ! grep -qE 'FAILED or unavailable' <<<"$_rp"; then
        ok "a proven failure and an undetermined result are reported separately"
    else
        bad "FAILED and UNAVAILABLE are still collapsed into one message"
    fi
    # Affirmative wording must be reachable ONLY from the proven-success branch.
    if grep -qE 'RECONCILED\)' <<<"$_rp" && grep -qE 'SYNCED \(intended coverage verified' <<<"$_rp"; then
        ok "affirmative wording is gated on proven coverage, not on an exit status"
    else
        bad "affirmative wording is not gated on proven coverage"
    fi
fi
# The old lanes swallowed everything with `2>/dev/null || true`, so a failed restore
# was indistinguishable from a successful one. No recovery call site may do that now.
if grep -nE 'nftban_feeds_sync_to_nftables 2>/dev/null \|\| true|_nftban_reconcile_(feeds|geoban) \|\| true' "$FIREWALL" \
     | grep -vE '^\s*[0-9]+:\s*#' >/dev/null; then
    bad "a recovery call site still discards its result with a bare || true"
else
    ok "no recovery call site discards its result with a bare || true"
fi

echo "=== E. zero-country configuration remains a valid no-op ==="
# nftban_geoban_apply_to_nftables warns and returns 0 when no 50-ban-* files
# exist; an empty GeoBan configuration is a legitimate state, not an error.
if grep -q 'No banned country files found' "$GEOBAN"; then
    ok "empty GeoBan configuration is handled explicitly (valid no-op)"
else
    bad "no explicit empty-configuration path"
fi

echo "=== F. operator guidance names a command that actually restores ==="
if grep -q 'nftban firewall rebuild        (reconciles feeds + GeoBan from durable state)' "$FIREWALL"; then
    ok "reset guidance points at the lane that performs the restore"
else
    bad "reset guidance still names non-restoring commands"
fi

echo
echo "=== geoban_derived_state_convergence_v1228_8: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
