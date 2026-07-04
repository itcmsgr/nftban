#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.214.0 - BotScan pattern-delimiter fix test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_pattern_delimiter_v214_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-02"
# meta:description="v1.214.0 OPEN_BOTSCAN_PATTERN_DELIMITER_FIX. BotScan .patterns records are NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION (8 fields, |-delimited), and the PATTERN field legally contains regex alternation |. The old naive IFS='|' read mis-split any |-bearing pattern (EXP_CGIBIN/EXP_SQLBACKUP/SCAN_BACKUP_SQL) → truncated regex → RE2 skipped it (dead). This proves: (A) the anchored _botscan_parse_record peels name from the front + 6 constrained trailing fields from the back so the |-bearing pattern (the middle) survives; (B) the internal _BOTSCAN_PATTERNS join/split uses ASCII Unit Separator \\x1f so the downstream re-splits (hot path :755, threshold :906, prefilter build :1004 that feeds the Go matcher) do NOT re-corrupt the |; (C) the 3 shipped |-patterns + an operator |-body pattern parse+match; (D) negatives do not overmatch; (E) the constrained-field validation guard emits a visible WARN and skips malformed/|-in-description/bad-field records; (F) the never-ban guards (loopback/private/exempt-list/WP-admin session) still gate; (G) active/skipped counts (real shipped copy → 140 enabled, 3 formerly-dead now intact); (H) CRLF + blank/comment lines."
#
# meta:inventory.files="botscan_pattern_delimiter_v214_test.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,BOTSCAN_PATTERNS_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
REPO_ROOT="$(cd "$NFTBAN_LIB_DIR/../../.." && pwd)"
SHIPPED_PATTERNS="$REPO_ROOT/etc/nftban/patterns.d/botscan"

fail() { echo "FAIL: $*" >&2; exit 1; }
US=$'\x1f'   # internal '|'-safe delimiter (must match _BS_US in the module)

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" \
       BOTSCAN_STATE_FILE="$tmp/s.db" BOTSCAN_LOG_FILE="$tmp/b.log" \
       NFTBAN_CONFIG_DIR="$tmp/noetc" BOTSCAN_ENABLED=true \
       BOTSCAN_EXEMPT_FILE="$tmp/exempt.list"
mkdir -p "$NFTBAN_DATA_DIR" "$BOTSCAN_PATTERNS_DIR"

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"; nftban_botscan_load_config

# The 3 shipped |-alternation patterns (verbatim; kept literal for parity).
CGIBIN_RE='/cgi-bin/.*\.(sh|pl|cgi)'
SQLBK_RE='\.(sql|sql\.gz|sql\.zip)$'
SCANSQL_RE='\.(sql|sql\.gz)$'

# ----------------------------------------------------------------------------
# Fixture: a controlled patterns dir (the 3 |-patterns + clean + malformed).
# ----------------------------------------------------------------------------
write_fixture() {
    : > "$BOTSCAN_PATTERNS_DIR/exploit.patterns"
    {
        echo "# Format: NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION"
        echo ""
        echo "EXP_CGIBIN|${CGIBIN_RE}|url-404|3|60|3600|true|CGI script probe"
        echo "EXP_SQLBACKUP|${SQLBK_RE}|url-404|3|60|3600|true|SQL backup probe"
        echo "WP_LOGIN|wp-login\\.php|url-404|3|60|3600|true|clean pattern no pipe"
        echo "UA_EVIL|evilbot|useragent|1|60|3600|true|UA pattern"
        echo "DISABLED_ONE|/x\\.php|url-any|3|60|3600|false|disabled record"
    } > "$BOTSCAN_PATTERNS_DIR/exploit.patterns"

    : > "$BOTSCAN_PATTERNS_DIR/scanner.patterns"
    {
        echo "SCAN_BACKUP_SQL|${SCANSQL_RE}|url-404|3|60|3600|true|SQL backup probe"
    } > "$BOTSCAN_PATTERNS_DIR/scanner.patterns"

    # Operator custom.patterns with a |-alternation body.
    : > "$BOTSCAN_PATTERNS_DIR/custom.patterns"
    {
        echo "# operator custom"
        echo "CUSTOM_ALT|/x/(a|b|c)\\.php|url-any|2|60|3600|true|custom alternation"
    } > "$BOTSCAN_PATTERNS_DIR/custom.patterns"
}
write_fixture

# ============================================================================
# (A) Anchored parse — the |-bearing pattern (middle) survives intact.
# ============================================================================
nftban_botscan_load_patterns 2>"$tmp/warn_load.txt"

assert_stored() {
    local key="$1" want_pat="$2" want_mt="$3" want_thr="$4" want_win="$5" want_ban="$6" want_desc="$7"
    local def="${_BOTSCAN_PATTERNS[$key]:-}"
    [[ -n "$def" ]] || fail "A: $key not loaded"
    local f_pat f_mt f_thr f_win f_ban f_desc
    IFS="$US" read -r f_pat f_mt f_thr f_win f_ban f_desc <<< "$def"
    [[ "$f_pat"  == "$want_pat"  ]] || fail "A: $key pattern re-split MANGLED: got [$f_pat] want [$want_pat]"
    [[ "$f_mt"   == "$want_mt"   ]] || fail "A: $key match_type: got [$f_mt] want [$want_mt]"
    [[ "$f_thr"  == "$want_thr"  ]] || fail "A: $key threshold: got [$f_thr] want [$want_thr]"
    [[ "$f_win"  == "$want_win"  ]] || fail "A: $key window: got [$f_win] want [$want_win]"
    [[ "$f_ban"  == "$want_ban"  ]] || fail "A: $key ban: got [$f_ban] want [$want_ban]"
    [[ "$f_desc" == "$want_desc" ]] || fail "A: $key description: got [$f_desc] want [$want_desc]"
    # The '|' must be preserved in the pattern (the whole point).
    [[ "$f_pat" == *"|"* ]] || fail "A: $key lost its '|' alternation"
}
assert_stored EXP_CGIBIN     "$CGIBIN_RE"  url-404 3 60 3600 "CGI script probe"
assert_stored EXP_SQLBACKUP  "$SQLBK_RE"   url-404 3 60 3600 "SQL backup probe"
assert_stored SCAN_BACKUP_SQL "$SCANSQL_RE" url-404 3 60 3600 "SQL backup probe"
assert_stored CUSTOM_ALT     '/x/(a|b|c)\.php' url-any 2 60 3600 "custom alternation"
[[ -z "${_BOTSCAN_PATTERNS[DISABLED_ONE]:-}" ]] || fail "A: disabled record must not be loaded"
echo "PASS A: anchored parse + \\x1f internal store — |-patterns intact end to end (store→re-split)"

# ============================================================================
# (B) Downstream re-split proof — hot path (:755) + threshold (:906) intact.
# ============================================================================
# Hot path: match_url_g re-splits _BOTSCAN_PATTERNS[def] on \x1f, then [[ =~ pattern ]].
for u in '/cgi-bin/x.sh' '/cgi-bin/x.pl' '/cgi-bin/x.cgi'; do
    nftban_botscan_match_url_g "$u" GET 404 "-" || fail "B: EXP_CGIBIN did not match $u (hot-path re-split broke the |)"
    [[ "$_BS_MATCHED" == "EXP_CGIBIN" ]] || fail "B: expected EXP_CGIBIN for $u got [$_BS_MATCHED]"
done
for u in '/db.sql' '/db.sql.gz' '/db.sql.zip'; do
    nftban_botscan_match_url_g "$u" GET 404 "-" || fail "B: EXP_SQLBACKUP did not match $u"
done
for u in '/db.sql' '/db.sql.gz'; do
    nftban_botscan_match_url_g "$u" GET 404 "-" || fail "B: SCAN_BACKUP_SQL/EXP_SQLBACKUP did not match $u"
done
nftban_botscan_match_url_g '/x/b.php' GET 200 "-" || fail "B: operator CUSTOM_ALT did not match /x/b.php"
[[ "$_BS_MATCHED" == "CUSTOM_ALT" ]] || fail "B: expected CUSTOM_ALT got [$_BS_MATCHED]"

# Threshold field (:906 idiom) reads correctly from the \x1f store.
_thr=""; _win=""; _ban=""
IFS="$US" read -r _ _ _thr _win _ban _ <<< "${_BOTSCAN_PATTERNS[EXP_CGIBIN]}"
[[ "$_thr" == "3" && "$_win" == "60" && "$_ban" == "3600" ]] \
    || fail "B: threshold re-split (:906 idiom) MANGLED thr=$_thr win=$_win ban=$_ban"
echo "PASS B: downstream re-splits (hot-path :755, threshold :906) preserve the |"

# ============================================================================
# (C) Prefilter build (:1004) → Go-matcher input is the INTACT regex.
# ============================================================================
pf="$tmp/prefilter.txt"
nftban_botscan_build_prefilter "$pf" || fail "C: build_prefilter returned non-zero"
grep -qF "$CGIBIN_RE" "$pf"                 || fail "C: prefilter missing intact EXP_CGIBIN regex"
grep -qF '\.(sql|sql\.gz|sql\.zip)' "$pf"   || fail "C: prefilter missing intact EXP_SQLBACKUP regex (anchors stripped)"
grep -qF '\.(sql|sql\.gz)' "$pf"            || fail "C: prefilter missing intact SCAN_BACKUP_SQL regex"
grep -qF '/x/(a|b|c)\.php' "$pf"            || fail "C: prefilter missing intact operator CUSTOM_ALT regex"
# Every emitted pattern line compiles as an ERE (RE2 would too → skipped=0, not 3).
# grep rc: 0=match, 1=no-match (both fine); 2=invalid regex (would be RE2-skipped).
while IFS= read -r _pfl; do
    [[ -z "$_pfl" ]] && continue
    _grc=0
    printf '\n' | grep -E -- "$_pfl" >/dev/null 2>&1 || _grc=$?
    [[ "$_grc" -le 1 ]] || fail "C: prefilter emitted a non-compiling regex: [$_pfl]"
done < "$pf"
echo "PASS C: prefilter build feeds the Go matcher the intact |-regex (skipped 3 -> 0 conceptually)"

# ============================================================================
# (D) Negative fixtures — no overmatch on legit paths.
# ============================================================================
neg_nomatch() {  # url method status  -> expect NO match
    local url="$1" m="$2" st="$3"
    if nftban_botscan_match_url_g "$url" "$m" "$st" "-"; then
        fail "D: OVERMATCH — $url ($m $st) matched [$_BS_MATCHED]"
    fi
}
neg_nomatch '/cgi-bin/legit.html' GET 404   # not .sh/.pl/.cgi
neg_nomatch '/report.sqlite'       GET 404   # $-anchor: not .sql/.sql.gz end
neg_nomatch '/notes.sql.txt'       GET 404   # .sql not at end
neg_nomatch '/docs/guide.html'     GET 404   # unrelated static doc, 404
neg_nomatch '/data.sql'            GET 200   # .sql but status 200 (url-404 gate)
echo "PASS D: negatives do not overmatch (regex bodies + status gate intact)"

# ============================================================================
# (E) Validation guard — visible WARN + skip on malformed / |-in-description.
# ============================================================================
guard_check() {  # record  reason-substring
    local rec="$1" why="$2"
    : > "$BOTSCAN_PATTERNS_DIR/badcase.patterns"
    printf '%s\n' "$rec" > "$BOTSCAN_PATTERNS_DIR/badcase.patterns"
    local warn="$tmp/warn_case.txt"; : > "$warn"
    nftban_botscan_load_patterns 2>"$warn"
    local name="${rec%%|*}"
    [[ -z "${_BOTSCAN_PATTERNS[$name]:-}" ]] || fail "E: malformed [$name] was STORED (should skip): $why"
    grep -q "malformed pattern record" "$warn" || fail "E: no visible WARN for [$name] ($why)"
    grep -q "$name" "$warn" || fail "E: WARN missing record name [$name]"
}
guard_check 'BADDESC|foo\.php|url-404|3|60|3600|true|desc with | pipe'  "| in description shifts trailing fields"
guard_check 'BADMT|foo\.php|url-bogus|3|60|3600|true|desc'             "unknown match_type"
guard_check 'BADTHR|foo\.php|url-404|x|60|3600|true|desc'             "non-integer threshold"
guard_check 'BADWIN|foo\.php|url-404|3|y|3600|true|desc'             "non-integer window"
guard_check 'BADBAN|foo\.php|url-404|3|60|z|true|desc'               "non-integer ban"
guard_check 'BADEN|foo\.php|url-404|3|60|3600|maybe|desc'            "non-boolean enabled"
guard_check 'BADEMPTY||url-404|3|60|3600|true|desc'                  "empty pattern"
guard_check 'TOOFEW|foo|url-404|3|60'                                "too few fields"
rm -f "$BOTSCAN_PATTERNS_DIR/badcase.patterns"
echo "PASS E: validation guard — WARN+skip on |-in-description / bad field / empty / too-few (never silent-corrupt)"

# ============================================================================
# (F) Never-ban invariants preserved with the re-enabled patterns.
# ============================================================================
write_fixture
nftban_botscan_load_patterns 2>/dev/null

# loopback (:672) — a re-enabled cgi-bin 404 from 127.0.0.1 must NOT be tracked.
nftban_botscan_init_state
nftban_botscan_process_entry "127.0.0.1" "/cgi-bin/x.sh" "GET" "404" "-"
[[ -z "${_BOTSCAN_IP_HITS[127.0.0.1]:-}" ]] || fail "F: loopback 127.0.0.1 was tracked (never-ban :672 broken)"

# private (:675-679)
nftban_botscan_init_state
nftban_botscan_process_entry "10.1.2.3" "/cgi-bin/x.sh" "GET" "404" "-"
[[ -z "${_BOTSCAN_IP_HITS[10.1.2.3]:-}" ]] || fail "F: private 10.x tracked (never-ban broken)"

# exempt-list (:681-690)
printf '%s\n' "203.0.113.20" > "$BOTSCAN_EXEMPT_FILE"
nftban_botscan_init_state
nftban_botscan_process_entry "203.0.113.20" "/cgi-bin/x.sh" "GET" "404" "-"
[[ -z "${_BOTSCAN_IP_HITS[203.0.113.20]:-}" ]] || fail "F: exempt-list IP tracked (never-ban :681 broken)"
: > "$BOTSCAN_EXEMPT_FILE"

# NON-exempt DOC IP IS tracked (re-enabled pattern is live end-to-end).
nftban_botscan_init_state
nftban_botscan_process_entry "203.0.113.10" "/cgi-bin/x.sh" "GET" "404" "-"
[[ "${_BOTSCAN_IP_HITS[203.0.113.10]:-0}" == "1" ]] || fail "F: DOC IP not tracked — re-enabled EXP_CGIBIN not live"
[[ "${_BOTSCAN_IP_PATTERNS[203.0.113.10]:-}" == *EXP_CGIBIN* ]] || fail "F: DOC IP hit not attributed to EXP_CGIBIN"

# WP-admin context marker (:816) — a proven login (POST login_path -> 302) is recorded.
nftban_botscan_init_state
nftban_botscan_process_entry "203.0.113.30" "/wp-login.php" "POST" "302" "-"
[[ "${_BOTSCAN_IP_ADMIN_SESSION[203.0.113.30]:-}" == "1" ]] || fail "F: WP-admin session gate (:816) not set"
echo "PASS F: never-ban guards (loopback/private/exempt/WP-admin) preserved; re-enabled pattern live for non-exempt"

# ============================================================================
# (G) Real shipped copy — active/skipped counts (140 enabled, 3 now intact).
# ============================================================================
if [[ -d "$SHIPPED_PATTERNS" ]]; then
    ship="$tmp/shipped"; mkdir -p "$ship"
    cp "$SHIPPED_PATTERNS"/*.patterns "$ship"/
    BOTSCAN_PATTERNS_DIR="$ship" nftban_botscan_load_patterns 2>"$tmp/warn_ship.txt"
    # No shipped record is malformed (the 3 |-patterns now parse cleanly).
    if grep -q "malformed pattern record" "$tmp/warn_ship.txt"; then
        fail "G: shipped patterns produced a malformed WARN: $(cat "$tmp/warn_ship.txt")"
    fi
    loaded="${#_BOTSCAN_PATTERNS[@]}"
    [[ "$loaded" == "140" ]] || fail "G: expected 140 enabled shipped patterns loaded, got $loaded"
    for k in EXP_CGIBIN EXP_SQLBACKUP SCAN_BACKUP_SQL; do
        [[ -n "${_BOTSCAN_PATTERNS[$k]:-}" ]] || fail "G: formerly-dead $k not loaded from shipped set"
        [[ "${_BOTSCAN_PATTERNS[$k]}" == *"|"* ]] || fail "G: shipped $k lost its | alternation"
    done
    echo "PASS G: shipped set → 140 enabled, 3 formerly-dead |-patterns now intact (skipped 0)"
    # restore fixture dir for any later use
    write_fixture
else
    echo "SKIP G: shipped patterns dir not found at $SHIPPED_PATTERNS (non-repo run)"
fi

# ============================================================================
# (H) CRLF + blank/comment handling.
# ============================================================================
: > "$BOTSCAN_PATTERNS_DIR/crlf.patterns"
printf 'CRLF_PAT|/y/(a|b)\\.php|url-any|2|60|3600|true|crlf record\r\n' > "$BOTSCAN_PATTERNS_DIR/crlf.patterns"
printf '\r\n' >> "$BOTSCAN_PATTERNS_DIR/crlf.patterns"
printf '   # a comment\r\n' >> "$BOTSCAN_PATTERNS_DIR/crlf.patterns"
nftban_botscan_load_patterns 2>"$tmp/warn_crlf.txt"
def="${_BOTSCAN_PATTERNS[CRLF_PAT]:-}"
[[ -n "$def" ]] || fail "H: CRLF record not loaded"
IFS="$US" read -r c_pat c_mt _ _ c_ban c_desc <<< "$def"
[[ "$c_pat" == '/y/(a|b)\.php' ]] || fail "H: CRLF pattern mangled: [$c_pat]"
[[ "$c_mt"  == 'url-any' ]] || fail "H: CRLF match_type mangled: [$c_mt]"
[[ "$c_ban" == '3600' ]] || fail "H: CRLF ban mangled (trailing \\r not stripped?): [$c_ban]"
[[ "$c_desc" == 'crlf record' ]] || fail "H: CRLF description mangled (trailing \\r not stripped?): [$c_desc]"
grep -q "malformed" "$tmp/warn_crlf.txt" && fail "H: CRLF/blank/comment produced a spurious WARN"
rm -f "$BOTSCAN_PATTERNS_DIR/crlf.patterns"
echo "PASS H: CRLF stripped; blank + comment lines ignored"

echo "PASS: botscan pattern-delimiter fix (v1.214.0) — parse + \\x1f internal rep + guard + never-ban"
