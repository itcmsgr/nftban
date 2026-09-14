#!/usr/bin/env bash
# =============================================================================
# NFTBan - a delivery claim requires a delivery (v1.231.0)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="connector_transport_success_truth_v1231_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="connector"
# meta:ta.id="connector_transport_success_truth_v1231_test"
# meta:ta.owner="connector"
# meta:ta.module="connector"
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
# meta:description="`nftban connector push` announced delivery for a byte it never sent.
#   MEASURED LIVE on lab4 with nc absent, on the shipped CLI: stderr 'nc: command not
#   found', stdout '✅ Event pushed to syslog', rc=0. The file DOES set `set -Eeuo
#   pipefail` — that is exactly why this is worth a test: errexit is SUPPRESSED when the
#   function's result is consumed by the caller's conditional, which is how the dispatcher
#   reaches it. So the invariant cannot rely on shell flags and is asserted here with
#   errexit explicitly OFF: a success message REQUIRES transport success; transport
#   failure REQUIRES a non-zero return and MUST NOT emit affirmative delivery text.
#   syslog and Kafka are asserted as INDEPENDENT manifestations — a shared fix pattern is
#   not evidence that both paths execute correctly. Elasticsearch and webhook are NOT in
#   scope: they already gate on `if curl -sf ...; then` and this lane does not refactor
#   working code. Hermetic: transports are PATH stubs, config is a temp dir, no root, no
#   network, no installed product."
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$SD/../cli/cmd_connector.sh"
PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }
ne(){ printf '  [NOT_EXECUTED] %s\n' "$1"; printf 'RESULT: NOT_EXECUTED\n'; exit 3; }

[[ -f "$MOD" ]] || ne "module not found: $MOD"

# ---------------------------------------------------------------------------
# run_push <type> <stub_mode> -> "rc|combined output"
#   stub_mode: absent | fail | ok
# errexit is deliberately OFF inside the subshell: the defect is reachable only
# when the caller's context suppresses it, so a test that runs under `set -e`
# would never observe the very behaviour it exists to forbid.
# ---------------------------------------------------------------------------
run_push() {
    local ctype="$1" mode="$2" bindir cfg out rc
    bindir="$(mktemp -d)"; cfg="$(mktemp -d)"
    case "$ctype" in
        syslog) tool=nc ;;
        kafka)  tool=kafka-console-producer.sh ;;
    esac
    # ⛔ PREPENDING AN EMPTY DIR DOES NOT MAKE A BINARY ABSENT. The first draft did
    # exactly that; the real ncat was still on PATH, the arm reported "Connection
    # refused", and S2/S3 passed for the WRONG REASON — they were testing a failing
    # transport while claiming to test a missing one. Absence needs a SEALED PATH.
    local sealed=""
    case "$mode" in
        absent)
            sealed=1
            local b
            for b in bash sh env date hostname cat grep sed awk tr cut head tail \
                     mktemp rm mkdir chmod printf sleep jq curl openssl id stat wc sort; do
                command -v "$b" >/dev/null 2>&1 && ln -sf "$(command -v "$b")" "$bindir/$b" 2>/dev/null
            done
            ;;
        fail)   printf '#!/bin/sh\nexit 7\n'  > "$bindir/$tool"; chmod +x "$bindir/$tool" ;;
        ok)     printf '#!/bin/sh\nexit 0\n'  > "$bindir/$tool"; chmod +x "$bindir/$tool" ;;
    esac
    mkdir -p "$cfg/connectors"
    if [[ "$ctype" == syslog ]]; then
        printf 'CONNECTOR_NAME="t"\nCONNECTOR_TYPE="syslog"\nCONNECTOR_ENABLED="true"\nCONNECTOR_SYSLOG_HOST="127.0.0.1"\nCONNECTOR_SYSLOG_PORT="5514"\nCONNECTOR_SYSLOG_PROTO="udp"\n' > "$cfg/connectors/t.conf"
    else
        printf 'CONNECTOR_NAME="t"\nCONNECTOR_TYPE="kafka"\nCONNECTOR_ENABLED="true"\nCONNECTOR_KAFKA_BROKERS="127.0.0.1:9092"\nCONNECTOR_KAFKA_TOPIC="t"\n' > "$cfg/connectors/t.conf"
    fi
    local usepath="$bindir:$PATH"; [[ -n "$sealed" ]] && usepath="$bindir"
    out="$(PATH="$usepath" NFTBAN_CONFIG_DIR="$cfg" bash -c '
        source "$1" 2>/dev/null
        # ⛔ errexit is suppressed for a function invoked as an `if` CONDITION. The
        # module sets `set -Eeuo pipefail` itself when sourced, so `set +e` before
        # sourcing is overridden. The shipped dispatcher reaches this code through a
        # conditional, and THAT is the context where an unconditional success message
        # survives a failed transport. Reproduce the caller, not a convenient shell.
        if _cmd_connector_push t; then exit 0; else exit $?; fi
    ' _ "$MOD" 2>&1)"; rc=$?
    rm -rf "$bindir" "$cfg"
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

claims(){ printf '%s' "$1" | grep -ci 'Event pushed' ; }

echo "=== a delivery claim requires a delivery (v1.231.0) ==="

# --- PRECONDITION: the harness can reach the subject at all -----------------
r="$(run_push syslog ok)"; rc="${r%%|*}"; out="${r#*|}"
[[ "$(claims "$out")" -ge 1 ]] || ne "harness never reached the syslog success path (out='$out') — every arm below would be vacuous"
ok "P0 precondition: the harness reaches the real _cmd_connector_push syslog path"

# --- SYSLOG ----------------------------------------------------------------
r="$(run_push syslog ok)"; rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" -eq 0 ]] && [[ "$(claims "$out")" -ge 1 ]]; } \
  && ok "S1 transport SUCCEEDS -> rc=0 and the delivery claim is present" \
  || no "S1 a working transport must still report success (rc=$rc out='$out')"

r="$(run_push syslog absent)"; rc="${r%%|*}"; out="${r#*|}"
[[ "$(claims "$out")" -eq 0 ]] \
  && ok "S2 transport ABSENT -> NO delivery claim" \
  || no "S2 FALSE SUCCESS: claimed delivery with no transport (out='$out')"
[[ "$rc" -ne 0 ]] \
  && ok "S3 transport ABSENT -> non-zero exit (rc=$rc)" \
  || no "S3 transport absent yet exit 0 — the caller cannot detect the failure"
printf '%s' "$out" | grep -qiE 'not installed|failed to push' \
  && ok "S4 the cause is stated, not just a bare failure" \
  || no "S4 no cause given — operator cannot act (out='$out')"

r="$(run_push syslog fail)"; rc="${r%%|*}"; out="${r#*|}"
{ [[ "$rc" -ne 0 ]] && [[ "$(claims "$out")" -eq 0 ]]; } \
  && ok "S5 transport PRESENT but FAILS -> non-zero, no claim" \
  || no "S5 a failing transport was reported as delivery (rc=$rc out='$out')"

# --- KAFKA: independently executed, not inferred from syslog ----------------
r="$(run_push kafka ok)"; rc="${r%%|*}"; out="${r#*|}"
if [[ "$(claims "$out")" -ge 1 ]]; then
    ok "K0 precondition: the harness reaches the Kafka success path"
    r="$(run_push kafka fail)"; rc="${r%%|*}"; out="${r#*|}"
    { [[ "$rc" -ne 0 ]] && [[ "$(claims "$out")" -eq 0 ]]; } \
      && ok "K1 Kafka transport FAILS -> non-zero, no delivery claim" \
      || no "K1 Kafka reported delivery for a failed producer (rc=$rc out='$out')"
    r="$(run_push kafka absent)"; rc="${r%%|*}"; out="${r#*|}"
    [[ "$(claims "$out")" -eq 0 ]] \
      && ok "K2 Kafka producer ABSENT -> no delivery claim" \
      || no "K2 Kafka claimed delivery with no producer (out='$out')"
else
    printf '  [NOT_EXECUTED] K0 Kafka success path unreachable in this harness — Kafka arms NOT asserted\n'
fi

# --- HISTORICAL NEGATIVE CONTROL -------------------------------------------
# Synthesise the PRE-FIX form and require the guard to go RED. Without this,
# S2/S3 could be passing because the harness cannot observe a claim at all.
tmpmod="$(mktemp)"; cp "$MOD" "$tmpmod"
python3 - "$tmpmod" <<'PY' >/dev/null 2>&1
import sys,re
p=sys.argv[1]; s=open(p).read()
s=re.sub(r"            if ! command -v nc.*?\n            fi\n", "", s, flags=re.S)
s=s.replace("""            fi || {
                _connector_print_error "Failed to push event to syslog (transport exit $?)"
                return 1
            }
""", "            fi\n")
open(p,'w').write(s)
PY
if ! grep -q 'command -v nc' "$tmpmod"; then
    nbin="$(mktemp -d)"; for b in bash sh env date hostname cat grep sed awk tr cut head tail mktemp rm mkdir chmod printf sleep jq curl openssl id stat wc sort; do command -v "$b" >/dev/null 2>&1 && ln -sf "$(command -v "$b")" "$nbin/$b" 2>/dev/null; done
    out="$(PATH="$nbin" NFTBAN_CONFIG_DIR="$(d=$(mktemp -d); mkdir -p "$d/connectors"; printf 'CONNECTOR_NAME="t"\nCONNECTOR_TYPE="syslog"\nCONNECTOR_ENABLED="true"\nCONNECTOR_SYSLOG_HOST="127.0.0.1"\nCONNECTOR_SYSLOG_PORT="5514"\nCONNECTOR_SYSLOG_PROTO="udp"\n' > "$d/connectors/t.conf"; printf '%s' "$d")" \
        bash -c 'source "$1" 2>/dev/null; if _cmd_connector_push t; then exit 0; else exit $?; fi' _ "$tmpmod" 2>&1)"
    [[ "$(claims "$out")" -ge 1 ]] \
      && ok "N1 NEGATIVE CONTROL: the PRE-FIX form still emits a false delivery claim — the assertions discriminate" \
      || no "N1 the pre-fix form did NOT reproduce the defect — S2/S3 may be vacuous (out='$out')"
else
    printf '  [NOT_EXECUTED] N1 could not synthesise the pre-fix form — discrimination NOT proven\n'
fi
rm -f "$tmpmod"

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
