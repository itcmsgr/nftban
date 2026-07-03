#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - Sysctl Safe-Default + Registry + Risk Scan (v1.216.0, PR-1/2/3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="sysctl-safe-default-v216-test"
# meta:type="test"
# meta:header="Sysctl Safe-Default v1.216.0"
# meta:version="1.215.0"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Verify v1.216.0 sysctl safe-default: established=600 no longer shipped + transitional hardening kept + rationale/override comments (PR-1); DEB conffile parity + RPM %config(noreplace) (PR-2); declarative registry + read-only risk scan logic (dead-socket precondition, drift, module-load race, operator override) + support collection, no writes (PR-3)."
# meta:inventory.files="install/sysctl/90-nftban.conf,packaging/build_nftban.sh,cli/lib/nftban/lib/nftban_sysctl_registry.sh,cli/lib/nftban/cli/cmd_support.sh,cli/lib/nftban/core/nftban_watchdog_checks.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_SYSCTL_FILE,NFTBAN_SYSCTL_LOCAL"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-07-03"
# meta:updated_date="2026-07-03"
# =============================================================================
set -Eeuo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cd "$SD/../../../.." && pwd)
CONF="$ROOT/install/sysctl/90-nftban.conf"
BUILD="$ROOT/packaging/build_nftban.sh"
REG="$ROOT/cli/lib/nftban/lib/nftban_sysctl_registry.sh"
SUP="$ROOT/cli/lib/nftban/cli/cmd_support.sh"
WD="$ROOT/cli/lib/nftban/core/nftban_watchdog_checks.sh"
P=0; F=0
ok(){ echo "PASS $1"; P=$((P+1)); }
no(){ echo "FAIL $1"; F=$((F+1)); }

# ---- PR-1: sysctl file policy ----
grep -qE '^\s*net\.netfilter\.nf_conntrack_tcp_timeout_established\s*=' "$CONF" && no "PR1 established=600 removed" || ok "PR1 established timeout no longer set (kernel default)"
grep -qE '^\s*net\.netfilter\.nf_conntrack_tcp_timeout_time_wait\s*=\s*30' "$CONF" && ok "PR1 time_wait=30 kept" || no "PR1 time_wait"
grep -qE '^\s*net\.netfilter\.nf_conntrack_tcp_timeout_syn_sent\s*=\s*30' "$CONF" && ok "PR1 syn_sent=30 kept" || no "PR1 syn_sent"
grep -qE '^\s*net\.netfilter\.nf_conntrack_tcp_timeout_syn_recv\s*=\s*15' "$CONF" && ok "PR1 syn_recv=15 kept" || no "PR1 syn_recv"
grep -q '99-local.conf' "$CONF" && ok "PR1 99-local override documented" || no "PR1 99-local comment"
grep -qiE 'keepalive|dead socket|dead-socket' "$CONF" && ok "PR1 rationale comment present" || no "PR1 rationale"
grep -qiE 'NO automatic live-kernel|no automatic live' "$CONF" && ok "PR1 no-auto-write note" || no "PR1 no-auto-write note"

# ---- PR-2: packaging parity ----
grep -qxF '/etc/sysctl.d/90-nftban.conf' <(sed -n '/DEBIAN\/conffiles/,/CONFFILES_EOF/p' "$BUILD") && ok "PR2 DEB conffiles declares sysctl" || no "PR2 DEB conffile"
grep -qE '%config\(noreplace\)\s+/etc/sysctl.d/90-nftban.conf' "$BUILD" && ok "PR2 RPM %config(noreplace) kept" || no "PR2 RPM noreplace"

# ---- PR-3: registry + risk scan ----
# shellcheck source=/dev/null
source "$REG"
reg=$(nftban_sysctl_registry)
grep -q 'nf_conntrack_tcp_timeout_established|' <<<"$reg" && ok "PR3 registry has established key" || no "PR3 reg est"
grep -q 'nf_conntrack_max|nftban-owned-default|262144' <<<"$reg" && ok "PR3 registry has conntrack_max" || no "PR3 reg max"
grep -q '99-local.conf' <<<"$reg" && ok "PR3 registry override path" || no "PR3 reg override"

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export NFTBAN_SYSCTL_FILE="$WORK/90.conf" NFTBAN_SYSCTL_LOCAL="$WORK/99.conf"
: > "$NFTBAN_SYSCTL_FILE"
E=net.netfilter.nf_conntrack_tcp_timeout_established

# (a) incident precondition: live 600 < keepalive 7200 + DB pool -> WARN dead-socket
r=$(NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 \
    NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_DB_POOL=yes nftban_sysctl_risk_scan)
grep -q "^WARN|$E|.*dead-socket risk" <<<"$r" && ok "PR3 dead-socket WARN (est<keepalive + DB pool)" || no "PR3 dead-socket"
# (a') same but no DB pool -> INFO low risk, not a dead-socket WARN
r=$(NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 \
    NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_DB_POOL=no nftban_sysctl_risk_scan)
{ grep -q "^INFO|$E|.*low risk" <<<"$r" && ! grep -q 'dead-socket risk' <<<"$r"; } && ok "PR3 no-DB-pool -> INFO low-risk only" || no "PR3 no-DB-pool"
# (b) legacy 600 present in file -> WARN
printf '%s = 600\n' "$E" > "$NFTBAN_SYSCTL_FILE"
r=$(NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_DB_POOL=no nftban_sysctl_risk_scan)
grep -q "^WARN|$E|.*legacy established=600" <<<"$r" && ok "PR3 legacy 600-in-file WARN" || no "PR3 legacy600"
# (c)+(d) file=600 but live=432000 -> drift WARN + module-load-race WARN
r=$(NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=432000 NFTBAN_TEST_DB_POOL=no nftban_sysctl_risk_scan)
grep -q "^WARN|$E|.*!= live value" <<<"$r" && ok "PR3 file-vs-live drift WARN" || no "PR3 drift"
grep -q "^WARN|$E|.*module-load race" <<<"$r" && ok "PR3 module-load-race WARN" || no "PR3 modrace"
# (e) operator override in 99-local -> INFO
: > "$NFTBAN_SYSCTL_FILE"; printf '%s = 300\n' "$E" > "$NFTBAN_SYSCTL_LOCAL"
r=$(NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=300 NFTBAN_TEST_DB_POOL=no nftban_sysctl_risk_scan)
grep -q "^INFO|$E|operator override" <<<"$r" && ok "PR3 operator override INFO" || no "PR3 override"

# no writes: the registry lib must not write kernel/files (no sysctl -w, no > to /proc or sysctl.d)
grep -qE 'sysctl\s+-w|>\s*/proc/sys|>\s*/etc/sysctl' "$REG" && no "PR3 registry must not write" || ok "PR3 registry is read-only (no writes)"

# ---- PR-3 wiring: support + watchdog ----
grep -q '_collect_sysctl()' "$SUP" && grep -q '_collect_sysctl "\$bundle_dir"' "$SUP" && ok "PR3 support _collect_sysctl defined+called" || no "PR3 support wire"
grep -q 'nftban_sysctl_risk_scan' "$WD" && ok "PR3 watchdog wires risk scan" || no "PR3 watchdog wire"

echo "=== sysctl_safe_default_v216: PASS=$P FAIL=$F ==="
[ "$F" -eq 0 ]
