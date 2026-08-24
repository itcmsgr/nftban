#!/usr/bin/env bash
# =============================================================================
# NFTBan - plan projection contract (v1.229.7 PR-3B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="plan_projection_v1229_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="Proves the renderer CONSUMES a decision rather than making one. Holds the environment constant and varies ONLY the supplied plan, then asserts the mode-specific projection follows the plan: classic renders the classic pipeline and removes the Suricata one, suricata does the reverse, and neither runs both. Module-specific by design -- DDoS distinguishes the two modes by different nft-owning pipelines, while PortScan/Suricata owns NO nft projection, so its distinction is the ABSENCE of the classic projection with no fabricated replacement. SAME MODE CONTRACT != SAME KERNEL OBJECT SHAPE. Also proves the renderer refuses rather than repairs: hybrid, inactive, unknown, and a missing plan all refuse mutation, and none falls back to resolving auto or inferring from live state."
# meta:ta.id="plan_projection_v1229_7_test"
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
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_portscan.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_PLAN_MODULE,NFTBAN_PLAN_EFFECTIVE_MODE,NFTBAN_PLAN_RESOLUTION_ID,NFTBAN_PLAN_TXN_ID"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (every side-effecting dependency is stubbed)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
CALLLOG="$TMPD/calls.txt"; export CALLLOG
: > "$CALLLOG"

echo "=== plan projection contract (v1.229.7 PR-3B) ==="

for f in "$ROOT/cli/lib/nftban/core/nftban_ddos.sh" "$ROOT/cli/lib/nftban/core/nftban_portscan.sh"; do
    [[ -f "$f" ]] || fail "SUBJECT_NOT_FOUND: $f"
done
[[ $FAILURES -eq 0 ]] || { echo "::error::subjects unresolved"; exit 1; }

# Run <module>_apply under a SUPPLIED plan, with every mode-owning entrypoint
# stubbed to record that it ran. The environment is IDENTICAL across runs --
# only NFTBAN_PLAN_EFFECTIVE_MODE differs -- so any difference in the recorded
# calls is attributable to the plan and nothing else.
project() {  # <module> <effective_mode> [--no-plan]
    local mod="$1" mode="$2" noplan="${3:-}"
    : > "$CALLLOG"
    bash --noprofile --norc -c '
        set -Eeuo pipefail
        mod="$1"; mode="$2"; noplan="$3"; root="$4"
        # --- constant environment for every run -----------------------------
        systemctl() { return 1; }
        nft() { return 0; }
        nft_ipc_apply_ruleset() { return 0; }
        nft_ipc_request() { return 0; }
        nft_ipc_flush_set() { return 0; }
        nft_fragment_disable_module() { echo "CALL nft_fragment_disable_module $*" >> "$CALLLOG"; return 0; }
        export -f systemctl nft nft_ipc_apply_ruleset nft_ipc_request nft_ipc_flush_set nft_fragment_disable_module
        export NFTBAN_LIB_DIR="$root/cli/lib/nftban"
        # shellcheck disable=SC1090
        source "$root/cli/lib/nftban/lib/module_authority.sh" 2>/dev/null || true
        source "$root/cli/lib/nftban/core/nftban_${mod}.sh" 2>/dev/null || true
        if [ "$(type -t "nftban_${mod}_apply" || true)" != "function" ]; then
            echo "SUBJECT_UNREACHABLE: nftban_${mod}_apply"; exit 97
        fi
        # Record which mode-owning entrypoints run. These REPLACE the real ones,
        # so nothing touches a kernel.
        for side in classic suricata; do
            for act in enable disable; do
                eval "nftban_${mod}_${side}_${act}() { echo \"CALL ${side}_${act}\" >> \"$CALLLOG\"; return 0; }"
            done
        done
        # ⛔ The apply path calls a module loader that re-sources the REAL mode
        # modules, which would OVERWRITE these stubs and make the guard exercise
        # real code against a real kernel path. Neutralise it: this guard tests
        # projection DISPATCH, not module loading.
        eval "_nftban_${mod}_load_modules() { return 0; }"
        eval "nftban_${mod}_load_config() { return 0; }"
        eval "nftban_${mod}_suricata_get_status() { echo stub; }"
        eval "_nftban_${mod}_log() { :; }"
        eval "nftban_${mod}_verify_applied() { return 0; }"
        if [ "$noplan" != "--no-plan" ]; then
            export NFTBAN_PLAN_MODULE="$mod" NFTBAN_PLAN_EFFECTIVE_MODE="$mode"
            export NFTBAN_PLAN_RESOLUTION_ID="fixed-id" NFTBAN_PLAN_TXN_ID="fixed-id"
            export NFTBAN_PLAN_CONFIGURED_MODE="auto" NFTBAN_PLAN_ENABLED="true"
            export NFTBAN_PLAN_RESOLUTION_BASIS="test"
        fi
        "nftban_${mod}_apply" 2>&1 || echo "RC=$?"
    ' _ "$mod" "$mode" "$noplan" "$ROOT" 2>&1 || true
    # stdout of the run is the RC/diagnostic channel; $CALLLOG is the call channel.
}

# ⛔ Reads the FILE, not the run's stdout: the production helper invokes the
# opposite-mode teardown with `>/dev/null 2>&1`, so an stdout channel would be
# discarded and the exclusivity arm would silently observe nothing.
#   A GUARD MUST NOT USE A CHANNEL ITS SUBJECT IS ALLOWED TO CLOSE.
# ⛔ `|| true`: no matches is a LEGITIMATE observation (a refusing plan calls
# nothing), and under `set -e` a bare grep would abort the guard at exactly the
# moment the subject produced nothing -- the case most worth reporting.
#   NO MATCHES != COMMAND FAILURE.
calls() { grep -oE "CALL [a-z_]+(_[a-z]+)?" "$CALLLOG" 2>/dev/null | sed 's/^CALL //' | sort -u | tr '\n' ' ' || true; }

# --- 1. the plan, and only the plan, selects the projection ------------------
echo ""
echo "1. same environment, different plan -> different mode-specific projection..."
for mod in ddos portscan; do
    project "$mod" classic  >/dev/null; c="$(calls)"
    project "$mod" suricata >/dev/null; s="$(calls)"

    # classic plan: classic pipeline runs, suricata pipeline does NOT
    if grep -q "classic_enable" <<<"$c" && ! grep -q "suricata_enable" <<<"$c"; then
        ok "$mod plan=classic  -> classic projection only [$c]"
    else
        fail "$mod plan=classic produced [$c] — expected classic_enable and NO suricata_enable"
    fi
    # suricata plan: suricata pipeline runs, classic pipeline does NOT
    if grep -q "suricata_enable" <<<"$s" && ! grep -q "classic_enable" <<<"$s"; then
        ok "$mod plan=suricata -> suricata projection only [$s]"
    else
        fail "$mod plan=suricata produced [$s] — expected suricata_enable and NO classic_enable"
    fi
    # ⛔ The environment was identical. If the two runs are indistinguishable the
    #    plan is not controlling anything.
    if [[ "$c" == "$s" ]]; then
        fail "$mod produced IDENTICAL calls under both plans — THE PLAN CONTROLS NOTHING"
    else
        ok "$mod projection differs by plan alone (environment held constant)"
    fi
done

# --- 2. exclusivity: entering a mode removes the other projection ------------
echo ""
echo "2. entering a mode removes the OPPOSITE projection..."
# DDoS: both modes own nft state, so both directions must remove.
project ddos classic  >/dev/null; d_c="$(calls)"
project ddos suricata >/dev/null; d_s="$(calls)"
grep -q "suricata_disable" <<<"$d_c" \
    && ok "ddos plan=classic removes the Suricata projection" \
    || fail "ddos plan=classic leaves the Suricata projection live — PLAN SWITCH != DRIFT"
grep -q "classic_disable" <<<"$d_s" \
    && ok "ddos plan=suricata removes the classic projection" \
    || fail "ddos plan=suricata leaves the classic projection live — CLASSIC_ACTIVE + SURICATA_ACTIVE = INVALID"

# PortScan: ASYMMETRIC BY SUBSTRATE. Classic owns an nft projection; Suricata
# owns none. So the meaningful assertion is one-directional.
#   SAME MODE CONTRACT != SAME KERNEL OBJECT SHAPE
project portscan suricata >/dev/null; p_s="$(calls)"
grep -q "classic_disable" <<<"$p_s" \
    && ok "portscan plan=suricata removes the classic nft projection" \
    || fail "portscan plan=suricata leaves the classic nft projection present — that IS the drift"
project portscan classic >/dev/null; p_c="$(calls)"
if grep -qE "suricata_enable" <<<"$p_c"; then
    fail "portscan plan=classic invoked the Suricata pipeline"
else
    ok "portscan plan=classic renders no Suricata projection (none exists to render)"
fi

# --- 3. the renderer REFUSES; it never repairs -------------------------------
echo ""
echo "3. non-projectable plans refuse mutation (no repair, no fallback)..."
for mod in ddos portscan; do
    for bad in hybrid unknown bogus; do
        out="$(project "$mod" "$bad")"
        c="$(calls)"
        if grep -qE "classic_enable|suricata_enable" <<<"$c"; then
            fail "$mod plan=$bad still projected [$c] — a non-projectable mode must REFUSE"
        elif grep -q "RC=" <<<"$out"; then
            ok "$mod plan=$bad refused (no projection, non-zero rc)"
        else
            fail "$mod plan=$bad neither projected nor refused — silent success is not refusal"
        fi
    done
    # ⛔ hybrid specifically: the arm that ran BOTH pipelines lived here.
    project "$mod" hybrid >/dev/null; hout="$(calls)"
    if grep -q "classic_enable" <<<"$hout" && grep -q "suricata_enable" <<<"$hout"; then
        fail "$mod plan=hybrid ran BOTH pipelines — FULL_CLASSIC_INSIDE_SURICATA = BUG"
    else
        ok "$mod plan=hybrid does not run both pipelines"
    fi
    # `inactive` is NOT a refusal case. PR-3A defines it as a benign no-op:
    # apply projects nothing, and the reconcile root routes inactive to teardown,
    # which owns removal. Asserted as "projects nothing", never as "removed".
    #   APPLY PROJECTED NOTHING != APPLY REMOVED SOMETHING
    project "$mod" inactive >/dev/null; iout="$(calls)"
    if grep -qE "classic_enable|suricata_enable" <<<"$iout"; then
        fail "$mod plan=inactive projected [$iout] — inactive must render no higher tier"
    else
        ok "$mod plan=inactive renders no higher-tier projection"
    fi

    # No plan at all: a consumer without a plan is a contract failure, never an
    # invitation to resolve one.
    project "$mod" classic --no-plan >/dev/null
    if grep -qE "classic_enable|suricata_enable" <<<"$(calls)"; then
        fail "$mod projected with NO PLAN — MISSING PLAN != A MODE"
    else
        ok "$mod refuses to project without a plan"
    fi
done

# --- 3b. exclusivity that cannot be established must REFUSE ----------------
echo ""
echo "3b. unestablished exclusivity refuses (no silent rc0)..."
# ⛔ The first cut used `if type -t <fn>; then <fn>; fi` with no else, so a
# MISSING opposite-mode entrypoint made exclusivity vanish at rc0 and both
# projections could coexist while the helper reported success. The repo's
# mode-authority SILENT_NO_OP check flagged it as a NEW violation -- the guard
# caught a defect in this lane's own fix.
#   SELECTED MODE + MISSING ENTRYPOINT MUST NEVER BE rc0.
for mod in ddos portscan; do
    out="$(bash --noprofile --norc -c '
        set -Eeuo pipefail
        mod="$1"; root="$2"
        export NFTBAN_LIB_DIR="$root/cli/lib/nftban"
        source "$root/cli/lib/nftban/core/nftban_${mod}.sh" 2>/dev/null || true
        eval "_nftban_${mod}_log() { :; }"
        # The opposite-mode entrypoint is deliberately NOT defined.
        unset -f "nftban_${mod}_suricata_disable" 2>/dev/null || true
        if "_nftban_${mod}_remove_other_projection" classic >/dev/null 2>&1; then
            echo "ACCEPTED"
        else
            echo "REFUSED"
        fi' _ "$mod" "$ROOT" 2>&1 || true)"
    if grep -q "REFUSED" <<<"$out"; then
        ok "$mod refuses when the opposite-mode teardown is unavailable"
    else
        fail "$mod returned success without establishing exclusivity — SILENT rc0 NO-OP"
    fi
done

# --- 4. no MUTATION path may hold a local mode resolver --------------------
echo ""
echo "4. mutation paths hold no second mode authority..."
# ⛔ `_nftban_<mod>_detect_mode` resolves `auto` by probing Suricata
# availability. That is a SECOND, INDEPENDENT authority, and it does not pass
# through nftban_module_resolve_plan -- so PLAN-N1 cannot see it. In a mutation
# path it can disagree with the plan the transaction actually applied.
#   A MUTATION PATH CONSUMES THE PLAN. IT DOES NOT RE-DERIVE ONE.
# Read/report paths still call it; that surface is registered, not guarded here.
for mod in ddos portscan; do
    src="$ROOT/cli/lib/nftban/core/nftban_${mod}.sh"
    bad=""
    while IFS=: read -r ln _; do
        [[ -n "$ln" ]] || continue
        fn="$(awk -v L="$ln" 'NR<=L && /^[a-z_]+\(\) \{/{f=$1} END{print f}' "$src")"
        fn="${fn%%(*}"
        case "$fn" in
            "nftban_${mod}_enable"|"nftban_${mod}_disable"|"nftban_${mod}_apply"|"nftban_${mod}_teardown"|"nftban_${mod}_reconcile")
                bad="$bad $fn" ;;
        esac
    done < <(sed 's/#.*$//' "$src" | grep -n "_nftban_${mod}_detect_mode" | grep -v "_detect_mode() {" || true)
    if [[ -n "$bad" ]]; then
        fail "$mod mutation path(s) invoke the local resolver:$bad — SECOND AUTHORITY IN A WRITE PATH"
    else
        ok "$mod mutation paths hold no local mode resolver"
    fi
done

# --- LAB obligation, declared not faked (PR-4B, closes Pass A finding F-A3) ---
echo ""
echo "5. runtime classic XOR suricata..."
# ⛔ Every arm above is CALL-LEVEL: it proves which entrypoints ran, never what
# ended up in the kernel. This PASS must not be read as runtime proof.
#   CALL-LEVEL EXCLUSIVITY != RUNTIME EXCLUSIVITY
echo "  LAB   this guard proves DISPATCH, not live nft state."
echo "  LAB   required per module, independently, in live nft:"
echo "  LAB     effective_mode=classic  => suricata projection ABSENT (ip AND ip6)"
echo "  LAB     effective_mode=suricata => classic  projection ABSENT (ip AND ip6)"
echo "  LAB   observed across reload / rebuild / reset / restart / reboot."

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::plan projection contract FAILED: $FAILURES"
    exit 1
fi
echo "plan projection contract PASSED"
