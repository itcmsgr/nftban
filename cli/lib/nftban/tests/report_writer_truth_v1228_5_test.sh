#!/usr/bin/env bash
# =============================================================================
# NFTBan - report writer truth (v1.228.5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="report_writer_truth_v1228_5_test.sh"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Behavioural proof that nftban_report_generate_html FAILS when it cannot produce a report, and never publishes a zero-byte or truncated artifact. Every negative case is ALSO run against the pre-fix implementation extracted from git, so the harness proves it discriminates instead of asserting into a vacuum. No network."
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="unprivileged"
# meta:ta.id="report_writer_truth_v1228_5_test"
# meta:ta.owner="mail"
# meta:ta.module="report-writer-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
# WHY THIS TEST EXISTS
#   v1.228.5 Gate 1 reported "8 passed, 0 failed" while the journal held Permission
#   denied and the published report was 0 bytes. Two mechanisms hid it: the generator
#   ignored its own write failure, and the unit declared SuccessExitStatus=0 1. The
#   assertions in use — unit result, then file existence — could not tell a good run
#   from a failed one. This harness asserts on the DISCRIMINATION first: a probe that
#   cannot fail is not evidence.
#
# WHAT IT CANNOT PROVE
#   The SELinux Enforcing path. DAC read-only directories stand in for the denied
#   write locally; the nftband_t -> nftban_log_t behaviour is only provable on a
#   real Enforcing host running the real systemd unit.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
assert() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== report_writer_truth_v1228_5 ==="

# ---------------------------------------------------------------------------
# GUARD: root bypasses DAC. Under EUID 0 a chmod 500 directory stays writable,
# every negative case would silently pass, and the suite would report a green
# result while testing nothing. Refuse rather than mislead.
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    echo "  [FATAL] must run unprivileged: root bypasses the DAC controls this test relies on"
    exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "  [SKIP] jq not available"; exit 0; }

SB="$(mktemp -d)"
# This test deliberately creates unreadable/unwritable directories to drive the
# DAC failure paths, so cleanup must restore traversal before rm -rf can descend.
# Only DIRECTORIES need it: removing a file requires write+execute on its parent,
# not on the file itself. Bounded by construction — $SB is a fresh mktemp -d whose
# entire contents this test created, and find does not follow symlinks without -L,
# so the restore cannot escape the sandbox. A recursive chmod over the whole tree
# is both broader than required and indiscriminate about object type.
cleanup() {
    find "$SB" -type d -exec chmod u+rwx {} + 2>/dev/null || true
    rm -rf "$SB"
}
trap cleanup EXIT

# The pre-fix implementation, extracted from the rejected candidate. If the commit is
# unreachable the discrimination controls are SKIPPED loudly — never assumed to pass.
OLD_SRC="$SB/cmd_report_prefix.sh"
OLD_AVAILABLE=0
if git -C "$ROOT" show 6b88a9a7:cli/lib/nftban/cli/cmd_report.sh > "$OLD_SRC" 2>/dev/null; then
    OLD_AVAILABLE=1
fi
NEW_SRC="$ROOT/cli/lib/nftban/cli/cmd_report.sh"

# ---------------------------------------------------------------------------
# probe <source-file> <scenario> <sandbox>
#   Emits: RC=<n> SIZE=<n|absent> BODY=<sha|absent> TEMPS=<n>
#   Each probe runs in its own bash -c: cmd_report.sh declares readonly globals
#   and cannot be sourced twice in one shell.
# ---------------------------------------------------------------------------
probe() {
    local src="$1" scenario="$2" box="$3"
    mkdir -p "$box/log/reports/daily" "$box/data" "$box/run" "$box/state"

    # THE SHIPPED TEMPLATE SHAPE — three lines, exactly as
    # /usr/share/nftban/templates/reports/stats_dashboard.html carries it.
    # The previous fixture put the assignment and the placeholder comment on ONE line. No
    # shipped template ever looked like that, so the injector was only ever exercised
    # against a layout that did not exist in production — and a data-free report passed
    # every test for as long as that fixture stood. A fixture that does not match the
    # artifact under test is not a control.
    local tmpl="$box/tmpl.html"
    {
        echo '<html><body>'
        echo '<script>'
        echo '        // Data will be injected here by bash script'
        if [[ "$scenario" == "template_copy" ]]; then
            # Unmatchable assignment AND no placeholder sentinel, so the placeholder rule
            # cannot fire. Only the byte-identity check stands between this and publication.
            echo '        window.__NFTBAN_DATA__ ='
            echo '        {'
            echo '        };'
        elif [[ "$scenario" == "placeholder_survives" ]]; then
            # TEMPLATE DRIFT: the opening brace moves to its own line, so the injector
            # matches nothing. This is the general form of the defect measured on EL9 —
            # the template changed shape and the writer silently published a data-free
            # document. The publisher must REFUSE it, not ship it.
            echo '        window.__NFTBAN_DATA__ ='
            echo '        {'
        else
            echo '        window.__NFTBAN_DATA__ = {'
        fi
        if [[ "$scenario" != "template_copy" ]]; then
            echo '            // Placeholder - will be replaced'
            echo '        };'
        fi
        echo '        const data = window.__NFTBAN_DATA__;'
        echo '</script>'
        # TRUNCATED scenario: the closing </html> is withheld, standing in for a write
        # that stopped early (ENOSPC, a killed writer, a full quota).
        if [[ "$scenario" != "truncated" ]]; then
            echo '</body></html>'
        fi
    } > "$tmpl"

    local out="$box/log/reports/daily/report.html"
    # A KNOWN-GOOD predecessor. Atomic publication must leave it untouched on failure.
    printf 'PREVIOUS-REPORT-SENTINEL\n' > "$out"

    [[ "$scenario" == "dest_ro" ]] && chmod 500 "$box/log/reports/daily"

    local rc
    NFTBAN_SCENARIO="$scenario" NFTBAN_SRC="$src" NFTBAN_OUT="$out" \
    NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" NFTBAN_DATA_DIR="$box/data" \
    NFTBAN_RUN_DIR="$box/run" NFTBAN_LOG_DIR="$box/log" NFTBAN_STATE_DIR="$box/state" \
    NFTBAN_REPORT_TEMPLATE="$tmpl" \
    bash -c '
        # shellcheck disable=SC1090
        source "$NFTBAN_SRC" 2>/dev/null || true
        if [[ "$NFTBAN_SCENARIO" == "stats_empty" ]]; then
            # Export succeeds loudly and produces nothing — the shape that makes a
            # data-less report look healthy to a return-code check.
            nftban_stats_export_json() { : > "$1"; return 0; }
        elif [[ "$NFTBAN_SCENARIO" == "no_hostname" ]]; then
            # Valid JSON, but the identity field is empty — the exact shape produced while
            # /usr/bin/hostname was unexecutable in nftband_t under Enforcing.
            nftban_stats_export_json() { jq -n "{report:{hostname:\"\"}, n:1}" > "$1"; }
        else
            # PRETTY-PRINTED, exactly as nftban_stats_export_json emits it in production.
            # The earlier fixture used `jq -cn` (compact). Production never was, so a
            # post-injection parse that reads the assignment LINE saw only "{" — a
            # regression this harness could not see because its fixture was the wrong shape.
            nftban_stats_export_json() { jq -n "{report:{hostname:\"testhost\"}, n:1}" > "$1"; }
        fi
        nftban_report_generate_html "$NFTBAN_OUT" "" "" dark >/dev/null 2>&1
    ' >/dev/null 2>&1
    rc=$?

    chmod 700 "$box/log/reports/daily" 2>/dev/null || true

    local size body temps ph mode
    if [[ -f "$out" ]]; then
        size="$(wc -c < "$out" | tr -d ' ')"
        body="$(sha256sum < "$out" | cut -c1-16)"
        # PLACEHOLDER survival is the assertion that catches a FULL-SIZE, well-formed,
        # data-free document — the shape measured on EL9 that passed size, </html> and
        # marker-presence checks while carrying no data at all.
        ph="$(grep -c 'Placeholder - will be replaced' "$out" 2>/dev/null || true)"
        ph="${ph:-0}"
        mode="$(stat -c %a "$out" 2>/dev/null || echo unknown)"
    else
        size="absent"; body="absent"; ph="absent"; mode="absent"
    fi
    temps="$(find "$box/log/reports/daily" -name '.nftban-report-*' 2>/dev/null | wc -l | tr -d ' ')"
    echo "RC=$rc SIZE=$size BODY=$body TEMPS=$temps PLACEHOLDER=$ph MODE=$mode"
}

# shellcheck disable=SC2034  # consumed by the assert eval expressions below
SENTINEL="$(printf 'PREVIOUS-REPORT-SENTINEL\n' | sha256sum | cut -c1-16)"

# ---------------------------------------------------------------------------
# STAGE 1 — INSTRUMENTATION CONTROL
# Prove the real generator ran and produced a real document. Without this a green
# negative matrix could just mean the function was never reached.
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 1: instrumentation control (the healthy path really runs) ---"
H_BOX="$SB/new_healthy"; H="$(probe "$NEW_SRC" healthy "$H_BOX")"
H_RC="${H#RC=}";   H_RC="${H_RC%% *}"
H_SIZE="${H##*SIZE=}"; H_SIZE="${H_SIZE%% *}"
H_BODY="${H##*BODY=}"; H_BODY="${H_BODY%% *}"
# shellcheck disable=SC2034  # consumed by the assert eval expressions below
H_TEMPS="${H##*TEMPS=}"; H_TEMPS="${H_TEMPS%% *}"

assert "HEALTHY_RC_ZERO"                  '[[ "$H_RC" == "0" ]]'
assert "HEALTHY_REPORT_NON_EMPTY"         '[[ "$H_SIZE" != "absent" && "$H_SIZE" -gt 0 ]]'
assert "HEALTHY_REPORT_REPLACED_PREVIOUS" '[[ "$H_BODY" != "$SENTINEL" ]]'
assert "HEALTHY_DATA_SECTION_PRESENT"     'grep -q "window.__NFTBAN_DATA__" "$H_BOX/log/reports/daily/report.html"'
assert "HEALTHY_DOCUMENT_COMPLETE"        'grep -qi "</html>" "$H_BOX/log/reports/daily/report.html"'
assert "HEALTHY_NO_TEMP_FILES_LEFT"       '[[ "$H_TEMPS" == "0" ]]'
# The injection must actually have happened against the SHIPPED template shape.
H_PH="${H##*PLACEHOLDER=}"; H_PH="${H_PH%% *}"
H_MODE="${H##*MODE=}"; H_MODE="${H_MODE%% *}"
assert "HEALTHY_PLACEHOLDER_REPLACED"     '[[ "$H_PH" == "0" ]]'
# mktemp creates 0600; the pre-lane `echo >` produced 0640 under umask 027. Publishing by
# rename must not silently tighten the published report's mode.
assert "HEALTHY_REPORT_MODE_0640"         '[[ "$H_MODE" == "640" ]]'
assert "HEALTHY_REAL_DATA_INJECTED"       'grep -q "testhost" "$H_BOX/log/reports/daily/report.html"'
assert "HEALTHY_LATER_READ_NOT_REWRITTEN" 'grep -q "const data = window.__NFTBAN_DATA__;" "$H_BOX/log/reports/daily/report.html"'

# ---------------------------------------------------------------------------
# STAGE 2 — DISCRIMINATION CONTROL
# Run the SAME negative scenarios against the pre-fix implementation. If the old
# code also "passes", the assertions below are non-discriminating and prove nothing.
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 2: discrimination control (pre-fix code must FAIL these) ---"
if [[ "$OLD_AVAILABLE" -eq 1 ]]; then
    for scen in dest_ro stats_empty truncated no_hostname placeholder_survives template_copy; do
        O="$(probe "$OLD_SRC" "$scen" "$SB/old_$scen")"
        O_RC="${O#RC=}"; O_RC="${O_RC%% *}"
        assert "PREFIX_FALSE_SUCCESS_REPRODUCED[$scen] (old rc=$O_RC, expected 0)" \
               '[[ "$O_RC" == "0" ]]'
    done
    # THE MEASURED EL9 DEFECT, reproduced here: against the SHIPPED template shape the
    # pre-fix injector matches nothing, so it publishes a full-size, well-formed document
    # whose placeholder is intact — and still returns 0.
    OP="$(probe "$OLD_SRC" healthy "$SB/old_healthy")"
    assert "PREFIX_PUBLISHES_FULL_SIZE_PLACEHOLDER_DOC (rc=${OP#RC=})" \
           'OP_PH="${OP##*PLACEHOLDER=}"; OP_PH="${OP_PH%% *}"; [[ "${OP#RC=}" == 0* ]] && [[ "$OP_PH" != "0" ]] && [[ "${OP##*SIZE=}" != absent* ]]' 
else
    # v1.228.5 post-merge: 6b88a9a7 lived ONLY on the feature branch. The squash merge made
    # it permanently unreachable from main, so on any main-based checkout (push CI, release
    # branches, fresh clones) this stage CANNOT run — and treating that as FAIL turned a
    # required gate red on a tree whose candidate assertions all pass. The discrimination
    # was PROVEN while the commit existed (old rc=0 on every failure scenario; recorded in
    # V1_228_5_REPORT_PIPELINE_ROOT_CAUSE_2026_08_06.md). STAGE 3 below is self-contained
    # and remains the enduring regression protection. A loud SKIP is the honest verdict:
    # not proven HERE, proven THEN, still enforced NOW.
    echo "  [SKIP] pre-fix commit 6b88a9a7 unreachable from this history (squash-merged)."
    echo "         Discrimination was proven in-lane before merge; STAGE 3's self-contained"
    echo "         candidate assertions below remain the active regression protection."
fi

# ---------------------------------------------------------------------------
# STAGE 3 — SUBJECT ASSERTION
# The candidate must turn each of those silent successes into a reported failure,
# without ever publishing a bad artifact over a good one.
# ---------------------------------------------------------------------------
echo ""
echo "--- STAGE 3: candidate assertion (failures must propagate) ---"
for scen in dest_ro stats_empty truncated no_hostname placeholder_survives template_copy; do
    N="$(probe "$NEW_SRC" "$scen" "$SB/new_$scen")"
    N_RC="${N#RC=}";       N_RC="${N_RC%% *}"
    N_SIZE="${N##*SIZE=}"; N_SIZE="${N_SIZE%% *}"
    N_BODY="${N##*BODY=}"; N_BODY="${N_BODY%% *}"
    # shellcheck disable=SC2034  # consumed by the assert eval expressions below
    N_TEMPS="${N##*TEMPS=}"; N_TEMPS="${N_TEMPS%% *}"

    assert "FAILURE_PROPAGATES[$scen] (rc=$N_RC)"        '[[ "$N_RC" != "0" ]]'
    assert "NO_ZERO_BYTE_PUBLISHED[$scen]"               '[[ "$N_SIZE" == "absent" || "$N_SIZE" -gt 0 ]]'
    assert "PREVIOUS_REPORT_PRESERVED[$scen]"            '[[ "$N_BODY" == "$SENTINEL" ]]'
    assert "NO_TEMP_FILES_LEFT[$scen]"                   '[[ "$N_TEMPS" == "0" ]]'
done

echo ""
echo "=== report_writer_truth_v1228_5: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
