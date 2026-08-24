#!/usr/bin/env bash
# =============================================================================
# NFTBan - read-path mode contract (v1.229.7 PR-4)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="read_path_mode_contract_v1229_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="Enforces STATUS MUST NOT RESOLVE AUTO. Runs the real read-path reader with the environment deliberately set to DISAGREE with the supplied plan, proving the environment can neither create a decision (R1/R2: no plan -> unknown even though availability has a clear answer) nor override one (R3/R4: plan wins over what availability would have chosen). R5 proves a stale or malformed plan yields unknown with NO configured-mode fallback, and R6 proves runtime observation is reportable but never promotes to effective_mode. Also asserts the three report axes stay distinct and that no read path retains a local resolver."
# meta:ta.id="read_path_mode_contract_v1229_7_test"
# meta:ta.owner="firewall"
# meta:ta.module="mode-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="90"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_portscan.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_PLAN_RECORD_DIR,NFTBAN_PLAN_GENERATION_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (config and run dirs redirected to a temp dir)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
AUTH="$ROOT/cli/lib/nftban/lib/module_authority.sh"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

echo "=== read-path mode contract (v1.229.7 PR-4) ==="
[[ -f "$AUTH" ]] || { echo "::error::SUBJECT_NOT_FOUND: $AUTH"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/conf.d/ddos" "$TMP/conf.d/portscan" "$TMP/run"

# report <module> <configured> <plan_eff|NONE> <plan_cfg> <rec_gen> <cur_gen> <env_would_choose> [enabled]
# `env_would_choose` sets what a local resolver WOULD have picked. The reader
# must never consult it -- it exists so the controls can make the environment
# disagree with the plan on purpose.
report() {
    local mod="$1" cfg="$2" peff="$3" pcfg="$4" rgen="$5" cgen="$6" envpick="$7" en="${8:-true}"
    local K; K="$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )"
    printf '%s_ENABLED="%s"\n%s_MODE="%s"\n' "$K" "$en" "$K" "$cfg" > "$TMP/conf.d/$mod/main.conf"
    rm -f "$TMP/run/module-plan-${mod}.env" "$TMP/run/convergence-generation"
    [[ "$cgen" != "NONE" ]] && printf '%s\n' "$cgen" > "$TMP/run/convergence-generation"
    if [[ "$peff" != "NONE" ]]; then
        printf 'NFTBAN_PLAN_MODULE=%s\nNFTBAN_PLAN_CONFIGURED_MODE=%s\nNFTBAN_PLAN_EFFECTIVE_MODE=%s\nNFTBAN_PLAN_BOUND_GENERATION=%s\n' \
            "$mod" "$pcfg" "$peff" "$rgen" > "$TMP/run/module-plan-${mod}.env"
    fi
    NFTBAN_CONFIG_DIR="$TMP" \
    NFTBAN_PLAN_RECORD_DIR="$TMP/run" \
    NFTBAN_PLAN_GENERATION_FILE="$TMP/run/convergence-generation" \
    bash -c "
        set -Eeuo pipefail
        source '$AUTH'
        # The environment is rigged to have a CLEAR, and often CONTRADICTORY,
        # answer. A reader that consults it will be caught by R1-R4.
        nftban_${mod}_suricata_is_available(){ [[ '$envpick' == suricata ]]; }
        _nftban_${mod}_suricata_is_available(){ [[ '$envpick' == suricata ]]; }
        nftban_module_report_modes $mod"
}
eff()   { grep '^NFTBAN_REPORT_EFFECTIVE_MODE=' <<<"$1" | cut -d= -f2-; }
cfgm()  { grep '^NFTBAN_REPORT_CONFIGURED_MODE=' <<<"$1" | cut -d= -f2-; }
basis() { grep '^NFTBAN_REPORT_EFFECTIVE_BASIS=' <<<"$1" | cut -d= -f2-; }

# --- R1 / R2: the environment cannot CREATE a decision ----------------------
echo ""
echo "R1/R2 — no plan, environment has a clear answer -> unknown..."
for mod in ddos portscan; do
    for envpick in classic suricata; do
        out="$(report "$mod" auto NONE auto 1 1 "$envpick")"
        if [[ "$(eff "$out")" == "unknown" ]]; then
            ok "$mod configured=auto, no plan, environment would pick $envpick -> unknown ($(basis "$out"))"
        else
            fail "$mod no plan but reported '$(eff "$out")' — ENVIRONMENT CANNOT CREATE A DECISION"
        fi
    done
done

# --- R3 / R4: the environment cannot OVERRIDE a decision --------------------
echo ""
echo "R3/R4 — valid plan, environment actively disagrees -> plan wins..."
for mod in ddos portscan; do
    out="$(report "$mod" auto classic auto 1 1 suricata)"
    [[ "$(eff "$out")" == "classic" ]] \
        && ok "$mod plan=classic while environment would pick suricata -> classic" \
        || fail "$mod plan=classic but reported '$(eff "$out")' — ENVIRONMENT CANNOT OVERRIDE A DECISION"
    out="$(report "$mod" auto suricata auto 1 1 classic)"
    [[ "$(eff "$out")" == "suricata" ]] \
        && ok "$mod plan=suricata while environment would pick classic -> suricata" \
        || fail "$mod plan=suricata but reported '$(eff "$out")' — ENVIRONMENT CANNOT OVERRIDE A DECISION"
done

# --- R5: stale/malformed -> unknown, NO configured fallback -----------------
echo ""
echo "R5 — stale or malformed plan -> unknown, never the configured mode..."
for mod in ddos portscan; do
    # Each row is a distinct way the plan is unusable. The configured mode is
    # deliberately EXPLICIT so a fallback would be visible as that value.
    for spec in "stale-generation:classic:classic:1:2" \
                "config-changed-since:classic:auto:1:1" \
                "wrong-effective:classic:classic:1:1" ; do
        name="${spec%%:*}"; rest="${spec#*:}"
        cfg="${rest%%:*}"; rest="${rest#*:}"
        pcfg="${rest%%:*}"; rest="${rest#*:}"
        rgen="${rest%%:*}"; cgen="${rest#*:}"
        peff="classic"; [[ "$name" == "wrong-effective" ]] && peff="bogus"
        out="$(report "$mod" "$cfg" "$peff" "$pcfg" "$rgen" "$cgen" classic)"
        if [[ "$(eff "$out")" == "unknown" ]]; then
            ok "$mod $name -> unknown ($(basis "$out"))"
        elif [[ "$(eff "$out")" == "$cfg" ]]; then
            fail "$mod $name fell back to the CONFIGURED mode '$cfg' — NO CONFIGURED FALLBACK"
        else
            fail "$mod $name reported '$(eff "$out")', expected unknown"
        fi
    done
    out="$(report "$mod" auto NONE auto 1 NONE classic)"
    [[ "$(eff "$out")" == "unknown" ]] \
        && ok "$mod no plan and no convergence generation -> unknown" \
        || fail "$mod reported '$(eff "$out")' with no plan at all"
done

# --- R6: observation is reportable, never promotable ------------------------
echo ""
echo "R6 — the reader derives nothing from observed runtime..."
# The reader takes NO ruleset input at all, by construction: there is no
# parameter, no nft call, and no observation source it could promote.
#   OBSERVED STATE != AUTHORITY TO RECONSTRUCT THE DECISION
body="$(awk '/^nftban_module_report_modes\(\) \{/{i=1} i{print} i&&/^\}/{exit}' "$AUTH")"
if [[ -z "$body" ]]; then
    fail "nftban_module_report_modes not found"
elif grep -qE '(^|[^a-z_])nft( |$)|nft_ipc_|ChainExists|list ruleset|_is_available' <<<"$(sed 's/#.*$//' <<<"$body")"; then
    fail "the reader inspects runtime or probes availability — it must consume the plan only"
else
    ok "the reader consults no runtime observation and no availability probe"
fi

# --- axes stay distinct -----------------------------------------------------
echo ""
echo "the three axes stay distinct..."
for mod in ddos portscan; do
    out="$(report "$mod" auto NONE auto 1 1 classic)"
    if [[ "$(cfgm "$out")" == "auto" && "$(eff "$out")" == "unknown" ]]; then
        ok "$mod configured=auto reported verbatim while effective=unknown"
    else
        fail "$mod axes collapsed: configured='$(cfgm "$out")' effective='$(eff "$out")'"
    fi
    # An explicit configured mode still does not prove effect freshness.
    out="$(report "$mod" classic NONE classic 1 1 classic)"
    if [[ "$(cfgm "$out")" == "classic" && "$(eff "$out")" == "unknown" ]]; then
        ok "$mod configured=classic with no plan -> effective unknown (no effect freshness from value freshness)"
    else
        fail "$mod claimed effective='$(eff "$out")' from configured value alone"
    fi
    # The one valid short-circuit.
    out="$(report "$mod" auto NONE auto 1 1 classic false)"
    [[ "$(eff "$out")" == "inactive" ]] \
        && ok "$mod disabled -> inactive (the valid short-circuit, preserved)" \
        || fail "$mod disabled reported '$(eff "$out")', expected inactive"
done

# --- no read path retains a local resolver ----------------------------------
echo ""
echo "no read path retains a local resolver..."
for mod in ddos portscan; do
    n="$(sed 's/#.*$//' "$ROOT/cli/lib/nftban/core/nftban_${mod}.sh" | grep -c "_nftban_${mod}_detect_mode" || true)"
    if [[ "$n" -le 1 ]]; then
        ok "$mod has no remaining caller of the local resolver (definition only)"
    else
        fail "$mod still has $((n-1)) caller(s) of _nftban_${mod}_detect_mode"
    fi
done

# --- no read path may DERIVE A MODE from an availability probe -------------
echo ""
echo "no read path derives a mode from availability (PR-4B / F-A1)..."
# ⛔ The arm above counts callers of a NAMED function. The claim it is read as
# supporting is broader: "no read path resolves auto". Probing availability and
# assigning a mode is the same defect under a different name.
#   NO CALLER OF A NAMED FUNCTION != NO INSTANCE OF THE BEHAVIOUR.
# Reporting `suricata_available` as its OWN field is legitimate -- that is the
# observed-runtime axis. Assigning a MODE from it is not.
for mod in ddos portscan; do
    src="$ROOT/cli/lib/nftban/core/nftban_${mod}.sh"
    bad=""
    while IFS=: read -r ln _; do
        [[ -n "$ln" ]] || continue
        # look at the probe line and the few lines it guards
        window="$(sed -n "${ln},$((ln+6))p" "$src" | sed 's/#.*$//')"
        if grep -qE '\b(mode|MODE|_ACTIVE_MODE|detected_mode|effective[_a-z]*)=' <<<"$window"; then
            fn="$(awk -v L="$ln" 'NR<=L && /^[a-z_]+\(\) \{/{f=$1} END{print f}' "$src")"
            bad="$bad ${fn%%(*}:$ln"
        fi
    done < <(sed 's/#.*$//' "$src" | grep -nE "_suricata_is_available|suricata_available\b" | grep -v "() {" || true)
    if [[ -n "$bad" ]]; then
        fail "$mod derives a mode from an availability probe at:$bad — AVAILABILITY IS AN OBSERVATION, NOT A DECISION"
    else
        ok "$mod probes availability only to report it, never to choose a mode"
    fi
done

# --- ONE MODE DECISION AUTHORITY, over the EXECUTABLE population (PR-5C) ----
echo ""
echo "one mode-decision authority for ddos/portscan, repo-wide..."
# ⛔ THE SUBJECT-POPULATION FAILURE THIS GUARD EXISTS FOR. Authority Map Pass A/B
# declared row 5 COMPLETE while `cmd_modes.sh` and `helpers/nftban_mode.sh` --
# both live, both reachable, both independently resolving `auto` -- were absent
# from every .7 guard's population. `nftban modes` could report an effective mode
# the system never decided, and `_modes_resolve_effective` even accepted `hybrid`,
# which .7 treats as unrenderable.
#   A GUARD'S PASS ESTABLISHES EXACTLY ITS SUBJECT POPULATION AND NOTHING MORE.
#
# Population is derived by CALL GRAPH, not a filename list: any shell file that
# reaches a legacy resolver is in scope automatically.
LEGACY_RESOLVERS='_modes_resolve_effective|_nftban_mode_detect_effective'
declare -a OFFENDERS=()
while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    src="${hit%%:*}"; rest="${hit#*:}"; ln="${rest%%:*}"
    line="$(sed -n "${ln}p" "$src")"
    grep -qE "^\s*#"      <<<"$line" && continue   # comment
    grep -qE "\(\) \{"  <<<"$line" && continue   # definition
    grep -qE "^export -f"  <<<"$line" && continue   # export
    rel="${src#"$ROOT"/}"

    # (a) DIRECT: the call site itself names ddos/portscan. Always an offender --
    #     no context exemption. An earlier revision exempted the whole enclosing
    #     function if ANY line in it used the plan path, so a legacy call sitting
    #     one line below a plan-consuming call went undetected (M38 did not fire).
    #       AN EXEMPTION MUST BIND TO THE CALL SITE, NOT ITS NEIGHBOURHOOD.
    # ⛔ NO TRAILING \b. Underscore is a word character, so `\bddos\b` does NOT
    # match `ddos_effective` or `$ddos_config` -- the exact identifier forms this
    # code uses. An earlier revision used it and the control silently failed to
    # see its own subject (M38 did not fire against a real regression).
    #   A WORD BOUNDARY IS NOT A TOKEN BOUNDARY IN SNAKE_CASE.
    if grep -qiE '(^|[^a-z0-9_])(ddos|portscan)' <<<"$line"; then
        OFFENDERS+=("$rel:$ln(direct)")
        continue
    fi

    # (b) PARAMETERISED: reached with a module variable. Legitimate ONLY as the
    #     fallback arm of an immediately-preceding plan check, which for
    #     ddos/portscan always succeeds and so cannot reach here.
    guard="$(sed -n "$((ln>2 ? ln-2 : 1)),$((ln-1))p" "$src")"
    if grep -qE '_effective_from_plan|_modes_effective_for' <<<"$guard"; then
        continue
    fi
    # Structurally unreachable for ddos/portscan: an earlier `case` arm in the
    # SAME function matches them and returns before this line. That is a real
    # exemption, not a neighbourhood one -- the in-scope modules never arrive.
    fstart="$(awk -v L="$ln" 'NR<=L && /^_?[a-z_]+\(\) \{/{n=NR} END{print n}' "$src")"
    before="$(sed -n "${fstart},$((ln-1))p" "$src")"
    if grep -qE '^\s*(ddos\|portscan|portscan\|ddos)\)' <<<"$before" \
       && grep -qE 'return 0' <<<"$before"; then
        continue
    fi
    if grep -qE 'module_name|mode_var_name|\$1|\$2' <<<"$line"; then
        OFFENDERS+=("$rel:$ln(parameterised, no plan guard)")
    fi
done < <(grep -rnE "$LEGACY_RESOLVERS" "$ROOT/cli/lib/nftban" --include="*.sh" 2>/dev/null | grep -v "/tests/" || true)

# ⛔ NON-VACUITY. "No offenders" is only meaningful if the search actually had a
# subject. A wrong path, a renamed resolver, or a broken glob would produce an
# empty scan and this guard would report clean while a regression was live.
#   COUNT PRINTED != POPULATION ASSERTED
#   ZERO OFFENDERS OVER ZERO SUBJECTS PROVES NOTHING.
# ⛔ `|| true` on BOTH pipelines. Under `set -e` + pipefail an empty grep result
# returns non-zero and kills the assignment -- so this detector would DIE on
# exactly the condition it exists to detect, producing no output at all rather
# than a failure. Observed: M40 ran and printed nothing.
#   A VACUITY DETECTOR MUST SURVIVE VACUITY.
_scanned="$(grep -rlE "$LEGACY_RESOLVERS" "$ROOT/cli/lib/nftban" --include="*.sh" 2>/dev/null | grep -v "/tests/" | wc -l || true)"
_defs="$(grep -rcE "^(_modes_resolve_effective|_nftban_mode_detect_effective)\(\) \{" \
         "$ROOT/cli/lib/nftban/cli/cmd_modes.sh" "$ROOT/cli/lib/nftban/helpers/nftban_mode.sh" 2>/dev/null \
         | awk -F: '{s+=$2} END{print s+0}' || true)"
if [[ "$_defs" -lt 2 ]]; then
    fail "population vacuous: found $_defs/2 legacy resolver definitions — the guard has no subject"
elif [[ "$_scanned" -lt 2 ]]; then
    fail "population vacuous: only $_scanned file(s) scanned; expected at least cmd_modes.sh + nftban_mode.sh"
else
    ok "population non-vacuous: $_defs legacy resolvers still defined across $_scanned scanned file(s)"
fi

if [[ ${#OFFENDERS[@]} -eq 0 ]]; then
    ok "no ddos/portscan path reaches a legacy mode resolver"
else
    fail "ddos/portscan still reach a legacy resolver at: ${OFFENDERS[*]}"
fi

# ⛔ Login must NOT have been dragged into .7 semantics.
#   COLLAPSING A DUPLICATE AUTHORITY != EXTENDING IT TO NEW SUBJECTS.
if grep -qE 'login_effective=\$\(_modes_resolve_effective' "$ROOT/cli/lib/nftban/cli/cmd_modes.sh"; then
    ok "Login row still uses its own legacy path (behaviour unchanged)"
else
    fail "Login was moved onto .7 mode semantics without its provenance being proven"
fi

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::read-path mode contract FAILED: $FAILURES"
    exit 1
fi
echo "read-path mode contract PASSED"
