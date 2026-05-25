#!/usr/bin/env bash
# =============================================================================
# V131.1 D13 — Option C validator output-capture regression test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v131_1_d13_option_c_output_capture_test"
# meta:type="test"
# meta:version="1.131.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:description="Deterministic assertions locking the V131.1 D13 fix: nftban firewall validate Option C output is captured via a group-readable /run/nftban/firewall-validate/last.json file written by the firewall_validate_run.sh ExecStart wrapper, NOT via a non-root-unreadable journalctl read. Structural asserts: the unit ExecStart points to the wrapper (not bare nftban-validate --json); the wrapper exists, is executable, contains the run-dir/last.json path, chgrp nftban, chmod 0640, a pre-run rm -f stale-cleanup, and exit-code preservation; cmd_firewall.sh reads the last.json file. Behavioral asserts (dev-host runnable, no root/nftban group): a stub validator exercises the wrapper through NFTBAN_RUN_DIR + NFTBAN_VALIDATE_BIN overrides and proves the file is written with the validator JSON, the wrapper preserves the validator exit code (rc=0 and rc=3), and the pre-run rm -f removes stale prior output when a run produces nothing."
# meta:input="self-contained; pattern-greps the source files + runs the wrapper against a stub validator in a temp dir"
# meta:output="[PASS]/[FAIL] per assertion; exit 0 iff all pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_RUN_DIR,NFTBAN_VALIDATE_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: gate OPEN_V1_131_1_D13_OPTION_C_OUTPUT_CAPTURE_FIX (D13 only).
# =============================================================================

set -Eeuo pipefail
set +e

_pass=0
_fail=0
_failed_names=()
_t_assert() {
    local name="$1" rc="$2" detail="${3:-}"
    if [[ "$rc" == "0" ]]; then
        printf "  [PASS] %s\n" "$name"; _pass=$((_pass+1))
    else
        printf "  [FAIL] %s%s\n" "$name" "${detail:+ — $detail}"; _fail=$((_fail+1))
        _failed_names+=("$name")
    fi
}

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_unit_file="${_repo_root}/install/systemd/nftban-firewall-validate.service"
_wrapper="${_repo_root}/cli/lib/nftban/helpers/firewall_validate_run.sh"
_firewall_cli="${_repo_root}/cli/lib/nftban/cli/cmd_firewall.sh"

echo "==============================================================================="
echo "V131.1 D13 — Option C validator output-capture regression test"
echo "  Repo root: $_repo_root"
echo "==============================================================================="

# ----------------------------------------------------------------------------
# A: structural — unit ExecStart, wrapper presence/content, CLI file read
# ----------------------------------------------------------------------------
echo "--- A: structural ---"

# A1: unit ExecStart points to the wrapper, NOT bare nftban-validate --json.
if grep -qE '^ExecStart=/usr/lib/nftban/helpers/firewall_validate_run\.sh' "$_unit_file"; then
    _t_assert "A1: unit ExecStart points to firewall_validate_run.sh wrapper" 0
else
    _t_assert "A1: unit ExecStart points to firewall_validate_run.sh wrapper" 1
fi

# A2: the old bare ExecStart is gone (no `ExecStart=...nftban-validate --json`).
if grep -qE '^ExecStart=/usr/lib/nftban/bin/nftban-validate --json' "$_unit_file"; then
    _t_assert "A2: bare 'nftban-validate --json' ExecStart no longer present" 1 \
        "unit still has the bare validator ExecStart"
else
    _t_assert "A2: bare 'nftban-validate --json' ExecStart no longer present" 0
fi

# A3: wrapper exists and is executable.
if [[ -f "$_wrapper" && -x "$_wrapper" ]]; then
    _t_assert "A3: wrapper exists and is executable" 0
else
    _t_assert "A3: wrapper exists and is executable" 1 "$_wrapper missing or not +x"
fi

# A4: wrapper resolves the /run/nftban .../firewall-validate/last.json path.
if grep -qE '/run/nftban' "$_wrapper" && grep -qE 'firewall-validate' "$_wrapper" && grep -qE 'last\.json' "$_wrapper"; then
    _t_assert "A4: wrapper references /run/nftban .../firewall-validate/last.json" 0
else
    _t_assert "A4: wrapper references /run/nftban .../firewall-validate/last.json" 1
fi

# A5: wrapper chgrps the file to the nftban group.
if grep -qE 'chgrp nftban' "$_wrapper"; then
    _t_assert "A5: wrapper chgrp nftban (group-readable hand-off)" 0
else
    _t_assert "A5: wrapper chgrp nftban (group-readable hand-off)" 1
fi

# A6: wrapper chmods the file 0640 (group read, no group write).
if grep -qE 'chmod 0640' "$_wrapper"; then
    _t_assert "A6: wrapper chmod 0640 on the output file" 0
else
    _t_assert "A6: wrapper chmod 0640 on the output file" 1
fi

# A7: wrapper has a pre-run rm -f stale-output guard.
if grep -qE 'rm -f .*_file' "$_wrapper" || grep -qE 'rm -f "\$_file"' "$_wrapper"; then
    _t_assert "A7: wrapper has a pre-run 'rm -f' stale-output guard" 0
else
    _t_assert "A7: wrapper has a pre-run 'rm -f' stale-output guard" 1
fi

# A8: wrapper preserves the validator exit code (exit "$rc" / exit $rc).
if grep -qE '^exit "?\$rc"?' "$_wrapper"; then
    _t_assert "A8: wrapper preserves validator exit code (exit \$rc)" 0
else
    _t_assert "A8: wrapper preserves validator exit code (exit \$rc)" 1
fi

# A9: cmd_firewall.sh service branch reads the last.json file (no longer SOLELY
#     dependent on journalctl).
if grep -qE 'firewall-validate/last\.json' "$_firewall_cli"; then
    _t_assert "A9: cmd_firewall.sh reads the last.json file" 0
else
    _t_assert "A9: cmd_firewall.sh reads the last.json file" 1
fi

# ----------------------------------------------------------------------------
# B: behavioral — run the wrapper against a stub validator in a temp dir.
#    No root / nftban group required (chgrp/chmod are || true on a dev host).
# ----------------------------------------------------------------------------
echo "--- B: behavioral (stub validator, temp dir) ---"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

# Stub validator: prints a known JSON, exits with the rc passed via env STUB_RC.
_stub="$_tmp/stub-validate"
cat > "$_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"status":"OK","findings":[]}'
exit "${STUB_RC:-0}"
STUB
chmod +x "$_stub"

_runfile="$_tmp/firewall-validate/last.json"

# B1: rc=0 path → file written with the JSON, wrapper exit code 0.
STUB_RC=0 NFTBAN_RUN_DIR="$_tmp" NFTBAN_VALIDATE_BIN="$_stub" bash "$_wrapper" >/dev/null 2>&1
_w_rc=$?
if [[ "$_w_rc" == "0" ]]; then
    _t_assert "B1a: wrapper preserves rc=0 from the validator" 0
else
    _t_assert "B1a: wrapper preserves rc=0 from the validator" 1 "wrapper rc=$_w_rc"
fi
if [[ -f "$_runfile" ]] && grep -q '"status":"OK"' "$_runfile"; then
    _t_assert "B1b: last.json exists and contains the validator JSON" 0
else
    _t_assert "B1b: last.json exists and contains the validator JSON" 1 \
        "runfile=$_runfile contents=[$(cat "$_runfile" 2>/dev/null)]"
fi

# B2: rc=3 path (DEGRADED) → wrapper exit code 3 (rc preserved), file still written.
STUB_RC=3 NFTBAN_RUN_DIR="$_tmp" NFTBAN_VALIDATE_BIN="$_stub" bash "$_wrapper" >/dev/null 2>&1
_w_rc=$?
if [[ "$_w_rc" == "3" ]]; then
    _t_assert "B2a: wrapper preserves non-zero rc=3 from the validator (DEGRADED propagates)" 0
else
    _t_assert "B2a: wrapper preserves non-zero rc=3 from the validator (DEGRADED propagates)" 1 "wrapper rc=$_w_rc"
fi
if [[ -f "$_runfile" ]] && grep -q '"status":"OK"' "$_runfile"; then
    _t_assert "B2b: last.json is written even when the validator exits non-zero" 0
else
    _t_assert "B2b: last.json is written even when the validator exits non-zero" 1
fi

# B3: stale-cleanup — pre-seed last.json with old content, then run a stub that
#     exits non-zero WITHOUT printing. The pre-run rm -f must remove the old
#     content (file is rewritten empty, not left stale).
_silent_stub="$_tmp/stub-silent"
cat > "$_silent_stub" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_RC:-1}"
STUB
chmod +x "$_silent_stub"

mkdir -p "$_tmp/firewall-validate"
printf '%s\n' '{"status":"STALE_OLD_RUN"}' > "$_runfile"

STUB_RC=1 NFTBAN_RUN_DIR="$_tmp" NFTBAN_VALIDATE_BIN="$_silent_stub" bash "$_wrapper" >/dev/null 2>&1
_w_rc=$?
if ! grep -q 'STALE_OLD_RUN' "$_runfile" 2>/dev/null; then
    _t_assert "B3a: pre-run rm -f removes stale prior last.json content" 0
else
    _t_assert "B3a: pre-run rm -f removes stale prior last.json content" 1 \
        "stale content survived: [$(cat "$_runfile" 2>/dev/null)]"
fi
if [[ "$_w_rc" == "1" ]]; then
    _t_assert "B3b: wrapper preserves rc=1 from the silent (no-output) validator" 0
else
    _t_assert "B3b: wrapper preserves rc=1 from the silent (no-output) validator" 1 "wrapper rc=$_w_rc"
fi

# ----------------------------------------------------------------------------
# C: every changed shell file still parses.
# ----------------------------------------------------------------------------
echo "--- C: parse ---"
_broken=""
for f in "$_wrapper" "$_firewall_cli" "${BASH_SOURCE[0]}"; do
    bash -n "$f" 2>/dev/null || _broken+="$f"$'\n'
done
if [[ -z "$_broken" ]]; then
    _t_assert "C1: wrapper, cmd_firewall.sh, and this test all parse (bash -n)" 0
else
    _t_assert "C1: wrapper, cmd_firewall.sh, and this test all parse (bash -n)" 1 \
        "broken:"$'\n'"$_broken"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "V131.1 D13 Option C output-capture test summary"
echo "  Passed:  $_pass"
echo "  Failed:  $_fail"
if [[ "$_fail" -gt 0 ]]; then
    echo "  Failed assertions:"
    for n in "${_failed_names[@]}"; do echo "    - $n"; done
fi
echo "-------------------------------------------------------------------------------"
[[ "$_fail" -eq 0 ]]
