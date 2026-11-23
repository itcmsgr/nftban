#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238 `nftban feeds abuseipdb` menu: thin delegation, key never in argv
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="feeds_abuseipdb_menu_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-20"
# meta:description="v1.238 part B2 (owner 2026-11-20). The nftban feeds abuseipdb menu is thin: key set hands the key to nftban-core on STDIN, never as an argument; key remove and disable ask and refuse without a terminal unless --yes; config set accepts only CONFIDENCE_MINIMUM/LIMIT/MAX_AGE/MIN_INTERVAL with valid values and writes through the generic property writer; test/update/status delegate to nftban-core (test = abuseipdb-test, update = the single-feed update). A provider feed is never downloaded by the shell curl fallback, and enabling it downloads through nftban-core. nftban feeds help is no longer a two-line dispatcher stub and includes the abuseipdb commands. Behavioural, stubbed (fake nftban-core records argv and stdin); no network, no firewall change; the key is a test fixture."
# meta:input="None (repo source read-only; temp dirs)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk,jq"
# meta:inventory.files="cli/lib/nftban/cli/cmd_feeds.sh,cli/lib/nftban/core/nftban_feeds.sh,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,awk,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="feeds_abuseipdb_menu_v1238_test"
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
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

CMD_FEEDS="$REPO_ROOT/cli/lib/nftban/cli/cmd_feeds.sh"
FEEDS_SH="$REPO_ROOT/cli/lib/nftban/core/nftban_feeds.sh"
SBIN="$REPO_ROOT/cli/sbin/nftban"
for f in "$CMD_FEEDS" "$FEEDS_SH" "$SBIN"; do [[ -f "$f" ]] || { echo "missing: $f"; exit 1; }; done

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
# fake nftban-core: records argv (one line per call) and stdin
cat > "$W/core" <<'CORE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$W_LOG/argv"
if [[ "$*" == "feeds abuseipdb-key set" ]]; then cat > "$W_LOG/stdin"; fi
if [[ "$*" == "feeds abuseipdb-key status" ]]; then echo "API key file: /etc/nftban/abuseipdb.key: absent"; fi
exit 0
CORE
chmod 0755 "$W/core"

# the menu and its helpers, extracted from the module
fns=$(awk '/^_NFTBAN_ABUSEIPDB_FEED=/ {print} /^_NFTBAN_ABUSEIPDB_SETTABLE=/ {print}
           /^(_nftban_abuseipdb_[a-z_]+|nftban_feeds_abuseipdb)\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$CMD_FEEDS")
run(){  # args... -> output; stdin passed through; logs in $W
    : > "$W/argv"; rm -f "$W/stdin" "$W/calls"
    W_LOG="$W" NFTBAN_CORE_BIN="$W/core" bash -c '
        nftban_feeds_get_property(){ echo "v-$1-$2"; }
        nftban_feeds_set_property(){ echo "SET $*" >> "$W_LOG/calls"; }
        nftban_feeds_enable_json(){ echo "ENABLE $*" >> "$W_LOG/calls"; }
        nftban_feeds_disable_json(){ echo "DISABLE $*" >> "$W_LOG/calls"; }
        eval "$1"; shift; nftban_feeds_abuseipdb "$@"' _ "$fns" "$@" 2>&1
}
export W_LOG="$W"
KEY="fixturekey$(printf 'x%.0s' {1..20})"   # test fixture, not a credential

echo "=== key set: stdin only, never argv ==="
rc=0; out=$(printf '%s\n' "$KEY" | run key set) || rc=$?
[[ $rc -eq 0 && "$(cat "$W/argv")" == "feeds abuseipdb-key set" ]] && ok "key set calls nftban-core feeds abuseipdb-key set" || no "key set argv" "rc=$rc argv=$(cat "$W/argv")"
grep -qF "$KEY" "$W/stdin" && ok "the key reaches nftban-core on stdin" || no "key not on stdin"
grep -qF "$KEY" "$W/argv" && no "the key appeared in argv" || ok "the key never appears in argv"
grep -qF "$KEY" <<<"$out" && no "the key was printed" || ok "the key is never printed"

echo "=== confirmation without a terminal ==="
rc=0; out=$(run key remove </dev/null) || rc=$?
[[ $rc -ne 0 && ! -s "$W/argv" && "$out" == *"--yes"* ]] && ok "key remove refused without a terminal (asks for --yes)" || no "key remove without tty" "rc=$rc argv=$(cat "$W/argv")"
rc=0; run key remove --yes </dev/null >/dev/null || rc=$?
[[ $rc -eq 0 && "$(cat "$W/argv")" == "feeds abuseipdb-key remove" ]] && ok "key remove --yes delegates" || no "key remove --yes" "rc=$rc"
rc=0; run disable </dev/null >/dev/null || rc=$?
[[ $rc -ne 0 && ! -s "$W/calls" ]] && ok "disable refused without a terminal" || no "disable without tty" "rc=$rc"
rc=0; out=$(run disable --yes </dev/null) || rc=$?
[[ $rc -eq 0 && "$(cat "$W/calls")" == "DISABLE ABUSEIPDB false" && "$out" == *"Only AbuseIPDB's contribution is removed"* ]] \
    && ok "disable --yes uses the generic disable and says only its contribution goes" || no "disable --yes" "rc=$rc out=$out"

echo "=== config set: allow-list and values ==="
for bad in "LIMIT 999999" "CONFIDENCE_MINIMUM 10" "MAX_AGE soon" "URL https://x.invalid" "FORMAT plain" "MIN_INTERVAL"; do
    rc=0; IFS=' ' read -r -a a <<<"$bad"; run config set "${a[@]}" >/dev/null || rc=$?
    [[ $rc -ne 0 && ! -s "$W/calls" ]] && ok "config set $bad refused" || no "config set $bad" "rc=$rc"
done
rc=0; run config set max_age 48h >/dev/null || rc=$?
[[ $rc -eq 0 && "$(cat "$W/calls")" == "SET ABUSEIPDB MAX_AGE 48h" ]] && ok "config set max_age 48h -> generic property writer" || no "config set max_age" "rc=$rc calls=$(cat "$W/calls" 2>/dev/null)"

echo "=== delegation ==="
sub="test"; run "$sub" >/dev/null; [[ "$(cat "$W/argv")" == "feeds abuseipdb-test" ]] && ok "test -> nftban-core feeds abuseipdb-test" || no "test argv" "$(cat "$W/argv")"
run update >/dev/null; [[ "$(cat "$W/argv")" == "feeds update ABUSEIPDB" ]] && ok "update -> the single-feed update" || no "update argv" "$(cat "$W/argv")"
run status >/dev/null; [[ "$(cat "$W/argv")" == "feeds status --feed abuseipdb" ]] && ok "status -> the one status reader" || no "status argv" "$(cat "$W/argv")"
rc=0; run bogus >/dev/null || rc=$?; [[ $rc -ne 0 ]] && ok "unknown command refused" || no "unknown command rc=0"

echo "=== provider feeds never use the shell curl path; help ==="
blk=$(awk '/^nftban_feeds_update_single\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$FEEDS_SH")
lf=$(grep -m1 -n 'nftban_feeds_get_property "$feed_name" "FORMAT"' <<<"$blk" || true); lf="${lf%%:*}"
lc=$(grep -m1 -n 'if ! curl ' <<<"$blk" || true); lc="${lc%%:*}"
[[ -n "$lf" && -n "$lc" && $lf -lt $lc ]] && ok "shell fallback refuses a provider feed before any curl" || no "fallback FORMAT guard" "format=$lf curl=$lc"
en=$(awk '/^nftban_feeds_enable\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$FEEDS_SH")
grep -qF '"$core" feeds update "$feed_name"' <<<"$en" && ok "enabling a provider feed downloads through nftban-core" || no "enable provider path"
if grep -qxF '        search|export|suricata|geoban|install|uninstall|rebuild)' "$SBIN" && ! grep -qE '^ +search\|feeds\|' "$SBIN"; then
    ok "feeds is not in the dispatcher's two-line help stub"
else
    no "feeds still in the dispatcher help stub"
fi
help=$(NFTBAN_LIB_DIR=/nonexistent bash -c 'eval "$1"; eval "$2"; _nftban_feeds_help' _ "$fns" "$(awk '/^_nftban_feeds_help\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$CMD_FEEDS")" 2>&1)
[[ "$help" == *"nftban feeds abuseipdb <command>"* && "$help" == *"key set | status | remove"* && $(wc -l <<<"$help") -gt 40 ]] \
    && ok "feeds help is the full help and includes the abuseipdb commands" || no "feeds help content"

echo "=== one downloader; property reader = Go reader order (v1.238 feeds bugs) ==="
pr=$(awk '/^(_nftban_feeds_conf_value|nftban_feeds_get_property)\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$FEEDS_SH")
mkdir -p "$W/etc/conf.d"
printf '%s\n' 'FEED_X_ENABLED="false"' 'FEED_X_URL="https://a.invalid/x"   # comment' 'FEED_Y_ENABLED=true # unquoted' "FEED_Z_LIMIT='5'" > "$W/etc/conf.d/feeds.conf"
printf '%s\n' 'FEED_X_ENABLED="true"' > "$W/etc/conf.d/feeds.conf.local"
printf '%s\n' '# FEED_X_URL="https://commented.invalid"' > "$W/etc/nftban.conf.local"
prop(){ NFTBAN_FEEDS_CONFIG="$W/etc/conf.d/feeds.conf" NFTBAN_CONFIG_DIR="$W/etc" bash -c 'eval "$1"; nftban_feeds_get_property "$2" "$3"' _ "$pr" "$1" "$2"; }
[[ "$(prop X ENABLED)" == "true" ]] && ok "feeds.conf.local overrides feeds.conf (as the Go reader)" || no "feeds.conf.local ignored" "$(prop X ENABLED)"
[[ "$(prop X URL)" == "https://a.invalid/x" && "$(prop Y ENABLED)" == "true" && "$(prop Z LIMIT)" == "5" && -z "$(prop Q URL)" ]] \
    && ok "values read like the Go reader (quotes, trailing comment, commented line ignored, unknown empty)" || no "value parsing" "$(prop X URL)|$(prop Y ENABLED)|$(prop Z LIMIT)"
printf '%s\n' 'FEED_X_ENABLED="false"' > "$W/etc/nftban.conf.local"
[[ "$(prop X ENABLED)" == "false" ]] && ok "nftban.conf.local is applied last (highest)" || no "central override" "$(prop X ENABLED)"
us=$(awk '/^nftban_feeds_update_single\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$FEEDS_SH")
ld=$(grep -m1 -n '"$_core" feeds update "$feed_name"' <<<"$us" || true); ld="${ld%%:*}"
lc=$(grep -m1 -n 'if ! curl ' <<<"$us" || true); lc="${lc%%:*}"
[[ -n "$ld" && -n "$lc" && $ld -lt $lc ]] && ok "per-feed update hands off to nftban-core before any shell download" || no "update_single delegation" "core=$ld curl=$lc"
if grep -qF 'NFTBAN_FEEDS_CACHE_DIR}/${feed_name}.tmp' <<<"$us" || ! grep -qF 'mktemp -d' <<<"$us"; then
    no "fallback still downloads into the service account's cache dir"
else
    ok "fallback download goes to a private mktemp directory, never /var/cache/nftban/feeds"
fi
en2=$(awk '/^nftban_feeds_enable\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$FEEDS_SH")
grep -qF 'if [[ -n "$feed_format" || -x "$core" ]]; then' <<<"$en2" && ok "enable downloads every feed through nftban-core when installed" || no "enable delegation"

echo "=== per-feed last/next update lines (format the one reader) ==="
hl=$(awk '/^_nftban_feeds_refresh_(short|long)\(\) \{/ {f=1} f {print} f && /^\}/ {f=0}' "$CMD_FEEDS")
J='{"feeds":[{"feed":"abuseipdb","last_success_at":"2026-11-21T03:22:10Z","next_update_at":"2026-11-23T03:20:00Z","next_update_text":"2026-11-23 03:20 + up to 15 min (host time; daily feeds timer); earlier runs skip it until 2026-11-22 05:00 UTC (back-off or minimum interval)","next_permitted_retry":"2026-11-22T05:00:00Z","last_attempt":{"ok":false,"reason":"abuseipdb: rate_limited (HTTP 429)"}},{"feed":"spamhaus_drop","last_success_at":null,"next_update_at":"2026-11-22T03:20:00Z","next_update_text":"Sun 2026-11-22 03:27:41 UTC (daily feeds timer)"}]}'
short=$(bash -c 'eval "$1"; _nftban_feeds_refresh_short "$2" abuseipdb' _ "$hl" "$J")
[[ "$short" == "last 11-21 03:22 - next 11-23 03:20 UTC (deferred)" && ${#short} -le 52 ]] && ok "list line: last and next update, deferral marked, fits the box" || no "list line" "$short"
long=$(bash -c 'eval "$1"; _nftban_feeds_refresh_long "$2" abuseipdb' _ "$hl" "$J")
[[ "$long" == *"Last update: 2026-11-21 03:22 UTC (last attempt failed: abuseipdb: rate_limited (HTTP 429))"* && "$long" == *"Next update: 2026-11-23 03:20"*"earlier runs skip it"* ]] && ok "status lines: last update (with a failed attempt) and the next update with its reason" || no "status lines" "$long"
never=$(bash -c 'eval "$1"; _nftban_feeds_refresh_short "$2" spamhaus_drop' _ "$hl" "$J")
[[ "$never" == "last never - next 11-22 03:20 UTC" ]] && ok "never-updated feed shows 'never'" || no "never" "$never"
none=$(bash -c 'eval "$1"; _nftban_feeds_refresh_short "$2" nosuchfeed' _ "$hl" "$J")
[[ -z "$none" ]] && ok "unknown feed prints nothing" || no "unknown feed" "$none"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
