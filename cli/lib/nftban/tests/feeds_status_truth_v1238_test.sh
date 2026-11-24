#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 feeds status / list / help / JSON say what is selected, enforced and known
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="feeds_status_truth_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 (owner 2026-11-23, srv2 sample: master switch off, TOR_EXITS selected and retained CONFLICT_KEPT, 1263 snapshot entries — the old output called all of it 'enabled'). Drives the REAL nftban_feeds_status / nftban_feeds_status_json / _nftban_feeds_master_effective / _nftban_feeds_selection_readback with a sandbox config (feeds.conf + nftban.conf + nftban.conf.local) and a stubbed nftban-core (feeds effective = CONFLICT_KEPT, feeds status --json = refresh record). Asserts: master switch, selected feeds and enforcement on separate lines; the master switch source file shown only when it agrees with the daemon decision; per feed 'entries in snapshot' (not IPs) and 'selected in <file>'; refresh labels Last successful refresh / Last failed attempt / Next scheduled refresh from the record, else 'Snapshot timestamp'; JSON keeps summary.enabled_count/total_ips and enabled_feeds[].ip_count/last_update and adds master_switch{state,source}, selected, authority{state,enforced,reasons}, entries, selected_source, last_successful_refresh, last_failed_attempt, next_scheduled_refresh; the selection read-back reports 'Selection saved' with the effective file and fails (naming the file) when the effective value differs; list legend and help wording. Sandbox only; no network, no firewall change."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,jq,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_feeds.sh,cli/lib/nftban/core/nftban_feeds.sh"
# meta:inventory.binaries="bash,jq,awk,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_LIB_DIR,NFTBAN_FEEDS_CONFIG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="feeds_status_truth_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="feeds"
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
CMD="$LIB/cli/cmd_feeds.sh"
CORE="$LIB/core/nftban_feeds.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/etc" "$W/data/feeds" "$W/lib/bin"
cat > "$W/etc/feeds.conf" <<'EOF'
FEED_TOR_EXITS_URL="https://tor.example.invalid/list"
FEED_TOR_EXITS_ENABLED="false"
FEED_SPAMHAUS_DROP_URL="https://drop.example.invalid/drop.txt"
FEED_SPAMHAUS_DROP_ENABLED="false"
EOF
printf 'NFTBAN_FEEDS_ENABLED="true"\n' > "$W/etc/nftban.conf"
printf 'NFTBAN_FEEDS_ENABLED="false"\nFEED_TOR_EXITS_ENABLED="true"\n' > "$W/etc/nftban.conf.local"
printf '198.51.100.1\n198.51.100.2\n2001:db8::/48\n' > "$W/data/feeds/tor_exits.txt"
cat > "$W/lib/bin/nftban-core" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "feeds effective") echo '{"state":"CONFLICT_KEPT","master":false,"enforced":["tor_exits"],"reasons":["feeds_config_conflict"],"texts":["feeds loaded but the master switch NFTBAN_FEEDS_ENABLED is off — kept as enforced before the upgrade"]}' ;;
  "feeds status --json") [[ -f "$NO_RECORD" ]] && exit 0
     echo '{"feeds":[{"feed":"tor_exits","last_success_at":"2026-11-23T03:26:38Z","last_attempt":{"at":"2026-11-23T02:20:00Z","ok":false,"reason":"http 503"},"next_update_text":"Tue 2026-11-24 03:31:12 UTC (daily feeds timer)"}]}' ;;
  "feeds status") echo "(refresh state)" ;;
esac
EOF
chmod 755 "$W/lib/bin/nftban-core"
export NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_DATA_DIR="$W/data" NFTBAN_LIB_DIR="$W/lib" NFTBAN_FEEDS_CONFIG="$W/etc/feeds.conf" \
       NFTBAN_FEEDS_STORAGE_DIR="$W/data/feeds" NO_RECORD="$W/no_record"

pick(){ awk -v re="$2" '$0 ~ "^("re")\\(\\) \\{" {f=1} f {print} f && /^\}/ {f=0}' "$1"; }
fns="$(pick "$CORE" '_nftban_feeds_conf_value|nftban_feeds_get_property|nftban_feeds_property_source|nftban_feeds_discover_all|nftban_feeds_get_stats|_nftban_feeds_selection_readback')
$(pick "$CMD" '_nftban_feeds_master_effective|_nftban_feeds_enforcement_text|nftban_feeds_status|nftban_feeds_status_json|_nftban_feeds_status_json|_nftban_feeds_refresh_long')"
run(){ bash -c 'nftban_feeds_log(){ :; }; json_output(){ printf "%s\n" "$2"; }; eval "$1"; shift; "$@"' _ "$fns" "$@" 2>&1; }

echo "=== text: srv2 situation ==="
out=$(run nftban_feeds_status)
grep -qE '^Master switch +OFF +\(NFTBAN_FEEDS_ENABLED in .*/etc/nftban.conf.local\)' <<<"$out" && ok "master switch OFF, with the file it is effectively set in" || no "master switch line" "$(grep -m1 'Master switch' <<<"$out")"
grep -qE '^Selected feeds +1 of 2: TOR_EXITS$' <<<"$out" && ok "selected feeds on their own line" || no "selected line" "$(grep -m1 'Selected feeds' <<<"$out")"
grep -qE '^Enforcement +TOR_EXITS retained from before the upgrade \(CONFLICT_KEPT\)$' <<<"$out" && ok "enforcement line states the retained feed" || no "enforcement line" "$(grep -m1 Enforcement <<<"$out")"
grep -q 'feeds enabled' <<<"$out" && no "status still says 'feeds enabled'" || ok "no 'feeds enabled' wording"
grep -qE 'TOR_EXITS +3 entries in snapshot +\(selected in .*/etc/nftban.conf.local\)' <<<"$out" && ok "per feed: entries in snapshot + selection source" || no "per-feed line" "$(grep -m1 TOR_EXITS <<<"$out")"
grep -q 'Last successful refresh: 2026-11-23 03:26 UTC' <<<"$out" && grep -q 'Last failed attempt:     2026-11-23 02:20 UTC — http 503' <<<"$out" \
  && grep -q 'Next scheduled refresh:  Tue 2026-11-24 03:31:12 UTC (daily feeds timer)' <<<"$out" && ok "refresh record labels (timer's actual next run)" || no "refresh labels" "$(grep -A3 TOR_EXITS <<<"$out")"
grep -q 'Snapshot entries: 3' <<<"$out" && ok "totals labelled as totals across the selected feeds" || no "totals label"
touch "$NO_RECORD"; out=$(run nftban_feeds_status); rm -f "$NO_RECORD"
grep -q 'Snapshot timestamp:' <<<"$out" && ! grep -q 'Last successful refresh' <<<"$out" && ok "no refresh record -> 'Snapshot timestamp' only" || no "snapshot timestamp fallback"

echo "=== source shown only when it agrees with the daemon ==="
printf 'NFTBAN_FEEDS_ENABLED="true"\nFEED_TOR_EXITS_ENABLED="true"\n' > "$W/etc/nftban.conf.local"
out=$(run nftban_feeds_status)
grep -qE '^Master switch +OFF$' <<<"$out" && ok "file says on, daemon decided off -> value from the daemon, no source shown" || no "disagreeing source" "$(grep -m1 'Master switch' <<<"$out")"
printf 'NFTBAN_FEEDS_ENABLED="false"\nFEED_TOR_EXITS_ENABLED="true"\n' > "$W/etc/nftban.conf.local"

echo "=== JSON ==="
j=$(run nftban_feeds_status_json true)
jq -e . >/dev/null 2>&1 <<<"$j" && ok "valid JSON" || no "invalid JSON" "$j"
[[ "$(jq -r '[.summary.enabled_count, .summary.total_ips, .enabled_feeds[0].ip_count, (.enabled_feeds[0].last_update|length>0)] | @tsv' <<<"$j")" == $'1\t3\t3\ttrue' ]] && ok "existing fields kept for current consumers" || no "existing fields" "$j"
[[ "$(jq -r '.master_switch.state + " " + (.master_switch.source|tostring)' <<<"$j")" == "off $W/etc/nftban.conf.local" ]] && ok "master_switch.state + source" || no "master_switch" "$(jq -c .master_switch <<<"$j")"
[[ "$(jq -c '[.selected, .authority.state, .authority.enforced, .authority.reasons]' <<<"$j")" == '[["TOR_EXITS"],"CONFLICT_KEPT",["tor_exits"],["feeds_config_conflict"]]' ]] && ok "selected + authority (state, enforced, reasons)" || no "authority" "$(jq -c .authority <<<"$j")"
[[ "$(jq -c '.enabled_feeds[0] | [.entries, .selected_source, .last_successful_refresh, .last_failed_attempt.reason, .next_scheduled_refresh]' <<<"$j")" == "[3,\"$W/etc/nftban.conf.local\",\"2026-11-23T03:26:38Z\",\"http 503\",\"Tue 2026-11-24 03:31:12 UTC (daily feeds timer)\"]" ]] \
  && ok "per feed: entries, selected_source, refresh record" || no "per-feed JSON" "$(jq -c '.enabled_feeds[0]' <<<"$j")"

echo "=== selection read-back ==="
out=$(run _nftban_feeds_selection_readback TOR_EXITS true); rc=$?
[[ $rc -eq 0 && "$out" == *"Selection saved: FEED_TOR_EXITS_ENABLED=\"true\" (effective, from $W/etc/nftban.conf.local)"* ]] && ok "read-back: 'Selection saved' with the effective file" || no "read-back ok" "$out"
rc=0; out=$(run _nftban_feeds_selection_readback SPAMHAUS_DROP true) || rc=$?
[[ $rc -ne 0 && "$out" == *"is \"false\" in $W/etc/feeds.conf"*"NOT saved"* ]] && ok "read-back mismatch fails and names the file" || no "read-back mismatch" "rc=$rc $out"

echo "=== list legend and help ==="
grep -q 'Enable the selected feeds (master switch NFTBAN_FEEDS_ENABLED)' "$CMD" && ! grep -q 'Turn ALL feeds on' "$CMD" && ok "help: 'Enable the selected feeds'" || no "help wording"
grep -q '\[✓\] Selected   \[✗\] Not selected' "$CMD" && ok "list legend: Selected / Not selected; interval is the provider's" || no "list legend"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
