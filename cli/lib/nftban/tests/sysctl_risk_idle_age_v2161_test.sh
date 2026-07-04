#!/usr/bin/env bash
# =============================================================================
# NFTBan Test - Sysctl Risk Guard Idle-Age Refinement + conntrack fallback (v1.216.1)
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
# meta:description="Verify v1.216.1 idle-age-aware dead-socket classification (CLEAN/INFO/WARN/UNKNOWN by idle age vs established timeout, incl the monitor zabbix-agent2 active class), the optional conntrack-tool fallback (procfs -> conntrack -L -> none), IPv4/IPv6 loopback parsing, UNKNOWN-FORMAT defensiveness, the idle_age_source field, and credential-free/no-DB-query/no-write guarantees."
# meta:inventory.files="cli/lib/nftban/lib/nftban_sysctl_registry.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_TEST_POOL_COUNT,NFTBAN_TEST_MAXIDLE,NFTBAN_TEST_IDLE_SOURCE,NFTBAN_TEST_SAMPLE_STABLE"
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
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
# mock `conntrack` (PATH shim) emitting MOCK_CONNTRACK_OUT — for the conntrack-tool fallback path
mkdir -p "$WORK/bin"; printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${MOCK_CONNTRACK_OUT:-}"\n' > "$WORK/bin/conntrack"; chmod +x "$WORK/bin/conntrack"
export PATH="$WORK/bin:$PATH"
# shellcheck source=/dev/null
source "$REG"
E=net.netfilter.nf_conntrack_tcp_timeout_established
cls(){ nftban_db_dead_socket_classify "$1" "$2" | cut -d'|' -f1; }        # CLASS
src(){ nftban_db_dead_socket_classify "$1" "$2" | cut -d'|' -f4; }        # idle_age_source
scan(){ ( local kv; for kv in "$@"; do export "${kv?}"; done; nftban_sysctl_risk_scan 2>/dev/null ); }

# ---- classifier matrix (hook-driven, est=600 keepalive=7200) ----
[ "$(NFTBAN_TEST_POOL_COUNT=0 cls 600 7200)" = CLEAN ] && ok "CLEAN: no pool" || no "CLEAN"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=procfs NFTBAN_TEST_MAXIDLE=500 cls 600 7200)" = WARN ] && ok "WARN: long-idle (500>=300)" || no "WARN long-idle"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=procfs NFTBAN_TEST_MAXIDLE=59 cls 600 7200)" = INFO ] && ok "INFO: active short-idle (59<<600) [agent2 class]" || no "INFO active"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=none NFTBAN_TEST_MAXIDLE=UNKNOWN NFTBAN_TEST_SAMPLE_STABLE=yes cls 600 7200)" = UNKNOWN ] && ok "UNKNOWN: no source + stable pool (not silent CLEAN)" || no "UNKNOWN"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=none NFTBAN_TEST_MAXIDLE=UNKNOWN NFTBAN_TEST_SAMPLE_STABLE=no cls 600 7200)" = INFO ] && ok "INFO: unmeasurable but churning (active)" || no "INFO churn"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_MAXIDLE=999999 cls 432000 7200)" = INFO ] && ok "INFO: est(432000)>=keepalive -> no risk" || no "INFO est>=keep"
[ "$(NFTBAN_TEST_POOL_COUNT=1 NFTBAN_TEST_IDLE_SOURCE=procfs NFTBAN_TEST_MAXIDLE=300 cls 600 7200)" = WARN ] && ok "boundary idle=300 -> WARN" || no "boundary 300"
[ "$(NFTBAN_TEST_POOL_COUNT=1 NFTBAN_TEST_IDLE_SOURCE=procfs NFTBAN_TEST_MAXIDLE=299 cls 600 7200)" = INFO ] && ok "boundary idle=299 -> INFO" || no "boundary 299"

# ---- idle_age_source field ----
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=procfs NFTBAN_TEST_MAXIDLE=59 src 600 7200)" = procfs ] && ok "source=procfs surfaced" || no "source procfs"
[ "$(NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=none NFTBAN_TEST_MAXIDLE=UNKNOWN NFTBAN_TEST_SAMPLE_STABLE=yes src 600 7200)" = none ] && ok "source=none surfaced (UNKNOWN)" || no "source none"

# ---- REAL conntrack-tool fallback via mock (no NFTBAN_TEST_MAXIDLE -> exercises conntrack -L + parser) ----
CT_IDLE='tcp      6 100 ESTABLISHED src=127.0.0.1 dst=127.0.0.1 sport=54321 dport=5432 src=127.0.0.1 dst=127.0.0.1 sport=5432 dport=54321 [ASSURED] mark=0 use=1'
CT_ACT='tcp      6 580 ESTABLISHED src=127.0.0.1 dst=127.0.0.1 sport=54322 dport=5432 [ASSURED]'
CT_V6='tcp      6 120 ESTABLISHED src=::1 dst=::1 sport=54323 dport=5432 [ASSURED]'
CT_BAD='tcp SOMEGARBAGE ESTABLISHED src=127.0.0.1 dport=5432'
r=$(MOCK_CONNTRACK_OUT="$CT_IDLE" NFTBAN_TEST_POOL_COUNT=3 NFTBAN_TEST_IDLE_SOURCE=conntrack-tool cls 600 7200); [ "$r" = WARN ] && ok "conntrack-tool fallback: remaining=100 -> idle=500 -> WARN" || no "ct-tool WARN ($r)"
r=$(MOCK_CONNTRACK_OUT="$CT_ACT" NFTBAN_TEST_POOL_COUNT=3 NFTBAN_TEST_IDLE_SOURCE=conntrack-tool cls 600 7200); [ "$r" = INFO ] && ok "conntrack-tool fallback: remaining=580 -> idle=20 -> INFO" || no "ct-tool INFO ($r)"
r=$(MOCK_CONNTRACK_OUT="$CT_V6" NFTBAN_TEST_POOL_COUNT=1 NFTBAN_TEST_IDLE_SOURCE=conntrack-tool cls 600 7200); [ "$r" = WARN ] && ok "conntrack-tool fallback: IPv6 ::1 loopback parsed (idle=480 -> WARN)" || no "ct-tool v6 ($r)"
r=$(MOCK_CONNTRACK_OUT="$CT_BAD" NFTBAN_TEST_POOL_COUNT=1 NFTBAN_TEST_IDLE_SOURCE=conntrack-tool src 600 7200); [ "$r" = unknown-format ] && ok "malformed conntrack output -> UNKNOWN-FORMAT (defensive, not CLEAN)" || no "ct-tool malformed ($r)"
r=$(MOCK_CONNTRACK_OUT="" NFTBAN_TEST_POOL_COUNT=1 NFTBAN_TEST_IDLE_SOURCE=conntrack-tool cls 600 7200); [ "$r" = UNKNOWN ] && ok "conntrack-tool present but no DB entries -> UNKNOWN" || no "ct-tool empty ($r)"

# ---- full risk_scan integration (message text + watchdog compat + no-hidden-unknown) ----
export NFTBAN_SYSCTL_FILE=/nonexistent-90 NFTBAN_SYSCTL_LOCAL=/nonexistent-99
rA=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=procfs NFTBAN_TEST_MAXIDLE=500)
{ grep -q "^WARN|$E|.*dead-socket risk" <<<"$rA" && grep -q 'idle_age_source=procfs' <<<"$rA"; } && ok "scan WARN carries 'dead-socket risk' + idle_age_source" || no "scan WARN"
rB=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=procfs NFTBAN_TEST_MAXIDLE=59)
{ grep -q "^INFO|$E|.*low risk" <<<"$rB" && ! grep -q 'dead-socket risk' <<<"$rB"; } && ok "scan INFO active pool, no dead-socket WARN (agent2 repro)" || no "scan INFO agent2"
rU=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=5 NFTBAN_TEST_IDLE_SOURCE=none NFTBAN_TEST_MAXIDLE=UNKNOWN NFTBAN_TEST_SAMPLE_STABLE=yes)
{ grep -q "^UNKNOWN|$E|.*unmeasurable" <<<"$rU" && grep -qi 'cannot confirm safe' <<<"$rU" && ! grep -q "dead-socket risk" <<<"$rU"; } && ok "scan UNKNOWN surfaced (not hidden, not WARN, mentions conntrack)" || no "scan UNKNOWN"
grep -qi "install 'conntrack'" <<<"$rU" && ok "UNKNOWN advises installing conntrack (DEB)" || no "UNKNOWN advice"
rC=$(scan NFTBAN_TEST_LIVE_net_netfilter_nf_conntrack_tcp_timeout_established=600 NFTBAN_TEST_LIVE_net_ipv4_tcp_keepalive_time=7200 NFTBAN_TEST_POOL_COUNT=0)
[ -z "$(grep -E "dead-socket|local TCP DB" <<<"$rC")" ] && ok "scan CLEAN emits no dead-socket line" || no "scan CLEAN"

# ---- credential-free / read-only guards ----
fn=$(declare -f nftban_db_dead_socket_classify _nftban_db_conntrack_maxidle _nftban_db_pool_count _nftban_db_pool_stable _nftban_db_idle_source)
grep -qE 'psql|pg_connect|PGPASSWORD|pg_stat|mysql -|redis-cli|mongo ' <<<"$fn" && no "must not query DBs" || ok "no DB queries (credential-free)"
grep -qE 'sysctl -w|sysctl --system|> */proc/sys|conntrack -[DFU]' <<<"$fn" && no "must not write / no conntrack mutation" || ok "read-only (conntrack -L only, no -D/-F/-U/writes)"
grep -q '/proc/net/nf_conntrack' <<<"$fn" && grep -q 'conntrack -L' <<<"$fn" && ok "idle source order procfs -> conntrack -L (host-only)" || no "source order"

# ---- packaging: DEB Recommends conntrack (optional, not Depends); RPM unchanged ----
BUILD="$ROOT/packaging/build_nftban.sh"
grep -qE '^Recommends:.*\bconntrack\b' "$BUILD" && ok "DEB Recommends includes conntrack (optional)" || no "DEB Recommends conntrack"
grep -qE '^Depends:.*\bconntrack\b' "$BUILD" && no "conntrack must NOT be a hard DEB Depends" || ok "conntrack is not a hard DEB dependency"
# RPM %spec Recommends (the RHEL block) must NOT gain conntrack-tools (procfs already full)
sed -n '/^Recommends:     acl/,/^Recommends:     newt/p' "$BUILD" | grep -qE 'conntrack' && no "RPM must not add conntrack-tools" || ok "RPM dependency metadata unchanged (procfs full)"

echo "=== sysctl_risk_idle_age_v2161: PASS=$P FAIL=$F ==="
[ "$F" -eq 0 ]
