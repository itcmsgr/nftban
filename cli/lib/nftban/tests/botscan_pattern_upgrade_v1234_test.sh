#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.234.0 - BotScan shipped rules vs operator edits across package upgrades
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botscan_pattern_upgrade_v1234_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-01"
# meta:description="v1.234.0 upgrade contract for BotScan rules. Measured on the published v1.233.1 packages: RPM shipped /etc/nftban/patterns.d/botscan/*.patterns as %config(noreplace) (an edited file keeps the old, defective rules active after upgrade; new defaults land in .rpmnew) and DEB shipped them as NON-conffiles (edits and custom.patterns overwritten). Now shipped rules are payload under <lib>/data/botscan_*.patterns, /etc holds only operator files (override.local + own *.patterns), and pre-v1.234 edits are migrated once. Arms: P1 packaging (no /etc pattern file packaged or staged on either family; DEB conffiles cannot include patterns; custom.patterns is a seeded template; both families run the migration); P2 DEB preinst saves only locally edited legacy files (md5sum-proven) and custom.patterns, only on upgrade; P3 RPM leftovers (.rpmsave) and P4 DEB leftovers (.nftban-saved) migrate enable/disable decisions to override.local, keep operator records, restore custom.patterns, NEVER re-activate an edited old definition, report it, and are idempotent; P5 a stale legacy copy left in /etc cannot override shipped rules and stale package-manager files are reported (WARN + status); P6 patterns enable/disable/add never edit a shipped file. Set BSDC_SUBJECT_ROOT to an older tree (v1.233.1) to run the loader arms against it: they FAIL there."
#
# meta:inventory.files="botscan_pattern_upgrade_v1234_test.sh"
# meta:inventory.binaries="bash,sh,md5sum,awk,grep,sha256sum,mktemp"
# meta:inventory.env_vars="BSDC_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_pattern_upgrade_v1234_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan"
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
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SUBJECT_ROOT="${BSDC_SUBJECT_ROOT:-$REPO_ROOT}"
SUBJ_LIB="$SUBJECT_ROOT/cli/lib/nftban"
SHIP="$REPO_ROOT/cli/lib/nftban/data"          # the v1.234 shipped set (fixture source)
OLD_SHIP_EXPLOIT_LINE='EXP_WPREST|/wp-json/wp/v2/users|url-get|5|300|1800|true|WP user enumeration'

notexec() { echo "NOT_EXECUTED: $*" >&2; exit 2; }
[[ -r "$SUBJ_LIB/core/nftban_botscan.sh" ]] || notexec "subject module missing"
compgen -G "$SHIP/botscan_*.patterns" >/dev/null || notexec "v1.234 shipped rules missing under $SHIP"
echo "subject: $SUBJECT_ROOT"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0; ARMS=0; declare -a FAILED=()
ok()  { PASS=$(( PASS + 1 )); echo "PASS $1"; }
bad() { FAIL=$(( FAIL + 1 )); FAILED+=("$1"); echo "FAIL $1" >&2; }
arm() { ARMS=$(( ARMS + 1 )); echo "== $1"; }

# run_mod DIR 'commands' -> runs a fresh shell with the SUBJECT module, operator dir DIR,
# shipped dir = a copy of the v1.234 shipped set (ignored by an older subject).
run_mod() {
    local od="$1" body="$2"
    mkdir -p "$ROOT/ship" "$ROOT/data"
    compgen -G "$ROOT/ship/botscan_*.patterns" >/dev/null || cp "$SHIP"/botscan_*.patterns "$ROOT/ship/"
    bash -c '
        export LC_ALL=C NFTBAN_LIB_DIR="$1" BOTSCAN_PATTERNS_DIR="$2" BOTSCAN_SHIPPED_PATTERNS_DIR="$3" \
               NFTBAN_DATA_DIR="$4" NFTBAN_CONFIG_DIR="$5" BOTSCAN_CUSTOM_PATTERNS_TEMPLATE="$6"
        source "$1/core/nftban_botscan.sh" >/dev/null 2>&1
        set +e
        eval "$7"
    ' _ "$SUBJ_LIB" "$od" "$ROOT/ship" "$ROOT/data" "$ROOT/noetc" "$REPO_ROOT/etc/nftban/patterns.d/botscan/custom.patterns" "$body"
}
# def_of DIR NAME -> "<regex>|<type>" of the LOADED record for NAME ("absent" if not loaded)
def_of() {
    run_mod "$1" 'nftban_botscan_load_config; nftban_botscan_load_patterns 2>/dev/null; d="${_BOTSCAN_PATTERNS['"$2"']:-}"; if [[ -n "$d" ]]; then IFS=$'"'"'\x1f'"'"' read -r p t _ <<< "$d"; echo "$p|$t"; else echo absent; fi'
}

# =============================================================================
arm "P1 packaging: no /etc pattern file is packaged or staged; both families migrate"
SPEC="$REPO_ROOT/packaging/build_nftban.sh"
code="$(grep -vE '^[[:space:]]*#' "$SPEC")"
if grep -qE '%config.*patterns\.d' <<<"$code"; then bad "P1 RPM still declares a %config pattern file"; else ok "P1 RPM declares no %config pattern file"; fi
if grep -qE 'cp .*patterns\.d/botscan.*\*\.patterns .*(buildroot|deb_root)[^ ]*/etc/' <<<"$code"; then bad "P1 a build path still stages *.patterns under /etc"; else ok "P1 neither family stages *.patterns under /etc"; fi
if grep -qE '^/usr/lib/nftban/data/\*' <<<"$code"; then ok "P1 RPM ships /usr/lib/nftban/data/* (carries botscan_*.patterns)"; else bad "P1 RPM does not ship the data dir"; fi
n_tpl="$(grep -cE 'templates/patterns\.d/botscan/custom\.patterns' <<<"$code" || true)"
[[ "$n_tpl" -ge 3 ]] && ok "P1 custom.patterns ships as a template on both families ($n_tpl refs)" || bad "P1 custom.patterns template missing ($n_tpl refs)"
grep -q 'nftban_botscan_migrate_legacy_patterns' <<<"$code" && ok "P1 RPM %post runs the migration" || bad "P1 RPM %post does not run the migration"
grep -q 'nftban_botscan_migrate_legacy_patterns' "$REPO_ROOT/packaging/deb/postinst" && ok "P1 DEB postinst runs the migration" || bad "P1 DEB postinst does not run the migration"
# lab4 2026-10-03: on an rpm UPGRADE the post scriptlet runs before the old package's
# files are erased, so an edited custom.patterns became .rpmsave only AFTER the migration
# and was lost. The migration must also run in the posttrans section (after the erase).
posttrans_body="$(awk '/^%posttrans([[:space:]]|$)/ { inside = 1; next } inside && /^%[a-z]/ { inside = 0 } inside' <<<"$code")"
if [[ -n "$posttrans_body" ]] && grep -q 'nftban_botscan_migrate_legacy_patterns' <<<"$posttrans_body"; then
    ok "P1 RPM posttrans runs the migration (after rpm renames edited files to .rpmsave)"
else bad "P1 RPM posttrans does not run the migration: an upgrade loses an edited custom.patterns"; fi
# DEB conffiles generator: every `find ... -name` it uses selects only *.conf / *.yaml / *.yml
gen="$(awk '/v1.227 MAIL-F8: GENERATE the DEB conffiles/,/DEBIAN\/conffiles"/' "$SPEC")"
names="$(grep -oE "\-name '[^']+'" <<<"$gen" | grep -v '! -name' | sort -u | tr '\n' ' ')"
if [[ -n "$gen" ]] && ! grep -qE "patterns" <<<"$names" && grep -q "'\*\.conf'" <<<"$names"; then
    ok "P1 DEB conffiles generator cannot select a *.patterns file (selects: $names)"
else bad "P1 DEB conffiles generator not located or may select patterns: [$names]"; fi

# =============================================================================
arm "P2 DEB preinst saves only edited legacy files, only on upgrade"
pre="$REPO_ROOT/packaging/deb/preinst"
blk="$(awk '/== BEGIN v1.234 botscan legacy pattern save ==/,/== END v1.234 botscan legacy pattern save ==/' "$pre")"
[[ -n "$blk" ]] || bad "P2 preinst block markers not found"
printf '%s\n' "$blk" > "$ROOT/preinst_blk.sh"
if sh -n "$ROOT/preinst_blk.sh" 2>/dev/null; then ok "P2 preinst block parses as POSIX sh"; else bad "P2 preinst block does not parse"; fi
d2="$ROOT/deb_etc"; mkdir -p "$d2"
printf '%s\n' "$OLD_SHIP_EXPLOIT_LINE" > "$d2/exploit.patterns"                    # unmodified (md5 matches)
printf 'SCAN_ADMIN|^/admin|url-404|10|60|1800|false|edited\n' > "$d2/scanner.patterns"   # edited
printf 'MY_RULE|evil\\.php|url-404|3|60|3600|true|mine\n' > "$d2/custom.patterns"
md5="$ROOT/md5sums"
{ printf '%s  etc/nftban/patterns.d/botscan/exploit.patterns\n' "$(md5sum < "$d2/exploit.patterns" | awk '{print $1}')"
  printf '%s  etc/nftban/patterns.d/botscan/scanner.patterns\n' "0123456789abcdef0123456789abcdef"; } > "$md5"
NFTBAN_PREINST_PATTERNS_DIR="$d2" NFTBAN_PREINST_MD5SUMS="$md5" sh "$ROOT/preinst_blk.sh" install
[[ ! -e "$d2/scanner.patterns.nftban-saved" ]] && ok "P2 nothing saved on a fresh install" || bad "P2 preinst saved on install"
NFTBAN_PREINST_PATTERNS_DIR="$d2" NFTBAN_PREINST_MD5SUMS="$md5" sh "$ROOT/preinst_blk.sh" upgrade
[[ ! -e "$d2/exploit.patterns.nftban-saved" ]] && ok "P2 an unmodified legacy file (md5 match) is not saved" || bad "P2 unmodified file saved"
[[ -f "$d2/scanner.patterns.nftban-saved" ]] && ok "P2 a locally edited legacy file is saved" || bad "P2 edited file not saved"
[[ -f "$d2/custom.patterns.nftban-saved" ]] && ok "P2 custom.patterns (operator data) is saved" || bad "P2 custom.patterns not saved"

# =============================================================================
mk_legacy() { # DIR SUFFIX -> an edited legacy exploit file + custom.patterns with operator data
    local d="$1" sfx="$2"
    mkdir -p "$d"
    {   echo "# old shipped file, edited by the operator"
        echo 'EXP_WPREST|/wp-json/wp/v2/users|url-get|5|300|1800|false|WP user enumeration'     # disabled (state edit)
        echo 'EXP_ENVFILE|/\.env|url-any|20|60|7200|true|.env file exposure'                       # threshold edited (old def)
        echo 'MY_ADDED|/secret-probe|url-any|1|60|7200|true|operator added inside a shipped file'  # not a shipped name
    } > "$d/exploit.patterns${sfx}"
    printf 'MY_CUSTOM|evil\\.php|url-404|3|60|3600|true|mine\n' > "$d/custom.patterns${sfx}"
}
for fam in "P3 RPM:.rpmsave" "P4 DEB:.nftban-saved"; do
    tag="${fam%%:*}"; sfx="${fam#*:}"
    arm "$tag leftovers ($sfx) migrate once"
    od="$ROOT/etc_${sfx#.}"; mk_legacy "$od" "$sfx"
    out="$(run_mod "$od" 'declare -F nftban_botscan_migrate_legacy_patterns >/dev/null || { echo NOFUNC; exit 0; }; nftban_botscan_migrate_legacy_patterns' 2>&1 || true)"
    if [[ "$out" == *NOFUNC* ]]; then bad "$tag subject has no migration"; continue; fi
    grep -qx 'EXP_WPREST|false|migrated from exploit.patterns'"$sfx"' (v1.234)' "$od/override.local" 2>/dev/null \
        && ok "$tag the operator's disable decision is kept in override.local" || bad "$tag disable decision not migrated: $(cat "$od/override.local" 2>/dev/null)"
    grep -q '^MY_ADDED|' "$od/local-migrated.patterns" 2>/dev/null && ok "$tag an operator record inside a shipped file stays active (local-migrated.patterns)" || bad "$tag operator record lost"
    grep -q '^MY_CUSTOM|' "$od/custom.patterns" 2>/dev/null && ok "$tag custom.patterns restored" || bad "$tag custom.patterns not restored"
    [[ ! -e "$od/exploit.patterns${sfx}" && -f "$od/exploit.patterns${sfx}.migrated-v1234" ]] && ok "$tag the saved file is renamed .migrated-v1234 (kept, not loaded)" || bad "$tag saved file not renamed"
    grep -q 'NOT APPLIED EXP_ENVFILE' "$ROOT/data/botscan/pattern-migration.report" 2>/dev/null && ok "$tag an edited old definition is reported, NOT applied" || bad "$tag edited definition not reported"
    envdef="$(def_of "$od" EXP_ENVFILE)"; envship="$(grep '^EXP_ENVFILE|' "$SHIP/botscan_exploit.patterns" | cut -d'|' -f2,3)"
    [[ "$envdef" == "$envship" ]] && ok "$tag the loaded EXP_ENVFILE is the v1.234 definition" || bad "$tag loaded EXP_ENVFILE=[$envdef] want [$envship]"
    [[ "$(def_of "$od" EXP_WPREST)" == absent ]] && ok "$tag EXP_WPREST is disabled as the operator had it" || bad "$tag EXP_WPREST still active"
    p_ov="$(stat -c %a "$od/override.local" 2>/dev/null || echo none)"
    [[ "$p_ov" == 640 ]] && ok "$tag override.local is 0640" || bad "$tag override.local mode $p_ov"
    run_mod "$od" 'nftban_botscan_migrate_legacy_patterns' >/dev/null 2>&1 || true
    [[ "$(grep -c '^EXP_WPREST|' "$od/override.local")" -eq 1 && "$(grep -c '^MY_ADDED|' "$od/local-migrated.patterns")" -eq 1 ]] \
        && ok "$tag a second run changes nothing (idempotent)" || bad "$tag second run duplicated entries"
done

# =============================================================================
arm "P5 a stale legacy copy in /etc cannot override the shipped rules; stale files are visible"
od5="$ROOT/etc_stale"; mkdir -p "$od5"
printf '%s\n' "$OLD_SHIP_EXPLOIT_LINE" > "$od5/exploit.patterns"          # pre-v1.234 copy left behind
printf '%s\n' "$OLD_SHIP_EXPLOIT_LINE" > "$od5/exploit.patterns.rpmnew"
want="$(grep '^EXP_WPREST|' "$SHIP/botscan_exploit.patterns" | cut -d'|' -f2-3)"
got="$(def_of "$od5" EXP_WPREST)"
# extract the regex+type of the shipped record robustly (regex contains '|')
shipped_line="$(grep '^EXP_WPREST|' "$SHIP/botscan_exploit.patterns")"; r="${shipped_line#*|}"; r="${r%|*}"; r="${r%|*}"; r="${r%|*}"; r="${r%|*}"; r="${r%|*}"; t="${r##*|}"; r="${r%|*}"
[[ "$got" == "$r|$t" ]] && ok "P5 EXP_WPREST loads the shipped v1.234 definition, not the stale copy" || bad "P5 stale copy active: loaded [$got] (shipped [$r|$t])"
w="$(run_mod "$od5" 'nftban_botscan_load_config; nftban_botscan_load_patterns' 2>&1 || true)"
grep -q 'reuse shipped pattern names and are IGNORED' <<<"$w" && ok "P5 the stale copy is REPORTED (WARN)" || bad "P5 stale copy not reported"
grep -q 'stale pattern file(s).*NOT active' <<<"$w" && ok "P5 package-manager leftovers (.rpmnew) are REPORTED" || bad "P5 .rpmnew not reported"
st="$(run_mod "$od5" 'nftban_botscan_status' 2>&1 || true)"
grep -q '^Stale patterns: ' <<<"$st" && ok "P5 status lists stale pattern files" || bad "P5 status silent about stale files"
: "${want:=}"

# =============================================================================
arm "P6 patterns enable/disable/add never edit a shipped file"
od6="$ROOT/etc_cli"; mkdir -p "$od6"
run_mod "$od6" 'true' >/dev/null 2>&1 || true
before="$(sha256sum "$ROOT"/ship/botscan_*.patterns)"
out6="$(run_mod "$od6" 'nftban_botscan_load_config; nftban_botscan_toggle_pattern SCAN_ADMIN disable; nftban_botscan_add_pattern EXP_WPREST "x" url-any 1 60 60 dup; echo "add_rc=$?"; nftban_botscan_add_pattern MY_NEW "y\\.php" distinct-404 3 60 3600 mine; echo "add2_rc=$?"' 2>&1 || true)"
after="$(sha256sum "$ROOT"/ship/botscan_*.patterns)"
[[ "$before" == "$after" ]] && ok "P6 shipped files byte-identical after disable/add" || bad "P6 a shipped file was modified"
grep -qx 'SCAN_ADMIN|false' "$od6/override.local" 2>/dev/null && ok "P6 disable is recorded in override.local" || bad "P6 disable not in override.local"
grep -q 'add_rc=1' <<<"$out6" && ok "P6 adding a record under a shipped name is refused" || bad "P6 shipped-name add not refused: $out6"
grep -q '^MY_NEW|' "$od6/custom.patterns" 2>/dev/null && ok "P6 a new operator record goes to custom.patterns" || bad "P6 operator record not written"
[[ "$(def_of "$od6" SCAN_ADMIN)" == absent ]] && ok "P6 the disabled shipped rule is not loaded" || bad "P6 disabled rule still loaded"

# =============================================================================
arm "P7 fresh install and reinstall: vendor defaults separate, operator surface untouched"
od7="$ROOT/etc_fresh"; mkdir -p "$od7"
out7="$(run_mod "$od7" 'declare -F nftban_botscan_migrate_legacy_patterns >/dev/null || { echo NOFUNC; exit 0; }; nftban_botscan_migrate_legacy_patterns' 2>&1 || true)"
if [[ "$out7" == *NOFUNC* ]]; then bad "P7 subject has no install-time step"; else
    grep -q '^# NFTBan Bot Scanner - Custom User Patterns' "$od7/custom.patterns" 2>/dev/null && ok "P7 fresh install seeds custom.patterns from the template" || bad "P7 custom.patterns not seeded"
    [[ ! -e "$od7/override.local" && ! -e "$od7/local-migrated.patterns" ]] && ok "P7 fresh install creates no override.local and no migrated file" || bad "P7 fresh install created operator state"
    [[ -z "$out7" ]] && ok "P7 fresh install prints no migration summary" || bad "P7 unexpected migration output: $out7"
    n7="$(run_mod "$od7" 'nftban_botscan_load_config; nftban_botscan_load_patterns 2>/dev/null; echo ${#_BOTSCAN_PATTERNS[@]}' 2>/dev/null || echo 0)"
    s7="$(grep -h -c '|true|' "$ROOT"/ship/botscan_*.patterns | awk '{t+=$1} END {print t+0}')"
    [[ "$n7" -eq "$s7" && "$n7" -gt 0 ]] && ok "P7 the loader serves exactly the shipped enabled set ($n7)" || bad "P7 loaded $n7, shipped enabled $s7"
    # operator work after install, then a REINSTALL (same package, scripts run again)
    printf 'MY_X|/x-probe|url-any|1|60|60|true|mine\n' >> "$od7/custom.patterns"
    printf 'GPTBOT|false\n' > "$od7/override.local"
    sum_before="$(sha256sum "$od7/custom.patterns" "$od7/override.local")"
    run_mod "$od7" 'nftban_botscan_migrate_legacy_patterns' >/dev/null 2>&1 || true
    [[ "$(sha256sum "$od7/custom.patterns" "$od7/override.local")" == "$sum_before" ]] && ok "P7 reinstall leaves custom.patterns and override.local byte-identical" || bad "P7 reinstall changed operator files"
    [[ "$(def_of "$od7" GPTBOT)" == absent && "$(def_of "$od7" MY_X)" != absent ]] && ok "P7 operator decisions and records stay effective after reinstall" || bad "P7 operator state not effective after reinstall"
fi

# =============================================================================
arm "P8 runtime and packaging agree on where the shipped rules and edge ranges live"
# One location, stated by every reader: repo source -> packaged path -> runtime default.
LIBD="$REPO_ROOT/cli/lib/nftban/data"
n_src="$(compgen -G "$LIBD/botscan_*.patterns" | wc -l)"
[[ "$n_src" -eq 5 ]] && ok "P8 repo carries the 5 shipped rule files in cli/lib/nftban/data" || bad "P8 repo shipped rule files: $n_src (want 5)"
[[ -f "$LIBD/botscan_shared_edges.tsv" ]] && ok "P8 repo carries the shared-edge snapshot in cli/lib/nftban/data" || bad "P8 shared-edge snapshot missing"
compgen -G "$REPO_ROOT/etc/nftban/patterns.d/botscan/*.patterns" >/dev/null && \
    [[ "$(compgen -G "$REPO_ROOT/etc/nftban/patterns.d/botscan/*.patterns")" == "$REPO_ROOT/etc/nftban/patterns.d/botscan/custom.patterns" ]] \
    && ok "P8 etc/nftban/patterns.d/botscan holds only the custom.patterns template" || bad "P8 shipped rules still under etc/: $(compgen -G "$REPO_ROOT/etc/nftban/patterns.d/botscan/*.patterns" | tr '\n' ' ')"
# packaging: cli/lib/nftban/* -> /usr/lib/nftban on RPM and DEB; RPM lists data/*; Go installer stages data/*
grep -qE '^cp -r cli/lib/nftban/\* %\{buildroot\}/usr/lib/nftban/' "$SPEC" && grep -qE '^/usr/lib/nftban/data/\*' "$SPEC" \
    && ok "P8 RPM stages cli/lib/nftban/* to /usr/lib/nftban and owns /usr/lib/nftban/data/*" || bad "P8 RPM staging/ownership of data/ not found"
grep -qE 'cp -r "\$\{PROJECT_ROOT\}/cli/lib/nftban"/\* "\$\{deb_root\}/usr/lib/nftban/"' "$SPEC" && ok "P8 DEB stages cli/lib/nftban/* to /usr/lib/nftban" || bad "P8 DEB staging not found"
grep -qE 'srcRel: "cli/lib/nftban/data", srcGlob: "\*", dstGlob: "/usr/lib/nftban/data"' "$REPO_ROOT/internal/installer/payload/payload.go" \
    && ok "P8 Go installer stages cli/lib/nftban/data/* to /usr/lib/nftban/data" || bad "P8 Go installer data entry not found"
# runtime defaults (shell + Go) point at the packaged location
grep -qF 'printf '"'"'%s'"'"' "${BOTSCAN_SHIPPED_PATTERNS_DIR-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data}"' "$SUBJ_LIB/core/nftban_botscan.sh" \
    && grep -qF '"$sd"/botscan_*.patterns' "$SUBJ_LIB/core/nftban_botscan.sh" \
    && ok "P8 shell loader default = /usr/lib/nftban/data/botscan_*.patterns" || bad "P8 shell loader default differs"
grep -qF '${BOTSCAN_SHARED_EDGE_FILE-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data/botscan_shared_edges.tsv}' "$SUBJ_LIB/core/nftban_botscan.sh" \
    && grep -qF '"/usr/lib/nftban/data/botscan_shared_edges.tsv",' "$REPO_ROOT/internal/botguard/botscan_shared_edge.go" \
    && ok "P8 shell and daemon read the same shared-edge snapshot path" || bad "P8 shell/daemon shared-edge paths differ"
grep -qF 'filepath.Join("..", "..", "cli", "lib", "nftban", "data")' "$REPO_ROOT/internal/botscanmatch/matcher_test.go" \
    && grep -qF 'shippedPatternsGlob = "botscan_*.patterns"' "$REPO_ROOT/internal/botscanmatch/matcher_test.go" \
    && ok "P8 the Go matcher corpus test reads the shipped location" || bad "P8 Go matcher corpus test reads another location"
# the matcher binary itself never reads a fixed rule location (it gets the prefilter file as an argument)
if grep -qE 'patterns\.d|/usr/lib/nftban/data' "$REPO_ROOT/cmd/nftban-botscan-matcher/main.go" "$REPO_ROOT/internal/botscanmatch/matcher.go" "$REPO_ROOT/internal/botscanmatch/ahocorasick.go"; then
    bad "P8 the matcher runtime hard-codes a rule location"; else ok "P8 the matcher runtime has no hard-coded rule location (prefilter file is passed in)"; fi

# =============================================================================
arm "P9 retired EMPTY_UA cannot survive an upgrade (RPM, DEB, live legacy, operator copy)"
for shape in ".rpmsave" ".nftban-saved" ""; do
    od9="$ROOT/etc_retired${shape:-_live}"; mkdir -p "$od9"
    {   echo 'EMPTY_UA|-$|useragent|20|60|3600|true|Empty user agent'          # old shipped, enabled
        echo 'SINGLE_DASH|^-$|useragent|20|60|3600|true|Single dash user agent'
    } > "$od9/badbots.patterns${shape}"
    o9="$(run_mod "$od9" 'declare -F nftban_botscan_migrate_legacy_patterns >/dev/null || { echo NOFUNC; exit 0; }; nftban_botscan_migrate_legacy_patterns' 2>&1 || true)"
    tag="P9 ${shape:-live legacy file}"
    if [[ "$o9" == *NOFUNC* ]]; then bad "$tag subject has no migration"; continue; fi
    [[ "$(def_of "$od9" EMPTY_UA)" == absent ]] && ok "$tag: EMPTY_UA is not active after the upgrade" || bad "$tag: EMPTY_UA still active"
    grep -q '^EMPTY_UA|' "$od9/override.local" "$od9/local-migrated.patterns" 2>/dev/null && bad "$tag: EMPTY_UA carried into operator files" || ok "$tag: EMPTY_UA not carried into override.local or local-migrated.patterns"
done
grep -q 'retired EMPTY_UA: not migrated' "$ROOT/data/botscan/pattern-migration.report" 2>/dev/null && ok "P9 the report names the retired rule" || bad "P9 report does not name the retired rule"
# an operator copy that defines EMPTY_UA under its own file name is ignored and reported
od9c="$ROOT/etc_retired_copy"; mkdir -p "$od9c"
echo 'EMPTY_UA|-$|useragent|20|60|3600|true|operator copy' > "$od9c/mine.patterns"
[[ "$(def_of "$od9c" EMPTY_UA)" == absent ]] && ok "P9 an operator record named EMPTY_UA is not loaded" || bad "P9 operator EMPTY_UA record loaded"
w9="$(run_mod "$od9c" 'nftban_botscan_load_config; nftban_botscan_load_patterns' 2>&1 || true)"
grep -q 'RETIRED rule record(s) ignored: EMPTY_UA@mine.patterns' <<<"$w9" && ok "P9 the ignored retired record is reported" || bad "P9 retired record not reported"
o9a="$(run_mod "$od9c" 'nftban_botscan_add_pattern EMPTY_UA "-$" useragent 20 60 3600 x; echo "rc=$?"; nftban_botscan_toggle_pattern EMPTY_UA enable; echo "rc2=$?"' 2>&1 || true)"
grep -q 'rc=1' <<<"$o9a" && grep -q 'rc2=1' <<<"$o9a" && ok "P9 patterns add/enable refuse the retired name" || bad "P9 add/enable of retired name not refused: $o9a"

echo "----"
EXPECTED=9
echo "arms run: $ARMS/$EXPECTED  pass=$PASS fail=$FAIL"
[[ "$ARMS" -eq "$EXPECTED" ]] || { echo "INCOMPLETE: $ARMS of $EXPECTED arms ran" >&2; exit 1; }
if [[ "$FAIL" -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}" >&2; exit 1; fi
echo "PASS: botscan pattern upgrade contract (shipped payload vs operator surface, migration, visibility)"
