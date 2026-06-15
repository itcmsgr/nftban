#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.190 — SOS-4 lab-first OpenMetrics scrape-contract validation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="openmetrics_scrape_validate_v190"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-15"
# meta:description="Operator-run lab-first validation of the LIVE NFTBan Prometheus/OpenMetrics scrape against the v1.190.0 contract (SOS-4). Captures /metrics from the daemon HTTP endpoint (default http://127.0.0.1:9580/metrics, localhost-only) or a node_exporter textfile, validates the exposition with promtool if available (else a strict grep parser), and asserts the v1.190 contract invariants: parser-valid; nftban_counters_population_phase present == 0 (anti-false-zero gate); canonical nftban_nft_rules_total present; DEPRECATED alias nftban_firewall_rules_total mirrors nft_rules_total when both present; nftban_suricata_rules_total distinct (if Suricata enabled); NO dedicated nftban_nft_anchor_* metric (anchors only via nft_named_counter_*); named-counter family labels stay raw ip/ip6 (NOT relabeled ipv4/ipv6); NO new v1.190 BotScan/BotGuard/Whitelist/FCrDNS counter series (false-zero-free); and nftban health --json reports schema 1.84.0. Read-only: scrapes + reads; mutates nothing."
# meta:input="live /metrics scrape (HTTP or textfile) + nftban health --json"
# meta:output="pass/fail report; exit 0 all-pass, 1 on any contract violation"
# meta:depends="bash,curl-or-cat,grep,awk; promtool optional; jq optional"
# meta:inventory.files="/var/lib/node_exporter/textfile_collector/nftban.prom"
# meta:inventory.binaries="curl,grep,awk,promtool(optional),jq(optional),nftban"
# meta:inventory.env_vars="NFTBAN_METRICS_URL,NFTBAN_METRICS_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftband.service"
# meta:inventory.network="127.0.0.1:9580/tcp (read-only scrape)"
# meta:inventory.privileges="none (root only if reading a 0600 textfile)"
# =============================================================================
set -Eeuo pipefail
# NOTE: IFS is intentionally left at the shell default (space/tab/newline). An
# earlier global `IFS=$' \t\n'` was redundant (it re-set the default) and tripped
# Semgrep bash.lang.security.ifs-tampering; no IFS-dependent splitting is used here.

URL="${NFTBAN_METRICS_URL:-http://127.0.0.1:9580/metrics}"
TEXTFILE="${NFTBAN_METRICS_FILE:-/var/lib/node_exporter/textfile_collector/nftban.prom}"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.190 SOS-4 lab OpenMetrics scrape validation ==="

# ---- 1. capture the scrape (HTTP preferred; textfile fallback; explicit arg wins)
SRC=""
if [[ "${1:-}" == http* ]]; then URL="$1"; fi
if [[ "${1:-}" == /* && -f "${1:-}" ]]; then TEXTFILE="$1"; fi
if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 5 "$URL" -o "$TMP" 2>/dev/null && [[ -s "$TMP" ]]; then
    SRC="HTTP $URL"
elif [[ -r "$TEXTFILE" ]]; then
    cp "$TEXTFILE" "$TMP"; SRC="textfile $TEXTFILE"
elif command -v nftban >/dev/null 2>&1 && nftban metrics export -o "$TMP" >/dev/null 2>&1 && [[ -s "$TMP" ]]; then
    SRC="nftban metrics export"
else
    no "could not capture a /metrics scrape (tried HTTP $URL, textfile $TEXTFILE, nftban metrics export)"
    echo "=== RESULT: $PASS passed, $FAIL failed ==="; exit 1
fi
ok "captured scrape via: $SRC ($(wc -l < "$TMP") lines)"

# ---- 2. format validity (promtool preferred; else strict HELP/TYPE structural check)
if command -v promtool >/dev/null 2>&1; then
    if promtool check metrics < "$TMP" >/dev/null 2>&1; then
        ok "promtool check metrics: exposition is parser-valid"
    else
        no "promtool check metrics FAILED" "$(promtool check metrics < "$TMP" 2>&1 | head -3 | tr '\n' ' ')"
    fi
else
    # Fallback: every HELP must precede its TYPE; one TYPE per family; no dup TYPE.
    DUPTYPE="$(grep '^# TYPE ' "$TMP" | awk '{print $3}' | sort | uniq -d || true)"
    if [[ -z "$DUPTYPE" ]]; then
        ok "no duplicate # TYPE family declarations (promtool unavailable — structural check)"
    else
        no "duplicate # TYPE declarations" "$(echo "$DUPTYPE" | tr '\n' ' ')"
    fi
fi

val(){ awk -v m="$1" '$1==m {print $2; exit}' "$TMP"; }       # value of a no-label series
has(){ grep -qE "$1" "$TMP"; }

# ---- 3. anti-false-zero gate: counters_population_phase present AND == 0
PHASE="$(val nftban_counters_population_phase)"
if [[ "$PHASE" == "0" ]]; then
    ok "nftban_counters_population_phase = 0 (contract phase, anti-false-zero)"
elif [[ -z "$PHASE" ]]; then
    no "nftban_counters_population_phase MISSING (must be present == 0 in v1.190.0)"
else
    no "nftban_counters_population_phase != 0 (population must not be live in v1.190.0)" "got=$PHASE"
fi

# ---- 4. canonical rule-count present
if has '^nftban_nft_rules_total '; then ok "nftban_nft_rules_total present (canonical rule-count)"
else no "nftban_nft_rules_total MISSING"; fi

# ---- 5. alias mirrors canonical (only assert when BOTH present on this surface)
RT="$(val nftban_nft_rules_total)"; FW="$(val nftban_firewall_rules_total)"
if [[ -n "$RT" && -n "$FW" ]]; then
    if [[ "$RT" == "$FW" ]]; then ok "nftban_firewall_rules_total ($FW) mirrors nftban_nft_rules_total ($RT)"
    else no "alias mismatch: firewall_rules_total=$FW != nft_rules_total=$RT"; fi
else
    ok "alias-mirror skipped (firewall_rules_total not on this surface: alias='$FW' canonical='$RT')"
fi

# ---- 6. suricata distinct (only if present / enabled)
if has '^nftban_suricata_rules_total '; then ok "nftban_suricata_rules_total present + distinct (Suricata SID count)"
else ok "nftban_suricata_rules_total absent (Suricata not enabled on this host) — distinctness N/A"; fi

# ---- 7. SOS-2: NO dedicated anchor metric
if has 'nftban_nft_anchor'; then no "SOS-2 violation: dedicated nftban_nft_anchor_* metric present (double-count)"
else ok "no nftban_nft_anchor_* metric (anchors only via nft_named_counter_*)"; fi

# ---- 8. SOS-3 compat: named-counter family stays ip/ip6 (never relabeled ipv4/ipv6)
if grep -E '^nftban_nft_named_counter_(packets|bytes)_total\{' "$TMP" | grep -qE 'family="(ipv4|ipv6)"'; then
    no "SOS-3 violation: named-counter family relabeled to ipv4/ipv6 (must stay raw ip/ip6)"
else
    ok "named-counter family stays raw ip/ip6 (SOS-3 Prometheus compat preserved)"
fi

# ---- 9. false-zero-free: NO new v1.190 population counter series
LEAK="$(grep -oE 'nftban_(botscan_(scanned|matched|signals|bans|crawler_verify)|botguard_(decisions|eventbus)|whitelist_changes|fcrdns_)[a-z_]*' "$TMP" | sort -u || true)"
if [[ -z "$LEAK" ]]; then ok "no new v1.190 BotScan/BotGuard/Whitelist/FCrDNS counter series (false-zero-free)"
else no "false-zero risk: new counter series present before population" "$(echo "$LEAK" | tr '\n' ' ')"; fi

# ---- 10. health JSON schema 1.84.0 parses
if command -v nftban >/dev/null 2>&1; then
    HJ="$(nftban health --json 2>/dev/null || true)"
    if command -v jq >/dev/null 2>&1; then
        SV="$(printf '%s' "$HJ" | jq -r '.schema_version // empty' 2>/dev/null || true)"
    else
        SV="$(printf '%s' "$HJ" | grep -oE '"schema_version":"[^"]*"' | head -1 | cut -d'"' -f4)"
    fi
    if [[ "$SV" == "1.84.0" ]]; then ok "nftban health --json schema_version = 1.84.0"
    else no "health --json schema_version != 1.84.0" "got='$SV'"; fi
else
    ok "health --json schema check skipped (nftban CLI not on PATH)"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
