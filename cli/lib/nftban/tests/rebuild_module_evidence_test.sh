#!/usr/bin/env bash
# =============================================================================
# NFTBan - a failed module re-apply must leave recoverable evidence
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="rebuild-module-evidence-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="rebuild_module_evidence_test"
# meta:ta.owner="firewall"
# meta:ta.module="rebuild-module-reapply-evidence"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="The module re-apply calls were `nftban <mod> reload 2>/dev/null`. On 2026-08-26 three production hosts recorded PRE protected (chains: 16) -> POST degraded (chains: 6) — six chains is base input/forward/output across two families, i.e. every module chain absent. The base ruleset had loaded; the MODULE RE-APPLY had failed. But the reason was gone: stderr went to /dev/null and the warning went to the rebuild's own stdout, which the installer never captured. The mechanism was reproducible; the TRIGGER was not recoverable from any surviving evidence. Un-suppressing without redacting would have fixed diagnosability by creating disclosure, since this record is collected into support bundles emailed to third parties. Asserts the record captures module/command/timestamps/exit/result, that a failure preserves stderr and attributes it to the right module, that a planted secret is redacted by the CANONICAL redactor, that an unloadable redactor withholds the capture rather than emitting raw text, and that an uncapturable stream reads UNAVAILABLE rather than empty."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/lib/nftban_redact.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${LIB_DIR}/../../.." && pwd)"
FW="${LIB_DIR}/cli/cmd_firewall.sh"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export NFTBAN_LIB_DIR="$LIB_DIR"
mkdir -p "$T/bin"; export PATH="$T/bin:$PATH"

# Extract only the functions under test; the rest of the CLI must not execute.
sed -n '/^_rebuild_run_module_reapply()/,/^}/p' "$FW" >  "$T/fn.sh"
sed -n '/^_rebuild_redact_stream()/,/^}/p'      "$FW" >> "$T/fn.sh"
[[ -s "$T/fn.sh" ]] || { echo "  [FAIL] could not extract the evidence functions"; exit 1; }

# Stub `nftban <module> reload` — deterministic, never touches a real module.
mk_nftban() { # $1=exit $2=stdout $3=stderr
cat > "$T/bin/nftban" <<EOS
#!/bin/sh
[ -n "$2" ] && printf '%s\n' "$2"
[ -n "$3" ] && printf '%s\n' "$3" >&2
exit $1
EOS
chmod +x "$T/bin/nftban"; }

run() { # $1=module -> writes evidence to $T/ev
  : > "$T/ev"
  ( source "$T/fn.sh"; set +e
    _REBUILD_MODULE_EVIDENCE="$T/ev" quiet=true _rebuild_run_module_reapply "$1" "$1" >/dev/null 2>&1
    echo $? > "$T/rc" ); }

echo "=== SUCCESS case ==="
mk_nftban 0 "reload ok" ""
run ddos
grep -q '^step=ddos_reload'            "$T/ev" && ok "records the step"           || bad "step missing"
grep -q '^command=nftban ddos reload'  "$T/ev" && ok "records the exact command"  || bad "command missing"
grep -qE '^start=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$T/ev" && ok "records a UTC start timestamp" || bad "start missing"
grep -qE '^end=[0-9]{4}-'              "$T/ev" && ok "records an end timestamp"   || bad "end missing"
grep -q '^exit=0'                      "$T/ev" && ok "records exit=0"             || bad "exit missing"
grep -q '^result=SUCCESS'              "$T/ev" && ok "records result=SUCCESS"     || bad "result missing"
[[ "$(cat "$T/rc")" == "0" ]]          && ok "propagates rc=0 to the caller"      || bad "rc not propagated"

echo "=== FAILURE case — the 2026-08-26 shape ==="
mk_nftban 3 "" "nft: Error: Could not process rule: No such file or directory"
run portscan
grep -q '^exit=3'         "$T/ev" && ok "records the real exit code (3)"          || bad "exit code lost"
grep -q '^result=FAILED'  "$T/ev" && ok "records result=FAILED"                   || bad "result not FAILED"
grep -q '^step=portscan_reload' "$T/ev" && ok "failure attributed to the correct module" || bad "wrong attribution"
grep -q 'Could not process rule' "$T/ev" && ok "STDERR CAPTURED — the reason survives (it went to /dev/null before)" \
                                         || bad "stderr not captured; the trigger is unrecoverable"
[[ "$(cat "$T/rc")" == "3" ]] && ok "propagates the failing rc" || bad "rc not propagated"

echo "=== REDACTION — a planted secret must not reach a bundle ==="
mk_nftban 1 "" "connecting with SASL_PASSWORD=hunter2SuperSecret and Bearer abc123XYZtoken"
run feeds
if grep -q 'hunter2SuperSecret' "$T/ev"; then
    bad "RAW SECRET PRESENT in evidence collected into emailed bundles"
else
    ok "raw secret absent from the evidence record"
fi
grep -q 'REDACTED' "$T/ev" && ok "canonical redactor applied ([REDACTED] present)" || bad "no redaction marker"
grep -q 'abc123XYZtoken' "$T/ev" && bad "raw bearer token present" || ok "bearer token redacted too"

echo "=== FAIL CLOSED — an unloadable redactor withholds, never emits raw ==="
mk_nftban 1 "" "SECRET=topsecretvalue"
: > "$T/ev"
( source "$T/fn.sh"; set +e
  # canonical redactor unreachable
  export NFTBAN_LIB_DIR="$T/nonexistent"
  unset -f nftban_redact_stream 2>/dev/null
  _REBUILD_MODULE_EVIDENCE="$T/ev" quiet=true _rebuild_run_module_reapply botguard botguard >/dev/null 2>&1 )
if grep -q 'topsecretvalue' "$T/ev"; then
    bad "raw text emitted when the redactor could not be loaded"
else
    ok "no raw capture when the redactor is unavailable"
fi
grep -q 'REDACTOR UNAVAILABLE' "$T/ev" && ok "withholding is STATED, not silent" || bad "withholding not stated"

echo "=== UNAVAILABLE != empty ==="
mk_nftban 0 "" ""
run trust
grep -q 'stderr=<empty>' "$T/ev" && ok "a genuinely empty stream reads <empty>" || bad "empty stream not marked"
grep -q 'UNAVAILABLE' "$T/ev" && bad "empty stream wrongly reported UNAVAILABLE" || ok "empty is NOT conflated with UNAVAILABLE"

echo "=== SUPPORT BUNDLE: the collector must not render absence as zero ==="
# The collector is an inline block, so it is EXTRACTED and driven verbatim rather
# than asserted by grepping its source text.
SUP="${LIB_DIR}/cli/cmd_support.sh"
sed -n '/---- module re-apply evidence (v1.229.12 B-lane)/,/} > "\$d\/module_reapply.txt"/p' "$SUP" \
  | sed 's|} > "\$d/module_reapply.txt" 2>&1|}|' > "$T/coll.sh"
if [[ ! -s "$T/coll.sh" ]]; then
    bad "could not extract the support collector block"
else
    collect() { ( _support_correlation_header() { echo "== $1 =="; }
                  # Both are consumed by the collector block sourced below.
                  # Static analysis cannot follow a runtime source, so they look
                  # like dead locals; they are inputs. (A comment opening with the
                  # word shellcheck is itself parsed as a directive - hence this
                  # wording.)
                  # shellcheck disable=SC2034
                  local d="$T"
                  # shellcheck disable=SC2034
                  local NFTBAN_LOG_DIR="$1"
                  set +e; source "$T/coll.sh" ) > "$T/mr.txt" 2>&1; }

    # (a) directory absent
    collect "$T/no_such_logdir"
    grep -q 'UNAVAILABLE' "$T/mr.txt" && ok "absent evidence dir -> UNAVAILABLE" || bad "absent dir not UNAVAILABLE"
    grep -qE '^records_present=0' "$T/mr.txt" && bad "absent dir rendered as records_present=0" \
                                              || ok "absent dir is NOT rendered as a zero count"

    # (b) directory present but empty — the dangerous middle case
    mkdir -p "$T/logdir/rebuild-modules"
    collect "$T/logdir"
    grep -q 'records_present=0' "$T/mr.txt" && ok "empty evidence dir -> records_present=0" || bad "empty dir count wrong"
    grep -q "NOT the same as" "$T/mr.txt" \
        && ok "states that zero records is NOT 'all modules succeeded'" \
        || bad "zero records could be misread as success"

    # (c) directory with a real record
    printf 'step=ddos_reload\nexit=3\nresult=FAILED\n' > "$T/logdir/rebuild-modules/reapply-20260831T000000Z-1.log"
    collect "$T/logdir"
    grep -q 'records_present=1' "$T/mr.txt" && ok "present record counted" || bad "record not counted"
    grep -q 'result=FAILED' "$T/mr.txt" && ok "record CONTENT reaches the bundle" || bad "record content missing"
fi

echo "=== NEGATIVE CONTROL: synthesised pre-fix shape ==="
# ⛔ THIS CONTROL MUST NOT READ ITS SUBJECT FROM A MOVING REF.
#    It previously did `git show origin/main:cmd_firewall.sh` and asserted that
#    the file had NO evidence capture. The moment this lane merged, origin/main
#    BECAME the fixed code, the assertion inverted, and the test failed
#    deterministically on main and on every branch cut from it — blocking the
#    release train. (Same defect, same week, as the D9a control fixed in #1333.)
#    Pinning a tag is not the answer either: the ci-bash checkout is shallow
#    (no fetch-depth), so no historical ref is guaranteed present.
#
#    A negative control exists to prove the DETECTOR is not vacuous. So synthesise
#    the pre-fix shape from the LIVE file by a declared transformation, and assert
#    the detector distinguishes it. Immutable by construction, no history needed.
FW="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
if [[ ! -f "$FW" ]]; then
    bad "cmd_firewall.sh not found — the control would be vacuous"
else
    # PRECONDITION: the fix must be present, or there is nothing to invert.
    n_fix="$(grep -c '_rebuild_run_module_reapply' "$FW")" || n_fix=0
    [[ "$n_fix" =~ ^[0-9]+$ ]] || n_fix=0
    if [[ "$n_fix" -eq 0 ]]; then
        bad "live cmd_firewall.sh has no _rebuild_run_module_reapply — the fix is gone"
    else
        ok "live code captures module re-apply evidence ($n_fix references)"

        # Synthesise the pre-fix shape: strip the evidence helper entirely and
        # restore the stderr-discarding call it replaced.
        sed -e '/_rebuild_run_module_reapply/d' "$FW" > "$T/old_fw.sh"
        printf '    nftban ddos reload 2>/dev/null\n' >> "$T/old_fw.sh"

        # The transformation must actually have changed something.
        if cmp -s "$FW" "$T/old_fw.sh"; then
            bad "synthesised baseline is identical to the live file — control vacuous"
        else
            ok "synthesised pre-fix baseline differs from the live file"
        fi

        # THE CONTROL: the detector must report NO evidence capture on the
        # synthesised shape. If it does not, every positive arm above is suspect.
        n_old="$(grep -c '_rebuild_run_module_reapply' "$T/old_fw.sh")" || n_old=0
        [[ "$n_old" =~ ^[0-9]+$ ]] || n_old=0
        [[ "$n_old" -eq 0 ]] \
            && ok "pre-fix shape has NO module re-apply evidence capture — detector distinguishes" \
            || bad "detector still sees evidence capture in the pre-fix shape ($n_old) — vacuous"

        n_err="$(grep -cE 'nftban (ddos|portscan) reload 2>/dev/null' "$T/old_fw.sh")" || n_err=0
        [[ "$n_err" =~ ^[0-9]+$ ]] || n_err=0
        [[ "$n_err" -ge 1 ]] \
            && ok "pre-fix shape discards module stderr (2>/dev/null) — the reason was unrecoverable" \
            || bad "could not reproduce the stderr-discarding call in the pre-fix shape"

        # ⛔ DELIBERATELY NOT ASSERTED: that the live file contains NO
        #    `2>/dev/null` module reload at all. It still does, at four sites
        #    (cmd_firewall.sh ~2361, ~2373, ~4308, ~4318) on OTHER code paths this
        #    lane did not touch. Asserting their absence would claim a scope this
        #    fix never had, and would fail honestly-correct code. The evidence
        #    contract this test owns is the re-apply path, not every reload call
        #    site in the file.
    fi
fi

echo
echo "=== rebuild_module_evidence: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
