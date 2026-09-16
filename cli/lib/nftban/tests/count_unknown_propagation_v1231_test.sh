#!/usr/bin/env bash
# =============================================================================
# NFTBan - "could not read" must survive every hop to the operator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="count-unknown-propagation-v1231-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="count_unknown_propagation_v1231_test"
# meta:ta.owner="metrics"
# meta:ta.module="nft-counting-model"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="P1S-C shell half (v1.231.0). perset_predicate_v1229_13_test locks the counting PRIMITIVES to emit UNKNOWN when the kernel cannot be read; nothing governed the CONSUMER layer above them, which converted UNKNOWN straight back into a number. Bash arithmetic resolves a bare identifier as a variable name, so the string UNKNOWN is looked up as \$UNKNOWN: MEASURED on bash 5.3.9, \$((UNKNOWN+UNKNOWN))=0 (silent false zero), \$((1510+UNKNOWN))=1510 (silent undercount), and under set -u it aborts the caller with 'unbound variable'. Which of the three you get depends on the CALLER's shell options, not on the kernel. This proves, with nft stubbed to fail, that the aggregate counters (nftban_nft_count_blacklist/_whitelist), the stats consumers (nftban_stats_count_active_bans/_whitelist and both breakdown emitters) and the unified exporter all keep UNKNOWN distinguishable from 0 — the exporter by WITHHOLDING the sample, which Prometheus and Zabbix both model as no-data and alert on, rather than publishing a zero nobody measured. Also proves nftban_nft_count_all_sets emits PARSEABLE JSON in the unreadable arm (it previously interpolated the bare word UNKNOWN, making the whole document unparseable so every downstream '// 0' manufactured the same zero by a longer route) and that the readable arm is numerically UNCHANGED. Includes a structural guard against reintroducing raw \$(( )) arithmetic or ':-0'/'// 0' defaults over a count capture in the governed files, and a negative control that fails if the guard cannot see its own motivating defect."
# meta:inventory.files="cli/lib/nftban/lib/nft_schema.sh,cli/lib/nftban/core/nftban_stats_collect.sh,cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:inventory.binaries="bash,awk,jq"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== count_unknown_propagation_v1231 ==="

NS="$ROOT/cli/lib/nftban/lib/nft_schema.sh"
SC="$ROOT/cli/lib/nftban/core/nftban_stats_collect.sh"
EX="$ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
SP="$ROOT/cli/lib/nftban/lib/shell_predicates.sh"
for f in "$NS" "$SC" "$EX" "$SP"; do
    [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "  FATAL: jq required for the JSON arms"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract one function body by name (brace-depth walk), so the harness runs the
# REAL shipped code rather than a paraphrase of it.
fn(){ awk -v f="$2" '$0 ~ "^[[:space:]]*"f"\\(\\)[[:space:]]*\\{"{d=1}
      d{print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if(depth<=0&&NR>1)exit}' "$1"; }

HELPERS='nftban_count_is_known nftban_count_sum nftban_count_json'

# ⛔ SUBJECT-EXECUTION GUARD. Every arm below asserts on captured stdout, and an
#    undefined function also produces empty stdout. Without this, a harness that
#    failed to extract the subject would look exactly like a subject that
#    printed nothing, and the whole file would pass while testing nothing.
echo "--- 0. the harness can actually extract its subjects ---"
# ⛔ v1.231.0: no `| grep -q` under pipefail here. grep -q exits on the FIRST MATCH, the
#    producer takes SIGPIPE, pipefail reports 141 — a SUCCESSFUL match read as failure.
#    In THIS arm that would report a PRESENT helper as missing — and this is the vacuity
#    guard, so an inverted result claims the suite is vacuous when it is not. Presence is
#    now tested with a command substitution: no pipeline exists, so nothing can be EPIPE'd.
_missing=""
for _f in $HELPERS nftban_nft_count_set nftban_nft_count_blacklist \
          nftban_nft_count_whitelist nftban_nft_count_all_sets; do
    [[ -n "$(fn "$NS" "$_f")" ]] || _missing="$_missing $_f"
done
for _f in nftban_stats_count_active_bans nftban_stats_count_whitelist \
          nftban_stats_get_whitelist_breakdown; do
    [[ -n "$(fn "$SC" "$_f")" ]] || _missing="$_missing $_f"
done
if [[ -z "$_missing" ]]; then
    ok "all subjects extracted from source (no arm can pass by vacuity)"
else
    no "subject extraction FAILED — arms below would be vacuous" "$_missing"
    echo "  FATAL: refusing to report on subjects that never executed"; exit 2
fi

# Build a harness with nft stubbed. $1 = nft body, $2 = extra defs, $3 = driver.
build(){
    {   echo 'set -uo pipefail'
        echo "nft() { $1 }"
        cat "$SP"
        for _h in $HELPERS; do fn "$NS" "$_h"; done
        printf '%s\n' "$2"
        printf '%s\n' "$3"
    } > "$WORK/h.sh"
}
NFT_FAIL='return 1;'
NFT_OK='printf %s "{\"nftables\":[{\"set\":{\"elem\":[\"10.0.0.1\",\"10.0.0.2\"]}}]}"; return 0;'

# -----------------------------------------------------------------------------
echo "--- 1. aggregate counters absorb UNKNOWN instead of summing it away ---"
# -----------------------------------------------------------------------------
AGG="$(fn "$NS" nftban_nft_count_set)
$(fn "$NS" nftban_nft_count_blacklist)
$(fn "$NS" nftban_nft_count_whitelist)"

for pair in "nftban_nft_count_blacklist:blacklist" "nftban_nft_count_whitelist:whitelist"; do
    f="${pair%%:*}"; lbl="${pair##*:}"
    build "$NFT_FAIL" "$AGG" "$f"
    out="$(bash "$WORK/h.sh" 2>/dev/null)"
    if [[ "$out" == *UNKNOWN* ]]; then
        ok "$lbl aggregate: unreadable kernel -> '$out'"
    else
        no "$lbl aggregate fabricated a count from an unreadable kernel" "got '$out'"
    fi
    # Non-regression: a readable kernel must still produce the real numbers.
    build "$NFT_OK" "$AGG" "$f"
    out="$(bash "$WORK/h.sh" 2>/dev/null)"
    if [[ "$out" =~ ^[0-9]+\ [0-9]+\ [0-9]+$ ]]; then
        ok "$lbl aggregate: readable kernel -> '$out' (still numeric)"
    else
        no "$lbl aggregate broke the HEALTHY path" "got '$out'"
    fi
done

# -----------------------------------------------------------------------------
echo "--- 2. nftban_nft_count_all_sets stays PARSEABLE when unreadable ---"
# -----------------------------------------------------------------------------
ALL="$(fn "$NS" nftban_nft_count_set)
$(fn "$NS" nftban_nft_count_all_sets)"

build "$NFT_FAIL" "$ALL" 'nftban_nft_count_all_sets'
bash "$WORK/h.sh" > "$WORK/j_bad" 2>/dev/null
if jq -e . "$WORK/j_bad" >/dev/null 2>&1; then
    ok "unreadable arm emits VALID JSON"
    if [[ "$(jq -r '.blacklist.total' "$WORK/j_bad")" == "null" ]] \
    && [[ "$(jq -r '.totals.blocked_total' "$WORK/j_bad")" == "null" ]]; then
        ok "unreadable arm reports null, not 0, for blacklist.total and totals.blocked_total"
    else
        no "unreadable arm published a NUMBER for a count nobody established" \
           "blacklist.total=$(jq -c '.blacklist.total' "$WORK/j_bad")"
    fi
else
    no "unreadable arm emits UNPARSEABLE JSON (bare UNKNOWN interpolated)" \
       "$(jq . "$WORK/j_bad" 2>&1 | head -1)"
fi

build "$NFT_OK" "$ALL" 'nftban_nft_count_all_sets'
bash "$WORK/h.sh" > "$WORK/j_ok" 2>/dev/null
if jq -e . "$WORK/j_ok" >/dev/null 2>&1 \
   && [[ "$(jq -r '.blacklist.total' "$WORK/j_ok")" == "4" ]] \
   && [[ "$(jq -r '.totals.blocked_total' "$WORK/j_ok")" == "8" ]]; then
    ok "readable arm UNCHANGED (blacklist.total=4, blocked_total=8)"
else
    no "readable arm regressed" "total=$(jq -c '.blacklist.total' "$WORK/j_ok" 2>&1)"
fi

# -----------------------------------------------------------------------------
echo "--- 3. stats consumers do not re-manufacture the zero ---"
# -----------------------------------------------------------------------------
STATS="$(fn "$NS" nftban_nft_count_set)
$(fn "$NS" nftban_nft_count_blacklist)
$(fn "$NS" nftban_nft_count_whitelist)
nftban_stats_get_unified() { return 1; }   # force the kernel fallback path
$(fn "$SC" nftban_stats_count_active_bans)
$(fn "$SC" nftban_stats_count_whitelist)
$(fn "$SC" nftban_stats_get_whitelist_breakdown)"

for f in nftban_stats_count_active_bans nftban_stats_count_whitelist; do
    build "$NFT_FAIL" "$STATS" "$f"
    out="$(bash "$WORK/h.sh" 2>/dev/null)"
    if [[ "$out" == "UNKNOWN" ]]; then
        ok "$f: unreadable kernel -> UNKNOWN"
    else
        no "$f reported a measurement that was never taken" "got '$out'"
    fi
    build "$NFT_OK" "$STATS" "$f"
    out="$(bash "$WORK/h.sh" 2>/dev/null)"
    [[ "$out" =~ ^[0-9]+$ ]] \
        && ok "$f: readable kernel -> $out (still numeric)" \
        || no "$f broke the HEALTHY path" "got '$out'"
done

build "$NFT_FAIL" "$STATS" 'nftban_stats_get_whitelist_breakdown'
bash "$WORK/h.sh" > "$WORK/wb" 2>/dev/null
if jq -e . "$WORK/wb" >/dev/null 2>&1 && [[ "$(jq -r '.total' "$WORK/wb")" == "null" ]]; then
    ok "whitelist breakdown: valid JSON, total=null (not 0)"
else
    no "whitelist breakdown published a zero or unparseable document" "$(cat "$WORK/wb")"
fi

# -----------------------------------------------------------------------------
echo "--- 4. the exporter WITHHOLDS a sample it could not measure ---"
# -----------------------------------------------------------------------------
# _emit_count is the exporter's publication decision. An absent series is a
# state Prometheus and Zabbix both model; a 0 asserts a measurement.
EMIT="$(awk '/^        _emit_count\(\) \{/,/^        \}/' "$EX")"
if [[ -z "$EMIT" ]]; then
    no "could not extract _emit_count from the exporter — publication gate missing?"
else
    build "$NFT_FAIL" "metrics=''
$EMIT" '_emit_count "nftban_active_count" "UNKNOWN"; _emit_count "nftban_blocks_total" "77"; printf %b "$metrics"'
    out="$(bash "$WORK/h.sh" 2>/dev/null)"
    if [[ "$out" != *nftban_active_count* ]]; then
        ok "UNKNOWN count emits NO sample (absent series, not a fabricated 0)"
    else
        no "UNKNOWN count was published as a metric sample" "got '$out'"
    fi
    if [[ "$out" == *"nftban_blocks_total 77"* ]]; then
        ok "established count still publishes normally (77)"
    else
        no "the publication gate swallowed a REAL measurement" "got '$out'"
    fi
fi

# -----------------------------------------------------------------------------
echo "--- 5. structural guard: no raw arithmetic / zero-defaults over a count ---"
# -----------------------------------------------------------------------------
# NEGATIVE CONTROL FIRST: the guard must be able to SEE its motivating defect.
# A guard that cannot fail on the original code proves nothing about the fix.
cat > "$WORK/defect.sh" <<'DEFECT'
v4_interval=$(nftban_nft_count_set ip nftban blacklist_ipv4)
v4_count=$((v4_interval + v4_manual))
DEFECT
_scan(){ # $1=file -> prints offending lines
    grep -nE '\$\(\([^)]*\b(v4_interval|v4_manual|v6_interval|v6_manual|active_v4|active_v6|whitelist_v4|whitelist_v6)\b' "$1" \
      | grep -vE 'nftban_count_(sum|is_known|json)' || true
}
if [[ -n "$(_scan "$WORK/defect.sh")" ]]; then
    ok "negative control: guard DOES detect the v1.230.0 defect form"
else
    no "negative control FAILED — the guard cannot see its own motivating defect"
    echo "  FATAL: an undetecting guard must not be reported as a pass"; exit 2
fi

# The real subjects. Lines already gated by an explicit nftban_count_is_known
# test are legitimate and are excluded by line number below.
for f in "$NS" "$SC" "$EX"; do
    b="$(basename "$f")"; hits=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        ln="${line%%:*}"
        # allow if a nftban_count_is_known guard appears within 3 lines above
        if sed -n "$((ln>3 ? ln-3 : 1)),${ln}p" "$f" | grep -F 'nftban_count_is_known' >/dev/null; then
            continue
        fi
        hits="$hits$line"$'\n'
    done < <(_scan "$f")
    if [[ -z "$hits" ]]; then
        ok "$b: no ungated arithmetic over a count capture"
    else
        no "$b: raw arithmetic over a count capture reintroduced" "$(echo "$hits" | head -3 | tr '\n' ' ')"
    fi
done

# `// 0` on the count fields of the unified document turns a deliberate null
# straight back into a measurement.
if grep -nE '\.(blacklist|whitelist)\.(ipv4|ipv6|total)[^|]*// 0' "$EX" "$SC" >/dev/null 2>&1; then
    no "a '// 0' default was reintroduced over a nullable count field" \
       "$(grep -nE '\.(blacklist|whitelist)\.(ipv4|ipv6|total)[^|]*// 0' "$EX" "$SC" | head -2 | tr '\n' ' ')"
else
    ok "no '// 0' default over a nullable count field"
fi

# The arithmetic rationale must stay next to the helper it explains.
if grep -q 'silent false zero' "$NS" && grep -q 'silent UNDERCOUNT' "$NS"; then
    ok "nft_schema.sh still records the measured bash-arithmetic failure modes"
else
    no "the measured rationale for nftban_count_sum was removed from nft_schema.sh"
fi

echo
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
