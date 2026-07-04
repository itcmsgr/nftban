#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - Sysctl Risk Guard Idle-Age Refinement (v1.216.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="sysctl-risk-idle-age-v2161-test"
# meta:type="test"
# meta:header="Sysctl Risk Guard Idle-Age v1.216.1"
# meta:version="1.216.0"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Verify the v1.216.1 idle-age-aware dead-socket classification: CLEAN (no pool), INFO (actively-refreshed short-idle pool, incl the monitor zabbix-agent2 class), WARN (long-idle pool approaching established timeout), UNKNOWN (pool exists but idle age unmeasurable — never silent CLEAN); est>=keepalive => no risk; threshold boundary; credential-free/no-DB-query/no-write."
# meta:inventory.files="cli/lib/nftban/lib/nftban_sysctl_registry.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_TEST_POOL_COUNT,NFTBAN_TEST_MAXIDLE,NFTBAN_TEST_SAMPLE_STABLE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:created_date="2026-07-04"
# meta:updated_date="2026-07-04"
# =============================================================================
set -Eeuo pipefail
SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(cd "$SD/../../../.." && pwd)
REG="$ROOT/cli/lib/nftban/lib/nftban_sysctl_registry.sh"
P=0; F=0
ok(){ echo "PASS $1"; P=$((P+1)); }
no(){ echo "FAIL $1"; F=$((F+1)); }
# shellcheck source=/dev/null
source "$REG"
E=net.netfilter.nf_conntrack_tcp_timeout_established
# helper: run the classifier directly -> CLASS
cls(){ nftban_db_dead_socket_classify "$1" "$2" | cut -d'|' -f1; }
# helper: run full scan with hooks (KEY=VAL ...) -> output (subshell so hooks don't leak)
scan(){ ( local kv; for kv in "$@"; do export "${kv?}"; done; nftban_sysctl_risk_scan 2>/dev/null ); }

# --- classifier matrix (est=600, keepalive=7200 unless noted) ---
[ "$(NFTBAN_TEST_POOL_COUNT=0 cls 600 7200)" = CLEAN ] && ok "CLEAN: no pool" || no "CLEAN"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=500 cls 600 7200)" = WARN ] && ok "WARN: long-idle (500>=300)" || no "WARN long-idle"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=59 cls 600 7200)" = INFO ] && ok "INFO: active short-idle (59<<600) [agent2 class]" || no "INFO active"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=UNKNOWN NFTBAN_TEST_SAMPLE_STABLE=yes cls 600 7200)" = UNKNOWN ] && ok "UNKNOWN: pool stable but idle unmeasurable (not silent CLEAN)" || no "UNKNOWN"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=UNKNOWN NFTBAN_TEST_SAMPLE_STABLE=no cls 600 7200)" = INFO ] && ok "INFO: unmeasurable but churning (active)" || no "INFO churn"
# est >= keepalive => keepalive probes first => no dead-socket risk even with a pool
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=999999 cls 432000 7200)" = INFO ] && ok "INFO: est(432000)>=keepalive(7200) -> no risk" || no "INFO est>=keep"
# threshold boundary (est=600 -> 50% = 300)
[ "$(NFTBAN_TEST_POOL_COUNT=1 NFTBAN_TEST_MAXIDLE=300 cls 600 7200)" = WARN ] && ok "boundary: idle=300 -> WARN (>=50%)" || no "boundary 300"
[ "$(NFTBAN_TEST_POOL_COUNT=1 NFTBAN_TEST_MAXIDLE=299 cls 600 7200)" = INFO ] && ok "boundary: idle=299 -> INFO (<50%)" || no "boundary 299"

# --- full risk_scan integration (message text) ---
export NFTBAN_SYSCTL_FILE=/nonexistent-90 NFTBAN_SYSCTL_LOCAL=/nonexistent-99
rA=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=500)
grep -q "^WARN|$E|.*dead-socket risk" <<<"$rA" && ok "scan WARN carries 'dead-socket risk' (watchdog-compat)" || no "scan WARN text"
rB=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=59)
{ grep -q "^INFO|$E|.*low risk" <<<"$rB" && ! grep -q 'dead-socket risk' <<<"$rB"; } && ok "scan INFO active-pool, no dead-socket WARN (agent2 repro)" || no "scan INFO agent2"
rU=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=UNKNOWN NFTBAN_TEST_SAMPLE_STABLE=yes)
{ grep -q "^UNKNOWN|$E|.*UNMEASURABLE" <<<"$rU" && ! grep -q "^WARN.*dead-socket" <<<"$rU"; } && ok "scan UNKNOWN surfaced (not hidden, not WARN)" || no "scan UNKNOWN"
rC=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=0)
[ -z "$(grep -E "dead-socket|local TCP DB" <<<"$rC")" ] && ok "scan CLEAN emits no dead-socket line" || no "scan CLEAN"

# --- reason text is explanatory (has est + keepalive + idle) ---
grep -qE "established .*600.* keepalive .*7200|max idle" <<<"$rA" && ok "reason text explains est/keepalive/idle" || no "reason text"

# --- credential-free / read-only guards ---
fn=$(declare -f nftban_db_dead_socket_classify _nftban_db_conntrack_maxidle _nftban_db_pool_count _nftban_db_pool_stable)
grep -qE 'psql|pg_connect|PGPASSWORD|pg_stat|mysql -|redis-cli|mongo ' <<<"$fn" && no "must not query DBs" || ok "no DB queries (credential-free)"
grep -qE 'sysctl -w|sysctl --system|> */proc/sys|conntrack -[DF]|-w /proc' <<<"$fn" && no "must not write" || ok "read-only (no sysctl/conntrack writes)"
grep -q '/proc/net/nf_conntrack' <<<"$fn" && ok "idle age from conntrack remaining (host-only)" || no "conntrack source"

echo "=== sysctl_risk_idle_age_v2161: PASS=$P FAIL=$F ==="
[ "$F" -eq 0 ]
