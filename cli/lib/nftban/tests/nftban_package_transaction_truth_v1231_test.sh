#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.231.0 Item 2b package-transaction truth
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_package_transaction_truth_v1231_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Hermetic tests for core/nftban_output.sh::nftban_package_transaction_classify, ::nftban_render_package_transaction_truth and the 6th (package-transaction) argument of ::nftban_render_operator_readiness. Covers the v1.231.0 defect PACKAGE_TRANSACTION_SUCCEEDS_WHILE_INSTALLER_TERMINAL_FAILURE: dpkg/rpm record the package installed and apt/dnf exit 0 while the bundled installer reached a terminal failure or never ran at all. The boundary receipt is the only durable carrier of that verdict, and the decisive case is a STALE same-version COMMITTED install_state, where no post-transaction reader can derive the truth from install_state alone. Carries declared-inversion negative controls: the pre-fix call shape (no 6th argument) must PASS the same NOT_VERIFIED fixture, and a receipt missing its completeness marker must never be read for content."
# meta:input="None (temp-dir receipt fixtures, self-contained)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="/var/lib/nftban/state/package_transaction"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nftban_package_transaction_truth_v1231_test"
# meta:ta.owner="health"
# meta:ta.module="package-transaction-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }
eq()  { if [[ "$2" == "$1" ]]; then ok "$3 (= $1)"; else bad "$3 — got '${2:-<empty>}', want '$1'"; fi; }
ar()  { if grep -qE -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (no match: $2)"; fi; }
nr()  { if grep -qE -- "$2" <<<"$1"; then bad "$3 (unexpected: $2)"; else ok "$3"; fi; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# mkreceipt <file> <version> <verified> <verdict> [complete]
# Shaped exactly like what the packaging recorder writes: package context first,
# then the verifier's tokens verbatim, then the completeness marker LAST.
mkreceipt() {
    local f="$1" ver="$2" verified="$3" verdict="$4" complete="${5:-1}"
    {
        echo "PACKAGE_TRANSACTION_SCHEMA=1"
        echo "PACKAGE_FAMILY=deb"
        echo "PACKAGE_MODE=upgrade"
        echo "PACKAGE_VERSION=${ver}"
        echo "PACKAGE_SCRIPT_START_UTC=2026-09-14T10:00:00.000000000Z"
        echo "NFTBAN_PACKAGE_INSTALLER_EXIT=75"
        echo "NFTBAN_PACKAGE_VERIFY_EXIT=2"
        echo "NFTBAN_PACKAGE_POSTINSTALL_VERIFIED=${verified}"
        echo "NFTBAN_PERSISTED_INSTALL_STATE=COMMITTED"
        echo "NFTBAN_PERSISTED_STATE_VERSION=${ver}"
        echo "NFTBAN_INSTALL_ATTEMPT_VERDICT=${verdict}"
        echo "NFTBAN_INSTALL_VERIFIED=${verified}"
        [[ "$complete" == "1" ]] && echo "PACKAGE_RECEIPT_COMPLETE=1"
    } > "$f"
    return 0
}

echo "v1.231.0 Item 2b — package-transaction truth (hermetic)"

# -----------------------------------------------------------------------------
echo "T1 classify — the four classes"
# -----------------------------------------------------------------------------
eq "NO_RECEIPT"    "$(nftban_package_transaction_classify "$W/absent" 1.231.0)" \
   "T1a absent receipt is NO_RECEIPT, not a failure (source install / pre-v1.231 package)"
eq "NO_RECEIPT"    "$(nftban_package_transaction_classify "" 1.231.0)" \
   "T1b empty path is NO_RECEIPT"

mkreceipt "$W/ok" 1.231.0 YES CURRENT_COMMITTED
eq "VERIFIED"      "$(nftban_package_transaction_classify "$W/ok" 1.231.0)" "T1c verified receipt"

mkreceipt "$W/stale" 1.231.0 NO STALE_STATE
eq "NOT_VERIFIED"  "$(nftban_package_transaction_classify "$W/stale" 1.231.0)" "T1d STALE_STATE receipt"

mkreceipt "$W/trunc" 1.231.0 NO STALE_STATE 0
eq "INDETERMINATE" "$(nftban_package_transaction_classify "$W/trunc" 1.231.0)" \
   "T1e truncated receipt is INDETERMINATE — never read for content"

# -----------------------------------------------------------------------------
echo "T2 POSITIVE ASSERTION — only the literal YES may verify"
# -----------------------------------------------------------------------------
# An enumeration of known-bad values would let a value no build recognises fall
# through to a pass. This is the same rule the install_state classifier follows.
for v in NO yes Yes TRUE 1 "" MAYBE_LATER_LITERAL; do
    mkreceipt "$W/lit" 1.231.0 "$v" STALE_STATE
    got="$(nftban_package_transaction_classify "$W/lit" 1.231.0)"
    if [[ "$v" == "" ]]; then
        eq "INDETERMINATE" "$got" "T2 empty verdict value -> INDETERMINATE"
    else
        eq "NOT_VERIFIED" "$got" "T2 verdict '$v' is not the literal YES -> NOT_VERIFIED"
    fi
done

# -----------------------------------------------------------------------------
echo "T3 STALE RECEIPT — a verdict for another version cannot answer for this one"
# -----------------------------------------------------------------------------
# This is the shape left behind when a LATER transaction installed what is on
# disk now and recorded nothing: the newest evidence is absent, not favourable.
mkreceipt "$W/oldver" 1.230.0 YES CURRENT_COMMITTED
eq "NOT_VERIFIED" "$(nftban_package_transaction_classify "$W/oldver" 1.231.0)" \
   "T3a a YES receipt for 1.230.0 does not verify an installed 1.231.0"
eq "VERIFIED"     "$(nftban_package_transaction_classify "$W/oldver" 1.230.0)" \
   "T3b the same receipt does verify the version it describes"
eq "VERIFIED"     "$(nftban_package_transaction_classify "$W/oldver")" \
   "T3c with no installed version supplied the version axis asserts nothing"

# -----------------------------------------------------------------------------
echo "T4 renderer — silent on success and on absence, loud otherwise"
# -----------------------------------------------------------------------------
OUT="$(nftban_render_package_transaction_truth "$W/ok" 1.231.0 || true)"
eq "" "$OUT" "T4a a verified package transaction renders nothing"
nftban_render_package_transaction_truth "$W/ok" 1.231.0 >/dev/null && ok "T4b verified -> rc 0" || bad "T4b verified -> rc 0"

OUT="$(nftban_render_package_transaction_truth "$W/absent" 1.231.0 || true)"
eq "" "$OUT" "T4c NO_RECEIPT renders nothing — an absent file is not a finding"
nftban_render_package_transaction_truth "$W/absent" 1.231.0 >/dev/null && ok "T4d NO_RECEIPT -> rc 0" || bad "T4d NO_RECEIPT -> rc 0"

OUT="$(nftban_render_package_transaction_truth "$W/stale" 1.231.0 || true)"
ar "$OUT" "Package transaction"                     "T4e NOT_VERIFIED renders the block"
ar "$OUT" "Package verdict:[[:space:]]+NOT VERIFIED" "T4f names the verdict"
ar "$OUT" "STALE_STATE"                              "T4g names the cause verbatim from the receipt"
ar "$OUT" "installer exit 75"                        "T4h names the installer exit"
ar "$OUT" "Recovery:"                                "T4i gives the recovery command"
# ⛔ enforcement truth and transaction truth stay SEPARATE lines — conflating
#    them is the original defect this whole lane exists to correct.
ar "$OUT" "Enforcement:.*NOT evidence that the kernel stopped enforcing" \
   "T4j enforcement truth is stated separately and is not overclaimed"
nr "$OUT" "unprotected|not protected|firewall is down" \
   "T4k the block never claims the host is unprotected"
if ! nftban_render_package_transaction_truth "$W/stale" 1.231.0 >/dev/null; then
    ok "T4l NOT_VERIFIED -> rc 1 so a caller can gate on it"
else
    bad "T4l NOT_VERIFIED -> rc 1 so a caller can gate on it"
fi

OUT="$(nftban_render_package_transaction_truth "$W/oldver" 1.231.0 || true)"
ar "$OUT" "receipt describes 1.230.0 but 1.231.0 is installed" "T4m version-mismatch cause is explicit"

# -----------------------------------------------------------------------------
echo "T5 readiness verdict — the package axis must be able to force FAIL"
# -----------------------------------------------------------------------------
# THE DEFECT, in the exact shape that reaches an operator: install_state is a
# same-version COMMITTED left by a PREVIOUS transaction, the validator is happy,
# and the package boundary is the only thing that knows the truth.
CLEAN_JSON='{"status":"protected","findings":[]}'

OUT="$(nftban_render_operator_readiness "$CLEAN_JSON" "COMMITTED" 0 "" "" "NOT_VERIFIED")"
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL" "T5a NOT_VERIFIED forces FAIL over a stale COMMITTED"
ar "$OUT" "package transaction: NOT VERIFIED"  "T5b the verdict block points at the package block"

OUT="$(nftban_render_operator_readiness "$CLEAN_JSON" "COMMITTED" 0 "" "" "INDETERMINATE")"
ar "$OUT" "Upgrade readiness:[[:space:]]+INDETERMINATE" "T5c unreadable receipt is never a PASS"
ar "$OUT" "Action needed:[[:space:]]+VERIFY"            "T5d INDETERMINATE asks the operator to VERIFY"

OUT="$(nftban_render_operator_readiness "$CLEAN_JSON" "COMMITTED" 0 "" "" "VERIFIED")"
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS" "T5e VERIFIED does not disturb a clean verdict"
nr "$OUT" "package transaction"                "T5f VERIFIED prints no package pointer line"

OUT="$(nftban_render_operator_readiness "$CLEAN_JSON" "COMMITTED" 0 "" "" "NO_RECEIPT")"
ar "$OUT" "Upgrade readiness:[[:space:]]+PASS" "T5g NO_RECEIPT asserts nothing — source installs stay PASS"
nr "$OUT" "package transaction"                "T5h NO_RECEIPT prints no package pointer line"

# NOT_VERIFIED must never MASK an existing failure either.
OUT="$(nftban_render_operator_readiness '{"status":"stopped","findings":[]}' "COMMITTED" 0 "" "" "VERIFIED")"
ar "$OUT" "Upgrade readiness:[[:space:]]+FAIL" "T5i a verified package transaction cannot rescue a stopped host"

# -----------------------------------------------------------------------------
echo "T6 DECLARED-INVERSION NEGATIVE CONTROLS"
# -----------------------------------------------------------------------------
# ⛔ EACH OF THESE MUST REPRODUCE THE PRE-FIX BEHAVIOUR. A negative control that
#    cannot pass against the defect proves nothing about the fix.

# 6a. The pre-fix CALL SHAPE: five arguments, no package axis. This is exactly
#     what cmd_health.sh passed before v1.231.0, and it is the call under which
#     a host that never ran the installer reported a clean bill of health.
OUT="$(nftban_render_operator_readiness "$CLEAN_JSON" "COMMITTED" 0 "" "")"
if grep -qE "Upgrade readiness:[[:space:]]+PASS" <<<"$OUT"; then
    ok "6a inversion: without the package axis the same host reads PASS — the defect is reproduced"
else
    bad "6a inversion: the pre-fix call shape did NOT reproduce the defect; T5a proves nothing"
fi
# and the fixed call shape must differ on the SAME inputs
OUT2="$(nftban_render_operator_readiness "$CLEAN_JSON" "COMMITTED" 0 "" "" "NOT_VERIFIED")"
if [[ "$OUT" != "$OUT2" ]]; then
    ok "6b inversion: adding the package axis changes the verdict on identical inputs"
else
    bad "6b inversion: the package axis made no difference — it is decorative"
fi

# 6c. The completeness marker must be load-bearing: a receipt that says YES but
#     was truncated before the marker must NOT read as VERIFIED.
mkreceipt "$W/yes_trunc" 1.231.0 YES CURRENT_COMMITTED 0
got="$(nftban_package_transaction_classify "$W/yes_trunc" 1.231.0)"
if [[ "$got" == "VERIFIED" ]]; then
    bad "6c inversion: a truncated YES receipt read as VERIFIED — the completeness marker is decorative"
else
    eq "INDETERMINATE" "$got" "6c inversion: a truncated YES receipt is INDETERMINATE, never VERIFIED"
fi

# 6d. An unreadable (not merely absent) receipt must not read as NO_RECEIPT-by-luck
#     with a content-bearing verdict. Permission-denied is indistinguishable from
#     absent to this classifier BY DESIGN, and both are non-assertive — but a
#     receipt that IS readable and says nothing must be INDETERMINATE, not absent.
printf 'PACKAGE_TRANSACTION_SCHEMA=1\nPACKAGE_RECEIPT_COMPLETE=1\n' > "$W/empty_verdict"
eq "INDETERMINATE" "$(nftban_package_transaction_classify "$W/empty_verdict" 1.231.0)" \
   "6d a readable receipt with no verdict key is INDETERMINATE, not NO_RECEIPT"

# -----------------------------------------------------------------------------
echo "T7 cmd_health wiring — the reader must actually be called"
# -----------------------------------------------------------------------------
# A classifier nothing calls is not a control. Assert the shipped call site,
# not a transcription of it.
H="${NFTBAN_LIB_DIR}/cli/cmd_health.sh"
if grep -q 'nftban_package_transaction_classify "\$_pkgtx_file" "\$_pkgtx_version"' "$H"; then
    ok "T7a cmd_health classifies the package transaction"
else
    bad "T7a cmd_health does not classify the package transaction"
fi
if grep -q 'nftban_render_operator_readiness "\$output" "\$_istate_class" "\$validator_rc" "\$_fth_code" "\$_comms_code" "\$_pkgtx_class"' "$H"; then
    ok "T7b cmd_health passes the package axis to the readiness verdict"
else
    bad "T7b cmd_health does not pass the package axis to the readiness verdict"
fi
if grep -q 'nftban_render_package_transaction_truth "\$_pkgtx_file" "\$_pkgtx_version"' "$H"; then
    ok "T7c cmd_health renders the package-transaction block"
else
    bad "T7c cmd_health does not render the package-transaction block"
fi
# the two blocks must stay SEPARATE calls — never merged into one authority
if grep -q 'nftban_render_install_transaction_truth' "$H"; then
    ok "T7d the install-transaction block is still rendered separately"
else
    bad "T7d the install-transaction block was removed — the two authorities were merged"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
