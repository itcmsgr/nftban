#!/usr/bin/env bash
# =============================================================================
# NFTBan - mutation-result suppression guard (v1.233.1, claim-truth C-f)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-mutation-rc-suppression"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-24"
# meta:description="Static guard for the claim-truth contract (V1_234_0 §2 C-f, owner ruling §6: ships now). Flags a call to a MUTATION PRIMITIVE whose result is suppressed or discarded inside a function that later makes a success claim. Mutation primitives: IPC writers (nft_ipc_*), fragment writers (nft_fragment_apply/delete_object/remove_jump), the durable-intent writer (nftban_module_set_enabled), the convergence commit (nftban_plan_txn_commit), module lifecycle entrypoints (nftban_<x>_{enable,disable,teardown,apply,reconcile,remove_rules,add_rules,add_jump,create_chain}), direct nft add/delete/flush/insert/replace/-f, and systemctl start/stop/restart/reload. Suppression forms: `|| true`, `|| :` (with or without 2>/dev/null) and a BARE call whose status is neither tested, captured on the next line, nor returned as the function's last statement. A success claim is a later line printing a success mark or success wording, or a final `return 0`. Exceptions need an in-line `# nftban:rc-suppression-ok: <justification>` on the call line or the line above, with a real justification. Findings are a RATCHET against scripts/ci/data/mutation-rc-suppression-baseline.tsv: a finding not in the baseline FAILS (new debt), a baseline row that no longer reproduces FAILS (stale; remove it). Why: nftban_portscan_teardown and nftban_ddos_teardown converted a child failure into parent success (dns4/lab3 witness, v1.233.0). Static analysis only: reads files, executes nothing."
# meta:input="cli/lib/nftban/core/*.sh, scripts/ci/data/mutation-rc-suppression-baseline.tsv"
# meta:output="one line per finding; MUTATION_RC_SUPPRESSION_* counters; exit 0 clean / 1 violation / 2 usage"
# meta:depends="bash,awk,sort"
# meta:inventory.files="scripts/ci/data/mutation-rc-suppression-baseline.tsv"
# meta:inventory.binaries="bash,awk,sort"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="check_mutation_rc_suppression"
# meta:ta.owner="cli"
# meta:ta.module="claim-truth"
# meta:ta.execution_class="CI_STATIC"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# Usage:
#   check-mutation-rc-suppression.sh                 gate the tree against the baseline
#   check-mutation-rc-suppression.sh --list          print findings only (no gate)
#   check-mutation-rc-suppression.sh --emit-baseline print the baseline for the current tree
#   check-mutation-rc-suppression.sh --root <dir> [--baseline <file>] ...
#
# Scope, stated so a reader can judge false negatives:
#   * the subject is cli/lib/nftban/core/*.sh (the module orchestrators). A call
#     through a variable ("$fn") is not recognised as a primitive.
#   * function extent is `name() {` at column 0 to the next `}` at column 0, the
#     repository's uniform style (same heuristic as check-mode-authority.sh).
#   * a finding key is file|function|primitive|form (no line numbers), so an
#     unrelated edit does not churn the baseline; repeated hits of one key in one
#     function count once.
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE=""
MODE="gate"
while (( $# )); do
    case "$1" in
        --root)          ROOT="$(cd "$2" && pwd)"; shift 2 ;;
        --baseline)      BASELINE="$2"; shift 2 ;;
        --list)          MODE="list"; shift ;;
        --emit-baseline) MODE="emit"; shift ;;
        -h|--help)       sed -n '2,/^set -Eeuo/p' "$0"; exit 0 ;;
        *) echo "usage: $0 [--root DIR] [--baseline FILE] [--list|--emit-baseline]" >&2; exit 2 ;;
    esac
done
[[ -n "$BASELINE" ]] || BASELINE="$ROOT/scripts/ci/data/mutation-rc-suppression-baseline.tsv"

# scan_file <file> <relpath> — emits TSV: rel<TAB>line<TAB>function<TAB>primitive<TAB>form
# plus "ANNOTATION_INVALID" rows for exceptions without a justification.
scan_file() {
    awk -v REL="$2" '
    function strip_quotes(s,   out) {
        # drop "..." and '"'"'...'"'"' so a primitive named inside a message is not a call
        gsub(/"([^"\\]|\\.)*"/, "\"\"", s)
        gsub(/'"'"'[^'"'"']*'"'"'/, "'"''"'", s)
        return s
    }
    function is_code(s) { return (s !~ /^[[:space:]]*#/ && s !~ /^[[:space:]]*$/) }
    function prim_of(s,   m) {
        # Read-only IPC helpers are not mutation primitives.
        gsub(/nft_ipc_(is_[a-z0-9_]+|success|error|ping|get_[a-z0-9_]+|list_[a-z0-9_]+|status[a-z0-9_]*|check_[a-z0-9_]+)/, "", s)
        if (match(s, /(^|[^A-Za-z0-9_$])(nft_ipc_[a-z0-9_]+|nft_fragment_(apply|delete_object|remove_jump)|nftban_module_set_enabled|nftban_plan_txn_commit|nftban_[a-z0-9_]+_(enable|disable|teardown|apply|reconcile|remove_rules|add_rules|add_jump|create_chain))([^A-Za-z0-9_]|$)/)) {
            m = substr(s, RSTART, RLENGTH)
            gsub(/^[^A-Za-z_]+|[^A-Za-z0-9_]+$/, "", m)
            return m
        }
        if (match(s, /(^|[^A-Za-z0-9_$-])nft[[:space:]]+(-[a-z]+[[:space:]]+)*(add|delete|flush|insert|replace|-f)([[:space:]]|$)/)) {
            m = substr(s, RSTART, RLENGTH); gsub(/^[^n]+/, "", m); gsub(/[[:space:]]+$/, "", m); gsub(/[[:space:]]+/, "_", m)
            return m
        }
        if (match(s, /(^|[^A-Za-z0-9_$-])systemctl[[:space:]]+(restart|start|stop|reload)([[:space:]]|$)/)) {
            m = substr(s, RSTART, RLENGTH); gsub(/^[^s]+/, "", m); gsub(/[[:space:]]+$/, "", m); gsub(/[[:space:]]+/, "_", m)
            return m
        }
        return ""
    }
    function annotated(i,   j) {
        if (L[i] ~ /#[[:space:]]*nftban:rc-suppression-ok:/) return check_note(L[i], i)
        j = i - 1
        if (j >= 1 && L[j] ~ /^[[:space:]]*#[[:space:]]*nftban:rc-suppression-ok:/) return check_note(L[j], j)
        return 0
    }
    function check_note(s, ln,   n) {
        n = s; sub(/.*nftban:rc-suppression-ok:[[:space:]]*/, "", n); gsub(/[[:space:]]+$/, "", n)
        if (length(n) < 12) { printf "%s\t%d\t-\t-\tANNOTATION_INVALID\n", REL, ln; return 0 }
        return 1
    }
    function claims_success_after(i, e,   k, s) {
        for (k = i + 1; k < e; k++) {
            s = L[k]
            if (!is_code(s)) continue
            if (s ~ /✅/) return 1
            if (s ~ /(echo|printf|_log[a-z_]*|log_[a-z_]+)[[:space:]].*([Ss]uccess|successfully|[Ee]nabled|[Dd]isabled|ENABLED|DISABLED|removed|applied|now active|[Cc]omplete)/) return 1
        }
        # final statement of the function
        for (k = e - 1; k > i; k--) { if (is_code(L[k])) break }
        if (k > i && L[k] ~ /^[[:space:]]*return[[:space:]]+0[[:space:]]*$/) return 1
        return 0
    }
    function rc_consumed(i, e, s,   k, t) {
        t = s; sub(/^[[:space:]]+/, "", t)
        if (t ~ /^(if|elif|while|until|!)[[:space:]]/) return 1
        if (t ~ /^(&&|\|\|)/) return 1                                    # continuation of a tested list
        if (s ~ /;[[:space:]]*(then|do)[[:space:]]*$/) return 1            # tail of an if/while condition
        if (t ~ /^(return|local|export|declare|readonly)[[:space:]]/) return 1
        if (t ~ /^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=/) return 1        # capture: x=$(prim)
        if (s ~ /\|\|/) return 1                                          # handled (|| true is judged separately)
        if (s ~ /\|[[:space:]]*$/ || s ~ /\\[[:space:]]*$/) return 1      # continued line: not judged
        for (k = i + 1; k < e; k++) {
            if (!is_code(L[k])) continue
            if (L[k] ~ /\$\?/) return 1                                    # rc captured on the next line
            break
        }
        # Last statement of the function (possibly nested in blocks that close
        # right before the function ends): its status IS the function status.
        for (k = i + 1; k < e; k++) {
            if (!is_code(L[k])) continue
            if (L[k] ~ /^[[:space:]]*(fi|done|esac|;;|\})[[:space:]]*$/) continue
            return 0
        }
        return 1
    }
    { L[NR] = $0 }
    END {
        n = NR
        for (i = 1; i <= n; i++) {
            if (L[i] !~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/) continue
            fname = L[i]; sub(/\(\).*/, "", fname)
            e = 0
            for (j = i + 1; j <= n; j++) if (L[j] ~ /^\}[[:space:]]*$/) { e = j; break }
            if (e == 0) continue
            for (k = i + 1; k < e; k++) {
                raw = L[k]
                if (!is_code(raw)) continue
                s = strip_quotes(raw)
                sub(/[[:space:]]#.*$/, "", s)
                t = s; sub(/^[[:space:]]+/, "", t)
                if (t ~ /^(echo|printf|type|declare|command|hash|unset|_log|_nftban_[a-z_]*_log|nftban_log)[[:space:]]/) continue
                if (t ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)/) continue
                p = prim_of(s)
                if (p == "") continue
                form = ""
                if (s ~ /\|\|[[:space:]]*(true|:)[[:space:]]*(;|$|\))/) {
                    form = (s ~ /(2>\/dev\/null|&>\/dev\/null|>\/dev\/null[[:space:]]+2>&1)/) ? "STDERR_HIDDEN_OR_TRUE" : "OR_TRUE"
                } else if (!rc_consumed(k, e, s)) {
                    form = "DISCARDED_RC"
                }
                if (form == "") continue
                if (!claims_success_after(k, e)) continue
                if (annotated(k)) continue
                printf "%s\t%d\t%s\t%s\t%s\n", REL, k, fname, p, form
            }
            i = e
        }
    }' "$1"
}

collect() {
    local f rel
    while IFS= read -r f; do
        rel="${f#"$ROOT"/}"
        scan_file "$f" "$rel"
    done < <(find "$ROOT/cli/lib/nftban/core" -maxdepth 1 -name '*.sh' -type f 2>/dev/null | sort)
}

RAW="$(collect)"
INVALID="$(awk -F'\t' '$5=="ANNOTATION_INVALID"' <<<"$RAW")"
FINDINGS="$(awk -F'\t' '$5!="ANNOTATION_INVALID" && NF==5' <<<"$RAW")"
KEYS="$(awk -F'\t' 'NF==5 {print $1"|"$3"|"$4"|"$5}' <<<"$FINDINGS" | sort -u)"

if [[ "$MODE" == "emit" ]]; then
    echo "# mutation-rc-suppression-baseline.tsv — OPEN findings of scripts/ci/check-mutation-rc-suppression.sh"
    echo "# A RATCHET, not an allowlist: every row is a live defect (a mutation result suppressed or"
    echo "# discarded inside a function that later claims success). A new finding fails the gate;"
    echo "# a row that stops reproducing fails the gate until it is removed. Fix the code, then"
    echo "# delete the row. Regenerate: scripts/ci/check-mutation-rc-suppression.sh --emit-baseline"
    echo "# key = file|function|primitive|form"
    [[ -n "$KEYS" ]] && printf '%s\n' "$KEYS"
    exit 0
fi

if [[ "$MODE" == "list" ]]; then
    [[ -n "$FINDINGS" ]] && printf '%s\n' "$FINDINGS"
    [[ -n "$INVALID" ]] && printf '%s\n' "$INVALID"
    printf 'MUTATION_RC_SUPPRESSION_FINDINGS = %s\n' "$(grep -c . <<<"$KEYS" || true)"
    exit 0
fi

FAIL=0
echo "=== mutation-result suppression guard (claim-truth C-f) ==="
if [[ ! -f "$BASELINE" ]]; then
    echo "  [FAIL] baseline missing: $BASELINE"; exit 1
fi
# An empty baseline is legitimate: grep's "no line selected" (rc 1) is not a failure here.
BASE_KEYS="$(grep -vE '^[[:space:]]*(#|$)' "$BASELINE" | sort -u || true)"
NEW="$(comm -23 <(printf '%s\n' "$KEYS" | sed '/^$/d') <(printf '%s\n' "$BASE_KEYS" | sed '/^$/d'))"
STALE="$(comm -13 <(printf '%s\n' "$KEYS" | sed '/^$/d') <(printf '%s\n' "$BASE_KEYS" | sed '/^$/d'))"
n_find="$(grep -c . <<<"$KEYS" || true)"
n_new="$(grep -c . <<<"$NEW" || true)"
n_stale="$(grep -c . <<<"$STALE" || true)"
n_inv="$(grep -c . <<<"$INVALID" || true)"

if [[ -n "$NEW" ]]; then
    echo "  [FAIL] NEW mutation-result suppression (not in the baseline):"
    while IFS='|' read -r f fn p form; do
        [[ -n "$f" ]] || continue
        ln="$(awk -F'\t' -v f="$f" -v fn="$fn" -v p="$p" -v fo="$form" '$1==f && $3==fn && $4==p && $5==fo {printf "%s%s", (c++?",":""), $2}' <<<"$FINDINGS")"
        echo "         $f:$ln  $fn()  $p  $form"
    done <<<"$NEW"
    echo "         Propagate the result, or — only for a genuinely best-effort call whose outcome"
    echo "         is verified independently — annotate: # nftban:rc-suppression-ok: <why>"
    FAIL=1
fi
if [[ -n "$STALE" ]]; then
    echo "  [FAIL] STALE baseline rows (no longer reproduce — remove them from $BASELINE):"
    while IFS= read -r _k; do [[ -n "$_k" ]] && echo "         $_k"; done <<<"$STALE"
    FAIL=1
fi
if [[ -n "$INVALID" ]]; then
    echo "  [FAIL] exception annotations without a justification:"
    printf '%s\n' "$INVALID" | awk -F'\t' '{print "         "$1":"$2}'
    FAIL=1
fi
echo "  open findings (baselined debt):"
while IFS='|' read -r f fn p form; do
    [[ -n "$f" ]] || continue
    grep -qxF "$f|$fn|$p|$form" <<<"$BASE_KEYS" || continue
    echo "         $f  $fn()  $p  $form"
done <<<"$KEYS"
echo "MUTATION_RC_SUPPRESSION_FINDINGS = ${n_find}"
echo "MUTATION_RC_SUPPRESSION_NEW = ${n_new}"
echo "MUTATION_RC_SUPPRESSION_STALE = ${n_stale}"
echo "MUTATION_RC_SUPPRESSION_INVALID_ANNOTATIONS = ${n_inv}"
if (( FAIL )); then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
