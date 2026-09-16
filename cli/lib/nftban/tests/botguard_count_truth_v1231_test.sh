#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotGuard counts: "I could not look" must not become the number 0
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="botguard-count-truth-v1231-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="botguard_count_truth_v1231_test"
# meta:ta.owner="botguard"
# meta:ta.module="botguard-count-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.231.0 FU-5. count_unknown_propagation_v1231_test governs the blacklist/whitelist counters; the BotGuard counter family was ungoverned and laundered an unreadable nftables set into the integer 0 at six sites: the counting primitive _botguard_kernel_set_count (unreadable arm echoed 0), _nftban_botguard_status (twelve counters pre-seeded 0 and overwritten only on a successful existence probe, published with a constant source=\\\"kernel\\\" and a freshly stamped freshness_at so a reading that never happened shipped labelled as the freshest possible one), _nftban_botguard_stats (same pre-seed, plus a grep -c 'timeout' that also counted the set's own flags/timeout header lines), the cmd_status human row (only the IPv4 set was probed, so an absent http_bot_suspect6 reported 0v6), the cmd_status JSON row (NO existence probe at all on the MACHINE-READABLE surface), and the unified exporter (six '// 0' jq defaults plus unconditional metrics+= emission and \\\${bg_X:-0} in the JSON cache, where :- does not fire for the non-empty string UNKNOWN). This proves, with nft and the counts document stubbed, that each surface now keeps UNKNOWN distinguishable from 0 — machine-readable paths emit JSON null or WITHHOLD the Prometheus sample, human paths print UNKNOWN with a FIX hint — while a set that IS readable and empty still reports a legitimate 0 and a populated set still reports its real count. Every arm is paired with a NEGATIVE CONTROL synthesised by DECLARED INVERSION of the current code (never by reading origin/main, which inverts the moment this merges): the pre-fix shape is rebuilt inline and must reproduce the fabricated zero, otherwise the arm is decorative and the suite aborts with exit 2 rather than reporting a pass."
# meta:inventory.files="cli/lib/nftban/cli/cmd_botguard.sh,cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh,cli/lib/nftban/lib/nft_schema.sh"
# meta:inventory.binaries="bash,awk,jq"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== botguard_count_truth_v1231 ==="

BG="$ROOT/cli/lib/nftban/cli/cmd_botguard.sh"
ST="$ROOT/cli/lib/nftban/cli/cmd_status.sh"
EX="$ROOT/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
NS="$ROOT/cli/lib/nftban/lib/nft_schema.sh"
for f in "$BG" "$ST" "$EX" "$NS"; do
    [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "  FATAL: jq required for the JSON arms"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract one function body by name (brace-depth walk) so every arm runs the
# REAL shipped code rather than a paraphrase of it.
fn(){ awk -v f="$2" '$0 ~ "^[[:space:]]*"f"\\(\\)[[:space:]]*\\{"{d=1}
      d{print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if(depth<=0&&NR>1)exit}' "$1"; }

# Extract an INLINE block (the two cmd_status sites and the exporter site are
# not functions — they live inside multi-hundred-line report builders). Anchored
# on distinctive TEXT, never on line numbers, which drift under any edit.
blk(){ awk -v a="$2" -v b="$3" 'index($0,a){p=1} p{print} p&&index($0,b){exit}' "$1"; }

HELPERS="$(fn "$NS" nftban_count_is_known)
$(fn "$NS" nftban_count_sum)
$(fn "$NS" nftban_count_json)"

# ⛔ SUBJECT-EXECUTION GUARD. Every arm asserts on captured stdout, and a subject
#    that was never extracted also produces empty stdout. Without this, a harness
#    that silently failed to find its subject looks exactly like a subject that
#    printed nothing — and the whole file would pass while testing NOTHING.
#    This distinguishes NOT_EXECUTED (exit 2) from PASS and FAIL.
echo "--- 0. the harness can actually extract its subjects ---"
S1="$(fn "$BG" _botguard_kernel_set_count)"
S2="$(fn "$BG" _nftban_botguard_status)"
S3="$(fn "$BG" _nftban_botguard_stats)"
# S4 ends at the UNREADABLE arm; the block's own trailing `fi` is re-attached by
# the driver below (the range's natural `fi` terminators are nested).
S4="$(blk "$ST" 'local v4_suspects=UNKNOWN' 'botguard_status="ENABLED (suspect sets UNREADABLE')"
S5="$(blk "$ST" 'local json_bg_v4=' '\"botguard\": {\"enabled\":')"
S6EMIT="$(awk '/^        _emit_count\(\) \{/,/^        \}/' "$EX")"
S6="$(blk "$EX" '--- Botguard Metrics (LIVE' 'nftban_count_sum "$bg_suspect"')"

_missing=""
[[ -n "$S1" ]] || _missing="$_missing S1:_botguard_kernel_set_count"
[[ -n "$S2" ]] || _missing="$_missing S2:_nftban_botguard_status"
[[ -n "$S3" ]] || _missing="$_missing S3:_nftban_botguard_stats"
[[ -n "$S4" ]] || _missing="$_missing S4:cmd_status-human-botguard-row"
[[ -n "$S5" ]] || _missing="$_missing S5:cmd_status-json-botguard-row"
[[ -n "$S6EMIT" ]] || _missing="$_missing S6:_emit_count"
[[ -n "$S6" ]] || _missing="$_missing S6:exporter-botguard-block"
[[ -n "$(fn "$NS" nftban_count_json)" ]] || _missing="$_missing helper:nftban_count_json"
# The extracted S4/S5/S6 blocks must contain their DECISION, not just their head.
[[ "$S4" == *'ACTIVE ('* ]] || _missing="$_missing S4:decision-missing"
[[ "$S5" == *'nftban_count_json'* ]] || _missing="$_missing S5:render-missing"
[[ "$S6" == *'_emit_count'* ]] || _missing="$_missing S6:emission-missing"
if [[ -z "$_missing" ]]; then
    ok "all subjects extracted from source (no arm can pass by vacuity)"
else
    no "subject extraction FAILED — arms below would be vacuous" "$_missing"
    echo "  FATAL: refusing to report on subjects that never executed"; exit 2
fi

# nft stubs. The BotGuard CLI runs under `set -Eeuo pipefail`, so each harness
# arms errexit too: a three-valued count that aborts the caller under -e is not
# a fix, and only a REAL CHILD PROCESS keeps errexit armed inside the subject.
NFT_FAIL='return 1;'
NFT_EMPTY='printf "%s\n" "table ip nftban {" "  set x {" "    type ipv4_addr" "    flags timeout" "  }" "}"; return 0;'
NFT_TWO='printf "%s\n" "table ip nftban {" "  set x {" "    type ipv4_addr" "    flags timeout" "    elements = { 10.0.0.1 timeout 1h expires 59m," "                 10.0.0.2 timeout 1h expires 58m }" "  }" "}"; return 0;'

# build <nft-body> <extra-defs> <driver>  -> $WORK/h.sh
build(){
    {   echo 'set -Eeuo pipefail'
        echo "nft() { $1 }"
        echo 'systemctl() { return 1; }'
        printf '%s\n' "$HELPERS"
        printf '%s\n' "$2"
        printf '%s\n' "$3"
    } > "$WORK/h.sh"
}
# run the harness, capturing rc EXPLICITLY. A bare call under this file's own
# options must never decide the suite's fate.
run(){ RC=0; OUT="$(bash "$WORK/h.sh" 2>"$WORK/err")" || RC=$?; }

# -----------------------------------------------------------------------------
echo "--- 1. S1 the counting primitive separates 'could not read' from 'empty' ---"
# -----------------------------------------------------------------------------
build "$NFT_FAIL" "$S1" '_botguard_kernel_set_count "ip nftban" "http_bot_suspect"'
run
if [[ "$OUT" == "UNKNOWN" && "$RC" -eq 0 ]]; then
    ok "unreadable set -> UNKNOWN (rc=0, caller not aborted)"
else
    no "unreadable set did not report UNKNOWN" "out='$OUT' rc=$RC"
fi

build "$NFT_EMPTY" "$S1" '_botguard_kernel_set_count "ip nftban" "http_bot_suspect"'
run
if [[ "$OUT" == "0" && "$RC" -eq 0 ]]; then
    ok "readable but EMPTY set -> 0 (a legitimate known zero, not UNKNOWN)"
else
    no "an empty-but-readable set stopped reporting a legitimate 0" "out='$OUT' rc=$RC"
fi

build "$NFT_TWO" "$S1" '_botguard_kernel_set_count "ip nftban" "http_bot_suspect"'
run
if [[ "$OUT" == "2" && "$RC" -eq 0 ]]; then
    ok "populated set -> 2 (the HEALTHY path is numerically unchanged)"
else
    no "the healthy counting path regressed" "out='$OUT' rc=$RC"
fi

# NEGATIVE CONTROL — DECLARED INVERSION of the line above. Not read from
# origin/main: that ref inverts the moment this change merges, so it can never
# serve as an immutable pre-fix subject.
cat > "$WORK/nc1.sh" <<'NC1'
_prefix_kernel_set_count() {
    local table="$1" set_name="$2" output
    output=$(nft list set $table "$set_name" 2>/dev/null) || { echo "0"; return; }
    echo "readable"
}
NC1
build "$NFT_FAIL" "$(cat "$WORK/nc1.sh")" '_prefix_kernel_set_count "ip nftban" "http_bot_suspect"'
run
if [[ "$OUT" == "0" ]]; then
    ok "negative control: the PRE-FIX primitive DOES fabricate 0 (arm 1 discriminates)"
else
    no "negative control FAILED — the pre-fix shape did not reproduce the defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 2. S2 'nftban botguard status' — JSON nulls, and no fake authority ---"
# -----------------------------------------------------------------------------
S2DEFS="_botguard_config_get() { echo \"\${2:-}\"; }
_BOTGUARD_CONF=/dev/null
_BOTGUARD_CONF_LOCAL=/dev/null
$S1
$S2"

build "$NFT_FAIL" "$S2DEFS" '_nftban_botguard_status true'
run
printf '%s' "$OUT" > "$WORK/s2_bad.json"
if [[ "$RC" -ne 0 ]]; then
    no "status aborted under errexit on an unreadable kernel" "rc=$RC $(head -1 "$WORK/err")"
elif ! jq -e . "$WORK/s2_bad.json" >/dev/null 2>&1; then
    no "status emitted UNPARSEABLE JSON on the unreadable path" "$(head -c 200 "$WORK/s2_bad.json")"
else
    ok "unreadable kernel: status still emits VALID JSON (rc=0)"
    _nulls=$(jq '[.sets[][]] | map(select(. == null)) | length' "$WORK/s2_bad.json")
    _zeros=$(jq '[.sets[][]] | map(select(. == 0)) | length' "$WORK/s2_bad.json")
    if [[ "$_nulls" == "12" && "$_zeros" == "0" ]]; then
        ok "all 12 set counts are null; ZERO of them were fabricated as 0"
    else
        no "the JSON surface published a number nobody measured" "nulls=$_nulls zeros=$_zeros"
    fi
    if [[ "$(jq -r '.source' "$WORK/s2_bad.json")" == "unavailable" ]]; then
        ok "source='unavailable' — the reading is no longer labelled 'kernel'"
    else
        no "an unperformed reading still claims a source" "source=$(jq -c '.source' "$WORK/s2_bad.json")"
    fi
    if [[ "$(jq -r '.freshness_at' "$WORK/s2_bad.json")" == "null" ]]; then
        ok "freshness_at=null — no authority timestamp on an unmeasured value"
    else
        no "an unmeasured value acquired a fresh authority timestamp" \
           "freshness_at=$(jq -c '.freshness_at' "$WORK/s2_bad.json")"
    fi
fi

build "$NFT_TWO" "$S2DEFS" '_nftban_botguard_status true'
run
printf '%s' "$OUT" > "$WORK/s2_ok.json"
if jq -e . "$WORK/s2_ok.json" >/dev/null 2>&1 \
   && [[ "$(jq -r '.sets.suspect.v4' "$WORK/s2_ok.json")" == "2" ]] \
   && [[ "$(jq -r '.source' "$WORK/s2_ok.json")" == "kernel" ]] \
   && [[ "$(jq -r '.freshness_at' "$WORK/s2_ok.json")" =~ ^[0-9]{4}- ]]; then
    ok "readable kernel UNCHANGED: counts numeric, source=kernel, freshness stamped"
else
    no "the healthy status path regressed" "$(head -c 200 "$WORK/s2_ok.json")"
fi

build "$NFT_FAIL" "$S2DEFS" '_nftban_botguard_status false'
run
if [[ "$OUT" == *"UNKNOWN"* ]] && [[ "$OUT" == *"FIX: systemctl restart nftband"* ]]; then
    ok "human renderer says UNKNOWN and offers the FIX hint"
else
    no "the human renderer did not name the unknown" "$(printf '%s' "$OUT" | head -c 200)"
fi
if [[ "$OUT" == *"source: unavailable"* ]]; then
    ok "human header reports source: unavailable (not 'kernel')"
else
    no "the human header still asserts a kernel reading" "$(printf '%s' "$OUT" | grep -F 'Kernel Sets' || true)"
fi

# -----------------------------------------------------------------------------
echo "--- 3. S3 'nftban botguard stats' ---"
# -----------------------------------------------------------------------------
S3DEFS="$S1
$S3"
build "$NFT_FAIL" "$S3DEFS" '_nftban_botguard_stats true'
run
printf '%s' "$OUT" > "$WORK/s3_bad.json"
if [[ "$RC" -eq 0 ]] && jq -e . "$WORK/s3_bad.json" >/dev/null 2>&1; then
    _nulls=$(jq '[.sets[][]] | map(select(. == null)) | length' "$WORK/s3_bad.json")
    _zeros=$(jq '[.sets[][]] | map(select(. == 0)) | length' "$WORK/s3_bad.json")
    if [[ "$_nulls" == "12" && "$_zeros" == "0" ]]; then
        ok "stats JSON: 12 nulls, 0 fabricated zeros"
    else
        no "stats JSON fabricated a count" "nulls=$_nulls zeros=$_zeros"
    fi
else
    no "stats aborted or emitted unparseable JSON on the unreadable path" \
       "rc=$RC $(head -c 160 "$WORK/s3_bad.json")"
fi

build "$NFT_TWO" "$S3DEFS" '_nftban_botguard_stats true'
run
printf '%s' "$OUT" > "$WORK/s3_ok.json"
if [[ "$(jq -r '.sets.suspect.v4' "$WORK/s3_ok.json" 2>/dev/null)" == "2" ]]; then
    ok "stats JSON healthy path: suspect.v4=2 (elements only, not header lines)"
else
    no "the healthy stats path regressed" "$(head -c 160 "$WORK/s3_ok.json")"
fi

# -----------------------------------------------------------------------------
echo "--- 4. S4 'nftban status' human row probes BOTH families ---"
# -----------------------------------------------------------------------------
# The extracted range stops on the UNREADABLE arm; re-attach the `fi` and wrap in
# a function because the block legitimately uses `local`.
S4DEFS="_s4() {
$S4
fi
printf '%s\n' \"\$botguard_status\"
}"
build "$NFT_FAIL" "$S4DEFS" 'botguard_status=DISABLED; _s4'
run
if [[ "$OUT" == *"UNREADABLE"* ]] && [[ "$OUT" != *"0v4"* ]] && [[ "$OUT" != *"0v6"* ]]; then
    ok "both families unreadable -> UNREADABLE, no fabricated 0v4/0v6"
else
    no "the human row fabricated a suspect count" "out='$OUT' rc=$RC"
fi

# v4 readable and empty, v6 unreadable: the v6 read must NOT inherit v4's success.
NFT_V4ONLY='if [[ "$*" == *ip6* ]]; then return 1; fi; '"$NFT_EMPTY"
build "$NFT_V4ONLY" "$S4DEFS" 'botguard_status=DISABLED; _s4'
run
if [[ "$OUT" == *"0v4"* && "$OUT" == *"UNKNOWNv6"* ]]; then
    ok "v4 readable+empty -> 0v4; v6 unreadable -> UNKNOWNv6 (families independent)"
else
    no "an unread IPv6 set was reported as a measured 0" "out='$OUT'"
fi

# NEGATIVE CONTROL — DECLARED INVERSION: the pre-fix shape gated the v6 read on
# the v4 probe and pre-seeded both to 0.
cat > "$WORK/nc4.sh" <<'NC4'
_prefix_s4() {
    local botguard_status="DISABLED"
    if nft list set ip nftban http_bot_suspect &>/dev/null 2>&1; then
        local v4_suspects=0 v6_suspects=0
        botguard_status="ACTIVE (${v4_suspects}v4+${v6_suspects}v6 suspects)"
    else
        botguard_status="ENABLED (sets not loaded)"
    fi
    printf '%s\n' "$botguard_status"
}
NC4
build "$NFT_V4ONLY" "$(cat "$WORK/nc4.sh")" '_prefix_s4'
run
if [[ "$OUT" == *"0v6"* ]]; then
    ok "negative control: the PRE-FIX row DOES report 0v6 for an unread set"
else
    no "negative control FAILED — pre-fix shape did not reproduce the v6 defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 5. S5 'nftban status --json' preserves unknown as null ---"
# -----------------------------------------------------------------------------
S5DEFS="_s5() {
$S5
}"
build "$NFT_FAIL" "$S5DEFS" 'NFTBAN_CONFIG_DIR=/nonexistent; json_botguard_enabled=true; _s5'
run
# The site emits one object member with a trailing comma; wrap it to parse.
printf '{%s"_end":1}' "$OUT" > "$WORK/s5_bad.json"
if [[ "$RC" -eq 0 ]] && jq -e . "$WORK/s5_bad.json" >/dev/null 2>&1; then
    if [[ "$(jq -r '.botguard.ipv4_suspects' "$WORK/s5_bad.json")" == "null" ]] \
    && [[ "$(jq -r '.botguard.ipv6_suspects' "$WORK/s5_bad.json")" == "null" ]]; then
        ok "machine-readable surface: both suspect counts null, neither 0"
    else
        no "the JSON surface published a zero nobody measured" "$OUT"
    fi
else
    no "the JSON row aborted or emitted unparseable output" "rc=$RC out='$OUT'"
fi

build "$NFT_TWO" "$S5DEFS" 'NFTBAN_CONFIG_DIR=/nonexistent; json_botguard_enabled=true; _s5'
run
printf '{%s"_end":1}' "$OUT" > "$WORK/s5_ok.json"
if [[ "$(jq -r '.botguard.ipv4_suspects' "$WORK/s5_ok.json" 2>/dev/null)" == "2" ]]; then
    ok "readable kernel still renders the real number (2)"
else
    no "the healthy JSON path regressed" "out='$OUT'"
fi

build "$NFT_EMPTY" "$S5DEFS" 'NFTBAN_CONFIG_DIR=/nonexistent; json_botguard_enabled=true; _s5'
run
printf '{%s"_end":1}' "$OUT" > "$WORK/s5_empty.json"
if [[ "$(jq -r '.botguard.ipv4_suspects' "$WORK/s5_empty.json" 2>/dev/null)" == "0" ]]; then
    ok "readable-but-empty set still renders a legitimate 0 (not over-converted)"
else
    no "a legitimate zero was converted into UNKNOWN" "out='$OUT'"
fi

# NEGATIVE CONTROL — DECLARED INVERSION: no existence probe, pre-seeded 0.
cat > "$WORK/nc5.sh" <<'NC5'
_prefix_s5() {
    local json_bg_v4=0 json_bg_v6=0
    local _o4 _o6
    _o4=$(nft list set ip nftban http_bot_suspect 2>/dev/null)
    _o6=$(nft list set ip6 nftban http_bot_suspect6 2>/dev/null)
    if echo "$_o4" | grep -q 'elements = {'; then json_bg_v4=1; fi
    if echo "$_o6" | grep -q 'elements = {'; then json_bg_v6=1; fi
    echo "    \"botguard\": {\"ipv4_suspects\": $json_bg_v4, \"ipv6_suspects\": $json_bg_v6},"
}
NC5
build "$NFT_FAIL" "$(cat "$WORK/nc5.sh")" 'set +e; _prefix_s5'
run
if [[ "$OUT" == *'"ipv4_suspects": 0'* ]]; then
    ok "negative control: the PRE-FIX JSON row DOES publish a fabricated 0"
else
    no "negative control FAILED — pre-fix shape did not reproduce the JSON defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 6. S6 the exporter WITHHOLDS botguard samples it could not measure ---"
# -----------------------------------------------------------------------------
# An absent series is a state Prometheus and Zabbix both model and alert on; a 0
# asserts a measurement. This matches the established blacklist/whitelist
# precedent already governed by count_unknown_propagation_v1231_test.
S6DEFS="_s6() {
$S6EMIT
$S6
}"
_metrics_of(){ # $1 = counts_json ; sets OUT to the rendered metric block
    build "$NFT_FAIL" "$S6DEFS" \
        "metrics=''; counts_json='$1'; _s6; printf %b \"\$metrics\""
    run
}

_metrics_of ''
if [[ "$RC" -eq 0 && "$OUT" != *nftban_botguard_set_count* && "$OUT" != *nftban_botguard_total_tracked* ]]; then
    ok "no counts document -> NO botguard samples at all (rc=0)"
else
    no "the exporter published botguard samples with nothing to measure" "rc=$RC out='$OUT'"
fi

_metrics_of '{"sets":{}}'
if [[ "$RC" -eq 0 && "$OUT" != *nftban_botguard_set_count* ]]; then
    ok "daemon-cache shape present but botguard fields absent -> samples withheld"
else
    no "missing botguard fields were published as measurements" "rc=$RC out='$OUT'"
fi

_metrics_of '{"sets":{"http_bot_suspect":{"count":3},"http_bot_suspect6":{"count":4},"http_bot_pending":{"count":1},"http_bot_pending6":{"count":0}}}'
if [[ "$OUT" == *'nftban_botguard_set_count{category="suspect"} 7'* ]] \
&& [[ "$OUT" == *'nftban_botguard_set_count{category="pending"} 1'* ]]; then
    ok "established counts still publish normally (suspect=7, pending=1)"
else
    no "the healthy exporter path regressed" "out='$OUT'"
fi
if [[ "$OUT" != *nftban_botguard_total_tracked* ]] && [[ "$OUT" != *'category="allow"'* ]]; then
    ok "UNKNOWN is ABSORBING: the partial total is withheld, not published short"
else
    no "a total was published that silently omits unreadable components" "out='$OUT'"
fi

_metrics_of '{"botguard":{"suspect":{"ipv4":3,"ipv6":2},"pending":{"ipv4":1,"ipv6":0},"allow":{"ipv4":0,"ipv6":0},"grey":{"ipv4":0,"ipv6":0},"ban":{"ipv4":12,"ipv6":3},"emergency":{"ipv4":0,"ipv6":0}}}'
if [[ "$OUT" == *'nftban_botguard_set_count{category="suspect"} 5'* ]] \
&& [[ "$OUT" == *'nftban_botguard_total_tracked 21'* ]]; then
    ok "legacy-kernel shape: suspect=5 and a COMPLETE total publishes (21)"
else
    no "the legacy-kernel exporter path regressed" "out='$OUT'"
fi

# NEGATIVE CONTROL — DECLARED INVERSION: 0-init plus unconditional emission.
cat > "$WORK/nc6.sh" <<'NC6'
_prefix_s6() {
    local bg_suspect=0 bg_pending=0
    if [[ -n "${counts_json:-}" ]] && command -v jq &>/dev/null; then
        if echo "$counts_json" | jq -e '.sets' &>/dev/null; then
            bg_suspect=$(echo "$counts_json" | jq -r '((.sets.http_bot_suspect.count // 0) + (.sets.http_bot_suspect6.count // 0))')
        fi
    fi
    metrics+="nftban_botguard_set_count{category=\"suspect\"} $bg_suspect\n"
}
NC6
build "$NFT_FAIL" "$(cat "$WORK/nc6.sh")" \
    "metrics=''; counts_json='{\"sets\":{}}'; _prefix_s6; printf %b \"\$metrics\""
run
if [[ "$OUT" == *'nftban_botguard_set_count{category="suspect"} 0'* ]]; then
    ok "negative control: the PRE-FIX exporter DOES publish a fabricated 0 sample"
else
    no "negative control FAILED — pre-fix shape did not reproduce the exporter defect" "out='$OUT'"
    echo "  FATAL: an arm that cannot fail proves nothing"; exit 2
fi

# -----------------------------------------------------------------------------
echo "--- 7. the exporter's JSON cache keeps the document PARSEABLE ---"
# -----------------------------------------------------------------------------
# `${x:-0}` substitutes only when x is unset or EMPTY, so it does NOT fire for
# the non-empty string UNKNOWN: the bare word would reach the cache document and
# make the WHOLE file unparseable, after which every downstream `// 0` would
# manufacture the same zero by a longer route.
_n=$(grep -cE '\$\{(bg_[a-z]+|elements_total):-0\}' "$EX") || _n=0
if [[ "$_n" -eq 0 ]]; then
    ok "no '\${x:-0}' laundering over a three-valued count in the cache heredoc"
else
    no "a ':-0' default over a three-valued count survives in the cache heredoc" "$_n occurrence(s)"
fi
_n=$(grep -cE '\$\(\([^)]*\bbg_[a-z]+' "$EX") || _n=0
if [[ "$_n" -eq 0 ]]; then
    ok "no raw \$(( )) arithmetic over a botguard count"
else
    no "raw arithmetic over a botguard count was reintroduced" "$_n occurrence(s)"
fi

echo
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
