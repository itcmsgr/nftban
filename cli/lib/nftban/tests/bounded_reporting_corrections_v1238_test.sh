#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 bounded reporting / config corrections (one section per defect)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="bounded_reporting_corrections_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 (owner 2026-11-23: incorrect status values, nonexistent command hints, GeoIP keys that do not reach their consumer). P: BUG-PORTAL-PAYLOAD-INVALID-JSON + BUG-PORTAL-MODULE-STATUS-READS-NONEXISTENT-MODULES-DIR — drives the REAL export_portal with a fake curl that captures the payload (stdin or -d argument): the payload is valid JSON, metric lines without a timestamp give ts null, string metrics are skipped, module status follows conf.d/<module>/main.conf(.local) (1/0) and unresolvable modules are null, never 0. G: BUG-GEOIP-CONFIG-SHOW-IGNORES-LOCAL — the REAL `nftban geoip config show` reports the effective source from main.conf.local and accepts the shipped key name GEOIP_PROVIDER. R: BUG-REGISTRY-LISTS-DDOS-CONFIG-NOT-DISPATCHED — commands.registry.yml lists no ddos verb that cmd_ddos.sh does not dispatch. F: BUG-FEEDS-STATUS-IGNORES-FEEDS-CONF-LOCAL-DEFINITIONS — discovery reads feeds.conf, feeds.conf.local and nftban.conf.local like the daemon; commented lines ignored. M: BUG-PROMETHEUS-MODULE-STATUS-READS-NONEXISTENT-MODULES-DIR — nftban_module_login_status from nftband modules answer (1/0/-1, unknown omitted / JSON null). S: BUG-STATS-JSON-TEMPORARY-COUNTS-PERMANENT — breakdown.temporary = timed elements only; active bans unchanged. Sandbox only; no network, no firewall change."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,jq,awk,grep"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_export.sh,cli/lib/nftban/cli/cmd_geoip.sh,commands.registry.yml,cli/lib/nftban/cli/cmd_ddos.sh"
# meta:inventory.binaries="bash,jq,awk,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_RUN_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="bounded_reporting_corrections_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="reporting"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$TEST_DIR/.." && pwd)"
ROOT="$(cd "$LIB/../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/etc/conf.d/ddos" "$W/etc/conf.d/portscan" "$W/etc/conf.d/geoip" "$W/run"

echo "=== P: portal payload ==="
cat > "$W/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev=""; for a in "$@"; do
  if [[ "$prev" == "-d" ]]; then if [[ "$a" == "@-" ]]; then cat > "$W/payload"; else printf '%s' "$a" > "$W/payload"; fi; fi
  prev="$a"; done
printf '\n200'
EOF
chmod 755 "$W/bin/curl"
printf 'DDOS_ENABLED="true"\n' > "$W/etc/conf.d/ddos/main.conf"
printf 'PORTSCAN_ENABLED="true"\n' > "$W/etc/conf.d/portscan/main.conf"
printf 'PORTSCAN_ENABLED="false"\n' > "$W/etc/conf.d/portscan/main.conf.local"
printf 'nftban_daemon_up 1\nnftban_version_info{version="1.237.0"} 1\nnftban.version.info |STRING|1.237.0\nnftban_bans_total 42 1700000000\n' > "$W/metrics.cache"
export W
out=$(PATH="$W/bin:$PATH" NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_RUN_DIR="$W/run" NFTBAN_LIB_DIR="$LIB" \
      NFTBAN_PORTAL_ENABLED=true NFTBAN_PORTAL_API_KEY="placeholder" NFTBAN_PORTAL_URL="https://portal.example.invalid/api" \
      bash -c 'log_info(){ :; }; log_warn(){ echo "WARN $*"; }; source "$1"; set +e; METRICS_CACHE="$W/metrics.cache"; export_portal; echo "RC=$?"' _ \
      "$LIB/exporters/nftban_unified_exporter_export.sh" 2>&1)
if [[ -s "$W/payload" ]] && jq -e . "$W/payload" >/dev/null 2>&1; then ok "payload is valid JSON"; else no "payload not valid JSON" "$(head -c 300 "$W/payload" 2>/dev/null) $out"; fi
P="$W/payload"
[[ "$(jq -r '[.metrics[] | select(.name=="nftban_daemon_up")][0].ts' "$P" 2>/dev/null)" == "null" ]] && ok "metric without timestamp -> ts null (was \"ts\":})" || no "ts handling"
[[ "$(jq -r '[.metrics[] | select(.name=="nftban_bans_total")][0].value' "$P" 2>/dev/null)" == "42" ]] && ok "numeric metric kept" || no "numeric metric"
[[ "$(jq -r '[.metrics[] | select(.name|test("version.info$"))] | length' "$P" 2>/dev/null)" == "0" ]] && ok "string metric skipped" || no "string metric present"
st(){ jq -r --arg m "$1" '.modules[] | select(.name==$m) | .status' "$P" 2>/dev/null; }
[[ "$(st ddos)" == "1" ]] && ok "ddos enabled in config -> status 1 (was always 0)" || no "ddos status $(st ddos)"
[[ "$(st portscan)" == "0" ]] && ok "portscan .local false overrides base true -> 0" || no "portscan status $(st portscan)"
[[ "$(st watchdog)" == "null" ]] && ok "unresolvable module (watchdog) -> null, not 0" || no "watchdog status $(st watchdog)"

echo "=== G: geoip config show ==="
printf 'GEOIP_PROVIDER="dbip"\n' > "$W/etc/conf.d/geoip/main.conf"
printf 'GEOIP_PROVIDER="maxmind"\nGEOIP_MAXMIND_KEY="placeholder0000"\n' > "$W/etc/conf.d/geoip/main.conf.local"
fn=$(awk '/^nftban_geoip_cmd_config\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$LIB/cli/cmd_geoip.sh")
out=$(NFTBAN_CONFIG_DIR="$W/etc" bash -c 'eval "$1"; nftban_geoip_cmd_config show' _ "$fn" 2>&1 || true)
[[ "$out" == *"Current: maxmind"* ]] && ok "effective source from main.conf.local with the shipped key name (was dbip)" || no "config show" "$(grep -m2 -E 'Current|source set' <<<"$out")"
[[ "$out" == *"License Key: ••••"* && "$out" != *"placeholder0000"* ]] && ok "licence key found and masked" || no "licence key display"

echo "=== R: registry vs ddos dispatcher ==="
verbs=$(awk '/^ddos:/{f=1;next} f && /^[a-z]/{f=0} f && /^    [a-z_-]+:$/ {gsub(/[: ]/,""); print}' "$ROOT/commands.registry.yml")
missing=""
for v in $verbs; do grep -qE "^[[:space:]]+(\"?)${v}(\"?)[|)]|[|]${v}[|)]" "$LIB/cli/cmd_ddos.sh" || missing+=" $v"; done
[[ -z "$missing" ]] && ok "every registry ddos verb is dispatched ($(echo $verbs | tr '\n' ' '))" || no "registry lists undispatched ddos verb(s):$missing"
grep -q 'nftban ddos config' "$ROOT/commands.registry.yml" && no "registry example still names 'nftban ddos config'" || ok "no 'nftban ddos config' example"

echo "=== F: feeds status discovers feeds.conf.local definitions (VM pass 2026-11-23) ==="
mkdir -p "$W/fc"
printf 'FEED_SHIPPED_URL="https://a.example.invalid/x"\n# FEED_COMMENTED_URL="https://c.example.invalid/x"\n' > "$W/fc/feeds.conf"
printf 'FEED_LOCALONLY_URL="https://b.example.invalid/x"\nFEED_LOCALONLY_ENABLED="true"\n' > "$W/fc/feeds.conf.local"
dfn=$(awk '/^nftban_feeds_discover_all\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$LIB/core/nftban_feeds.sh")
found=$(NFTBAN_FEEDS_CONFIG="$W/fc/feeds.conf" NFTBAN_CONFIG_DIR="$W/fc" bash -c 'nftban_feeds_log(){ :; }; eval "$1"; nftban_feeds_discover_all' _ "$dfn" | tr '\n' ' ')
[[ "$found" == *LOCALONLY* ]] && ok "feed defined only in feeds.conf.local is discovered (was enforced but shown as 0)" || no "local-only feed not discovered" "$found"
[[ "$found" == *SHIPPED* && "$found" != *COMMENTED* ]] && ok "shipped feed discovered; commented-out definition ignored (as the daemon reader)" || no "discovery" "$found"

echo "=== M: Prometheus nftban_module_login_status from nftband (active / disabled / failed / unknown) ==="
lfn=$(awk '/^_nftban_exporter_loginmon_status\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$LIB/exporters/nftban_unified_exporter_collect.sh")
mkdir -p "$W/mrun" "$W/mbin"
printf '#!/usr/bin/env bash\ncat >/dev/null; cat "%s/modans"\n' "$W" > "$W/mbin/socat"; chmod 755 "$W/mbin/socat"
ml(){ printf '{"success":true,"data":[{"name":"loginmon","enabled":%s,"running":%s,"last_error":"%s"}]}' "$1" "$2" "$3" > "$W/modans"
      PATH="$W/mbin:$PATH" NFTBAN_RUN_DIR="$W/mrun" bash -c 'eval "$1"; _nftban_exporter_loginmon_status' _ "$lfn"; }
[[ "$(ml true true '')" == 1 ]] && ok "LoginMon running -> 1 (was always 0)" || no "active -> $(ml true true '')"
[[ "$(ml false false '')" == 0 ]] && ok "LoginMon disabled -> 0" || no "disabled -> $(ml false false '')"
[[ "$(ml true false 'watcher failed')" == "-1" ]] && ok "enabled, not running, with error -> -1" || no "failed -> $(ml true false x)"
: > "$W/modans"; [[ -z "$(PATH="$W/mbin:$PATH" NFTBAN_RUN_DIR="$W/mrun" bash -c 'eval "$1"; _nftban_exporter_loginmon_status' _ "$lfn")" ]] \
  && ok "no answer -> empty (metric omitted, JSON null), never 0" || no "unknown published as a value"
grep -q '"login": ${module_login_status:-null},' "$LIB/exporters/nftban_unified_exporter_collect.sh" && ok "JSON cache renders unknown login status as null" || no "JSON default"

echo "=== S: stats --json temporary = timed elements only (1 permanent + 1 temporary) ==="
tfn=$(awk '/^_nftban_stats_temporary_counts\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$LIB/cli/cmd_stats.sh")
sfn=$(awk '/^(nftban_count_sum|nftban_count_is_known)\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$LIB/lib/nft_schema.sh")
out=$(bash -c 'eval "$1"; eval "$2"
  # manual v4 set: one permanent + one timed element; everything else empty
  nftban_nft_count_set_with_timeout(){ [[ "$3" == blacklist_manual_ipv4 ]] && echo 1 || echo 0; }
  _nftban_stats_temporary_counts' _ "$sfn" "$tfn")
[[ "$out" == "1 0 1" ]] && ok "manual set with 1 permanent + 1 temporary -> temporary ipv4=1 total=1 (was 2)" || no "temporary counts" "$out"
out=$(bash -c 'eval "$1"; eval "$2"; nftban_nft_count_set_with_timeout(){ echo UNKNOWN; }; _nftban_stats_temporary_counts' _ "$sfn" "$tfn")
[[ "$out" == "null null null" ]] && ok "unreadable sets -> null, not 0" || no "unknown temporary" "$out"
grep -q 'active_bans=$((${manual_v4} + ${manual_v6} + ${total_black}' "$LIB/cli/cmd_stats.sh" && ok "active_bans still sums the set elements (manual + blacklist + ...)" || no "active_bans changed"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
