#!/usr/bin/env bash
# =============================================================================
# NFTBan - typed nft probe authority + verdict honesty (v1.228.4 PR-3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="typed_nft_probe_v1228_4_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-29"
# meta:description="v1.228.4 PR-3 controls. Proves the typed nft probe distinguishes PRESENT, ABSENT and CANNOT_READ, that ONLY a verified ABSENT may authorise a rebuild, and that a component which could not read the ruleset can no longer report success. The defect being closed: every non-zero nft exit collapsed into 'table absent', producing a false firewall-absent verdict on 11/11 measured hosts about 927 times each, roughly 900 futile rebuild attempts per host, and roughly 900 emissions of destructive 'nftban firewall reset --force' guidance aimed at intact firewalls - while systemd recorded Result=success every time, so no systemd-based monitor could ever have detected it. Controls cover the three verdicts, six distinct failure modes that must all fail closed to CANNOT_READ, the fail-closed treatment of rc=0-with-empty-output (absence is never inferred from silence), redaction that masks IP literals while preserving file:line diagnostics, and the call-site invariants: no destructive advice on an unknown cause, no rebuild on CANNOT_READ, and non-zero propagation so the unit turns red instead of green. Hermetic - synthetic nft stubs, no host contact, no nft invocation, no privileges."
# meta:input="cli/lib/nftban/lib/nft_probe.sh and the three converted call sites"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,sed,grep"
# meta:inventory.files="cli/lib/nftban/lib/nft_probe.sh,cli/lib/nftban/cron/maintenance.sh,cli/lib/nftban/helpers/autoheal.sh,cli/lib/nftban/lib/ssh_port_detect.sh"
# meta:inventory.binaries="bash,sed,grep"
# meta:inventory.env_vars="NFTBAN_NFT_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="typed_nft_probe_v1228_4_test"
# meta:ta.owner="cli"
# meta:ta.module="nft-probe-authority"
# meta:ta.execution_class="CI_STATIC"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
PROBE="$REPO/cli/lib/nftban/lib/nft_probe.sh"
MAINT="$REPO/cli/lib/nftban/cron/maintenance.sh"
AUTOHEAL="$REPO/cli/lib/nftban/helpers/autoheal.sh"
SSHDET="$REPO/cli/lib/nftban/lib/ssh_port_detect.sh"

for f in "$PROBE" "$MAINT" "$AUTOHEAL" "$SSHDET"; do
    [[ -f "$f" ]] || { echo "FAIL: missing $f" >&2; exit 1; }
done

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# shellcheck source=/dev/null
source "$PROBE"

# Synthetic nft stubs — no real nft is ever invoked.
stub(){ mkdir -p "$WORK/$1"; printf '%s\n' "$2" > "$WORK/$1/nft"; chmod +x "$WORK/$1/nft"; }
stub present  '#!/bin/sh
echo "table ip nftban"
echo "table ip6 nftban"'
stub absent   '#!/bin/sh
echo "table inet other"'
stub netlink  '#!/bin/sh
echo "src/mnl.c:61: Unable to initialize Netlink socket: Address family not supported by protocol" >&2
exit 3'
stub perm     '#!/bin/sh
echo "Operation not permitted (you must be root)" >&2
exit 1'
stub syntax   '#!/bin/sh
echo "Error: syntax error, unexpected string" >&2
exit 1'
stub empty    '#!/bin/sh
exit 0'
stub garbage  '#!/bin/sh
echo "not a table listing at all"'

# Exported because the probe library reads it; shellcheck cannot see a
# cross-file read and would otherwise flag every assignment as unused.
export NFTBAN_NFT_BIN

verdict(){  # verdict <stub> <family> -> runs the probe, leaving globals set
    # The probe is a shell FUNCTION, so it runs in THIS shell and its global
    # assignments persist. A single call is sufficient; an earlier revision called
    # it twice, left over from debugging the subshell defect.
    NFTBAN_NFT_BIN="$WORK/$1/nft"
    nftban_nft_probe_table "$2" nftban test || true
}

echo "=== A. the three verdicts ==="
verdict present ip
[[ "$NFTBAN_NFT_PROBE_VERDICT" == "PRESENT" ]] \
    && ok "A1 readable ruleset + table listed -> PRESENT" \
    || no "A1 PRESENT" "got $NFTBAN_NFT_PROBE_VERDICT"
verdict present ip6
[[ "$NFTBAN_NFT_PROBE_VERDICT" == "PRESENT" ]] \
    && ok "A2 ip6 family -> PRESENT" || no "A2 ip6 PRESENT" "got $NFTBAN_NFT_PROBE_VERDICT"
verdict absent ip
[[ "$NFTBAN_NFT_PROBE_VERDICT" == "ABSENT" ]] \
    && ok "A3 readable ruleset + table NOT listed -> ABSENT" \
    || no "A3 ABSENT" "got $NFTBAN_NFT_PROBE_VERDICT"

echo "=== B. every failure mode fails CLOSED to CANNOT_READ ==="
for c in "netlink NETLINK_FAMILY_BLOCKED" "perm PERMISSION_DENIED" "syntax UNCLASSIFIED" \
         "empty EMPTY_OUTPUT_NO_ABSENCE_PROOF" "garbage MALFORMED_OUTPUT"; do
    set -- $c
    verdict "$1" ip
    if [[ "$NFTBAN_NFT_PROBE_VERDICT" == "CANNOT_READ" && "$NFTBAN_NFT_PROBE_CLASS" == "$2" ]]; then
        ok "B:$1 -> CANNOT_READ ($2)"
    else
        no "B:$1 -> CANNOT_READ ($2)" "got $NFTBAN_NFT_PROBE_VERDICT / $NFTBAN_NFT_PROBE_CLASS"
    fi
done
NFTBAN_NFT_BIN="$WORK/does-not-exist/nft"
nftban_nft_probe_table ip nftban test || true
[[ "$NFTBAN_NFT_PROBE_VERDICT" == "CANNOT_READ" ]] \
    && ok "B:missing-binary -> CANNOT_READ" || no "B:missing-binary" "got $NFTBAN_NFT_PROBE_VERDICT"

echo "=== C. THE mutation gate — only a verified ABSENT may rebuild ==="
verdict absent ip
nftban_nft_probe_may_rebuild && ok "C1 ABSENT permits considering rebuild" \
                             || no "C1 ABSENT permits rebuild" "predicate refused"
verdict present ip
nftban_nft_probe_may_rebuild && no "C2 PRESENT must NOT permit rebuild" "predicate allowed it" \
                             || ok "C2 PRESENT does not permit rebuild"
for s in netlink perm syntax empty garbage; do
    verdict "$s" ip
    nftban_nft_probe_may_rebuild \
        && no "C3:$s CANNOT_READ must NOT permit rebuild" "predicate allowed it" \
        || ok "C3:$s CANNOT_READ does not permit rebuild"
done

echo "=== D. no stored rebuild boolean (dual authority) ==="
grep -qE '^[[:space:]]*NFTBAN_NFT_PROBE_MAY_REBUILD=' "$PROBE" \
    && no "D1 no stored MAY_REBUILD variable" "a stored boolean exists and can go stale" \
    || ok "D1 rebuild permission is derived live from VERDICT, never stored"

echo "=== E. redaction: mask addresses, PRESERVE diagnostics ==="
r=$(nftban_nft_probe_redact 'src/mnl.c:61: at file.sh:148 errno EAFNOSUPPORT')
[[ "$r" == *"src/mnl.c:61"* && "$r" == *"file.sh:148"* ]] \
    && ok "E1 file:line diagnostics preserved" || no "E1 file:line preserved" "$r"
r=$(nftban_nft_probe_redact 'blocked 203.0.113.9 and 2001:db8::1 now')
[[ "$r" == *"<ip4>"* && "$r" == *"<ip6>"* ]] \
    && ok "E2 IPv4 and IPv6 literals redacted" || no "E2 addresses redacted" "$r"
long=$(printf 'x%.0s' $(seq 1 900)); r=$(nftban_nft_probe_redact "$long")
[[ "${#r}" -lt 700 ]] && ok "E3 stderr is bounded (${#r} bytes from 900)" \
                      || no "E3 stderr bounded" "len=${#r}"

echo "=== M. MONOTONICITY — a later result must never recover a prior CANNOT_READ ==="
# Every probe resets VERDICT on entry, so ordering alone could silently restore a
# healthy component after an unreadable probe. The latch makes that impossible.
nftban_nft_probe_session_reset
nftban_nft_probe_session_degraded \
    && no "M1 a fresh session starts clean" "latch set before any probe" \
    || ok "M1 a fresh session starts clean"

verdict netlink ip                      # CANNOT_READ
nftban_nft_probe_session_degraded \
    && ok "M2 CANNOT_READ sets the session latch" \
    || no "M2 CANNOT_READ sets the latch" "latch not set"

verdict present ip                      # a LATER successful probe
[[ "$NFTBAN_NFT_PROBE_VERDICT" == "PRESENT" ]] \
    && ok "M3 the later probe itself reports PRESENT (VERDICT is per-probe)" \
    || no "M3 later probe PRESENT" "got $NFTBAN_NFT_PROBE_VERDICT"
nftban_nft_probe_session_degraded \
    && ok "M4 the SESSION stays degraded — no recovery from a later success" \
    || no "M4 session stays degraded" "a later PRESENT recovered the component — monotonicity broken"

# set-probe path must latch too
nftban_nft_probe_session_reset
NFTBAN_NFT_BIN="$WORK/netlink/nft"
nftban_nft_probe_set ip nftban ssh_ports test || true
nftban_nft_probe_session_degraded \
    && ok "M5 an unreadable SET probe also latches the session" \
    || no "M5 set probe latches" "latch not set by nftban_nft_probe_set"

nftban_nft_probe_session_reset
nftban_nft_probe_session_degraded \
    && no "M6 explicit reset clears the latch" "reset did not clear" \
    || ok "M6 only an EXPLICIT reset clears the latch"

# callers must consult the latch, not the last VERDICT
grep -q 'nftban_nft_probe_session_degraded' "$AUTOHEAL" \
    && ok "M7 autoheal consults the monotonic latch" \
    || no "M7 autoheal consults the latch" "it reads the last VERDICT and can recover"
grep -q 'nftban_nft_probe_session_degraded' "$MAINT" \
    && ok "M8 maintenance consults the monotonic latch" \
    || no "M8 maintenance consults the latch" "it reads the last VERDICT and can recover"

echo "=== F. call-site invariants (static) ==="
grep -qE 'nft list table \$_tbl|nft list table \$\{NFTBAN_TABLE_IPV4\}' "$MAINT" "$SSHDET" \
    && no "F1 no untyped collapsing probe remains" "an old boolean nft probe survived" \
    || ok "F1 no untyped collapsing probe remains on the converted path"
grep -qE 'log_error "Try: nftban firewall reset --force"' "$AUTOHEAL" \
    && no "F2 no reset --force advice from unknown cause" "destructive guidance still emitted" \
    || ok "F2 destructive reset --force guidance removed"
grep -q 'NFTBAN_AUTOHEAL_PROBE_FAILED' "$AUTOHEAL" \
    && ok "F3 autoheal tracks probe failure" || no "F3 autoheal tracks probe failure" "flag absent"
grep -q '_MAINT_PROBE_UNREADABLE' "$MAINT" \
    && ok "F4 maintenance tracks probe failure" || no "F4 maintenance tracks failure" "flag absent"
grep -q "printf 'cannot-read" "$SSHDET" \
    && ok "F5 ssh_port_detect emits the distinct cannot-read state" \
    || no "F5 cannot-read state" "not emitted"
grep -q 'cannot-read)' "$MAINT" \
    && ok "F6 maintenance handles cannot-read distinctly from no-table" \
    || no "F6 cannot-read handled" "caller still collapses it"

echo "=== G. VERDICT HONESTY — the unit must go red, not green ==="
# The single most valuable assertion in this PR. Today the component reports
# success after a total failure of its nft-access and schema stages.
# Block-scoped check: locate the guard line, then require the non-zero exit
# WITHIN that block. Multiline regex over shell source is too fragile — an earlier
# revision of this very assertion failed against correct code because the pattern
# assumed a newline where the source has "]; then".
block_has(){  # block_has <file> <guard-pattern> <required-pattern> <window>
    local f="$1" guard="$2" want="$3" win="${4:-14}" ln
    ln=$(grep -n "$guard" "$f" | tail -1 | cut -d: -f1) || return 1
    [[ -n "$ln" ]] || return 1
    sed -n "${ln},$((ln+win))p" "$f" | grep -q "$want"
}
block_has "$AUTOHEAL" 'NFTBAN_AUTOHEAL_PROBE_FAILED:-0' '^[[:space:]]*exit 1' \
    && ok "G1 autoheal EXITS NON-ZERO when the ruleset could not be read" \
    || no "G1 autoheal exits non-zero on probe failure" "no exit 1 within the guard block"
block_has "$MAINT" '_MAINT_PROBE_UNREADABLE:-0' '^[[:space:]]*return 1' \
    && ok "G2 maintenance RETURNS NON-ZERO when the ruleset could not be read" \
    || no "G2 maintenance returns non-zero" "no return 1 within the guard block"
grep -q 'Health: DEGRADED' "$AUTOHEAL" \
    && ok "G3 autoheal reports DEGRADED instead of 'system ready'" \
    || no "G3 DEGRADED verdict" "still claims readiness"
grep -q 'Maintenance INCOMPLETE' "$MAINT" \
    && ok "G4 maintenance reports INCOMPLETE instead of Complete" \
    || no "G4 INCOMPLETE verdict" "still claims completion"

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
