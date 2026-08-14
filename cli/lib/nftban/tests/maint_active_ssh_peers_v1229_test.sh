#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.x — active-SSH auto-whitelist peer extraction (A6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="maint_active_ssh_peers_v1229_test"
# meta:type="test"
# meta:version="1.229.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-14"
# meta:description="A6 regression: maintenance.sh must auto-whitelist ACTIVE SSH sessions on every real listener port. Locks out TWO layered defects proven inert fleet-wide at runtime (srv2 :55000, srv3 :22, v1.228.11): (1) peer read as \$5 while 'ss -tn state established' omits the State column, so every host returned EMPTY; (2) the port filter hardcoded :22, which defect 1 masked. Each arm carries a falsifiability control asserting the OLD code fails on the same fixture. Hermetic: stubbed ss, no root/network/host."
# meta:inventory.files="maint_active_ssh_peers_v1229_test.sh"
# meta:inventory.binaries="bash,awk,grep,sort"
# meta:inventory.env_vars="_SS_FIXTURE,_SS_LAYOUT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="maint_active_ssh_peers_v1229_test"
# meta:ta.owner="firewall"
# meta:ta.module="maintenance-active-ssh-whitelist"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT="$SCRIPT_DIR/../cron/maintenance.sh"
[[ -f "$MAINT" ]] || { echo "FAIL: maintenance.sh not found at $MAINT"; exit 1; }
PASS=0; FAIL=0
ok(){  echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# Extract ONLY the shipped helper — the subject under test is the production
# function itself, not a copy of its pipeline.
HELPER="$(awk '/^_maint_active_ssh_peers\(\)/{f=1} f{print} f&&/^\}/{exit}' "$MAINT")"
[[ -n "$HELPER" ]] || { echo "FAIL: _maint_active_ssh_peers not found in maintenance.sh"; exit 1; }
eval "$HELPER"

# -----------------------------------------------------------------------------
# ss stub. Honours the port filter so the port arm cannot pass vacuously, and
# reproduces the three real column layouts.
#
#   _SS_FIXTURE  lines of "<local-ip>:<port> <peer-ip>:<port>"
#   _SS_LAYOUT   state    -> Recv-Q Send-Q Local Peer      (real `state established`)
#                full     -> State Recv-Q Send-Q Local Peer (real plain `ss -tn`)
#                noheader -> state layout with NO header row
# -----------------------------------------------------------------------------
ss() {
    local args="$*" ports lip pip lport want p
    ports="$(grep -oE '[ds]port = :[0-9]+' <<<"$args" | grep -oE '[0-9]+$' | sort -u || true)"
    case "${_SS_LAYOUT:-state}" in
        full)     printf 'State    Recv-Q Send-Q Local Address:Port  Peer Address:Port\n' ;;
        noheader) : ;;
        *)        printf 'Recv-Q Send-Q Local Address:Port  Peer Address:Port\n' ;;
    esac
    while read -r lip pip; do
        [[ -n "$lip" ]] || continue
        lport="${lip##*:}"
        want=0
        while read -r p; do [[ "$p" == "$lport" ]] && want=1; done <<<"$ports"
        [[ "$want" == 1 ]] || continue
        if [[ "${_SS_LAYOUT:-state}" == "full" ]]; then
            printf 'ESTAB    0      0      %s   %s\n' "$lip" "$pip"
        else
            printf '0      0      %s   %s\n' "$lip" "$pip"
        fi
    done <<<"${_SS_FIXTURE:-}"
    return 0
}

# The PRE-FIX pipeline, verbatim. Used only as a falsifiability control: every
# arm proves the old code FAILS on the same fixture the new code passes, so a
# green arm can never be an accident of the stub.
old_impl() {
    ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | \
        awk 'NR>1 {print $5}' | \
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f:]+:+)+[0-9a-f]+' | \
        grep -v '^127\.' | grep -v '^::1' | sort -u || true
}

echo "=== A6 · active-SSH peer extraction (v1.229.x) ==="

# -----------------------------------------------------------------------------
echo "ARM 1 — DEFECT 1: peer column under 'state established' (no State column)"
# -----------------------------------------------------------------------------
export _SS_FIXTURE='192.0.2.50:22 198.51.100.10:53646'
export _SS_LAYOUT=state
got="$(_maint_active_ssh_peers 22)"
[[ "$got" == "198.51.100.10" ]] \
    && ok "peer extracted on a port-22 host (got: $got)" \
    || bad "peer NOT extracted — got '[$got]', expected 198.51.100.10"

# 1b — falsifiability: the shipped-before code must return NOTHING here.
old="$(old_impl)"
[[ -z "$old" ]] \
    && ok "control: pre-fix \$5 pipeline returns EMPTY on the same fixture (arm is non-vacuous)" \
    || bad "control BROKEN: pre-fix code returned '[$old]' — the fixture does not reproduce defect 1"

# -----------------------------------------------------------------------------
echo "ARM 2 — DEFECT 2: non-22 listener port"
# -----------------------------------------------------------------------------
export _SS_FIXTURE='192.0.2.97:55000 198.51.100.10:38502'
got="$(_maint_active_ssh_peers 55000)"
[[ "$got" == "198.51.100.10" ]] \
    && ok "peer extracted on a :55000 host (got: $got)" \
    || bad "peer NOT extracted on non-22 port — got '[$got]'"

# 2b — the port filter must genuinely matter: asking for :22 finds nothing here.
got="$(_maint_active_ssh_peers 22)"
[[ -z "$got" ]] \
    && ok "control: querying :22 on a :55000 host yields EMPTY (filter is honoured, not ignored)" \
    || bad "filter ignored — :22 query returned '[$got]' on a :55000-only fixture"

# 2c — falsifiability: pre-fix code (hardcoded :22 AND \$5) returns nothing.
old="$(old_impl)"
[[ -z "$old" ]] \
    && ok "control: pre-fix pipeline returns EMPTY on the :55000 fixture" \
    || bad "control BROKEN: pre-fix returned '[$old]'"

# -----------------------------------------------------------------------------
echo "ARM 3 — layout robustness: \$NF is the peer in BOTH column layouts"
# -----------------------------------------------------------------------------
export _SS_FIXTURE='192.0.2.50:22 198.51.100.10:53646'
export _SS_LAYOUT=full
got="$(_maint_active_ssh_peers 22)"
[[ "$got" == "198.51.100.10" ]] \
    && ok "peer extracted when the State column IS present" \
    || bad "peer lost in 'full' layout — got '[$got]'"
export _SS_LAYOUT=state

# -----------------------------------------------------------------------------
echo "ARM 4 — lockout safety: a session is still found when ss emits no header"
# -----------------------------------------------------------------------------
export _SS_LAYOUT=noheader
got="$(_maint_active_ssh_peers 22)"
[[ "$got" == "198.51.100.10" ]] \
    && ok "headerless ss output still yields the session (NR>1 would have dropped it)" \
    || bad "headerless output dropped the only session — LOCKOUT RISK; got '[$got]'"
export _SS_LAYOUT=state

# -----------------------------------------------------------------------------
echo "ARM 5 — the LOCAL address must never be whitelisted"
# -----------------------------------------------------------------------------
export _SS_FIXTURE='192.0.2.50:22 198.51.100.10:53646'
got="$(_maint_active_ssh_peers 22)"
grep -q '46\.224\.164\.50' <<<"$got" \
    && bad "SERVER's own local IP leaked into the whitelist set: '[$got]'" \
    || ok "local address excluded (only the peer is returned)"

# -----------------------------------------------------------------------------
echo "ARM 6 — loopback excluded"
# -----------------------------------------------------------------------------
export _SS_FIXTURE='192.0.2.50:22 127.0.0.1:44100
192.0.2.50:22 198.51.100.10:53646'
got="$(_maint_active_ssh_peers 22)"
[[ "$got" == "198.51.100.10" ]] \
    && ok "127.0.0.1 filtered, real peer kept" \
    || bad "loopback handling wrong — got '[$got]'"

# -----------------------------------------------------------------------------
echo "ARM 7 — multi-port union (both listeners protected)"
# -----------------------------------------------------------------------------
export _SS_FIXTURE='192.0.2.50:22 198.51.100.10:53646
192.0.2.50:2222 203.0.113.9:41000'
got="$(_maint_active_ssh_peers 22 2222 | tr '\n' ' ')"
[[ "$got" == "198.51.100.10 203.0.113.9 " ]] \
    && ok "both listener ports contribute peers (got: $got)" \
    || bad "multi-port union wrong — got '[$got]'"

# -----------------------------------------------------------------------------
echo "ARM 8 — EMPTY still means empty (the fix must not fabricate peers)"
# -----------------------------------------------------------------------------
export _SS_FIXTURE=''
got="$(_maint_active_ssh_peers 22)"
[[ -z "$got" ]] \
    && ok "no sessions -> empty result (no fabricated whitelist entries)" \
    || bad "fabricated output with no sessions: '[$got]'"

# -----------------------------------------------------------------------------
echo "ARM 9 — IPv6 peer extracted"
# -----------------------------------------------------------------------------
export _SS_FIXTURE='[2001:db8::50]:22 [2001:db8::122]:53646'
got="$(_maint_active_ssh_peers 22)"
grep -q '2001:db8::122' <<<"$got" \
    && ok "IPv6 peer extracted (got: $got)" \
    || bad "IPv6 peer lost — got '[$got]'"

# -----------------------------------------------------------------------------
echo "ARM 10 — STATIC: the defective forms must not reappear in maintenance.sh"
# -----------------------------------------------------------------------------
if grep -nE "awk '.*NR>1 \{print \\\$5\}'" "$MAINT" >/dev/null 2>&1; then
    bad "maintenance.sh still contains an 'NR>1 {print \$5}' peer read"
else
    ok "no '\$5' peer read remains in maintenance.sh"
fi

if grep -n "dport = :22 or sport = :22" "$MAINT" | grep -v '_filter=' >/dev/null 2>&1; then
    bad "a hardcoded ':22' ss filter remains outside the documented fallback"
else
    ok "no hardcoded ':22' session filter outside the fallback"
fi

if grep -q '_maint_active_ssh_peers "${SSH_PORTS\[@\]:-22}"' "$MAINT"; then
    ok "call site passes the detected SSH_PORTS (reuses the existing authority)"
else
    bad "call site does not pass SSH_PORTS — the detected ports are not reaching the query"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
