#!/usr/bin/env bash
# =============================================================================
# NFTBan - mode plan / exclusivity contract (v1.229.7 PR-3A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="mode_plan_exclusivity_v1229_7_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="Enforces the v1.229.7 PR-3A mode-control contract for BOTH ddos and portscan: one operator intent, one mode resolution, one effective mode, one reconciliation path, zero cross-mode full-pipeline calls. Structural arm asserts the prohibited edges (cross-mode full apply, cross-mode config source, consumer calling the resolver, reload reaching a CLI orchestrator). Behavioural arm runs the real resolver: PLAN-N0 proves hybrid never aliases auto/classic/suricata, PLAN-N1 proves the resolver REFUSES a second resolution inside an open transaction (an earlier revision only proved a duplicate was DETECTABLE -- DETECTABLE != REFUSED), PLAN-N2 proves the provenance gate rejects both mixed and missing resolution_id while still accepting matching provenance. Written because CONFIG_EXCLUSIVITY != RUNTIME_EXCLUSIVITY: the defect that started this lane had config saying suricata while runtime ran both pipelines, so the structural arm alone cannot close it -- runtime classic-XOR-suricata is a LAB obligation, declared here and not faked."
# meta:ta.id="mode_plan_exclusivity_v1229_7_test"
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
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_portscan.sh,cli/lib/nftban/core/nftban_ddos_suricata.sh,cli/lib/nftban/core/nftban_portscan_suricata.sh,cli/lib/nftban/cli/cmd_ddos.sh,cli/lib/nftban/cli/cmd_portscan.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only; resolver run against a temp config dir)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

# Strip comments before matching: a comment RECORDING a removed call must not be
# mistaken for the call. SECURITY_GUARD_SOURCE_TEXT_CAN_MATCH_ITS_OWN_POLICY.
code_of() { [[ -f "$1" ]] && sed 's/#.*$//' "$1"; }

# ⛔ NEVER `code_of ... | grep -q`. Under `set -o pipefail`, grep -q exits as soon
# as it matches, sed can die on SIGPIPE (141), and the PIPELINE reports non-zero --
# so a REAL violation reads as "no match" and the guard prints ok. That is the
# failure direction that matters: the check goes quiet exactly when it fires.
#
# Whether it triggers is SIZE-DEPENDENT: on the ~600-line module files sed drains
# before grep exits and the raw pipe happened to work, but on cmd_firewall.sh
# (~4k lines) it did NOT -- section 9 reported ok for a violation that was
# demonstrably present. A check that works only below some file size is not a
# check. Capture first, then match.
#   SIGPIPE + pipefail + grep -q = FALSE "NOT FOUND"
code_has() { local body; body="$(code_of "$1")"; grep -qE "$2" <<<"$body"; }

echo "=== mode plan / exclusivity contract (v1.229.7 PR-3A) ==="

AUTH="$ROOT/cli/lib/nftban/lib/module_authority.sh"
for f in "$AUTH" "$ROOT/cli/lib/nftban/core/nftban_ddos.sh" "$ROOT/cli/lib/nftban/core/nftban_portscan.sh"; do
    [[ -f "$f" ]] || fail "SUBJECT_NOT_FOUND: $f"
done
[[ $FAILURES -eq 0 ]] || { echo "::error::subjects unresolved"; exit 1; }

# --- STRUCTURAL: no cross-mode full apply ------------------------------------
echo ""
echo "1. no cross-mode full apply..."
for spec in "core/nftban_ddos_suricata.sh:nftban_ddos_classic_(enable|disable)" \
            "core/nftban_portscan_suricata.sh:nftban_portscan_classic_(enable|disable)"; do
    rel="cli/lib/nftban/${spec%%:*}"; pat="${spec##*:}"
    if [[ ! -f "$ROOT/$rel" ]]; then ok "$rel absent (nothing to assert)"; continue; fi
    if code_has "$ROOT/$rel" "$pat"; then
        fail "$rel invokes the OTHER mode's full pipeline — CLASSIC_ACTIVE + SURICATA_ACTIVE = INVALID"
    else
        ok "$rel does not invoke the other mode's full pipeline"
    fi
done

# --- STRUCTURAL: no cross-mode config source ---------------------------------
echo ""
echo "2. no cross-mode config source..."
for spec in "core/nftban_ddos_suricata.sh:ddos/classic\.conf" \
            "core/nftban_portscan_suricata.sh:portscan/classic\.conf" \
            "core/nftban_ddos_classic.sh:ddos/suricata\.conf" \
            "core/nftban_portscan_classic.sh:portscan/suricata\.conf"; do
    rel="cli/lib/nftban/${spec%%:*}"; pat="${spec##*:}"
    if [[ ! -f "$ROOT/$rel" ]]; then ok "$rel absent (nothing to assert)"; continue; fi
    if code_has "$ROOT/$rel" "$pat"; then
        fail "$rel sources the OTHER mode's config — CLASSIC CONFIG IS READ ONLY BY CLASSIC MODE"
    else
        ok "$rel does not source the other mode's config"
    fi
done

# --- STRUCTURAL: only the transaction root may resolve -----------------------
echo ""
echo "3. only the reconcile root calls the resolver..."
for mod in ddos portscan; do
    rel="cli/lib/nftban/core/nftban_${mod}.sh"
    body="$(awk -v fn="nftban_${mod}_reconcile" '$0 ~ "^"fn"\\(\\) \\{"{i=1;next} i&&/^\}/{exit} i{print}' "$ROOT/$rel")"
    if [[ -z "$body" ]]; then fail "nftban_${mod}_reconcile not found"; continue; fi
    grep -q "nftban_module_resolve_plan" <<<"$body" \
        && ok "nftban_${mod}_reconcile resolves (it is the root)" \
        || fail "nftban_${mod}_reconcile does not resolve — the root must own resolution"
    # Any OTHER function in the file calling the resolver is a second authority.
    # Count INVOCATIONS only: the guard-source block references the name inside a
    # `declare -F` existence check, which is not a call. An earlier revision
    # counted it and reported a false positive against correct code --
    # A MENTION IS NOT AN INVOCATION.
    others="$(code_of "$ROOT/$rel" | grep "nftban_module_resolve_plan" | grep -vc "declare -F")"
    if [[ "$others" -gt 1 ]]; then
        fail "$rel invokes nftban_module_resolve_plan $others times — only the root may resolve"
    else
        ok "$rel invokes the resolver in exactly one place"
    fi
done

# --- STRUCTURAL: reload/rebuild must not reach a CLI orchestrator ------------
echo ""
echo "4. reload/restart arms use reconcile, not the CLI orchestrators..."
for spec in "cli/cmd_ddos.sh:nftban_ddos" "cli/cmd_portscan.sh:nftban_portscan"; do
    rel="cli/lib/nftban/${spec%%:*}"; pre="${spec##*:}"
    arm="$(awk '/^ *reload\)|^ *reload\|restart\)/{i=1} i{print} i&&/;;/{exit}' "$ROOT/$rel")"
    if [[ -z "$arm" ]]; then fail "$rel reload arm not found"; continue; fi
    if grep -qE "${pre}_(enable|disable)\b" <<<"$arm"; then
        fail "$rel reload calls ${pre}_enable/${pre}_disable — RELOAD != CONFIG MUTATION"
    else
        ok "$rel reload does not reach a CLI orchestrator"
    fi
done

# --- BEHAVIOURAL: run the REAL resolver --------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/conf.d/ddos" "$TMP/conf.d/portscan"

plan_field() {  # <module> <field> <MODE value> <available 0|1>
    local mod="$1" field="$2" modeval="$3" avail="$4" key
    key="$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )"
    printf '%s_ENABLED="true"\n%s_MODE="%s"\n' "$key" "$key" "$modeval" > "$TMP/conf.d/$mod/main.conf"
    NFTBAN_CONFIG_DIR="$TMP" bash -c "
        set -Eeuo pipefail
        source '$AUTH'
        nftban_${mod}_suricata_is_available(){ return $avail; }
        nftban_module_resolve_plan $mod" | grep "^NFTBAN_PLAN_${field}=" | cut -d= -f2-
}

echo ""
echo "5. PLAN-N0 — hybrid never aliases auto/classic/suricata..."
for mod in ddos portscan; do
    for avail in 0 1; do
        got="$(plan_field "$mod" EFFECTIVE_MODE hybrid "$avail")"
        if [[ "$got" == "unknown" ]]; then
            ok "$mod hybrid -> unknown (suricata_available=$([[ $avail == 0 ]] && echo yes || echo no))"
        else
            fail "$mod hybrid resolved to '$got' — LEGACY VALUE != AUTHORITY TO CHOOSE ITS REPLACEMENT"
        fi
    done
done

echo ""
echo "6. PLAN-N1 — the resolver REFUSES a second resolution inside a transaction..."
# ⛔ The earlier revision of this section asserted only that two resolutions
# produced DIFFERENT ids -- i.e. that a duplicate would be *detectable*.
# DETECTABLE != REFUSED. A mechanism that can tell two resolutions apart but
# still performs both leaves the second-authority defect fully open. This
# section now exercises the enforcement path and requires a non-zero status.
for mod in ddos portscan; do
    printf '%s_ENABLED="true"\n%s_MODE="auto"\n' \
        "$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )" \
        "$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )" > "$TMP/conf.d/$mod/main.conf"
    out="$(NFTBAN_CONFIG_DIR="$TMP" bash -c "
        set -Eeuo pipefail
        source '$AUTH'
        nftban_${mod}_suricata_is_available(){ return 1; }
        # First resolution: the transaction root.
        eval \"\$(nftban_module_resolve_plan $mod)\"
        export NFTBAN_PLAN_TXN_ID=\"\$NFTBAN_PLAN_RESOLUTION_ID\"
        # Second resolution inside the SAME open transaction -- must be refused.
        if nftban_module_resolve_plan $mod >/dev/null 2>&1; then
            echo ACCEPTED_SECOND_RESOLUTION
        else
            echo \"REFUSED rc=\$?\"
        fi" 2>&1 || true)"
    if grep -q "ACCEPTED_SECOND_RESOLUTION" <<<"$out"; then
        fail "$mod resolver PERFORMED a second resolution inside an open transaction — ONE TRANSACTION, ONE RESOLUTION"
    elif grep -q "REFUSED" <<<"$out"; then
        ok "$mod second resolution REFUSED inside an open transaction ($(grep -o 'rc=[0-9]*' <<<"$out" | head -1))"
    else
        fail "$mod PLAN-N1 inconclusive — neither acceptance nor refusal observed: $out"
    fi
done

echo ""
echo "7. PLAN-N2 — a consumer carrying foreign provenance is REJECTED..."
# Same correction: proving ids differ is not proving the system rejects the
# mismatch. This calls the real provenance gate and requires refusal, then runs
# a POSITIVE control so the section cannot pass by rejecting everything.
for mod in ddos portscan; do
    out="$(NFTBAN_CONFIG_DIR="$TMP" bash -c "
        set -Eeuo pipefail
        source '$AUTH'
        nftban_${mod}_suricata_is_available(){ return 1; }
        eval \"\$(nftban_module_resolve_plan $mod)\"
        export NFTBAN_PLAN_TXN_ID=\"\$NFTBAN_PLAN_RESOLUTION_ID\"
        # NEGATIVE: consumer carries a foreign resolution_id, same effective_mode.
        NFTBAN_PLAN_RESOLUTION_ID=00000000
        nftban_module_plan_provenance_ok $mod >/dev/null 2>&1 && echo MIXED_ACCEPTED || echo MIXED_REJECTED
        # NEGATIVE: provenance absent entirely (distinct failure class).
        NFTBAN_PLAN_RESOLUTION_ID=
        nftban_module_plan_provenance_ok $mod >/dev/null 2>&1 && echo EMPTY_ACCEPTED || echo EMPTY_REJECTED
        # POSITIVE control: matching provenance must be ACCEPTED.
        NFTBAN_PLAN_RESOLUTION_ID=\"\$NFTBAN_PLAN_TXN_ID\"
        nftban_module_plan_provenance_ok $mod >/dev/null 2>&1 && echo MATCH_ACCEPTED || echo MATCH_REJECTED" 2>&1 || true)"
    if ! grep -q "MIXED_REJECTED" <<<"$out"; then
        fail "$mod mixed resolution_id was ACCEPTED — a consumer may run under another transaction's plan"
    elif ! grep -q "EMPTY_REJECTED" <<<"$out"; then
        fail "$mod missing provenance was ACCEPTED — MISSING PROVENANCE != PASS"
    elif ! grep -q "MATCH_ACCEPTED" <<<"$out"; then
        fail "$mod matching provenance was REJECTED — the gate refuses everything and proves nothing"
    else
        ok "$mod provenance gate: mixed REJECTED, missing REJECTED, matching ACCEPTED"
    fi
done

echo ""
echo "9. every convergence root commits the plan binding LAST..."
# ⛔ v1.229.11 LANE 6A — THIS SECTION'S ASSERTION IS INVERTED ON PURPOSE.
# It used to require the bump BEFORE the module re-apply. That ordering was the
# defect: the generation became authoritative while the records describing it
# had not been republished yet, so every reader in between resolved UNKNOWN —
# a window entered on EVERY convergence, 453 seconds wide on srv3, and frozen
# permanently whenever the rebuild was killed inside it.
#
#	GENERATION N BECOMES AUTHORITATIVE ONLY AFTER THE WORK FOR N COMPLETES.
#
# ⛔ COMMENTS ARE STRIPPED BEFORE MATCHING. The previous form grepped the RAW
# function body, so a comment merely NAMING the bump satisfied it — this guard
# was observed passing on explanatory prose with no call behind it.
#	MENTION != WRITER. A GUARD THAT MATCHES A COMMENT PROVES NOTHING.
FW="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
if [[ ! -f "$FW" ]]; then
    fail "SUBJECT_NOT_FOUND: $FW"
else
    for fn in firewall_reload _firewall_rebuild_core firewall_reset; do
        body="$(awk -v fn="$fn" '$0 ~ "^"fn"\\(\\) \\{"{i=1;next} i&&/^\}/{exit} i{print}' "$FW" \
                | sed 's/#.*$//')"
        if [[ -z "$body" ]]; then
            fail "convergence root $fn NOT FOUND — cannot prove its commit ordering"
            continue
        fi
        # (a) the root must OPEN a transaction, and must NOT advance the
        #     generation by any other means.
        if ! grep -q "nftban_plan_txn_begin" <<<"$body"; then
            fail "$fn converges WITHOUT opening a convergence transaction"
            continue
        fi
        if grep -q "nftban_plan_generation_bump" <<<"$body"; then
            fail "$fn still advances the generation outside the commit — THE PRE-v1.229.11 DEFECT"
            continue
        fi
        begin_at="$(grep -n "nftban_plan_txn_begin"          <<<"$body" | head -1 | cut -d: -f1)"
        conv_at="$( grep -nE "nftban (ddos|portscan) reload" <<<"$body" | head -1 | cut -d: -f1)"
        conv_last="$(grep -nE "nftban (ddos|portscan) reload" <<<"$body" | tail -1 | cut -d: -f1)"
        commit_at="$(grep -n "nftban_plan_txn_commit"        <<<"$body" | head -1 | cut -d: -f1)"
        # (b) the transaction opens BEFORE any module resolves, so every record
        #     it publishes is stamped with this transaction's target.
        if [[ -n "$conv_at" && -n "$begin_at" && "$begin_at" -ge "$conv_at" ]]; then
            fail "$fn opens its transaction AFTER converging a module (line $begin_at >= $conv_at)"
        else
            ok "$fn opens its transaction before it converges (begin@$begin_at, first convergence@${conv_at:-none})"
        fi
        # (c) THE COMMIT IS LAST. This is the invariant of the lane.
        if [[ -z "$commit_at" ]]; then
            fail "$fn never commits — the generation would never advance for a completed convergence"
        elif [[ -n "$conv_last" && "$commit_at" -le "$conv_last" ]]; then
            fail "$fn commits the generation BEFORE its last module converges (line $commit_at <= $conv_last) — it would publish a generation whose work had not finished"
        else
            ok "$fn commits only after every module has converged (commit@$commit_at, last convergence@${conv_last:-none})"
        fi
        # (d) a root that opens a transaction must converge BOTH modules.
        missing=""
        grep -q "nftban ddos reload"     <<<"$body" || missing="$missing ddos"
        grep -q "nftban portscan reload" <<<"$body" || missing="$missing portscan"
        if [[ -n "$missing" ]]; then
            fail "$fn advances the generation but does not converge:$missing — an old plan would survive a render it does not describe"
        else
            ok "$fn converges both module plans it invalidates"
        fi
    done
    # A convergence path must never rewrite durable operator intent. `enable`
    # persists MODULE_ENABLED and restarts the daemon; reload does neither.
    #   RELOAD != CONFIG MUTATION
    # Match INVOCATIONS only. `Run: nftban ddos enable` inside an operator-facing
    # message is advice, not a call, and an earlier revision failed on it.
    #   A MENTION IS NOT AN INVOCATION.
    if code_has "$FW" '(^|[;&|]|then |else |do )[[:space:]]*nftban (ddos|portscan) (enable|disable)\b'; then
        fail "$(basename "$FW") drives a module through enable/disable — a convergence path must not rewrite durable intent"
    else
        ok "$(basename "$FW") drives modules through reload only"
    fi
fi

echo ""
echo "10. the binding has exactly one writer topology..."
# (a) ⛔ v1.229.11 LANE 6A: EXACTLY ONE FUNCTION IN THE TREE MAY ADVANCE THE
#     GENERATION, AND IT IS THE COMMIT. The standalone bump primitive is deleted;
#     an unaccounted advance announces a convergence that nothing performed.
#       THE GENERATION ADVANCES IN nftban_plan_txn_commit, OR NOWHERE.
bump_sites="$(grep -rlE "^[^#]*nftban_plan_generation_bump" "$ROOT/cli/lib/nftban" 2>/dev/null \
              | grep -v "/tests/" | sort || true)"
if [[ -z "$bump_sites" ]]; then
    ok "the standalone generation-bump primitive no longer exists anywhere in the tree"
else
    fail "generation-bump primitive still present in: $bump_sites — it can advance the binding outside a transaction"
fi
# The generation FILE must have exactly one writer, and that writer must be the
# commit. Located by OWNING FUNCTION, never by line number.
AUTHSRC="$ROOT/cli/lib/nftban/lib/module_authority.sh"
gen_writers="$(awk '
    /^[a-z_]+\(\) \{/ { fn=$1; sub(/\(\).*/,"",fn) }
    /^[^#]*mv -f "\$tmp" "\$gf"/ { print fn }
' "$AUTHSRC" | sort -u)"
if [[ "$gen_writers" == "nftban_plan_txn_commit" ]]; then
    ok "the generation file is written only by nftban_plan_txn_commit"
else
    fail "generation-file writer(s) = [${gen_writers:-none}], expected exactly nftban_plan_txn_commit"
fi
# Transactions may be OPENED only from the declared convergence roots plus the
# two module resolve roots (which own a standalone reload's transaction).
txn_sites="$(grep -rlE "^[^#]*nftban_plan_txn_begin" "$ROOT/cli/lib/nftban" 2>/dev/null \
             | grep -v "/tests/" | grep -v "module_authority.sh" | sort || true)"
txn_expected="$(printf '%s\n' \
    "$ROOT/cli/lib/nftban/cli/cmd_firewall.sh" \
    "$ROOT/cli/lib/nftban/core/nftban_ddos.sh" \
    "$ROOT/cli/lib/nftban/core/nftban_portscan.sh" | sort)"
if [[ "$txn_sites" == "$txn_expected" ]]; then
    ok "convergence transactions are opened only by the declared roots"
else
    fail "unexpected transaction-open site(s): ${txn_sites:-none}"
fi
# (b) the record may be written ONLY from the module's resolve root. A writer
#     anywhere else could stamp the CURRENT generation onto a plan nobody
#     resolved -- a forged "current" witness.
#       STAMPING MUST IMPLY RESOLVING.
for mod in ddos portscan; do
    src="$ROOT/cli/lib/nftban/core/nftban_${mod}.sh"
    # ⛔ v1.229.11: records are addressed by generation via nftban_plan_record_path,
    #    so the literal "module-plan-<mod>.env" no longer appears in the writer.
    #    LOCATE THE WRITER BY THE CALL IT MAKES, NOT BY A FILENAME IT NO LONGER SPELLS.
    wln="$(grep -nE "^[^#]*nftban_plan_record_path" "$src" | head -1 | cut -d: -f1)"
    if [[ -z "$wln" ]]; then
        fail "$mod publishes no plan record — the Go validator would have nothing to read"
        continue
    fi
    owner_fn="$(awk -v L="$wln" 'NR<=L && /^nftban_[a-z_]+\(\) \{/{f=$1} END{print f}' "$src")"
    owner_fn="${owner_fn%%(*}"
    if [[ "$owner_fn" == "nftban_${mod}_reconcile" ]]; then
        ok "$mod plan record is written only by its resolve root"
    else
        fail "$mod plan record is written by '${owner_fn:-unknown}', not nftban_${mod}_reconcile — STAMPING MUST IMPLY RESOLVING"
    fi
done

# --- 11. MODE CONFIG OWNERSHIP IS CROSS-LANGUAGE ---------------------------
echo ""
echo "11. mode-config ownership across BOTH languages..."
# ⛔ Section 2 proves "classic.conf read only by classic mode" over
# cli/lib/nftban/core/*.sh -- SHELL ONLY. A Go consumer choosing classic.conf vs
# suricata.conf sat outside that subject population and was found by hand
# (OPEN_MODULE_GO_AUTO_CONFIG_SOURCE_PRE_RESOLUTION).
#   A GUARD THAT PROVES SHELL CONSUMERS ARE CLEAN
#   DOES NOT ESTABLISH REPOSITORY-WIDE OWNERSHIP.
#
# The defect shape is a file that can choose BETWEEN the two mode configs. A
# mode module naming only its OWN config is not a selector, and neither is a
# declaration file that lists both. Population = references BOTH, minus data.
SELECTORS=()
while IFS= read -r f; do
    body="$(sed 's|//.*$||; s/#.*$//' "$f")"
    grep -q 'classic\.conf'  <<<"$body" || continue
    grep -q 'suricata\.conf' <<<"$body" || continue
    case "$f" in *.json|*.yaml|*.yml) continue ;; esac   # declarations, not selectors
    SELECTORS+=("$f")
done < <(grep -rlE '"(classic|suricata)\.conf"|/(classic|suricata)\.conf' \
            "$ROOT/cli/lib/nftban" "$ROOT/internal" "$ROOT/cmd" 2>/dev/null \
            | grep -vE "/tests/|_test\.(go|sh)$" | sort -u)

# ⛔ SUBJECT-POPULATION RECONCILIATION. Declare the INTENDED population and
# assert the ACTUAL one matches it. Printing a count is not asserting one: narrow
# the search path and the population silently shrinks while every row still says
# ok -- which is precisely how the Go selector stayed invisible until Pass A.
#   INTENDED != ACTUAL  =>  EITHER EXPAND THE GUARD OR NARROW THE CLAIM.
_sel_shell=0 _sel_go=0
for _s in "${SELECTORS[@]}"; do
    case "$_s" in *.sh) _sel_shell=$((_sel_shell+1)) ;; *.go) _sel_go=$((_sel_go+1)) ;; esac
done
if [[ ${#SELECTORS[@]} -eq 0 ]]; then
    fail "no mode-config SELECTOR found — the population cannot be empty"
elif [[ $_sel_go -lt 2 ]]; then
    fail "selector population contains $_sel_go Go file(s); the cross-language claim requires BOTH Go modules — the subject has silently narrowed"
elif [[ $_sel_shell -lt 1 ]]; then
    fail "selector population contains no shell file; the subject has silently narrowed"
else
    ok "mode-config selector population: ${#SELECTORS[@]} file(s) — shell=$_sel_shell go=$_sel_go (both languages present)"
fi
for src in "${SELECTORS[@]}"; do
    rel="${src#"$ROOT"/}"
    body="$(sed 's|//.*$||; s/#.*$//' "$src")"
    case "$rel" in
        *nftban_ddos.sh|*nftban_portscan.sh|internal/ddos/*|internal/portscan/*)
            # IN the v1.229.7 declared subject population: selection MUST be
            # plan-derived, and must not come from an availability probe.
            if grep -qE 'ReadEffectiveMode|NFTBAN_PLAN_EFFECTIVE_MODE|nftban_module_report_modes' <<<"$body"; then
                if grep -qE '(suricataAvail|_is_available)[^\n]*\?|Mode == "auto" && m\.suricataAvail' <<<"$body"; then
                    fail "$rel still selects a mode config from an availability probe"
                else
                    ok "$rel selects its mode config from the plan"
                fi
            else
                fail "$rel chooses between mode configs with NO plan-derived selection — CONFIG SOURCE MUST FOLLOW THE PLAN"
            fi
            ;;
        *)
            # OUTSIDE the .7 population. Reported, never silently passed: the
            # guard's claim covers ddos+portscan, and saying so is the point.
            #   SUBJECT BOUNDARY MUST MATCH THE CLAIM.
            echo "  NOTE  $rel selects between mode configs but is OUTSIDE the v1.229.7 subject"
            echo "        population (ddos + portscan). Not asserted here; see the register."
            ;;
    esac
done

# --- 12. PLAN BINDING MUST BE VALID BEFORE PUBLICATION (PR-5) ---------------
echo ""
echo "12. an unbound plan is never made durable..."
# ⛔ THE MOTIVATING DEFECT. The publisher interpolated the generation straight
# into the record. When the substitution yielded nothing it wrote
# `NFTBAN_PLAN_BOUND_GENERATION=` and published anyway. The validator then
# correctly rejected the unbound plan as UNKNOWN -> health degraded ->
# `firewall rebuild` exited 1. Measured on a clean package-native host:
#   pre-v1.229.7 rebuild rc=0 3/3   ·   v1.229.7 rebuild rc=1 5/5   (both distros)
#
#   AN INVALID PLAN MUST NEVER BE MADE DURABLE
#   MERELY SO A LATER VALIDATOR CAN REJECT IT.
for mod in ddos portscan; do
    K="$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )"
    bind_probe() {   # <generation-authority-behaviour> -> "<rc>|<record-state>"
        local behaviour="$1" d; d="$(mktemp -d)"
        mkdir -p "$d/conf.d/$mod" "$d/run"
        printf '%s_ENABLED="true"\n%s_MODE="classic"\n' "$K" "$K" > "$d/conf.d/$mod/main.conf"
        local out rc
        out="$(NFTBAN_CONFIG_DIR="$d" NFTBAN_PLAN_RECORD_DIR="$d/run" \
               NFTBAN_PLAN_GENERATION_FILE="$d/run/convergence-generation" \
           NFTBAN_RUN_DIR="$d/run" \
               NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" bash -c "
            set -Eeuo pipefail
            source '$ROOT/cli/lib/nftban/lib/module_authority.sh'
            source '$ROOT/cli/lib/nftban/core/nftban_${mod}.sh' 2>/dev/null || true
            printf '7\n' > '$d/run/convergence-generation'
            case '$behaviour' in
                valid)  : ;;                                                     # P
                empty)  nftban_plan_generation_current(){ printf ''; } ;;        # N1
                fail)   nftban_plan_generation_current(){ return 3; } ;;         # N2
            esac
            nftban_${mod}_suricata_is_available(){ return 1; }
            nftban_${mod}_apply(){ return 0; }; nftban_${mod}_teardown(){ return 0; }
            _nftban_${mod}_log(){ :; }
            nftban_${mod}_reconcile >/dev/null 2>&1; echo \"RC=\$?\"" 2>&1 || true)"
        rc="$(grep -oE 'RC=[0-9]+' <<<"$out" | tail -1 | cut -d= -f2)"
        # ⛔ v1.229.11: records are addressed BY GENERATION. Looking only at the
        # old unsuffixed path made every outcome report NO_RECORD — including the
        # POSITIVE control — so the negative controls were passing because the
        # probe could not see a record at all, not because publication was
        # refused.
        #     A CONTROL THAT CANNOT SEE THE ARTIFACT PROVES NOTHING ABOUT IT.
        local g state rec
        rec="$(find "$d/run" -maxdepth 1 -name "module-plan-$mod.env*" 2>/dev/null | sort | tail -1)"
        g="$([[ -n "$rec" ]] && sed -n 's/^NFTBAN_PLAN_BOUND_GENERATION=//p' "$rec" 2>/dev/null || true)"
        if [[ -z "$rec" ]]; then state=NO_RECORD
        elif [[ -z "$g" ]]; then state=UNBOUND_RECORD
        else state="BOUND($g)"; fi
        local committed; committed="$(cat "$d/run/convergence-generation" 2>/dev/null || echo "?")"
        rm -rf "$d"; echo "${rc:-?}|$state|gen=$committed"
    }

    # P — a valid generation yields a record bound to the TRANSACTION TARGET
    #     (current 7 -> target 8), and the generation advances to 8 ONLY at the
    #     commit, once the module has actually reconciled.
    r="$(bind_probe valid)"
    [[ "$r" == "0|BOUND(8)|gen=8" ]] \
        && ok "$mod P: reconcile bound the record to target 8 and committed generation 8" \
        || fail "$mod P: expected 0|BOUND(8)|gen=8, got $r"

    # N1 — resolver returns EMPTY. This is the exact production signature.
    r="$(bind_probe empty)"
    if [[ "$r" == 0\|* ]]; then
        fail "$mod N1: publication SUCCEEDED with an empty generation ($r) — EMPTY BINDING MUST BE UNREPRESENTABLE"
    elif [[ "$r" == *"UNBOUND_RECORD" ]]; then
        fail "$mod N1: an unbound record was made durable ($r)"
    else
        ok "$mod N1: empty generation -> publication refused, no usable record ($r)"
    fi

    # N2 — resolver FAILS (non-zero). Must not fall back to a default.
    r="$(bind_probe fail)"
    if [[ "$r" == 0\|* || "$r" == *"UNBOUND_RECORD" ]]; then
        fail "$mod N2: resolver failure still produced a record ($r)"
    else
        ok "$mod N2: resolver failure -> publication refused ($r)"
    fi
done

# --- 13. RUNTIME / IPC AUTHORITY BOUNDARY (PR-5) ----------------------------
echo ""
echo "13. no .7 component acquires authority over another lifecycle's runtime resource..."
# ⛔ /run/nftban is declared by systemd-tmpfiles as `0755 nftban nftban` and holds
# the daemon socket. A PR-5 revision used `mkdir -p` there, which recreated it
# ROOT-owned and produced an unsafe-path-transition report; destroying that
# directory in the lab removed the socket, IPC apply failed, module chains went
# 16 -> 6, health went DOWN and rebuild exited 1.
#   ESTABLISHING A PREREQUISITE != ACQUIRING AUTHORITY OVER THE PREREQUISITE.
_v7_files=(lib/module_authority.sh core/nftban_ddos.sh core/nftban_portscan.sh cli/cmd_firewall.sh)
seize=""
for rel in "${_v7_files[@]}"; do
    src="$ROOT/cli/lib/nftban/$rel"
    [[ -f "$src" ]] || continue
    if code_has "$src" '(mkdir|chown|chmod|install -d|rm -rf)[^|]*(/run/nftban|RECORD_DIR"?\}?"?$|RUN_DIR)'; then
        seize="$seize $rel"
    fi
done
if [[ -n "$seize" ]]; then
    fail "these .7 files mutate the tmpfiles-owned runtime directory:$seize"
else
    ok "no .7 file creates/chowns/removes the runtime directory"
fi

# N4 — a failed publication must not leave a current-looking record.
for mod in ddos portscan; do
    d="$(mktemp -d)"; mkdir -p "$d/conf.d/$mod" "$d/run"
    K="$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )"
    printf '%s_ENABLED="true"\n%s_MODE="classic"\n' "$K" "$K" > "$d/conf.d/$mod/main.conf"
    printf '7\n' > "$d/run/convergence-generation"
    # ⛔ v1.229.11: THE OBSTACLE MUST SIT WHERE THE WRITER ACTUALLY WRITES.
    # Records are now addressed by generation, so the writer targets
    # module-plan-<mod>.env.8 (current 7 -> target 8). Obstructing the old
    # unsuffixed path left publication free to SUCCEED, and this control then
    # counted the legitimately published record as an orphan — passing or
    # failing for reasons unrelated to the defect it exists to catch.
    #     A NEGATIVE CONTROL MUST STILL HIT THE MOTIVATING DEFECT.
    mkdir -p "$d/run/module-plan-$mod.env.8"
    NFTBAN_CONFIG_DIR="$d" NFTBAN_PLAN_RECORD_DIR="$d/run" \
    NFTBAN_PLAN_GENERATION_FILE="$d/run/convergence-generation" \
           NFTBAN_RUN_DIR="$d/run" \
    NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" bash -c "
        source '$AUTH'
        source '$ROOT/cli/lib/nftban/core/nftban_${mod}.sh' 2>/dev/null || true
        nftban_${mod}_suricata_is_available(){ return 1; }
        nftban_${mod}_apply(){ return 0; }; nftban_${mod}_teardown(){ return 0; }
        _nftban_${mod}_log(){ :; }
        nftban_${mod}_reconcile" >/dev/null 2>&1 || true
    # ⛔ `|| true` is load-bearing. This control DELIBERATELY makes publication
    # fail, so the reconcile root correctly returns non-zero — and under
    # `set -Eeuo pipefail` that aborted the whole suite before the assertion
    # below could run. Previously the obstacle sat at a path the writer no longer
    # used, publication SUCCEEDED, and the abort never surfaced.
    #     A CONTROL MUST TOLERATE THE FAILURE IT EXISTS TO INDUCE.
    # Count STAGING temporaries only — the obstructing directory itself also
    # matches a bare module-plan-<mod>.env.* glob.
    leftover="$(find "$d/run" -maxdepth 1 -type f -name "module-plan-$mod.env.*.tmp.*" 2>/dev/null | wc -l)"
    if [[ "$leftover" -eq 0 ]]; then
        ok "$mod N4: failed publication leaves no partial/temp record"
    else
        fail "$mod N4: $leftover orphaned temp record(s) survived a failed publication"
    fi
    rm -rf "$d"
done

# --- 14. auto MUST RESOLVE WITH ITS PREDICATE LOADED (PR-5C) -----------------
# `auto` is decided by calling nftban_<mod>_suricata_is_available. If the
# reconcile root resolves BEFORE that function has been sourced, the resolver
# records basis `auto_suricata_module_not_loaded` and falls back to classic --
# so the module can never select suricata regardless of the environment.
# WITNESSED 2026-08-24 on lab2/DEB and lab4/RPM: portscan resolved classic with
# its availability predicate observed TRUE on both families, because portscan
# loads optional modules from a function the enable/apply paths call only AFTER
# resolution, while ddos sources its suricata module at FILE scope.
#
#   RESOLVING BEFORE THE INPUTS ARE LOADED IS NOT A RESOLUTION.
#
# The subject is the reconcile ROOT body, and the assertion is ORDERING: a
# loader must appear before the resolve call. Mere presence of a loader
# somewhere in the file is exactly the condition that shipped broken.
#   MENTION != ORDERING
echo ""
echo "14. auto resolves with its predicate loaded..."
for mod in ddos portscan; do
    f="$ROOT/cli/lib/nftban/core/nftban_${mod}.sh"
    if [[ ! -f "$f" ]]; then fail "SUBJECT_NOT_FOUND: $f"; continue; fi

    # File-scope sourcing satisfies the precondition unconditionally (ddos).
    file_scope=0
    if awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\) *\{/{d=1} /^\}/{d=0} !d && /source .*nftban_'"$mod"'_suricata\.sh/{found=1} END{exit !found}' "$f"; then
        file_scope=1
    fi

    # ⛔ STRIP COMMENTS BEFORE MATCHING. The first revision of this guard passed
    # its own negative control: the explanatory comment inside the reconcile body
    # names _nftban_<mod>_load_modules, so deleting the actual CALL still matched.
    # A guard that reads prose is measuring documentation, not behaviour.
    #   MENTION != ORDERING  (this guard's own subject line)
    body="$(awk '/^nftban_'"$mod"'_reconcile\(\) \{/{i=1} i{print} i&&/^\}/{exit}' "$f" \
            | sed 's/[[:space:]]*#.*$//')"
    if [[ -z "$body" ]]; then
        fail "$mod: nftban_${mod}_reconcile not found — cannot assert resolution ordering"
        continue
    fi

    # ⛔ `|| true` above is load-bearing, not cosmetic. Under `set -Eeuo pipefail`
    # a no-match grep inside a command substitution makes the ASSIGNMENT fail, so
    # the script aborted at exactly the case this section exists to detect --
    # exit 1 with no diagnosis, and every later section skipped. A guard that
    # dies on its own defect case reports the right exit code for the wrong
    # reason and stops being readable evidence.
    #   ABORTING != REPORTING
    # Non-vacuity: the resolve call MUST be present, else the ordering assertion
    # below would pass on a body that never resolves at all.
    resolve_ln="$(grep -n "nftban_module_resolve_plan" <<<"$body" | head -1 | cut -d: -f1)" || true
    if [[ -z "$resolve_ln" ]]; then
        fail "$mod: reconcile root does not call nftban_module_resolve_plan — subject invalid"
        continue
    fi

    if [[ $file_scope -eq 1 ]]; then
        ok "$mod: suricata predicate sourced at file scope (precondition unconditional)"
        continue
    fi

    loader_ln="$(grep -nE "_nftban_${mod}_load_modules|source .*nftban_${mod}_suricata\.sh" <<<"$body" | head -1 | cut -d: -f1)" || true
    if [[ -z "$loader_ln" ]]; then
        fail "$mod: reconcile resolves \`auto\` without loading nftban_${mod}_suricata.sh — basis will be auto_suricata_module_not_loaded and suricata can NEVER be selected"
    elif (( loader_ln < resolve_ln )); then
        ok "$mod: predicate loaded (line $loader_ln) before resolution (line $resolve_ln)"
    else
        fail "$mod: predicate loaded at line $loader_ln but resolution happens at line $resolve_ln — LOADED AFTER RESOLVING IS NOT LOADED"
    fi
done

# --- LAB OBLIGATION, declared not faked --------------------------------------
echo ""
echo "8. runtime classic XOR suricata..."
echo "  LAB   CONFIG_EXCLUSIVITY != RUNTIME_EXCLUSIVITY — this arm CANNOT be proven here."
echo "  LAB   required per module, independently: effective_mode=classic  => suricata path ABSENT"
echo "  LAB                                       effective_mode=suricata => classic  path ABSENT"
echo "  LAB   observed in live nft state, across restart / reload / rebuild / reboot."

echo ""
if [[ $FAILURES -gt 0 ]]; then
    echo "::error::mode plan / exclusivity contract FAILED: $FAILURES"
    exit 1
fi
echo "mode plan / exclusivity contract PASSED (structural + PLAN-N0/N1/N2; runtime XOR is a LAB obligation)"
