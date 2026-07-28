#!/usr/bin/env bash
# =============================================================================
# NFTBan - shipped systemd units must not invoke an undispatchable CLI token
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="systemd_cli_token_dispatch_v1228_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-28"
# meta:description="v1.228.1 PR-1 consumer-safety test (T-E1). Until v1.228.1 the CLI router returned exit 0 for a command whose module could not be loaded, so a systemd unit could invoke a CLI token that does no work and the unit would still start green. Two shipped units do exactly that - nftban-suricata.service ExecStartPre and nftban-suricata-update.service ExecStart both run 'nftban suricata rules ...', and cmd_suricata.sh aborts at load because four sibling modules it declares as REQUIRED were deleted by ff1865b4. Neither unit sets SuccessExitStatus=, so once the router tells the truth those units fail to start. This test scans every Exec* directive in install/systemd and packaging/systemd, extracts each /usr/sbin/nftban token, and asserts the token is dispatchable: it must resolve to a router target (a cli/cmd_<token>.sh exposing an nftban_cmd_ entrypoint, or a router alias arm), and that module must not declare a sibling cmd_*.sh that is absent from the shipped tree - the general form of the Suricata defect. Tokens that are knowingly broken pending owner decisions D1/D2 are listed in a sanctioned set which is itself asserted to be still-broken, so the entry must be removed the moment PR-2 repairs it. Static analysis only - reads files, invokes nothing."
# meta:input="install/systemd/*, packaging/systemd/*, cli/sbin/nftban, cli/lib/nftban/cli/cmd_*.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed"
# meta:inventory.files="install/systemd/nftban-suricata.service,install/systemd/nftban-suricata-update.service,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="all shipped units under install/systemd and packaging/systemd"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="systemd_cli_token_dispatch_v1228_1_test"
# meta:ta.owner="cli"
# meta:ta.module="dispatcher"
# meta:ta.execution_class="CI_STATIC"
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
ROUTER="$REPO/cli/sbin/nftban"
CLI_DIR="$REPO/cli/lib/nftban/cli"
LIB_ROOT="$REPO/cli/lib/nftban"
UNIT_DIRS=("$REPO/install/systemd" "$REPO/packaging/systemd")

[[ -f "$ROUTER" ]]  || { echo "FAIL: cannot find $ROUTER" >&2; exit 1; }
[[ -d "$CLI_DIR" ]] || { echo "FAIL: cannot find $CLI_DIR" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# -----------------------------------------------------------------------------
# SANCTIONED GAP LIST — NOW EMPTY (v1.228.2). This is the terminal state.
#
# v1.228.1 PR-1 fixed the router but was forbidden from touching systemd units,
# so it sanctioned exactly one token — `suricata` — pending owner decisions D1
# (what nftban-suricata.service ExecStartPre should do now that
# `suricata rules verify` no longer exists) and D2 (delete or repoint
# nftban-suricata-update.service). Each entry was asserted below to STILL be
# broken, so that the list could not rot into a lie once the gap closed.
#
# That mechanism fired: the Suricata retirement (owner ruling D1-D4) DELETED
# install/systemd/nftban-suricata.service and nftban-suricata-update.{service,timer}
# rather than repointing them, and build/deprecated-units.yaml converges them
# away on upgrade. No shipped unit invokes `nftban suricata` any more, so the
# entry stopped earning its place and the reverse assertion failed until it was
# removed. It is removed here.
#
# DO NOT re-populate this list to make a red run green. An undispatchable token
# in a shipped unit is a unit that starts green while doing nothing — the exact
# defect v1.228.1 exists to remove. Fix the unit or delete it.
# -----------------------------------------------------------------------------
SANCTIONED_TOKENS=()
SANCTIONED_REASON="none — the list is empty and must stay empty"

is_sanctioned(){
    local t="$1" s
    # `${arr[@]+...}` form: the list is now empty and must survive `set -u`.
    for s in ${SANCTIONED_TOKENS[@]+"${SANCTIONED_TOKENS[@]}"}; do [[ "$s" == "$t" ]] && return 0; done
    return 1
}

# -----------------------------------------------------------------------------
# Router alias arms — extracted from the router source, never hardcoded, so a
# new alias needs no edit here.
# -----------------------------------------------------------------------------
ALIAS_TOKENS_FILE="$(mktemp)"
trap 'rm -f "$ALIAS_TOKENS_FILE"' EXIT
sed -n '/^main() {/,/^}$/p' "$ROUTER" \
    | grep -oE '^[[:space:]]+[a-z0-9|_"-]+\)' \
    | tr -d ' )"' | tr '|' '\n' | sed '/^$/d' | sort -u > "$ALIAS_TOKENS_FILE"

# resolve_module <token> -> echoes the module path, or nothing
resolve_module(){
    local t="$1"
    if [[ -f "$CLI_DIR/cmd_${t}.sh" ]]; then echo "$CLI_DIR/cmd_${t}.sh"; return 0; fi
    # mirror the router's hyphen->underscore filename remaps structurally
    if [[ -f "$CLI_DIR/cmd_${t//-/_}.sh" ]]; then echo "$CLI_DIR/cmd_${t//-/_}.sh"; return 0; fi
    return 1
}

has_entrypoint(){
    local file="$1" t="$2"
    local module_token; module_token="$(basename "$file" .sh)"; module_token="${module_token#cmd_}"
    grep -qE "^[[:space:]]*(function[[:space:]]+)?nftban_cmd_(${t//-/_}|${module_token})[[:space:]]*\(\)" "$file"
}

# missing_siblings <module> -> echoes any cmd_*.sh the module names that is not
# shipped anywhere under cli/lib/nftban. This is the general form of the
# Suricata defect: a module declaring a required sibling that does not exist
# aborts at load, which makes EVERY subcommand of that token undispatchable.
missing_siblings(){
    local file="$1" ref out=""
    for ref in $(grep -ohE '\bcmd_[a-z0-9_]+\.sh' "$file" | sort -u); do
        [[ "$(basename "$file")" == "$ref" ]] && continue
        if ! find "$LIB_ROOT" -name "$ref" -print -quit 2>/dev/null | grep -q .; then
            out+="$ref "
        fi
    done
    printf '%s' "$out"
}

echo "=========================================================="
echo "v1.228.1 PR-1 (T-E1): shipped systemd units vs CLI dispatch"
echo "=========================================================="

# -----------------------------------------------------------------------------
# Extract every "<unit>:<line>:<token>" the shipped units invoke.
# Covers direct ExecStart=, "+" privilege prefixes, flock wrappers and
# `bash -c '... /usr/sbin/nftban <token> ...'` forms by matching the CLI path
# anywhere on an Exec* directive line.
# -----------------------------------------------------------------------------
INVOCATIONS=()
for d in "${UNIT_DIRS[@]}"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r hit; do
        INVOCATIONS+=("$hit")
    done < <(grep -rnE '^[[:space:]]*Exec(Start|StartPre|StartPost|Stop|StopPost|Reload|Condition)=' "$d" 2>/dev/null \
             | grep -oE '^[^:]+:[0-9]+:.*/usr/sbin/nftban[[:space:]]+[a-z0-9_-]+' \
             | sed -E 's#^([^:]+):([0-9]+):.*/usr/sbin/nftban[[:space:]]+([a-z0-9_-]+)$#\1:\2:\3#')
done

echo "--- extraction ---"
if (( ${#INVOCATIONS[@]} == 0 )); then
    no "T-E1 extractor found CLI invocations in shipped units" "0 matches — the units or the extractor changed shape"
else
    ok "T-E1 extractor found ${#INVOCATIONS[@]} CLI invocation(s) across shipped units"
fi

echo "--- per-invocation dispatchability ---"
SEEN_BROKEN=()
for inv in "${INVOCATIONS[@]}"; do
    unit="${inv%%:*}"; rest="${inv#*:}"
    line="${rest%%:*}"; token="${rest#*:}"
    label="$(basename "$unit"):${line} -> nftban ${token}"

    reason=""
    module="$(resolve_module "$token" || true)"
    if [[ -z "$module" ]]; then
        if grep -qxF "$token" "$ALIAS_TOKENS_FILE"; then
            module=""   # alias arm, dispatchable without a module file
        else
            reason="no cli/cmd_${token}.sh and no router alias arm"
        fi
    elif ! has_entrypoint "$module" "$token"; then
        reason="$(basename "$module") exposes no nftban_cmd_ entrypoint"
    else
        miss="$(missing_siblings "$module")"
        if [[ -n "${miss// /}" ]]; then
            reason="$(basename "$module") requires unshipped module(s): ${miss% }"
        fi
    fi

    if [[ -z "$reason" ]]; then
        if is_sanctioned "$token"; then
            no "T-E1 sanctioned token '$token' is still undispatchable" \
               "'$token' now dispatches — DELETE it from SANCTIONED_TOKENS in this test"
        else
            ok "T-E1 $label dispatches"
        fi
    else
        SEEN_BROKEN+=("$token")
        if is_sanctioned "$token"; then
            ok "T-E1 $label UNDISPATCHABLE — sanctioned gap ($reason); $SANCTIONED_REASON"
        else
            no "T-E1 $label dispatches" "$reason"
        fi
    fi
done

# Reverse assertion: every sanctioned token must have been OBSERVED broken.
# A sanctioned token that no unit invokes any more, or that quietly started
# working, must be removed rather than left as decoration.
echo "--- sanctioned-set hygiene ---"
for s in ${SANCTIONED_TOKENS[@]+"${SANCTIONED_TOKENS[@]}"}; do
    hit="no"
    for b in ${SEEN_BROKEN[@]+"${SEEN_BROKEN[@]}"}; do [[ "$b" == "$s" ]] && hit="yes"; done
    if [[ "$hit" == "yes" ]]; then
        ok "T-E1 sanctioned token '$s' observed undispatchable (entry is still earning its place)"
    else
        no "T-E1 sanctioned token '$s' observed undispatchable" \
           "'$s' is no longer a broken systemd-invoked token — remove it from SANCTIONED_TOKENS"
    fi
done

# ZERO-GAP INVARIANT (v1.228.2). The allowlist is not merely "currently empty";
# emptiness is the asserted terminal state. Stated as two explicit numbers so a
# future PR that re-populates the list to silence a red run fails HERE, with the
# reason spelled out, instead of quietly shipping a unit that starts green while
# invoking a CLI token that does no work.
#
#   SANCTIONED_BROKEN_SURICATA_UNITS = 0
#   SYSTEMD_UNDISPATCHABLE_TOKENS    = 0
echo "--- zero-gap invariant ---"
_sanctioned_n=${#SANCTIONED_TOKENS[@]}
if (( _sanctioned_n == 0 )); then
    ok "T-E1 SANCTIONED_BROKEN_SURICATA_UNITS=0 — allowlist is empty (terminal state)"
else
    no "T-E1 SANCTIONED_BROKEN_SURICATA_UNITS=0 — allowlist is empty (terminal state)" \
       "${_sanctioned_n} sanctioned token(s) present: ${SANCTIONED_TOKENS[*]} — fix or delete the unit, do not allowlist it"
fi

_broken_n=${#SEEN_BROKEN[@]}
if (( _broken_n == 0 )); then
    ok "T-E1 SYSTEMD_UNDISPATCHABLE_TOKENS=0 — every shipped unit invokes a dispatchable token"
else
    no "T-E1 SYSTEMD_UNDISPATCHABLE_TOKENS=0 — every shipped unit invokes a dispatchable token" \
       "${_broken_n} undispatchable invocation(s): ${SEEN_BROKEN[*]}"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
