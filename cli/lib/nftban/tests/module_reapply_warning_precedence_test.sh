#!/usr/bin/env bash
# =============================================================================
# NFTBan — P12-R02-A: module re-apply warnings must reflect the actual outcome
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="module-reapply-warning-precedence-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-01"
# meta:description="P12-R02-A. firewall_reset re-applies ddos/portscan/botguard after a reset and warned with the form `cmd 2>/dev/null || [[ \$quiet == false ]] && echo Warning`. Bash parses A||B&&C as (A||B)&&C, so C ran whenever the command SUCCEEDED: the warning fired on success in BOTH quiet modes, and on genuine failure under --quiet it did not fire at all. The message was therefore uninformative in both directions — identical output for success and failure when verbose, and present-on-success/absent-on-failure when quiet, so an operator could not distinguish the two states from it. firewall_reload (sites 1-2) already used the correct brace form; this aligns firewall_reset with it. Asserts all four semantic arms (inner success/failure x quiet/verbose) for each of the three modules, drives the REAL statement extracted from cmd_firewall.sh rather than a retyped copy, and proves non-vacuity by requiring the pre-fix shape to fail the same arms."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.privileges="none"
# meta:ta.id="module_reapply_warning_precedence_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-reset"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FW="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

[[ -f "$FW" ]] || { bad "cmd_firewall.sh not found — every arm would be vacuous"; echo "== RESULT: PASS=0 FAIL=1 =="; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# ⛔ THE SUBJECT IS THE REAL STATEMENT, extracted from the shipped file. A retyped
#    copy would prove only that the test author can write correct bash.
extract() { # $1=file $2=marker -> the || statement, including a brace block
    local f="$1" pat="$2" n
    n="$(grep -nF "$pat" "$f" | grep -F '||' | tail -1 | cut -d: -f1)"
    [[ -n "$n" ]] || return 1
    awk -v s="$n" 'NR>=s{
        print
        if (NR==s && $0 !~ /\{[[:space:]]*$/) exit
        if (NR>s && $0 ~ /^[[:space:]]*\}[[:space:]]*$/) exit
    }' "$f"
}

# One arm: run the extracted statement with a stubbed command of known rc.
arm() { # $1=file $2=marker $3=inner_rc $4=quiet -> prints any warning
    local blk _rc="$3" _q="$4"
    blk="$(extract "$1" "$2")" || { echo "__NOSITE__"; return; }
    # ⛔ The stub MUST close over a named variable. `return "$3"` inside the stub
    #    resolves $3 against the STUB's own arguments at call time
    #    (`nftban ddos reload` -> $3 unset), not against arm's parameters. That
    #    silently returned 0 for every arm and produced results shifted off the
    #    contract — caught because the pre-fix non-vacuity check disagreed.
    (
        # shellcheck disable=SC2034  # consumed by the eval'd statement below
        quiet="$_q"
        _inner_rc="$_rc"
        nftban() { return "$_inner_rc"; }
        eval "$blk"
    ) 2>&1
}

declare -A MARK=(
    [ddos]='nftban ddos reload 2>/dev/null'
    [portscan]='nftban portscan reload 2>/dev/null'
    [botguard]='nftban botguard enable --quiet 2>/dev/null'
)

# The contract. A warning is correct ONLY when the command failed AND we are verbose.
want_for() { # $1=inner_rc $2=quiet
    [[ "$1" -ne 0 && "$2" == "false" ]] && echo warning || echo silent
}

echo "=== all four arms x three modules, against the SHIPPED statement ==="
for mod in ddos portscan botguard; do
    extract "$FW" "${MARK[$mod]}" >/dev/null || { bad "$mod: re-apply site not found in cmd_firewall.sh"; continue; }
    for rc in 0 1; do
        for q in false true; do
            out="$(arm "$FW" "${MARK[$mod]}" "$rc" "$q")"
            [[ "$out" == "__NOSITE__" ]] && { bad "$mod: site vanished mid-run"; continue; }
            got="silent"; [[ -n "${out//[[:space:]]/}" ]] && got="warning"
            want="$(want_for "$rc" "$q")"
            label="inner=$([[ $rc -eq 0 ]] && echo success || echo failure) quiet=$q"
            if [[ "$got" == "$want" ]]; then
                ok "$mod $label -> $got"
            else
                bad "$mod $label -> $got (want $want)"
            fi
        done
    done
done

echo "=== ⛔ NON-VACUITY: the pre-fix shape MUST fail these same arms ==="
# Reconstruct the exact defective form and require the detector to catch it.
cat > "$T/prefix.sh" <<'PRE'
        nftban ddos reload 2>/dev/null || [[ "$quiet" == "false" ]] && echo "    Warning: DDoS reload failed"
PRE
caught=0
for rc in 0 1; do
    for q in false true; do
        out="$(arm "$T/prefix.sh" 'nftban ddos reload 2>/dev/null' "$rc" "$q")"
        got="silent"; [[ -n "${out//[[:space:]]/}" ]] && got="warning"
        [[ "$got" != "$(want_for "$rc" "$q")" ]] && caught=$((caught+1))
    done
done
[[ "$caught" -eq 2 ]] \
    && ok "pre-fix shape fails exactly the 2 success arms — the arms above are non-vacuous" \
    || bad "pre-fix shape mismatched $caught arms (want 2); the contract check proves nothing"

echo "=== the defective precedence form is gone from the re-apply sites ==="
n="$(grep -cE '(reload|botguard enable --quiet) 2>/dev/null \|\| \[\[ "\$quiet"' "$FW")" || n=0
[[ "$n" -eq 0 ]] \
    && ok "no module re-apply site uses the 'cmd || [[ ]] && echo' form" \
    || bad "$n re-apply site(s) still use the defective precedence form"

echo "=== stderr suppression is PRESERVED (P12-R02-B is a separate lane) ==="
# ⛔ Removing 2>/dev/null here without routing through the canonical redactor would
#    trade diagnosability for disclosure: these records reach support bundles that
#    are emailed to third parties. That work is P12-R02-B, not this lane.
s="$(grep -cE '(nftban (ddos|portscan) reload|nftban botguard enable --quiet) 2>/dev/null' "$FW")" || s=0
[[ "$s" -ge 3 ]] \
    && ok "module re-apply calls still suppress stderr ($s sites) — scope not widened" \
    || bad "stderr suppression changed ($s sites) — this lane must not touch it"

echo
echo "=== module_reapply_warning_precedence: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
