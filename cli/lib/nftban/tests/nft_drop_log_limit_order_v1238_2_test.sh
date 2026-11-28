#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2 L0: the final-drop log is rate limited (limiter BEFORE log)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nft_drop_log_limit_order_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="v1.238.2 L0 (owner 2026-11-28; BUG-FINAL-DROP-LOG-BEFORE-LIMIT-UNCAPPED). nft evaluates statements left to right: `counter … log prefix \"nftban: drop: \" limit rate 10/minute` logged EVERY dropped packet and only then evaluated the limit (fleet read-only check 9/9 hosts, ip + ip6; peaks 10,284 lines/min). Static, over every shipped ruleset file: each final-drop log rule is ordered [counter name total_input_drop] -> limit rate 10/minute -> log prefix (the counter stays FIRST so every matching packet is counted), no rule has log before limit, and the per-file instance counts are pinned (nftables.conf 2, nftables.conf.tpl 2, nftables-safe.conf 2, nftables-ipv4.conf.tmpl 1) so a file cannot silently leave the scope. Kernel behaviour (counts, burst, both families, recovery ruleset) is proven in the lab, not here."
# meta:input="install/nftables/*.conf, *.tpl, *.tmpl (repo, read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="install/nftables/nftables.conf,install/nftables/nftables.conf.tpl,install/nftables/nftables-safe.conf,install/nftables/nftables-ipv4.conf.tmpl"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nft_drop_log_limit_order_v1238_2_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-schema"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
D="$ROOT/install/nftables"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

declare -A want=( [nftables.conf]=2 [nftables.conf.tpl]=2 [nftables-safe.conf]=2 [nftables-ipv4.conf.tmpl]=1 )
PREFIX='log prefix "nftban: drop: "'

echo "=== every shipped ruleset file: final-drop log rules ==="
mapfile -t files < <(grep -l -F "$PREFIX" "$D"/*.conf "$D"/*.tpl "$D"/*.tmpl 2>/dev/null)
[[ ${#files[@]} -gt 0 ]] || no "no shipped ruleset file contains the final-drop log (subject not found)"
for f in "${files[@]}"; do
    b="${f##*/}"
    [[ -n "${want[$b]:-}" ]] || no "$b carries a final-drop log rule but is not in the pinned set" "add it to the review and to want[]"
done
for b in "${!want[@]}"; do
    f="$D/$b"
    [[ -r "$f" ]] || { no "$b missing"; continue; }
    n=0; bad=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        n=$((n+1))
        body="${line#"${line%%[![:space:]]*}"}"
        # The ONLY accepted shapes, statement by statement (left to right):
        #   counter name total_input_drop limit rate 10/minute log prefix "nftban: drop: "
        #   limit rate 10/minute log prefix "nftban: drop: "
        if [[ "$body" == 'counter name total_input_drop limit rate 10/minute log prefix "nftban: drop: "'* \
           || "$body" == 'limit rate 10/minute log prefix "nftban: drop: "'* ]]; then
            :
        else
            bad=$((bad+1)); no "$b: final-drop log rule out of order" "$body"
        fi
        [[ "$body" == *'log prefix "nftban: drop: "'*'limit rate'* ]] && { bad=$((bad+1)); no "$b: log BEFORE limit (uncapped)" "$body"; }
    done < <(grep -F "$PREFIX" "$f")
    [[ "$n" -eq "${want[$b]}" ]] && ok "$b: ${n} rule(s), as pinned" || no "$b: rule count" "found $n, pinned ${want[$b]}"
    [[ "$bad" -eq 0 && "$n" -gt 0 ]] && ok "$b: counter (if any) -> limit -> log, in every rule"
done

echo "=== the counter stays first where the rule counts ==="
c=$(grep -hF "$PREFIX" "$D/nftables.conf" "$D/nftables.conf.tpl" | grep -vcE '^[[:space:]]*counter name total_input_drop limit ')
[[ "$c" -eq 0 ]] && ok "every counted final-drop rule starts with counter name total_input_drop" || no "counted rule without the counter first" "$c line(s)"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
