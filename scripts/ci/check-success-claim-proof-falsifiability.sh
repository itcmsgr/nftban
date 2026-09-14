#!/usr/bin/env bash
# =============================================================================
# NFTBan - falsifiability control for the success-claim guard (v1.231.0)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-success-claim-proof-falsifiability"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Proves check-success-claim-proof.sh discriminates. Requires: a clean baseline on the real subject; a TRIP on the negative fixture that NAMES the transport verb; a PASS on the positive fixture that carries the same verbs; a TRIP on a DECLARED INVERSION of the real subject that restores the two motivating v1.231.0 defects (the negative control must hit the motivating defect, not only a toy); and rc=2 -- never a silent pass -- on a zero-call-site emitter and on a missing subject. Every mutation is applied to a COPY; the tracked tree is never written."
# meta:input="scripts/ci/check-success-claim-proof.sh, its fixtures, cli/lib/nftban/cli/cmd_connector.sh"
# meta:output="PASS/FAIL per case; exit 0 when the guard discriminates on every case"
# meta:depends="bash,python3,sed,grep,awk,cksum,cmp,mktemp"
# meta:inventory.files="scripts/ci/fixtures/success-claim-proof/negative_unchecked_transport.sh,scripts/ci/fixtures/success-claim-proof/positive_checked_transport.sh"
# meta:inventory.binaries="bash,python3,sed,grep,awk,cksum,cmp,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# WHY A DECLARED INVERSION AND NOT "the previous commit".
#   origin/main inverts the moment the fix merges, so a negative control pinned
#   to it stops reproducing the defect exactly when it matters. The inversion
#   below is declared IN THIS FILE as an edit of the CURRENT subject: it is
#   stable across merges, works in a shallow checkout, and -- unlike a fixture
#   -- it is applied to the REAL motivating file.
#
#   It is applied to a COPY under $TMPDIR. The tracked tree is never mutated,
#   and the control asserts that at the end.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2

GUARD="scripts/ci/check-success-claim-proof.sh"
SUBJECT="cli/lib/nftban/cli/cmd_connector.sh"
FIX_DIR="scripts/ci/fixtures/success-claim-proof"
NEG="$FIX_DIR/negative_unchecked_transport.sh"
POS="$FIX_DIR/positive_checked_transport.sh"
EMITTER="_connector_print_success"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT INT TERM

SUBJECT_SHA_BEFORE="$(cksum "$SUBJECT" | awk '{print $1"-"$2}')"

echo "=== falsifiability control for $GUARD ==="
echo ""

# --- STAGE 0: the pieces must actually exist -------------------------------
# TOOL-ABSENCE MUST NOT READ AS AN EMPTY PASS.
for f in "$GUARD" "$SUBJECT" "$NEG" "$POS"; do
    if [[ ! -r "$f" ]]; then
        printf '  [FAIL] REQUIRED INPUT MISSING: %s\n' "$f"
        echo "=== falsifiability: PASS=$PASS FAIL=1 (aborted) ==="
        exit 2
    fi
done
ok "STAGE0 guard, subject and both fixtures present"

# --- STAGE 1: baseline on the real subject ---------------------------------
base_out="$(bash "$GUARD" 2>&1)"; base_rc=$?
if [[ $base_rc -eq 0 ]]; then
    ok "STAGE1 BASELINE_CLEAN on $SUBJECT (rc=0) - later trips are attributable"
else
    bad "STAGE1 BASELINE_ALREADY_FAILS (rc=$base_rc) - the guard cannot attribute an injection"
    printf '%s\n' "$base_out" | sed 's/^/        /'
fi
# the baseline must have examined a non-trivial population
if grep -qE 'call_sites=([2-9]|[1-9][0-9]+)' <<<"$base_out"; then
    ok "STAGE1 baseline examined a non-empty call-site population"
else
    bad "STAGE1 baseline examined ZERO/ONE call sites - an empty scan is not a pass"
fi

# --- STAGE 2: negative fixture MUST trip, and must NAME the transport -------
neg_out="$(bash "$GUARD" --scan "$NEG" --emitter "$EMITTER" 2>&1)"; neg_rc=$?
if [[ $neg_rc -ne 1 ]]; then
    bad "STAGE2 BLIND TO the negative fixture (rc=$neg_rc, expected 1)"
elif grep -q 'SUCCESS_CLAIM_UNPROVEN' <<<"$neg_out" \
     && grep -q '`nc`' <<<"$neg_out" \
     && grep -q '`kafka-console-producer.sh`' <<<"$neg_out"; then
    ok "STAGE2 DETECTS both unchecked-transport shapes and names each verb"
else
    bad "STAGE2 MISATTRIBUTED - tripped but did not name nc and kafka-console-producer.sh"
    printf '%s\n' "$neg_out" | sed 's/^/        /'
fi

# --- STAGE 3: positive fixture MUST NOT trip -------------------------------
pos_out="$(bash "$GUARD" --scan "$POS" --emitter "$EMITTER" 2>&1)"; pos_rc=$?
if [[ $pos_rc -eq 0 ]]; then
    ok "STAGE3 does NOT trip on checked-status transports carrying the same verbs"
else
    bad "STAGE3 OVER-MATCHES the positive fixture (rc=$pos_rc)"
    printf '%s\n' "$pos_out" | sed 's/^/        /'
fi
# the positive fixture must contain the same verbs, or the PASS proves nothing
if grep -q 'nc -u -w1' "$POS" && grep -q 'curl' "$POS" && grep -q 'wget' "$POS"; then
    ok "STAGE3 the positive fixture really does carry the flagged verbs"
else
    bad "STAGE3 the positive fixture lost its transports - its PASS is vacuous"
fi

# ---------------------------------------------------------------------------
# STAGE 4: DECLARED INVERSION of the REAL subject.
#   The negative control has to hit the MOTIVATING defect. Restore, on a copy,
#   exactly the two shapes v1.231.0 removed, and require the guard to trip on
#   the real file at the real call sites.
# ---------------------------------------------------------------------------
INV="$WORK/cmd_connector_inverted.sh"
cp "$SUBJECT" "$INV" || exit 2

# inversion A (syslog): drop the rc capture and the failure branch, leaving the
# transport unchecked and the success claim unconditional -- the pre-fix shape.
python3 - "$INV" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()

# --- syslog arm: back to "fire and claim" ---------------------------------
# Anchored on the rc capture this release introduced, running to the end of the
# case arm. Anchors are STRUCTURE (the rc variable, the arm terminator), not
# operator-facing wording, so a message reword does not silently disable the
# negative control -- and if the structure does change, the exit-3 below fires.
syslog_fixed = re.compile(
    r'[ \t]*local _syslog_rc=0\n.*?(?=\n[ \t]*;;)', re.S)
syslog_pre = (
    '            if [[ "$proto" == "udp" ]]; then\n'
    '                echo "$msg" | nc -u -w1 "$host" "$port"\n'
    '            else\n'
    '                echo "$msg" | nc -w1 "$host" "$port"\n'
    '            fi\n'
    '            _connector_print_success "Event pushed to syslog"')
s, n_sys = syslog_fixed.subn(lambda m: syslog_pre, s, count=1)

# --- kafka arm: back to "redirect stderr, discard rc, claim" ---------------
kafka_fixed = re.compile(
    r'[ \t]*local _kafka_rc=0[^\n]*\n.*?_connector_print_success "Event pushed to Kafka"',
    re.S)
kafka_pre = (
    '                echo "$event_json" | kafka-console-producer.sh \\\n'
    '                    --broker-list "$CONNECTOR_KAFKA_BROKERS" \\\n'
    '                    --topic "$CONNECTOR_KAFKA_TOPIC" 2>/dev/null\n'
    '                _connector_print_success "Event pushed to Kafka"')
s, n_kaf = kafka_fixed.subn(lambda m: kafka_pre, s, count=1)

if n_sys != 1 or n_kaf != 1:
    sys.stderr.write(
        "INVERSION_NOT_APPLIED syslog=%d kafka=%d - the fix's shape changed; "
        "update the declared inversion rather than deleting it\n" % (n_sys, n_kaf))
    sys.exit(3)
open(p, "w").write(s)
PY
inv_apply_rc=$?

if [[ $inv_apply_rc -ne 0 ]]; then
    bad "STAGE4 the declared inversion no longer matches the subject (rc=$inv_apply_rc) - NOT a pass"
elif cmp -s "$SUBJECT" "$INV"; then
    bad "STAGE4 the inversion produced an IDENTICAL file - ASSERT(X==X) proves nothing"
else
    ok "STAGE4 declared inversion applied to a copy of the real subject"
    inv_out="$(bash "$GUARD" --scan "$INV" --emitter "$EMITTER" 2>&1)"; inv_rc=$?
    if [[ $inv_rc -ne 1 ]]; then
        bad "STAGE4 BLIND TO the motivating defect in the REAL file (rc=$inv_rc, expected 1)"
        printf '%s\n' "$inv_out" | sed 's/^/        /'
    elif grep -q '`nc`' <<<"$inv_out" && grep -q '`kafka-console-producer.sh`' <<<"$inv_out"; then
        ok "STAGE4 DETECTS the motivating defect when re-injected into $SUBJECT"
    else
        bad "STAGE4 tripped on the inverted real file but did not name both transports"
        printf '%s\n' "$inv_out" | sed 's/^/        /'
    fi
fi

# --- STAGE 5: an empty scan is never a pass --------------------------------
ghost_out="$(bash "$GUARD" --scan "$SUBJECT" --emitter "_no_such_success_emitter" 2>&1)"; ghost_rc=$?
if [[ $ghost_rc -eq 2 ]] && grep -q 'ZERO call sites' <<<"$ghost_out"; then
    ok "STAGE5 a zero-call-site emitter exits 2 (tool/config failure), not 0"
else
    bad "STAGE5 a zero-call-site emitter returned rc=$ghost_rc - an empty scan read as a pass"
fi

bash "$GUARD" --scan "$WORK/does_not_exist.sh" --emitter "$EMITTER" >/dev/null 2>&1; missing_rc=$?
if [[ $missing_rc -eq 2 ]]; then
    ok "STAGE5 a missing subject exits 2, not 0"
else
    bad "STAGE5 a missing subject returned rc=$missing_rc - absence read as a pass"
fi

# --- STAGE 6: the tracked tree was not mutated -----------------------------
SUBJECT_SHA_AFTER="$(cksum "$SUBJECT" | awk '{print $1"-"$2}')"
if [[ "$SUBJECT_SHA_BEFORE" == "$SUBJECT_SHA_AFTER" ]]; then
    ok "STAGE6 $SUBJECT is byte-identical to its pre-run state"
else
    bad "STAGE6 $SUBJECT WAS MUTATED by this control ($SUBJECT_SHA_BEFORE -> $SUBJECT_SHA_AFTER)"
fi

echo ""
echo "=== falsifiability: PASS=$PASS FAIL=$FAIL ==="
exit $(( FAIL > 0 ? 1 : 0 ))
