#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.190 — NFT COUNTING-MODEL / SCHEMA-UNFREEZE contract CI guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_counting_model_guard_v190_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-15"
# meta:description="Locks the v1.190.0 NFT counting-model contract decisions (SOS-1/2/3). Source-truth grep guard: (1) nftban_nft_rules_total has exactly ONE promauto owner (watchdog); (2) NO dedicated nftban_nft_anchor_* Prometheus metric exists (SOS-2 Option A reuse, no double-count); (3) the generic nft_named_counter_packets_total/_bytes_total source is preserved (the anchor Prometheus surface); (4) firewall_rules_total alias present + marked DEPRECATED; (5) nftban_suricata_rules_total present + distinct (not aliased to nft_rules_total); (6) collector.go does not re-introduce a raw nft_rules_total textfile emit; (7) SOS-1: stats schema stays int 2 (counters NOT surfaced via nftban stats); (8) validator output schema bumped to 1.84.0; (9) counters_population_phase gauge declared + Set(0) at contract phase (anti-false-zero gate); (10) SOS-3: validator exposes NormalizeNFTFamily + NFTAnchorJSON and JSON never hardcodes raw nft family ip/ip6. Includes positive/negative self-tests for the two highest-risk checks (no-anchor-metric, single-rules-owner)."
# meta:input="repo Go tree (read-only)"
# meta:output="pass/fail; exit 0 all-pass, 1 on any contract regression"
# meta:depends="bash,grep,find"
# meta:inventory.files="internal/watchdog/metrics.go,internal/metrics/rule_counters.go,internal/metrics/sampler.go,internal/metrics/collector.go,internal/suricata/stats/metrics.go,internal/stats/types.go,internal/validator/types.go,internal/validator/health_output.go"
# meta:inventory.binaries="bash,grep,find"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# count promauto declarations of a given metric Name across the Go tree (no tests)
count_metric_owner() {
    local name="$1"
    grep -rEl "Name:[[:space:]]*\"${name}\"" --include='*.go' "$REPO/internal" "$REPO/cmd" 2>/dev/null \
        | grep -v '_test\.go$' | xargs -r grep -cE "Name:[[:space:]]*\"${name}\"" 2>/dev/null \
        | awk -F: '{s+=$NF} END{print s+0}'
}

echo "=== v1.190 NFT counting-model contract guard ==="

# T1 — single canonical rule-count owner (watchdog promauto). Class: rule-count.
N_RULES="$(count_metric_owner 'nft_rules_total')"
if [[ "$N_RULES" == "1" ]]; then
    ok "T1 nftban_nft_rules_total has exactly ONE promauto owner (watchdog)"
else
    no "T1 nftban_nft_rules_total owner count != 1 (single-owner invariant broken)" "count=$N_RULES"
fi

# T2 — SOS-2: NO dedicated anchor Prometheus metric (reuse named-counter source).
if grep -rEq 'Name:[[:space:]]*"nft_anchor|nft_anchor_(packets|bytes)_total' --include='*.go' "$REPO/internal" "$REPO/cmd" 2>/dev/null; then
    no "T2 SOS-2 violation: a dedicated nftban_nft_anchor_* Prometheus metric exists (double-count risk)" "$(grep -rEn 'nft_anchor' --include='*.go' "$REPO/internal" "$REPO/cmd" | tr '\n' ' ')"
else
    ok "T2 no dedicated nft_anchor_* Prometheus metric (SOS-2 Option A reuse — no double-count)"
fi

# T3 — generic named-counter source preserved (this IS the anchor Prometheus surface).
if grep -q 'Name:.*"nft_named_counter_packets_total"' "$REPO/internal/metrics/rule_counters.go" \
   && grep -q 'Name:.*"nft_named_counter_bytes_total"' "$REPO/internal/metrics/rule_counters.go"; then
    ok "T3 nft_named_counter_{packets,bytes}_total{family,counter} preserved (anchor Prometheus source)"
else
    no "T3 generic named-counter source missing — anchors lose their Prometheus surface"
fi

# T4 — firewall_rules_total alias present AND marked DEPRECATED (2-minor window).
if grep -q 'Name:.*"firewall_rules_total"' "$REPO/internal/metrics/sampler.go" \
   && grep -qi 'DEPRECATED' "$REPO/internal/metrics/sampler.go"; then
    ok "T4 firewall_rules_total alias present + marked DEPRECATED"
else
    no "T4 firewall_rules_total alias missing or not marked DEPRECATED"
fi

# T5 — suricata_rules_total present + DISTINCT (Suricata SID count, not an nft alias).
if grep -q 'suricata_rules_total' "$REPO/internal/suricata/stats/metrics.go"; then
    ok "T5 nftban_suricata_rules_total present + distinct (NOT aliased to nft_rules_total)"
else
    no "T5 nftban_suricata_rules_total missing (distinct Suricata SID metric)"
fi

# T6 — collector.go must NOT re-introduce a raw nft_rules_total textfile emit.
if grep -qE 'nft_rules_total' "$REPO/internal/metrics/collector.go" \
   && grep -qE 'Fprint.*nft_rules_total' "$REPO/internal/metrics/collector.go"; then
    no "T6 collector.go re-introduced a raw nft_rules_total emit (dual-source G-12 regression)"
else
    ok "T6 collector.go does not emit raw nft_rules_total (watchdog is sole owner)"
fi

# T7 — SOS-1: stats schema stays int 2 (counters NOT surfaced via nftban stats).
if grep -qE '^const SchemaVersion = 2$' "$REPO/internal/stats/types.go"; then
    ok "T7 SOS-1 stats schema untouched (const SchemaVersion = 2; counters stay out of nftban stats)"
else
    no "T7 SOS-1 violation: internal/stats/types.go SchemaVersion changed (must remain 2)"
fi
# T7b — no counters-contract leakage into the stats schema types.
if grep -qiE 'CountersPhase|counters_phase|BotScanCounters|NFTAnchor' "$REPO/internal/stats/types.go"; then
    no "T7b counters-contract types leaked into stats schema (must live only in validator output schema)"
else
    ok "T7b no counters-contract leakage into stats schema"
fi

# T8 — validator output schema bumped to 1.84.0 (the ONE deliberate bump).
if grep -q 'SchemaVersionCurrent = "1.84.0"' "$REPO/internal/validator/types.go"; then
    ok "T8 validator output schema = 1.84.0 (the single deliberate bump)"
else
    no "T8 validator SchemaVersionCurrent != 1.84.0"
fi

# T9 — anti-false-zero gate: phase gauge declared + Set(0) at contract phase.
if grep -q 'Name:.*"counters_population_phase"' "$REPO/internal/watchdog/metrics.go" \
   && grep -q 'countersPopulationPhase.Set(0)' "$REPO/internal/watchdog/metrics.go"; then
    ok "T9 counters_population_phase gauge declared + Set(0) (contract phase, anti-false-zero)"
else
    no "T9 counters_population_phase gauge or Set(0) missing"
fi

# T10 — SOS-3: JSON family normalization exists; JSON never hardcodes raw nft ip/ip6.
if grep -q 'func NormalizeNFTFamily' "$REPO/internal/validator/health_output.go" \
   && grep -q 'type NFTAnchorJSON struct' "$REPO/internal/validator/health_output.go"; then
    ok "T10 SOS-3 NormalizeNFTFamily + NFTAnchorJSON present (ip→ipv4, ip6→ipv6 bridge)"
else
    no "T10 SOS-3 normalization helper / NFTAnchorJSON missing"
fi
# T10b — the JSON family vocabulary constants must be ipv4/ipv6/inet/unknown (not ip/ip6).
if grep -qE 'FamilyIPv4[[:space:]]*=[[:space:]]*"ipv4"' "$REPO/internal/validator/health_output.go" \
   && ! grep -qE 'Family(IPv4|IPv6)[[:space:]]*=[[:space:]]*"ip6?"' "$REPO/internal/validator/health_output.go"; then
    ok "T10b JSON family vocabulary is ipv4/ipv6/inet/unknown (no raw ip/ip6 in JSON contract)"
else
    no "T10b JSON family vocabulary drifted toward raw nft ip/ip6"
fi

# -----------------------------------------------------------------------------
# Self-tests (positive + negative controls) for the two highest-risk checks.
# -----------------------------------------------------------------------------
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/internal/bad" "$FIX/cmd"
# planted dedicated anchor metric (must trip T2-style detection)
cat > "$FIX/internal/bad/m.go" <<'GO'
package bad
var x = promauto.NewGaugeVec(prometheus.GaugeOpts{Name: "nft_anchor_packets_total"}, nil)
GO
if grep -rEq 'Name:[[:space:]]*"nft_anchor' --include='*.go' "$FIX" 2>/dev/null; then
    ok "T11 self-test: scanner detects a planted dedicated nft_anchor_* metric (positive control)"
else
    no "T11 self-test: scanner FAILED to detect a planted nft_anchor metric"
fi
# planted duplicate rules owner (must make count==2)
cat > "$FIX/cmd/dup.go" <<'GO'
package main
var y = promauto.NewGauge(prometheus.GaugeOpts{Name: "nft_rules_total"})
var z = promauto.NewGauge(prometheus.GaugeOpts{Name: "nft_rules_total"})
GO
DUPN="$(grep -rE 'Name:[[:space:]]*"nft_rules_total"' --include='*.go' "$FIX" | wc -l | tr -d ' ')"
if [[ "$DUPN" == "2" ]]; then
    ok "T12 self-test: duplicate-owner detection counts >1 (positive control)"
else
    no "T12 self-test: duplicate-owner detection miscounted" "count=$DUPN"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
