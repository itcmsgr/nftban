#!/usr/bin/env bash
# =============================================================================
# NFTBan - CLI router exit-truth test (v1.228.1 PR-1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_router_exit_truth_v1228_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-28"
# meta:description="v1.228.1 PR-1 negative test for the governing CLI invariant: a command that cannot perform its requested work must never return exit 0. Before v1.228.1 the autoloader in cli/sbin/nftban sourced ANY cli/cmd_<token>.sh named by an unvalidated argv token, discarded the status of that source, probed for nftban_cmd_<token>, and on failure returned 0 with no output. Two situations collapsed onto that one line: (1) the file exists but exposes no entrypoint - eight such library files ship; (2) the file exists but aborted mid-load so the entrypoint was never defined - this is why 'nftban suricata status' exited 0 with empty stdout after printing a module-not-found error. The dispatcher could not be fixed by set -Eeuo pipefail because 'main \"\$@\" || exit \$?' suspends errexit for the whole call tree. This test locks the repaired contract STRUCTURALLY: T-A4 uses a synthetic entrypoint-less fixture module in a temporary NFTBAN_LIB_DIR to prove the rejection is not a hardcoded list of the eight known filenames, and T-A6 uses a fixture that returns non-zero at its top level to prove the source status is honoured. T-A3 pins every alias token so the rejection cannot become over-broad, and T-A5 pins support-bundle, the alias whose module entrypoint is not named after its token. Hermetic - runs against the source tree with a symlinked temporary NFTBAN_LIB_DIR, no daemon/nft/systemctl contact, no root."
# meta:input="cli/sbin/nftban + cli/lib/nftban/cli/*.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash"
# meta:inventory.files="cli/sbin/nftban,cli/lib/nftban/cli/cmd_support.sh,cli/lib/nftban/cli/cmd_suricata.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NONINTERACTIVE,NFTBAN_NO_BANNER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_router_exit_truth_v1228_1_test"
# meta:ta.owner="cli"
# meta:ta.module="rc-contract"
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
NFTBAN_SBIN="$REPO/cli/sbin/nftban"
REAL_LIB="$REPO/cli/lib/nftban"

[[ -f "$NFTBAN_SBIN" ]] || { echo "FAIL: cannot find $NFTBAN_SBIN" >&2; exit 1; }
[[ -d "$REAL_LIB" ]]    || { echo "FAIL: cannot find $REAL_LIB" >&2; exit 1; }

export NFTBAN_LIB_DIR="$REAL_LIB"
export NFTBAN_NONINTERACTIVE=1
export NFTBAN_NO_BANNER=1

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Router rejection markers. Both must exit 1; the TEXT differs so an operator
# can tell "no such command" from "the command exists but its payload broke".
MARK_UNKNOWN="Unknown command"
MARK_LOADFAIL="Failed to load command module"

TMP_ROOT=""
cleanup(){ [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# run <libdir> <args...> -> sets RC, OUT (stdout), ERRTXT (stderr)
run(){
    local libdir="$1"; shift
    local errf; errf="$(mktemp)"
    RC=0
    OUT="$(NFTBAN_LIB_DIR="$libdir" bash "$NFTBAN_SBIN" "$@" 2>"$errf")" || RC=$?
    ERRTXT="$(cat "$errf")"
    rm -f "$errf"
}

echo "=========================================================="
echo "v1.228.1 PR-1: CLI router exit-truth test"
echo "=========================================================="

# -----------------------------------------------------------------------------
# The eight entrypoint-less library files are DERIVED, never hardcoded.
# If a ninth appears (or one gains an entrypoint) this test follows the tree.
# -----------------------------------------------------------------------------
ENTRYPOINTLESS=()
for f in "$REAL_LIB"/cli/cmd_*.sh; do
    b="$(basename "$f" .sh)"; t="${b#cmd_}"
    grep -qE "^[[:space:]]*(function[[:space:]]+)?nftban_cmd_${t}[[:space:]]*\(\)" "$f" \
        || ENTRYPOINTLESS+=("$t")
done

echo "--- T-A1/T-A2: entrypoint-less library files must be rejected ---"
if (( ${#ENTRYPOINTLESS[@]} == 0 )); then
    ok "T-A1 no entrypoint-less cli/cmd_*.sh in tree (nothing to reject)"
else
    for t in "${ENTRYPOINTLESS[@]}"; do
        run "$REAL_LIB" "$t"
        if (( RC >= 1 )); then
            ok "T-A1 nftban $t -> rc=$RC (must be >=1)"
        else
            no "T-A1 nftban $t -> rc=$RC" "silent success: dispatcher returned 0 for a token that cannot do work"
        fi
        # T-A2: the rejection must be visible on STDERR, not swallowed and not
        # printed to stdout (a script doing `nftban X 2>/dev/null` must still
        # get clean stdout, per the v1.141 PR-B stream contract).
        if [[ "$ERRTXT" == *"ERROR"* ]]; then
            ok "T-A2 nftban $t -> error text on stderr"
        else
            no "T-A2 nftban $t -> error text on stderr" "stderr had no ERROR line"
        fi
    done
fi

# -----------------------------------------------------------------------------
# T-A3 — the rejection must not become over-broad. Every alias token in the
# router must still resolve to its handler. Aliases legitimately return
# non-zero (e.g. `restart --help` does today), so the assertion is on the
# ROUTER MARKERS, not on rc.
# -----------------------------------------------------------------------------
echo "--- T-A3: alias tokens must still dispatch ---"
ALIASES=(
    whitelist-system firewall-logs support-bundle          # filename remaps
    cloudflare enable disable restart verify explain       # post-autoloader case
    service export rollback hello help
)
for t in "${ALIASES[@]}"; do
    run "$REAL_LIB" "$t" --help
    if [[ "$ERRTXT" == *"$MARK_UNKNOWN"* || "$ERRTXT" == *"$MARK_LOADFAIL"* ]]; then
        no "T-A3 alias '$t' still dispatches" "router rejected it (over-broad guard)"
    else
        ok "T-A3 alias '$t' still dispatches (rc=$RC, no router rejection)"
    fi
done

# -----------------------------------------------------------------------------
# T-A5 — support-bundle. Its module is cmd_support.sh, so the entrypoint name
# does not follow the token. This is the alias most likely to be broken by a
# fix at the rejection site.
# -----------------------------------------------------------------------------
echo "--- T-A5: support-bundle alias renders support help at rc 0 ---"
run "$REAL_LIB" support-bundle --help
if (( RC == 0 )) && [[ "$OUT" == *"support"* ]] && (( ${#OUT} > 200 )); then
    ok "T-A5 nftban support-bundle --help -> rc=0, ${#OUT}B of support help on stdout"
else
    no "T-A5 nftban support-bundle --help" "rc=$RC stdout=${#OUT}B (expected rc 0 + support help)"
fi

# T-A5b — STRUCTURAL guard for the same class: every filename remap in the
# router must resolve to an entrypoint that actually exists. Parsed from the
# router source so a NEW remap is covered without editing this test.
echo "--- T-A5b: every router filename remap resolves to a defined entrypoint ---"
remap_token=""
remaps_checked=0
while IFS= read -r line; do
    if [[ "$line" =~ \[\[[[:space:]]+\"\$cmd\"[[:space:]]+==[[:space:]]+\"([a-z0-9-]+)\"[[:space:]]+\]\] ]]; then
        remap_token="${BASH_REMATCH[1]}"
        continue
    fi
    if [[ -n "$remap_token" && "$line" =~ cmd_file=\"\$\{NFTBAN_LIB_DIR\}/cli/(cmd_[a-z0-9_]+\.sh)\" ]]; then
        remap_file="${BASH_REMATCH[1]}"
        remaps_checked=$((remaps_checked + 1))
        token_func="${remap_token//-/_}"
        module_func="${remap_file%.sh}"; module_func="${module_func#cmd_}"
        if grep -qE "^[[:space:]]*(function[[:space:]]+)?nftban_cmd_(${token_func}|${module_func})[[:space:]]*\(\)" \
               "$REAL_LIB/cli/$remap_file"; then
            ok "T-A5b remap '$remap_token' -> $remap_file resolves to a defined entrypoint"
        else
            no "T-A5b remap '$remap_token' -> $remap_file" "neither nftban_cmd_${token_func} nor nftban_cmd_${module_func} is defined"
        fi
        remap_token=""
    fi
done < "$NFTBAN_SBIN"
if (( remaps_checked == 0 )); then
    no "T-A5b parsed at least one filename remap from the router" "extractor matched nothing — the router shape changed"
else
    ok "T-A5b parsed $remaps_checked filename remap(s) from the router source"
fi

# -----------------------------------------------------------------------------
# T-A4 / T-A6 — the falsifiability core. A synthetic module in a temporary
# NFTBAN_LIB_DIR proves the guard is STRUCTURAL. An implementation that
# denylists the eight known filenames passes everything above and fails here.
# -----------------------------------------------------------------------------
echo "--- T-A4/T-A6: synthetic fixture modules in a temporary NFTBAN_LIB_DIR ---"
TMP_ROOT="$(mktemp -d)"
FIX_LIB="$TMP_ROOT/lib"
mkdir -p "$FIX_LIB/cli"
for e in "$REAL_LIB"/*; do
    n="$(basename "$e")"
    [[ "$n" == "cli" ]] && continue
    ln -s "$e" "$FIX_LIB/$n"
done
for e in "$REAL_LIB"/cli/*; do
    ln -s "$e" "$FIX_LIB/cli/$(basename "$e")"
done

# Fixture 1 (T-A4): a real, sourceable module that defines NO entrypoint.
cat > "$FIX_LIB/cli/cmd_zzfixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
# v1.228.1 T-A4 fixture: sources cleanly, exposes no nftban_cmd_zzfixture.
_zzfixture_not_an_entrypoint() { echo "never dispatched"; }
FIXTURE

# Fixture 2 (T-A6): aborts at its top level BEFORE defining its entrypoint —
# the shape of cmd_suricata.sh's required-module loader.
cat > "$FIX_LIB/cli/cmd_zzabort.sh" <<'FIXTURE'
#!/usr/bin/env bash
# v1.228.1 T-A6 fixture: aborts mid-load, so the entrypoint below never exists.
echo "ERROR: fixture required module not found" >&2
return 1
nftban_cmd_zzabort() { echo "never defined"; }
FIXTURE

# Control: the temporary lib dir must itself be functional, otherwise T-A4/T-A6
# would "pass" for the wrong reason (everything failing).
run "$FIX_LIB" version
if (( RC == 0 )); then
    ok "T-A4-control nftban version in temp NFTBAN_LIB_DIR -> rc=0 (harness is sound)"
else
    no "T-A4-control nftban version in temp NFTBAN_LIB_DIR -> rc=$RC" "temp lib dir is broken; T-A4/T-A6 verdicts are meaningless"
fi

run "$FIX_LIB" zzfixture
if (( RC >= 1 )) && [[ "$ERRTXT" == *"$MARK_UNKNOWN"* ]]; then
    ok "T-A4 synthetic entrypoint-less module rejected -> rc=$RC, '$MARK_UNKNOWN'"
else
    no "T-A4 synthetic entrypoint-less module rejected" "rc=$RC; the guard is a name denylist, not structural"
fi

run "$FIX_LIB" zzabort
if (( RC >= 1 )) && [[ "$ERRTXT" == *"$MARK_LOADFAIL"* ]]; then
    ok "T-A6 module aborting mid-load rejected -> rc=$RC, '$MARK_LOADFAIL'"
else
    no "T-A6 module aborting mid-load rejected" "rc=$RC; the status of \`source\` is still discarded"
fi

# R4: the two rejections must be distinguishable in TEXT while both exit 1.
run "$FIX_LIB" zzfixture; a_rc=$RC; a_err="$ERRTXT"
run "$FIX_LIB" zzabort;   b_rc=$RC; b_err="$ERRTXT"
if (( a_rc == 1 && b_rc == 1 )) \
   && [[ "$a_err" == *"$MARK_UNKNOWN"*  && "$a_err" != *"$MARK_LOADFAIL"* ]] \
   && [[ "$b_err" == *"$MARK_LOADFAIL"* ]]; then
    ok "T-A6b both rejections exit 1 and are distinguishable in text (R4)"
else
    no "T-A6b both rejections exit 1 and are distinguishable in text" "unknown rc=$a_rc loadfail rc=$b_rc"
fi

# -----------------------------------------------------------------------------
# T-D2 / T-D3 — completion-authority consistency inside cli/sbin/nftban.
# Level-0 comes from the router's own __complete endpoint (runtime truth),
# the suggester list from its heredoc (static).
# -----------------------------------------------------------------------------
echo "--- T-D2/T-D3: Level-0 completion vs typo suggester ---"
L0_FILE="$TMP_ROOT/level0.txt"
CANON_FILE="$TMP_ROOT/canon.txt"
NFTBAN_LIB_DIR="$REAL_LIB" bash "$NFTBAN_SBIN" __complete 2>/dev/null | sed '/^$/d' > "$L0_FILE"
awk '/^_nftban_canonical_commands\(\) \{/{f=1;next} f&&/^EOF$/{exit} f&&!/<<.EOF.$/{print}' \
    "$NFTBAN_SBIN" | sed '/^$/d' > "$CANON_FILE"

if [[ ! -s "$L0_FILE" || ! -s "$CANON_FILE" ]]; then
    no "T-D2/T-D3 extractors produced non-empty lists" "level0=$(wc -l <"$L0_FILE") canon=$(wc -l <"$CANON_FILE")"
else
    dupes="$(sort "$L0_FILE" | uniq -d | tr '\n' ' ')"
    if [[ -z "${dupes// /}" ]]; then
        ok "T-D2 Level-0 completion emits no duplicate token ($(wc -l <"$L0_FILE") tokens)"
    else
        no "T-D2 Level-0 completion emits no duplicate token" "duplicated: $dupes"
    fi

    missing="$(comm -23 <(sort -u "$L0_FILE") <(sort -u "$CANON_FILE") | tr '\n' ' ')"
    if [[ -z "${missing// /}" ]]; then
        ok "T-D3 every Level-0 token is in _nftban_canonical_commands()"
    else
        no "T-D3 every Level-0 token is in _nftban_canonical_commands()" "absent from suggester: $missing"
    fi
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
