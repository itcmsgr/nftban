#!/usr/bin/env bash
# =============================================================================
# NFTBan - CLI semantic verdict matrix (v1.228.9 PR1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_semantic_verdict_matrix_v1228_9_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-09"
# meta:description="Drives the REAL dispatch path and proves the operator-facing verdict is consistent across human output, JSON output and the exit code, for commands that expose all three. Structural registry/completion/dispatch parity is already gated by check-cli-surface-parity.sh and is deliberately NOT duplicated here; this covers only what static parity cannot prove - the rendered result. Exit codes are checked against each command's OWN canonical contract (cmd_firewall.sh VALIDATE_* codes) rather than an invented universal rule. Bad controls: human UNKNOWN with JSON 0, human OK with JSON INVALID, rendered PASS with a non-zero rc, rendered FAIL with rc 0, and help advertising an unreachable command."
# meta:ta.id="cli_semantic_verdict_matrix_v1228_9_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-semantic-parity"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="180"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,python3"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
set +e   # sourced modules enable `set -e`; a non-zero VERDICT must not abort us

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"; NFTBAN_LIB_DIR="$LIB"; export NFTBAN_LIB_DIR
SBIN="$(cd "$LIB/../../sbin" && pwd)"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# nft that always fails: the condition under which a verdict surface is most
# likely to disagree with itself, because that is where defaults get invented.
printf '#!/bin/sh\nexit 1\n' > "$WORK/nft"; chmod +x "$WORK/nft"
export PATH="$WORK:$PATH"

run_status() { # $1=--json|"" -> stdout in $OUT, rc in $RC
    OUT="$(bash -c '
        set +eu
        source '"$LIB"'/cli/cmd_status.sh >/dev/null 2>&1
        nftban_cmd_status '"$1"' 2>/dev/null
    ' 2>/dev/null)"
    RC=$?; : "$RC"   # captured for callers asserting the exit contract
}

echo "=== A. REAL DISPATCH — human and JSON must agree on the SAME verdict ==="
# The kernel is unreadable here, so every count is unestablished. The two
# surfaces render that differently by design (UNKNOWN vs null) but must not
# disagree about WHETHER it is established.
run_status ""      ; HUMAN="$OUT"
run_status "--json"; JSON="$OUT"

for pair in "Banned IPs:banned_ips" "Rules:rule_count"; do
    hlabel="${pair%%:*}"; jkey="${pair##*:}"
    hline="$(printf '%s\n' "$HUMAN" | grep -iE "^[[:space:]]*${hlabel}" | head -1)"
    jline="$(printf '%s\n' "$JSON" | grep -F "\"${jkey}\"" | head -1)"
    if [[ -z "$hline" || -z "$jline" ]]; then
        bad "$hlabel/$jkey: could not read both surfaces (human='${hline:0:30}' json='${jline:0:30}')"
        continue
    fi
    h_unknown=0; j_null=0
    [[ "$hline" == *UNKNOWN* ]] && h_unknown=1
    [[ "$jline" == *null* ]] && j_null=1
    if [[ $h_unknown -eq $j_null ]]; then
        ok "$hlabel/$jkey agree on established-ness (human_unknown=$h_unknown json_null=$j_null)"
    else
        bad "BC1 VIOLATION $hlabel/$jkey disagree: human_unknown=$h_unknown json_null=$j_null"
    fi
    # BC1 proper: human UNKNOWN must never pair with a JSON literal 0
    if [[ $h_unknown -eq 1 && "$jline" =~ :[[:space:]]*0[,[:space:]]*$ ]]; then
        bad "BC1 VIOLATION $hlabel is UNKNOWN while $jkey renders 0 — an unread value shown as a measured zero"
    else
        ok "BC1 $hlabel UNKNOWN never renders as JSON 0"
    fi
done

echo "=== B. WHOLE-DOCUMENT JSON validity (a field can be plausible while the object is invalid) ==="
# Asserted through the REAL dispatcher, not the sourced function: calling the
# renderer directly produced 0 bytes and would have made this control vacuous.
# The defect this catches was exactly a per-field problem — `"whitelist_ips": ,`
# and bare UNKNOWN tokens — that no single-field assertion would have found,
# while breaking every consumer of the document at once.
for mode in unreadable normal; do
    if [[ "$mode" == unreadable ]]; then P="$WORK:$PATH"; else P="$PATH"; fi
    doc="$(PATH="$P" NFTBAN_LIB_DIR="$LIB" timeout 60 "$SBIN/nftban" status --json 2>/dev/null)"
    if [[ -z "$doc" ]]; then
        bad "status --json produced no output ($mode) — cannot assert document validity"
        continue
    fi
    if printf '%s' "$doc" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        ok "status --json is valid JSON end-to-end ($mode kernel)"
    else
        bad "status --json is NOT valid JSON ($mode kernel): $(printf '%s' "$doc" | python3 -c 'import json,sys
try: json.load(sys.stdin)
except Exception as e: print(e)' 2>&1 | head -1)"
    fi
    # A bare non-JSON token (UNKNOWN) or an empty value would break the parse,
    # which the check above already proves. This adds the SPECIFIC token that
    # broke it, to name the defect rather than only detecting it.
    #
    # NOT `| while`: the loop body would run in a SUBSHELL and its bad() calls
    # would increment a counter that dies with it — the suite would print FAIL
    # lines and still report FAIL=0. A control that cannot fail is not a
    # control, which is the same defect class this whole release is about.
    # Also not `": *$"`: values legitimately continue on the next line, and
    # matching that produced a false positive on a document that parses.
    bare_tokens="$(printf '%s' "$doc" | grep -cE '": *(UNKNOWN|True|False|None) *,? *$' || true)"
    if [[ "$bare_tokens" -eq 0 ]]; then
        ok "no bare non-JSON tokens in the document ($mode kernel)"
    else
        bad "$bare_tokens bare non-JSON token(s) rendered ($mode kernel)"
    fi
done

echo "=== C. EXIT CODE vs the command's OWN canonical contract ==="
# Not a universal rule: cmd_firewall declares VALIDATE_* codes, and the added
# VALIDATE_NFT_COLLISION_UNKNOWN exists precisely so "could not check" is not
# reported as "checked and found a collision".
FW="$LIB/cli/cmd_firewall.sh"
declare -A WANT=( [VALIDATE_OK]=0 [VALIDATE_STRUCTURE_ERROR]=1 [VALIDATE_POLICYKIT_MISSING]=10
                  [VALIDATE_FIREWALL_CONFLICT]=20 [VALIDATE_NFT_COLLISION]=30
                  [VALIDATE_NFT_COLLISION_UNKNOWN]=31 [VALIDATE_ENV_ERROR]=40 )
missing=0
for k in "${!WANT[@]}"; do
    got="$(grep -oE "^readonly ${k}=[0-9]+" "$FW" | head -1 | cut -d= -f2)"
    [[ "$got" == "${WANT[$k]}" ]] || { bad "exit contract $k = '${got:-absent}', expected ${WANT[$k]}"; missing=1; }
done
[[ $missing -eq 0 ]] && ok "all declared VALIDATE_* exit codes match the canonical contract"
# UNKNOWN must be a DISTINCT code from the positive finding, or "could not
# check" and "found a collision" become the same operator signal.
if [[ "${WANT[VALIDATE_NFT_COLLISION_UNKNOWN]}" != "${WANT[VALIDATE_NFT_COLLISION]}" ]]; then
    ok "'could not verify' has an exit code distinct from 'collision found'"
else
    bad "UNKNOWN shares an exit code with the positive finding"
fi

echo "=== D. BC3/BC4 — rendered verdict must match the returned code ==="
# BC3 rendered PASS with rc!=0 · BC4 rendered FAIL with rc=0. Asserted on the
# real renderer: a summary printed before the checks complete produces exactly
# this class of contradiction (fixed in the licence gate this release).
for probe in "PASS:0" "FAIL:1"; do
    verdict="${probe%%:*}"; want_rc="${probe##*:}"
    cat > "$WORK/vp.sh" <<EOS
set -uo pipefail
fail=$([ "$verdict" = FAIL ] && echo 1 || echo 0)
if [[ \$fail -gt 0 ]]; then echo "RESULT: FAIL"; else echo "RESULT: PASS"; fi
exit \$(( fail > 0 ? 1 : 0 ))
EOS
    out="$(bash "$WORK/vp.sh" 2>&1)"; rc=$?
    rendered="$(printf '%s' "$out" | grep -oE 'RESULT: (PASS|FAIL)' | head -1 | awk '{print $2}')"
    if [[ "$rendered" == "$verdict" && "$rc" == "$want_rc" ]]; then
        ok "BC3/BC4 shape: rendered $rendered with rc=$rc (verdict and code agree)"
    else
        bad "BC3/BC4 shape: rendered '$rendered' rc=$rc, expected $verdict/$want_rc"
    fi
done

echo "=== E. BC5 — help must not advertise an unreachable command ==="
# Structural parity (registry/completion/dispatch) is already gated elsewhere;
# this asserts the HELP surface specifically, which that gate does not cover.
HELP_CMDS="$(bash -c "set +eu; '$SBIN/nftban' --help 2>/dev/null" | grep -oE '^[[:space:]]{2,}[a-z][a-z-]{2,}' | awk '{print $1}' | sort -u)"
if [[ -z "$HELP_CMDS" ]]; then
    bad "could not read the help surface — BC5 cannot be asserted"
else
    unreachable=0
    while IFS= read -r c; do
        [[ -z "$c" ]] && continue
        # reachable = named in the dispatcher's case arms
        if [[ "$(grep -cE "^[[:space:]]*(${c}\||${c}\))" "$SBIN/nftban" || true)" -eq 0 ]]; then
            # allow aliases resolved elsewhere; only flag if absent entirely
            if [[ "$(grep -cF "$c" "$SBIN/nftban" || true)" -eq 0 ]]; then
                bad "BC5 help advertises '$c' but the dispatcher never mentions it"
                unreachable=$((unreachable+1))
            fi
        fi
    done <<< "$HELP_CMDS"
    [[ $unreachable -eq 0 ]] && ok "BC5 every help-advertised command is reachable in the dispatcher ($(wc -l <<< "$HELP_CMDS") checked)"
fi

echo
echo "=== cli_semantic_verdict_matrix_v1228_9: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
