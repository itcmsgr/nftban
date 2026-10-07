#!/usr/bin/env bash
# =============================================================================
# NFTBan - status --json no-self-contradict test (v1.141 PR-C D-json-fork)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="cli_status_json_no_contradict_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-C D-json-fork — asserts that `nftban status --json` reports banned_ips equal to counts.kernel_total equal to counts.kernel_automatic + counts.kernel_manual, and that counts.authority is 'kernel'. The text-mode headline (cli_status_count_truth_test) uses kernel total; this JSON contract MUST agree so a JSON consumer and a human reading the same status snapshot never disagree on the number."
# meta:input="cli/lib/nftban/cli/cmd_status.sh output_json"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,jq"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh"
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_status_json_no_contradict_test"
# meta:ta.owner="cli"
# meta:ta.module="status"
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
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NO_BANNER=1
export NFTBAN_NONINTERACTIVE=1
# --- v1.235 host isolation (TEST-HARNESS-MUTATES-LIVE-HOST-STATE-WHEN-RUN-AS-ROOT) ---
# Run as root, this test wrote live host state (2026-10-07 overlay sweep). Every product
# root it can reach now defaults into the sandbox, EXPORTED so every child shell inherits it;
# arms that need their own value still override locally.
_HI="$(mktemp -d)"
trap 'rm -rf "$_HI"' EXIT
export NFTBAN_CONFIG_DIR="$_HI/etc" NFTBAN_DATA_DIR="$_HI/data" NFTBAN_LOG_DIR="$_HI/log" \
       NFTBAN_CACHE_DIR="$_HI/cache" NFTBAN_RUN_DIR="$_HI/run" NFTBAN_STATE_DIR="$_HI/data/state"
mkdir -p "$NFTBAN_CONFIG_DIR" "$NFTBAN_DATA_DIR/state" "$NFTBAN_LOG_DIR" "$NFTBAN_CACHE_DIR" "$NFTBAN_RUN_DIR"
# Host guard: the HOST config paths this test once wrote must be unchanged at the end
# (logs/state/cache are rewritten by a live product, so those are checked in the sandbox).
_hg_state(){ local p; for p in "$@"; do if [[ ! -e "$p" ]]; then echo "$p ABSENT"; elif [[ -r "$p" ]]; then echo "$p $(sha256sum < "$p" | cut -c1-16) $(stat -c %Y "$p")"; else echo "$p UNREADABLE $(stat -c %Y "$p" 2>/dev/null)"; fi; done; }
_HG_PATHS=("/etc/nftban/ports.d/00-ssh.conf")
_HG_BEFORE="$(_hg_state "${_HG_PATHS[@]}")"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Run output_json with stubbed counters. v4_auto=10, v4_manual=5, v6_auto=2, v6_manual=1
# → kernel_total = 18; the cache count (999) is intentionally different so we
# verify that banned_ips uses KERNEL even when cache disagrees.
JSON=$(bash -c "
    set +e
    export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
    export NFTBAN_NO_BANNER=1
    source '$NFTBAN_LIB_DIR/cli/cmd_status.sh' 2>/dev/null || true
    nftban_nft_count_set() {
        case \"\$1 \$3\" in
            'ip blacklist_ipv4')         echo 10 ;;
            'ip blacklist_manual_ipv4')  echo 5  ;;
            'ip6 blacklist_ipv6')        echo 2  ;;
            'ip6 blacklist_manual_ipv6') echo 1  ;;
            *) echo 0 ;;
        esac
    }
    nftban_stats_count_active_bans() { echo 999; }
    nftban_stats_get_unified()       { echo 999; }
    nftban_stats_count_whitelist()   { echo 0; }
    _nftban_count_rules()            { echo 50; }
    _nftban_protection_state()       { echo 'PROTECTED'; }
    _check_config_divergence()       { return 0; }
    _unit_is_active()                { return 0; }
    nftban_render_banner()           { :; }
    nftban_banner()                  { :; }
    output_json 2>/dev/null | head -120
" || true)

# Extract just the firewall block (the JSON below is multi-block but we can
# pluck the firewall sub-object cleanly because output_json builds it field-
# by-field). Easier path: take everything up to a known later marker, then
# close the JSON for jq.
# Instead we'll parse the whole envelope; output_json writes a complete JSON
# document so jq -e '.' should succeed.
if ! echo "$JSON" | jq -e '.' >/dev/null 2>&1; then
    # output_json may not close cleanly without the full pipeline; salvage by
    # closing at the firewall block.
    JSON_FW=$(echo "$JSON" | awk '/\"firewall\": \{/,/^    \},/' | sed 's/,$//')
    JSON='{"firewall":'"$(echo "$JSON_FW" | sed 's/^    \"firewall\": //; s/^    //')"'}'
fi

echo "=========================================================="
echo "v1.141 PR-C — status --json kernel-authority contract"
echo "=========================================================="

extract() {
    echo "$JSON" | jq -r "$1" 2>/dev/null || true
}

banned_ips=$(extract '.firewall.banned_ips // empty')
kernel_total=$(extract '.firewall.counts.kernel_total // empty')
kernel_automatic=$(extract '.firewall.counts.kernel_automatic // empty')
kernel_manual=$(extract '.firewall.counts.kernel_manual // empty')
authority=$(extract '.firewall.counts.authority // empty')
cache_count=$(extract '.firewall.counts.cache_count // empty')

# T1 — banned_ips equals kernel_total
if [[ "$banned_ips" == "18" ]] && [[ "$kernel_total" == "18" ]]; then
    ok "T1 banned_ips == counts.kernel_total == 18"
else
    no "T1 banned_ips ↔ kernel_total" "banned_ips=$banned_ips kernel_total=$kernel_total (expected 18)"
fi

# T2 — kernel_automatic + kernel_manual == kernel_total
if [[ "$kernel_automatic" == "12" ]] && [[ "$kernel_manual" == "6" ]]; then
    ok "T2 kernel_automatic(12) + kernel_manual(6) == kernel_total(18)"
else
    no "T2 split arithmetic" "automatic=$kernel_automatic manual=$kernel_manual (expected 12+6)"
fi

# T3 — authority field is 'kernel'
if [[ "$authority" == "kernel" ]]; then
    ok "T3 counts.authority == 'kernel'"
else
    no "T3 authority field" "got '$authority' (expected 'kernel')"
fi

# T4 — banned_ips DIFFERS from cache_count (cache=999, kernel=18) — proves the
# kernel-authority change actually took effect.
if [[ "$banned_ips" != "$cache_count" ]] && [[ "$banned_ips" == "18" ]] && [[ "$cache_count" == "999" ]]; then
    ok "T4 banned_ips uses kernel even when cache (999) disagrees"
else
    no "T4 kernel-over-cache" "banned_ips=$banned_ips cache_count=$cache_count (expected 18 vs 999)"
fi

# --- host isolation guard (TEST-HARNESS-MUTATES-LIVE-HOST-STATE-WHEN-RUN-AS-ROOT) ---
if [[ "$(_hg_state "${_HG_PATHS[@]}")" == "$_HG_BEFORE" ]]; then ok "HOST-GUARD host config paths unchanged (${_HG_PATHS[*]})"
else no "HOST-GUARD host config CHANGED by this test" "$(_hg_state "${_HG_PATHS[@]}" | tr '\n' ';')"; fi
if [[ -e "$_HI/data/state/ssh_port_active.state" ]]; then ok "HOST-GUARD ssh_port_active.state landed in the sandbox"
else no "HOST-GUARD ssh_port_active.state not in the sandbox" "redirection lost?"; fi
echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
