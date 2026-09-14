#!/usr/bin/env bash
# =============================================================================
# NFTBan - a connector push may claim success only when the transport succeeded
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="connector_push_success_claim_truth_v1231_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="comms"
# meta:ta.id="connector_push_success_claim_truth_v1231_test"
# meta:ta.owner="comms"
# meta:ta.module="connector-push-truth"
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
# meta:description="v1.231.0 closes SUCCESS_CLAIM_REQUIRES_PROVEN_SUCCESS in cli/lib/nftban/cli/cmd_connector.sh. Two push arms ran a transport and then emitted _connector_print_success unconditionally: syslog invoked nc with its status discarded, and kafka invoked kafka-console-producer.sh with stderr sent to /dev/null and its status discarded. Proven on lab4 (Rocky 9.8, nc absent): stdout 'Event pushed to syslog', stderr 'nc: command not found', rc=0; and on lab2 (Ubuntu 24.04, TCP connection refused): stdout 'Event pushed to syslog', EMPTY stderr, rc=0. This test drives _cmd_connector_push against stubbed transports and asserts the OBSERVABLE CONTRACT — exit status, which stream carries the verdict, and whether the transport's own diagnostic survives. It asserts the failure path AND the success path, so a fix that simply always fails cannot pass. The UDP arm must succeed while wording its claim as a send, not a delivery receipt, because nc cannot observe the far end of an unacknowledged datagram. A declared inversion reconstructs both pre-fix arms in a COPY of the real module and requires the same fixtures to reproduce the success claim, proving every assertion is live. Hermetic: throwaway config dir, a PATH built from symlinks so a transport's ABSENCE is real absence, no root, no systemd, no network, no real state."
# meta:inventory.files="cli/lib/nftban/cli/cmd_connector.sh"
# meta:inventory.binaries="bash,date,hostname,grep,cat,awk,sed,mktemp,ln"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SD/../cli/cmd_connector.sh"

PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }

echo "=== a connector push may claim success only when the transport succeeded (v1.231.0) ==="
echo ""

if [[ ! -r "$SUBJECT" ]]; then
    no "SUBJECT_ABSENT: $SUBJECT" "a missing subject is not a pass"
    echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

mkdir -p "$TMP/etc/connectors" "$TMP/nolib" "$TMP/minbin" "$TMP/out"

# --- a PATH we fully control -------------------------------------------------
# Built from symlinks so that the ABSENCE of a transport is REAL absence, not a
# stub pretending. TOOL-ABSENCE MUST NOT READ AS AN EMPTY PASS: if a tool the
# subject genuinely needs cannot be resolved, this test fails loudly here.
_missing=""
for _t in bash env date hostname grep cat sed; do
    _p="$(command -v "$_t" 2>/dev/null)" || _p=""
    if [[ -z "$_p" ]]; then _missing="$_missing $_t"; continue; fi
    ln -sf "$_p" "$TMP/minbin/$_t"
done
if [[ -n "$_missing" ]]; then
    no "HARNESS_INCOMPLETE: cannot resolve$_missing" "the subject could not run; this is NOT_EXECUTED, not a pass"
    echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
if [[ -e "$TMP/minbin/nc" ]]; then
    no "HARNESS_INVALID: nc leaked into the controlled PATH"
fi

# --- connector fixtures ------------------------------------------------------
cat > "$TMP/etc/connectors/sltcp.conf" <<'EOF'
CONNECTOR_NAME="sltcp"
CONNECTOR_TYPE="syslog"
CONNECTOR_ENABLED="true"
CONNECTOR_SYSLOG_HOST="127.0.0.1"
CONNECTOR_SYSLOG_PORT="5515"
CONNECTOR_SYSLOG_PROTO="tcp"
EOF
cat > "$TMP/etc/connectors/sludp.conf" <<'EOF'
CONNECTOR_NAME="sludp"
CONNECTOR_TYPE="syslog"
CONNECTOR_ENABLED="true"
CONNECTOR_SYSLOG_HOST="127.0.0.1"
CONNECTOR_SYSLOG_PORT="5516"
CONNECTOR_SYSLOG_PROTO="udp"
EOF
cat > "$TMP/etc/connectors/ka.conf" <<'EOF'
CONNECTOR_NAME="ka"
CONNECTOR_TYPE="kafka"
CONNECTOR_ENABLED="true"
CONNECTOR_KAFKA_BROKERS="127.0.0.1:9092"
CONNECTOR_KAFKA_TOPIC="nftban"
EOF

# --- driver: sources the subject and calls the push entrypoint the way the CLI
#     dispatcher does (`main "$@" || exit $?` suspends errexit for the tree) ---
cat > "$TMP/driver.sh" <<'EOF'
#!/usr/bin/env bash
SUBJ="$1"; CONN="$2"
export NFTBAN_CONFIG_DIR="$3"
export NFTBAN_LIB_DIR="$4"
# shellcheck source=/dev/null
source "$SUBJ"
rc=0
_cmd_connector_push "$CONN" test || rc=$?
exit $rc
EOF

# --- transport stubs ---------------------------------------------------------
stub_nc() {   # $1 = exit code
    cat > "$TMP/minbin/nc" <<EOF
#!/usr/bin/env bash
cat > "$TMP/out/nc_payload" 2>/dev/null || true
exit $1
EOF
    chmod +x "$TMP/minbin/nc"
}
stub_kafka() { # $1 = exit code
    cat > "$TMP/minbin/kafka-console-producer.sh" <<EOF
#!/usr/bin/env bash
cat > "$TMP/out/kafka_payload" 2>/dev/null || true
if [[ $1 -ne 0 ]]; then
    echo "ERROR Error when sending message to topic nftban: NOT_LEADER_OR_FOLLOWER" >&2
fi
exit $1
EOF
    chmod +x "$TMP/minbin/kafka-console-producer.sh"
}

OUT=""; ERR=""; RC=0
run_push() { # $1 = subject file, $2 = connector
    rm -f "$TMP/out/"* 2>/dev/null || true
    RC=0
    OUT="$(PATH="$TMP/minbin" bash "$TMP/driver.sh" "$1" "$2" "$TMP/etc" "$TMP/nolib" 2>"$TMP/stderr")" || RC=$?
    ERR="$(cat "$TMP/stderr" 2>/dev/null || true)"
    # A TEST RESULT IS VALID ONLY IF THE SUBJECT PROVABLY EXECUTED. This banner
    # is printed by _cmd_connector_push before it touches any transport, so its
    # absence means the harness failed, not that the subject behaved.
    grep -q "Pushing test event to" <<<"$OUT" || return 9
    return 0
}

claims_success() { grep -qiE 'Event (pushed|sent|written)' <<<"$OUT"; }

# --- harness precondition: the driver must actually reach the subject --------
stub_nc 0
if run_push "$SUBJECT" sltcp; then
    ok "H1 the harness reaches _cmd_connector_push under the controlled PATH"
else
    no "H1 HARNESS_PRECONDITION_FAILED" "driver rc=$RC stdout=[$OUT] stderr=[$ERR]"
    echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi

# =============================================================================
# A. the FIXED module
# =============================================================================
echo "--- A. the shipped module ---"

# A1 syslog, nc genuinely absent from PATH
rm -f "$TMP/minbin/nc"
if run_push "$SUBJECT" sltcp; then
    [[ $RC -ne 0 ]]        && ok "A1 syslog with nc ABSENT -> non-zero exit"          || no "A1 exit status" "rc=$RC"
    claims_success         && no "A1 still claims the event was pushed" "stdout=$OUT" || ok "A1 syslog with nc ABSENT -> no success claim"
    grep -q "nc" <<<"$ERR" && ok "A1 the operator is told which command is missing"   || no "A1 diagnostic" "stderr=$ERR"
else
    no "A1 NOT_EXECUTED (no output on either stream)"
fi

# A2 syslog TCP, transport present but failing (connection refused shape)
stub_nc 1
if run_push "$SUBJECT" sltcp; then
    [[ $RC -ne 0 ]] && ok "A2 syslog TCP with nc exit 1 -> non-zero exit"              || no "A2 exit status" "rc=$RC"
    claims_success  && no "A2 still claims the event was pushed" "stdout=$OUT"         || ok "A2 syslog TCP failure -> no success claim"
    grep -q "nc exit 1" <<<"$ERR" && ok "A2 the transport's exit code is reported"     || no "A2 diagnostic" "stderr=$ERR"
else
    no "A2 NOT_EXECUTED"
fi

# A3 syslog TCP, transport succeeds -- THE SUCCESS PATH MUST STILL WORK.
#    A fix that merely always fails must not be able to pass this file.
stub_nc 0
if run_push "$SUBJECT" sltcp; then
    [[ $RC -eq 0 ]] && ok "A3 syslog TCP with nc exit 0 -> rc 0"                       || no "A3 exit status" "rc=$RC"
    claims_success  && ok "A3 syslog TCP success -> the success claim is still made"   || no "A3 success claim suppressed" "stdout=$OUT"
    [[ -s "$TMP/out/nc_payload" ]] && ok "A3 the message really reached the transport" || no "A3 no payload handed to nc"
else
    no "A3 NOT_EXECUTED"
fi

# A4 syslog UDP: succeeds, but the wording must not assert delivery
stub_nc 0
if run_push "$SUBJECT" sludp; then
    [[ $RC -eq 0 ]] && ok "A4 syslog UDP with nc exit 0 -> rc 0"                       || no "A4 exit status" "rc=$RC"
    if grep -qi 'unacknowledged' <<<"$OUT" || grep -qi 'not a delivery receipt' <<<"$OUT"; then
        ok "A4 UDP wording scopes the claim to a send, not a delivery receipt"
    else
        no "A4 UDP claims more than nc can observe" "stdout=$OUT"
    fi
else
    no "A4 NOT_EXECUTED"
fi

# A5 kafka, producer fails
stub_kafka 1
if run_push "$SUBJECT" ka; then
    [[ $RC -ne 0 ]] && ok "A5 kafka with producer exit 1 -> non-zero exit"             || no "A5 exit status" "rc=$RC"
    claims_success  && no "A5 still claims the event was pushed" "stdout=$OUT"         || ok "A5 kafka failure -> no success claim"
    grep -q "NOT_LEADER_OR_FOLLOWER" <<<"$ERR" \
        && ok "A5 the producer's OWN diagnostic survives (2>/dev/null no longer eats it)" \
        || no "A5 the broker's error was suppressed" "stderr=$ERR"
else
    no "A5 NOT_EXECUTED"
fi

# A6 kafka, producer succeeds
stub_kafka 0
if run_push "$SUBJECT" ka; then
    [[ $RC -eq 0 ]] && ok "A6 kafka with producer exit 0 -> rc 0"                      || no "A6 exit status" "rc=$RC"
    claims_success  && ok "A6 kafka success -> the success claim is still made"        || no "A6 success claim suppressed" "stdout=$OUT"
    [[ -s "$TMP/out/kafka_payload" ]] && ok "A6 the event really reached the producer" || no "A6 no payload handed to the producer"
else
    no "A6 NOT_EXECUTED"
fi

# =============================================================================
# B. DECLARED INVERSION of the real module -- proves A1/A2/A5 are live.
#    Not a hand-written toy: the pre-fix arms are restored inside a COPY of
#    cmd_connector.sh, so the negative control hits the MOTIVATING defect.
# =============================================================================
echo ""
echo "--- B. declared inversion (the pre-v1.231.0 arms, in a copy of the real module) ---"

INV="$TMP/cmd_connector_inverted.sh"
cat > "$TMP/invert.awk" <<'AWKEOF'
BEGIN { k_skip=0; s_skip=0; k_done=0; s_done=0 }
# --- kafka: from the rc capture to the success call, back to fire-and-claim ---
!k_skip && $0 ~ /local _kafka_rc=0/ {
    k_skip=1
    print "                echo \"$event_json\" | kafka-console-producer.sh \\"
    print "                    --broker-list \"$CONNECTOR_KAFKA_BROKERS\" \\"
    print "                    --topic \"$CONNECTOR_KAFKA_TOPIC\" 2>/dev/null"
    print "                _connector_print_success \"Event pushed to Kafka\""
    next
}
k_skip { if ($0 ~ /_connector_print_success "Event pushed to Kafka"/) { k_skip=0; k_done=1 } next }
# --- syslog: from the presence check to the arm terminator, back to the same ---
!s_skip && $0 ~ /if ! command -v nc >\/dev\/null 2>&1; then/ {
    s_skip=1
    print "            if [[ \"$proto\" == \"udp\" ]]; then"
    print "                echo \"$msg\" | nc -u -w1 \"$host\" \"$port\""
    print "            else"
    print "                echo \"$msg\" | nc -w1 \"$host\" \"$port\""
    print "            fi"
    print "            _connector_print_success \"Event pushed to syslog\""
    next
}
s_skip { if ($0 ~ /^[[:space:]]*;;[[:space:]]*$/) { s_skip=0; s_done=1; print } next }
{ print }
END {
    if (k_done != 1 || s_done != 1)
        exit 3
}
AWKEOF

if awk -f "$TMP/invert.awk" "$SUBJECT" > "$INV" 2>"$TMP/awkerr"; then
    if cmp -s "$SUBJECT" "$INV"; then
        no "B0 the inversion produced an IDENTICAL file" "ASSERT(X==X) proves nothing"
    elif ! bash -n "$INV" 2>"$TMP/synerr"; then
        no "B0 the inverted module does not parse" "$(cat "$TMP/synerr")"
    else
        ok "B0 declared inversion applied to a copy of the real module and parses"

        rm -f "$TMP/minbin/nc"
        if run_push "$INV" sltcp; then
            if [[ $RC -eq 0 ]] && claims_success; then
                ok "B1 pre-fix shape DOES claim success with nc absent (A1 assertions are live)"
            else
                no "B1 the inversion did not reproduce the defect" "rc=$RC stdout=$OUT"
            fi
        else
            no "B1 NOT_EXECUTED"
        fi

        stub_nc 1
        if run_push "$INV" sltcp; then
            if [[ $RC -eq 0 ]] && claims_success; then
                ok "B2 pre-fix shape DOES claim success on a failed nc (A2 assertions are live)"
            else
                no "B2 the inversion did not reproduce the defect" "rc=$RC stdout=$OUT"
            fi
        else
            no "B2 NOT_EXECUTED"
        fi

        stub_kafka 1
        if run_push "$INV" ka; then
            if [[ $RC -eq 0 ]] && claims_success; then
                ok "B3 pre-fix shape DOES claim success on a failed producer (A5 assertions are live)"
            else
                no "B3 the inversion did not reproduce the defect" "rc=$RC stdout=$OUT"
            fi
            grep -q "NOT_LEADER_OR_FOLLOWER" <<<"$ERR" \
                && no "B3 the pre-fix shape unexpectedly surfaced the broker error" \
                || ok "B3 pre-fix shape swallows the broker's diagnostic (A5 stderr assertion is live)"
        else
            no "B3 NOT_EXECUTED"
        fi

        stub_nc 0
        if run_push "$INV" sltcp; then
            [[ $RC -eq 0 ]] && claims_success \
                && ok "B4 pre-fix shape also succeeded when the transport worked (the inversion is faithful, not a strawman)" \
                || no "B4 the inversion broke the success path" "rc=$RC stdout=$OUT"
        else
            no "B4 NOT_EXECUTED"
        fi
    fi
else
    no "B0 the declared inversion no longer matches the module (awk exit $?)" \
       "update the inversion rather than deleting it: $(cat "$TMP/awkerr" 2>/dev/null)"
fi

# =============================================================================
# C. the tracked module was not mutated
# =============================================================================
echo ""
if [[ -n "$(find "$SUBJECT" -newer "$TMP/driver.sh" -print 2>/dev/null)" ]]; then
    no "C1 the tracked module was modified during this run"
else
    ok "C1 the tracked module was not written to"
fi

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
