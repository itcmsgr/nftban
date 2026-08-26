#!/usr/bin/env bash
# =============================================================================
# NFTBan - textfile exposition must carry no client-side timestamps (v1.229.11)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="exporter_textfile_no_timestamps_v1229_11_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="metrics"
# meta:ta.id="exporter_textfile_no_timestamps_v1229_11_test"
# meta:ta.owner="metrics"
# meta:ta.module="exporter-textfile-correctness"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.229.11. The unified exporter appended a per-sample exposition timestamp (date +%s) to 216 metric lines. node_exporter's textfile collector REJECTS THE ENTIRE FILE when it contains client-side timestamps -- proven empirically on lab2 with prometheus-node-exporter 1.7.0: node_textfile_scrape_error 1, 'contains unsupported client-side timestamps, skipping entire file'; control without the suffix served the metric with scrape_error 0. So every nftban metric was silently discarded at the collector on any host using the optional Prometheus textfile surface. A second defect sat in the same construct: exposition timestamps are MILLISECONDS while date +%s is SECONDS, so they read as 1970 -- any freshness model would classify everything STALE forever. SCOPE: this is a correctness defect in the OPTIONAL Prometheus exporter. It is NOT a CMS PRO blocker -- the canonical PRO path is a lightweight NFTBan-owned direct push and does not consume this surface. Guards the source shape; a real node_exporter scrape assertion belongs to the package-native lane where the binary exists."
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh,cli/lib/nftban/exporters/nftban_unified_exporter_export.sh"
# meta:inventory.binaries="bash,grep"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="$SD/../exporters/nftban_unified_exporter_collect.sh"
E="$SD/../exporters/nftban_unified_exporter_export.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# MENTION != CODE — the explanatory comment quotes the defective line on purpose.
code(){ grep -vE '^[[:space:]]*#' "$1" || true; }

echo "=== textfile exposition carries no client-side timestamps (v1.229.11) ==="
echo ""

# --- P1 no metric append ends with an exposition timestamp --------------------
tot=0
for f in "$C" "$E"; do
    n=$(code "$f" | grep -cE 'metrics\+="[^"]*\$(timestamp|ts)\\n"' || true)
    n="${n//[^0-9]/}"; n="${n:-0}"; tot=$((tot+n))
    printf '  %-42s %s\n' "$(basename "$f")" "$([ "$n" -eq 0 ] && echo 'no timestamped appends' || echo "*** $n TIMESTAMPED APPENDS ***")"
done
[[ "$tot" -eq 0 ]] && ok "P1 zero exposition timestamps across the exporters" \
                   || no "P1 $tot metric appends still carry a timestamp — node_exporter would discard the WHOLE file"

# --- P2 the variable is RETAINED for calculations -----------------------------
# The fix must remove the exposition suffix, NOT the variable: $timestamp is used
# for uptime, rate deltas and state files. Deleting it would break those.
#   REMOVE THE MISUSE, NOT THE MECHANISM.
n=$(code "$C" | grep -c '\$timestamp' || true); n="${n//[^0-9]/}"; n="${n:-0}"
[[ "$n" -gt 0 ]] && ok "P2 \$timestamp retained for calculations ($n uses)" \
                 || no "P2 \$timestamp was deleted entirely — uptime/rate/state calculations lost"

# --- P3 the unit trap must not be 'fixed' by scaling --------------------------
# Exposition timestamps are MILLISECONDS; date +%s is SECONDS. Multiplying by
# 1000 would still leave the file rejected, so it is the wrong fix.
if code "$C" | grep -qE 'timestamp=\$\(\(.*1000\)\)|timestamp.*\* *1000'; then
    no "P3 timestamp scaled to milliseconds — the file stays REJECTED either way"
else
    ok "P3 no millisecond scaling introduced (removal is the fix, not conversion)"
fi

# --- N1 NEGATIVE CONTROL: the guard must detect the pre-fix shape -------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '        metrics+="nftban_daemon_up $status $timestamp\n"' > "$TMP/pre.sh"
if grep -qE 'metrics\+="[^"]*\$(timestamp|ts)\\n"' "$TMP/pre.sh"; then
    ok "N1 negative control: the guard detects the pre-fix append (P1 is meaningful)"
else
    no "N1 negative control failed — the guard cannot see the defect"
fi

# --- N2 a comment quoting the defect must not trip P1 -------------------------
printf '%s\n' '#     metrics+="nftban_daemon_up $status $timestamp\n"     <- what it used to do' > "$TMP/c.sh"
if code "$TMP/c.sh" | grep -qE 'metrics\+="[^"]*\$timestamp\\n"'; then
    no "N2 a COMMENT satisfied the check — MENTION != CODE not enforced"
else
    ok "N2 a commented example does not trip the guard (MENTION != CODE)"
fi

# --- P4 exposition-format sanity on a synthesised line ------------------------
# value-only lines are valid exposition; value+timestamp is what gets rejected.
line='nftban_daemon_up 1'
if grep -qE '^[a-zA-Z_][a-zA-Z0-9_]*(\{[^}]*\})?[[:space:]]+[-0-9.e+]+[[:space:]]*$' <<<"$line"; then
    ok "P4 value-only exposition shape is what the exporter now emits"
else
    no "P4 shape assertion is wrong — the test itself is broken"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "exporter textfile no-timestamps PASSED"
