#!/usr/bin/env bash
# =============================================================================
# NFTBan - two numbers from one run must say when they were observed (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="update_failed_units_temporal_truth_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="update"
# meta:ta.id="update_failed_units_temporal_truth_v1229_10_test"
# meta:ta.owner="update"
# meta:ta.module="update-report-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.229.10 closes CANDIDATE_UPDATE_SUMMARY_FAILED_UNITS_CONTRADICTS_ITS_OWN_ASSERTION. The update summary printed 'Failed units: 0' while the same run carried 'ASSERT failed_units_postinstall_ok: FAIL — 2 failed' (monitor run 20260824T211440Z-2782103). The discriminator showed neither is wrong: the summary observes via systemctl --failed AT SUMMARY TIME, the assertion observes in the Go validate plane AT POSTINSTALL TIME. The defect was that the summary never said which moment its number describes. Locks that the observation point is named, that the reader is told post-install assertions are reported separately and may differ, and — critically — that the measurement itself is UNCHANGED: this PR must not widen systemctl --failed, which is known from FB-12 to miss units in activating/auto-restart. That is a separate measurement-authority decision and is deliberately excluded."
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh"
# meta:inventory.binaries="bash,grep"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$SD/../cli/cmd_update_helpers.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# MENTION != CODE
body="$(grep -vE '^[[:space:]]*#' "$F" || true)"
has(){ grep -q "$1" <<<"$body"; }

echo "=== two numbers from one run must say when they were observed (v1.229.10) ==="
echo ""

# --- P1 the observation point is named in the rendered line ------------------
has 'observed now, at summary time' \
  && ok "P1 the failed-units line names its observation point" \
  || no "P1 the number is still presented without a time"

# --- P2 the reader is told the other producer exists and may differ ----------
has 'post-install assertions are reported separately and may differ' \
  && ok "P2 the reader is told a differing post-install assertion is expected, not a contradiction" \
  || no "P2 the other producer is not acknowledged"

# --- N1 the MEASUREMENT must be unchanged ------------------------------------
# Presentation-only. Widening the query is a separate decision.
has 'systemctl --failed --no-legend' \
  && ok "N1 the summary still measures with systemctl --failed (query unchanged)" \
  || no "N1 the measurement was altered in a presentation PR"
# Scope to the failed-units computation itself. The file legitimately uses
# `systemctl is-failed` elsewhere (watchdog, line ~529, pre-existing on main) —
# a whole-file check would fail on code this PR never touched.
#   GUARD SUBJECT == GUARD INPUT.
blk="$(awk '/local failed_units/,/Failed units:/' "$F" | grep -vE '^[[:space:]]*#' || true)"
if grep -qE 'NRestarts|SubState|ActiveState|is-failed' <<<"$blk"; then
    no "N1b the failed-units query was widened — that is the measurement-authority decision, not this PR"
else
    ok "N1b no widened unit-state query in the failed-units path (FB-12 limitation left OPEN)"
fi

# --- N2 the count itself must not be recomputed or reconciled ----------------
n=$(grep -c 'failed_units=\$(systemctl' <<<"$body" || true)
[[ "$n" -eq 1 ]] && ok "N2 exactly one producer of the count (no second/reconciling parser)" \
                 || no "N2 the count has $n producers — a second authority was introduced"

# --- N3 the number is still reported, not suppressed -------------------------
has 'Failed units:' && ok "N3 the count is still shown (described, not hidden)" || no "N3 the count was suppressed"

# --- N4 NEGATIVE CONTROL: guard must detect the pre-fix line -----------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '    printf "  | %-16s %s\n" "Failed units:"    "$failed_units"' > "$TMP/pre.sh"
if grep -q 'observed now, at summary time' "$TMP/pre.sh"; then
    no "N4 negative control is not the pre-fix shape"
else
    ok "N4 negative control: the pre-fix line has no observation point (P1 is meaningful)"
fi

# --- N5 a comment must not satisfy P1 ----------------------------------------
printf '%s\n' '# it should say observed now, at summary time' > "$TMP/c.sh"
cb="$(grep -vE '^[[:space:]]*#' "$TMP/c.sh" || true)"
if grep -q 'observed now, at summary time' <<<"$cb"; then
    no "N5 a COMMENT satisfied the check — MENTION != CODE not enforced"
else
    ok "N5 a commented mention does not satisfy the guard (MENTION != CODE)"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "update failed-units temporal truth PASSED"
