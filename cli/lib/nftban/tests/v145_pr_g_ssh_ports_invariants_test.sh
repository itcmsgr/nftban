#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.145 - PR-G ssh_ports systemic-alignment invariants
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v145_pr_g_ssh_ports_invariants_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Negative/invariant guards for v1.145 PR-G: ssh_ports is never counted as a public/open service port, the set-driven @ssh_ports ct-count rule is never treated as a service-blocking drop, UDP paths never reference ssh_ports (TCP-only), Pure-FTPd/FTP stay on tcp_ports_in (never ssh_ports), and ssh_ports remains a required internal set mirrored across IPv4/IPv6."
# meta:input="None (greps repo source read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
cd "$REPO_ROOT"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

SCHEMA=cli/lib/nftban/lib/nft_schema.sh
REPORT=cli/lib/nftban/core/nftban_report_port.sh
PORTH=cmd/nftband/daemon_handlers_ports.go
GENGO=internal/validator/schema_generated.go

echo "== (a) ssh_ports is NOT counted as a public/open service port =="
# The open-port total must be derived from tcp_ports_in + udp_ports_in only.
if grep -nE 'total_open' "$SCHEMA" | grep -q 'ssh_ports'; then
    bad "nft_schema.sh total_open arithmetic references ssh_ports (would inflate open-port count)"
else
    ok "nft_schema.sh total_open does not include ssh_ports"
fi
# report_port's static standard_sets enumeration (exposure report) must omit ssh_ports.
if awk '/local -a standard_sets=\(/,/\)/' "$REPORT" | grep -q 'ssh_ports'; then
    bad "report_port standard_sets enumerates ssh_ports (would report it as an exposed service)"
else
    ok "report_port standard_sets omits ssh_ports (not an exposed service)"
fi

echo "== (b) @ssh_ports ct-count rule is NOT treated as a service-blocking drop =="
# Both the set-rule scanner AND the direct-rule scanner must skip 'ct count over'
# / 'limit rate' lines, so the brute-force rule is never recorded as a base BLOCK.
ctguards=$(grep -cE 'ct\[\[:space:\]\]\+count\[\[:space:\]\]\+over' "$REPORT" || true)
if [[ "${ctguards:-0}" -ge 2 ]]; then
    ok "report_port skips 'ct count over' in both set-rule and direct-rule scanners ($ctguards guards)"
else
    bad "report_port has fewer than 2 'ct count over' skip guards (set-rule scanner unguarded) — found ${ctguards:-0}"
fi

echo "== (c) ssh_ports is TCP-only: UDP paths never reference it =="
# No template/config may rate-limit a udp dport against @ssh_ports.
if grep -rnE 'udp[[:space:]]+dport[[:space:]]+@ssh_ports' install/ etc/ 2>/dev/null | grep -q .; then
    bad "a template/config has 'udp dport @ssh_ports' (ssh_ports must be TCP-only)"
else
    ok "no 'udp dport @ssh_ports' rule anywhere (TCP-only)"
fi
# The daemon port handler's UDP switch arms must map only to udp_ports_in/out.
if awk '/case "udp", "u":/,/case "both", "b":/' "$PORTH" | grep -q 'ssh_ports'; then
    bad "daemon_handlers_ports.go UDP switch references ssh_ports"
else
    ok "daemon_handlers_ports.go UDP switch maps only to udp_ports_in/out (no ssh_ports)"
fi

echo "== (d) the set-driven SSH rule is rendered as TCP =="
if grep -rqE 'tcp[[:space:]]+dport[[:space:]]+@ssh_ports[[:space:]]+ct[[:space:]]+count' install/nftables/; then
    ok "templates render 'tcp dport @ssh_ports ct count'"
else
    bad "no 'tcp dport @ssh_ports ct count' rule found in templates"
fi

echo "== (e) Pure-FTPd / FTP stay on tcp_ports_in (never ssh_ports) =="
# ssh_ports must never co-occur with an FTP association on the same line in the
# source tree (no ftp->ssh_ports wiring; FTP is a normal tcp_ports_in service).
if grep -rniE 'ssh_ports' cli/ cmd/ internal/ install/ etc/ 2>/dev/null | grep -iqE 'ftp|pure-?ftpd'; then
    bad "a source line associates ssh_ports with FTP/Pure-FTPd"
    grep -rniE 'ssh_ports' cli/ cmd/ internal/ install/ etc/ 2>/dev/null | grep -iE 'ftp|pure-?ftpd' | sed 's/^/        /'
else
    ok "no source line associates ssh_ports with FTP/Pure-FTPd"
fi

echo "== (f) ssh_ports is a REQUIRED internal set, mirrored IPv4 + IPv6 =="
# Canonical shell schema: the IPv4 and IPv6 set arrays each declare an
# ["ssh_ports"]=... entry, so exactly two declarations prove both-family mirror.
schema_decls=$(grep -cE '^\s*\["ssh_ports"\]=' "$SCHEMA" || true)
if [[ "${schema_decls:-0}" -eq 2 ]]; then
    ok "nft_schema.sh: ssh_ports declared in both IPv4 and IPv6 set arrays (2 entries)"
else
    bad "nft_schema.sh: expected 2 ssh_ports set declarations (IPv4+IPv6), found ${schema_decls:-0}"
fi
# Generated Go required-set lists: both families.
if awk '/GeneratedRequiredSetsIPv4 =/,/\}/' "$GENGO" | grep -q '"ssh_ports"'; then
    ok "schema_generated.go: ssh_ports in GeneratedRequiredSetsIPv4"
else
    bad "schema_generated.go: ssh_ports missing from GeneratedRequiredSetsIPv4"
fi
if awk '/GeneratedRequiredSetsIPv6 =/,/\}/' "$GENGO" | grep -q '"ssh_ports"'; then
    ok "schema_generated.go: ssh_ports in GeneratedRequiredSetsIPv6"
else
    bad "schema_generated.go: ssh_ports missing from GeneratedRequiredSetsIPv6"
fi

echo "== (g) nftban port help documents ssh_ports semantics =="
HELP=cli/lib/nftban/cli/cmd_port.sh
if grep -q 'ssh_ports' "$HELP" && grep -qE '5 managed nftables port sets' "$HELP"; then
    ok "cmd_port help lists 5 sets incl. ssh_ports"
else
    bad "cmd_port help does not document the 5th set (ssh_ports)"
fi
if grep -qiE 'Pure-FTPd, FTP, FTPS.*tcp_ports_in|never ssh_ports' "$HELP"; then
    ok "cmd_port help clarifies FTP/Pure-FTPd use tcp_ports_in, not ssh_ports"
else
    bad "cmd_port help does not clarify FTP/Pure-FTPd vs ssh_ports boundary"
fi

echo ""
echo "v1.145 PR-G ssh_ports invariants: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
