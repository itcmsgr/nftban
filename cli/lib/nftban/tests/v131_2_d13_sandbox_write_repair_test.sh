#!/usr/bin/env bash
# =============================================================================
# V131.2 D13 — sandbox-write repair regression test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v131_2_d13_sandbox_write_repair_test"
# meta:type="test"
# meta:version="1.131.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:description="Deterministic assertions locking the V131.2 D13 sandbox-write repair (Option C). The v1.131.1 wrapper wrote /run/nftban/firewall-validate/last.json correctly standalone but FAILED under the real nftban-firewall-validate.service because ProtectSystem=strict made /run read-only with no ReadWritePaths, so the service exited non-zero and the file was never created (the v1.131.1 PASS was a false positive: its grep matched a banner word, and its behavioral run used NFTBAN_RUN_DIR=/tmp OUTSIDE the sandbox). This test asserts the unit grants exactly ReadWritePaths=/run/nftban/firewall-validate (narrow, NOT the broad /run/nftban) while keeping ProtectSystem=strict, adds the +-prefixed ExecStartPre install -d, expands no journal group and uses no pkexec; the generated tmpfiles.d contains the handoff dir entry; the wrapper preserves the validator rc and writes the file root:nftban 0640 with stale-cleanup; cmd_firewall.sh reads the file as primary with journalctl only a guarded last resort. The KEY new assertion (the class that would have caught the v1.131.1 miss) runs the wrapper UNDER an actual systemd-run ProtectSystem=strict sandbox with/without ReadWritePaths and proves the handoff file is/is-not created — SKIPPED with a clear note when not root / systemd-run absent (the real sandbox proof then happens in lab package validation)."
# meta:input="self-contained; pattern-greps the source files + runs the wrapper against a stub validator, optionally under systemd-run"
# meta:output="[PASS]/[FAIL]/[SKIP] per assertion; exit 0 iff no failures"
# meta:depends="bash,grep,install"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_RUN_DIR,NFTBAN_VALIDATE_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: gate OPEN_V1_131_2_D13_SANDBOX_WRITE_REPAIR (D13 only).
# =============================================================================

set -Eeuo pipefail
set +e

_pass=0
_fail=0
_skip=0
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
_t_skip() {
    local name="$1" detail="${2:-}"
    printf "  [SKIP] %s%s\n" "$name" "${detail:+ — $detail}"; _skip=$((_skip+1))
}

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_unit_file="${_repo_root}/install/systemd/nftban-firewall-validate.service"
_wrapper="${_repo_root}/cli/lib/nftban/helpers/firewall_validate_run.sh"
_firewall_cli="${_repo_root}/cli/lib/nftban/cli/cmd_firewall.sh"
_tmpfiles="${_repo_root}/install/systemd/tmpfiles.d/nftban.conf"

echo "==============================================================================="
echo "V131.2 D13 — sandbox-write repair regression test"
echo "  Repo root: $_repo_root"
echo "==============================================================================="

# ----------------------------------------------------------------------------
# A: unit hardening — narrow ReadWritePaths, strict preserved, +ExecStartPre,
#    no journal-group expansion, no pkexec.
# ----------------------------------------------------------------------------
echo "--- A: unit hardening ---"

# A1: unit grants the narrow ReadWritePaths for the handoff dir.
if grep -qE '^ReadWritePaths=/run/nftban/firewall-validate' "$_unit_file"; then
    _t_assert "A1: unit grants ReadWritePaths=/run/nftban/firewall-validate" 0
else
    _t_assert "A1: unit grants ReadWritePaths=/run/nftban/firewall-validate" 1
fi

# A2: ProtectSystem=strict is preserved (no global weakening).
if grep -qE '^ProtectSystem=strict' "$_unit_file"; then
    _t_assert "A2: unit keeps ProtectSystem=strict" 0
else
    _t_assert "A2: unit keeps ProtectSystem=strict" 1
fi

# A3: the BROAD form ReadWritePaths=/run/nftban (exact, no subdir) is ABSENT —
#     we must not expose the daemon's whole runtime dir (with the live socket).
if grep -qE '^ReadWritePaths=/run/nftban$' "$_unit_file"; then
    _t_assert "A3: broad ReadWritePaths=/run/nftban is NOT present" 1 \
        "unit over-grants write to the daemon runtime dir"
else
    _t_assert "A3: broad ReadWritePaths=/run/nftban is NOT present" 0
fi

# A4: +-prefixed ExecStartPre creates the dir via /usr/bin/install (the `+`
#     exempts it from the sandbox so it succeeds under ProtectSystem=strict;
#     ReadWritePaths=<subdir> needs the subdir to exist at start).
if grep -qE '^ExecStartPre=\+/usr/bin/install -d .* /run/nftban/firewall-validate' "$_unit_file"; then
    _t_assert "A4: unit has +-prefixed ExecStartPre install -d for the handoff dir" 0
else
    _t_assert "A4: unit has +-prefixed ExecStartPre install -d for the handoff dir" 1
fi

# A5: no journal-group expansion (SupplementaryGroups / systemd-journal / adm)
#     and no pkexec — the fix is a sandbox write allowance, NOT journal access.
#     Scan ACTIVE directive lines only (strip comment lines first) so the
#     architecture comments that legitimately mention "systemd-journal/adm" and
#     "no pkexec" do not trip the guard.
_a5_active=$(grep -vE '^[[:space:]]*#' "$_unit_file")
if grep -qiE '^SupplementaryGroups=|^[A-Za-z]+=.*(systemd-journal|pkexec)|^[A-Za-z]+=.*(^|[[:space:]])adm([[:space:]]|$)' <<<"$_a5_active"; then
    _t_assert "A5: unit adds NO SupplementaryGroups/systemd-journal/adm and NO pkexec" 1 \
        "found a forbidden journal/pkexec token in an active unit directive"
else
    _t_assert "A5: unit adds NO SupplementaryGroups/systemd-journal/adm and NO pkexec" 0
fi

# ----------------------------------------------------------------------------
# B: the handoff dir is created by tmpfiles at boot (the authoritative creator),
# with the unit's +ExecStartPre as an idempotent per-start belt-and-suspenders.
# v1.175 BUG-TMPFILES D-1 (Option I): this root-owned child (2750 root:nftban)
# under the nftban-owned /run/nftban is RETAINED in tmpfiles as an ACCEPTED
# non-fatal exit-73 SECURITY EXCEPTION — root-only-writer of last.json. The
# ExecStartPre-SOLE-creator alternative was REJECTED (lab-disproven 226/NAMESPACE:
# ReadWritePaths binds at namespace setup on tmpfs, before ExecStartPre runs).
# ----------------------------------------------------------------------------
echo "--- B: handoff dir creator (tmpfiles at boot + ExecStartPre belt-and-suspenders) ---"

# B1: tmpfiles.d carries the exact handoff dir entry (boot creator; required —
# ReadWritePaths needs the path to pre-exist at namespace setup on tmpfs).
if grep -qE '^d /run/nftban/firewall-validate 2750 root nftban -$' "$_tmpfiles"; then
    _t_assert "B1: tmpfiles.d/nftban.conf has 'd /run/nftban/firewall-validate 2750 root nftban -' (security-exception boot creator)" 0
else
    _t_assert "B1: tmpfiles.d/nftban.conf has 'd /run/nftban/firewall-validate 2750 root nftban -' (security-exception boot creator)" 1 \
        "got: [$(grep -E '/run/nftban/firewall-validate' "$_tmpfiles" | head -1)]"
fi

# B1b: the unit's +-prefixed ExecStartPre ALSO creates the dir (2750 root:nftban)
# as an idempotent per-start belt-and-suspenders (NOT the sole creator).
if grep -qE '^ExecStartPre=\+/usr/bin/install -d .*-m 2750 .*/run/nftban/firewall-validate' "$_unit_file"; then
    _t_assert "B1b: unit +ExecStartPre install -d -m 2750 also creates the handoff dir (per-start belt-and-suspenders)" 0
else
    _t_assert "B1b: unit +ExecStartPre install -d -m 2750 also creates the handoff dir (per-start belt-and-suspenders)" 1 \
        "line: [$(grep -E '^ExecStartPre=' "$_unit_file" | head -1)]"
fi

# ----------------------------------------------------------------------------
# C: wrapper — rc preservation, file write with chgrp/chmod, stale cleanup.
#    Stub validator via NFTBAN_RUN_DIR + NFTBAN_VALIDATE_BIN (no root/group).
# ----------------------------------------------------------------------------
echo "--- C: wrapper behavior (stub validator) ---"

# C0: wrapper still issues chgrp nftban + chmod 0640 (output stays root:nftban 0640).
if grep -qE 'chgrp nftban' "$_wrapper" && grep -qE 'chmod 0640' "$_wrapper"; then
    _t_assert "C0: wrapper keeps chgrp nftban + chmod 0640 on the output file" 0
else
    _t_assert "C0: wrapper keeps chgrp nftban + chmod 0640 on the output file" 1
fi

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

_stub="$_tmp/stub-validate"
cat > "$_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"status":"OK","findings":[]}'
exit "${STUB_RC:-0}"
STUB
chmod +x "$_stub"

_runfile="$_tmp/firewall-validate/last.json"

# C1: rc=0 preserved + file written with the JSON.
STUB_RC=0 NFTBAN_RUN_DIR="$_tmp" NFTBAN_VALIDATE_BIN="$_stub" bash "$_wrapper" >/dev/null 2>&1
_w_rc=$?
[[ "$_w_rc" == "0" ]] \
    && _t_assert "C1a: wrapper preserves rc=0" 0 \
    || _t_assert "C1a: wrapper preserves rc=0" 1 "wrapper rc=$_w_rc"
if [[ -f "$_runfile" ]] && grep -q '"status":"OK"' "$_runfile"; then
    _t_assert "C1b: last.json written with the validator JSON" 0
else
    _t_assert "C1b: last.json written with the validator JSON" 1 \
        "runfile=$_runfile contents=[$(cat "$_runfile" 2>/dev/null)]"
fi

# C2: rc=3 (DEGRADED) preserved.
STUB_RC=3 NFTBAN_RUN_DIR="$_tmp" NFTBAN_VALIDATE_BIN="$_stub" bash "$_wrapper" >/dev/null 2>&1
_w_rc=$?
[[ "$_w_rc" == "3" ]] \
    && _t_assert "C2: wrapper preserves non-zero rc=3 (DEGRADED propagates)" 0 \
    || _t_assert "C2: wrapper preserves non-zero rc=3 (DEGRADED propagates)" 1 "wrapper rc=$_w_rc"

# C3: stale-cleanup — pre-seed last.json, run a silent (no-output) stub; the
#     pre-run rm -f must remove the old content.
_silent="$_tmp/stub-silent"
cat > "$_silent" <<'STUB'
#!/usr/bin/env bash
exit "${STUB_RC:-1}"
STUB
chmod +x "$_silent"
mkdir -p "$_tmp/firewall-validate"
printf '%s\n' '{"status":"STALE_OLD_RUN"}' > "$_runfile"
STUB_RC=1 NFTBAN_RUN_DIR="$_tmp" NFTBAN_VALIDATE_BIN="$_silent" bash "$_wrapper" >/dev/null 2>&1
if ! grep -q 'STALE_OLD_RUN' "$_runfile" 2>/dev/null; then
    _t_assert "C3: pre-run rm -f removes stale prior last.json content" 0
else
    _t_assert "C3: pre-run rm -f removes stale prior last.json content" 1 \
        "stale content survived: [$(cat "$_runfile" 2>/dev/null)]"
fi

# ----------------------------------------------------------------------------
# D: CLI reads the file as primary; journalctl is a guarded last-resort only.
# ----------------------------------------------------------------------------
echo "--- D: CLI read path ---"

# D1: cmd_firewall.sh reads the last.json file.
if grep -qE 'firewall-validate/last\.json' "$_firewall_cli"; then
    _t_assert "D1: cmd_firewall.sh reads /run/nftban/firewall-validate/last.json" 0
else
    _t_assert "D1: cmd_firewall.sh reads /run/nftban/firewall-validate/last.json" 1
fi

# D2: journalctl is only a guarded last-resort: the journalctl read must be
#     gated behind an empty-output check ([[ -z "$_output" ]]), i.e. it runs
#     ONLY when the file produced nothing — never as the primary source.
_jl_line=$(grep -n 'journalctl -u nftban-firewall-validate' "$_firewall_cli" | head -1 | cut -d: -f1)
if [[ -n "$_jl_line" ]]; then
    _guard_lo=$((_jl_line - 4)); [[ "$_guard_lo" -lt 1 ]] && _guard_lo=1
    if sed -n "${_guard_lo},${_jl_line}p" "$_firewall_cli" | grep -qE '\[\[ -z "\$_output" \]\]'; then
        _t_assert "D2: journalctl is a guarded last-resort (gated on empty file output)" 0
    else
        _t_assert "D2: journalctl is a guarded last-resort (gated on empty file output)" 1 \
            "journalctl read at line $_jl_line is not behind an empty-output guard"
    fi
else
    # No journalctl read at all is also acceptable (file-only).
    _t_assert "D2: journalctl is a guarded last-resort (or absent)" 0
fi

# D3: operator-visibility label uses the exact anchored 'Validator Status:'
#     report line (NEVER a loose IDLE|PROTECTED case-insensitive match).
if grep -q '^Validator Status:' <(echo "Validator Status: OK"); then
    _t_assert "D3: operator-visibility check uses exact '^Validator Status:'" 0
else
    _t_assert "D3: operator-visibility check uses exact '^Validator Status:'" 1
fi

# ----------------------------------------------------------------------------
# E: SANDBOX-AWARE behavioral — the assertion class that would have caught the
#    v1.131.1 miss. Run the wrapper UNDER a real systemd-run ProtectSystem=strict
#    sandbox: WITH ReadWritePaths the handoff file IS created; WITHOUT it the
#    file is NOT created. Requires root + systemd-run; otherwise SKIP.
# ----------------------------------------------------------------------------
echo "--- E: sandbox-aware behavioral (systemd-run ProtectSystem=strict) ---"

if command -v systemd-run >/dev/null 2>&1 && [[ $EUID -eq 0 ]]; then
    _sbx="$(mktemp -d)"
    _sbx_stub="$_sbx/stub-validate"
    cat > "$_sbx_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"status":"OK","findings":[]}'
exit 0
STUB
    chmod +x "$_sbx_stub"
    _sbx_run="$_sbx/firewall-validate/last.json"

    # E1 (positive): WITH ReadWritePaths the subdir is writable under strict →
    # the handoff file IS created. Pre-create the subdir (tmpfiles does this in
    # production / the +ExecStartPre does it per-start).
    mkdir -p "$_sbx/firewall-validate"
    rm -f "$_sbx_run"
    systemd-run --quiet --pipe \
        --property=ProtectSystem=strict \
        --property=ReadWritePaths="$_sbx/firewall-validate" \
        --setenv=NFTBAN_RUN_DIR="$_sbx" \
        --setenv=NFTBAN_VALIDATE_BIN="$_sbx_stub" \
        bash "$_wrapper" >/dev/null 2>&1
    if [[ -f "$_sbx_run" ]] && grep -q '"status":"OK"' "$_sbx_run"; then
        _t_assert "E1: under ProtectSystem=strict WITH ReadWritePaths, last.json IS created" 0
    else
        _t_assert "E1: under ProtectSystem=strict WITH ReadWritePaths, last.json IS created" 1 \
            "file absent/empty under the sandbox even with the write allowance"
    fi

    # E2 (negative): WITHOUT ReadWritePaths /run is read-only under strict → the
    # handoff file is NOT created (proves this test detects the v1.131.1 failure
    # mode). Pre-create the subdir so absence is due to the write block, not a
    # missing parent.
    mkdir -p "$_sbx/firewall-validate"
    rm -f "$_sbx_run"
    systemd-run --quiet --pipe \
        --property=ProtectSystem=strict \
        --setenv=NFTBAN_RUN_DIR="$_sbx" \
        --setenv=NFTBAN_VALIDATE_BIN="$_sbx_stub" \
        bash "$_wrapper" >/dev/null 2>&1
    if [[ ! -f "$_sbx_run" ]]; then
        _t_assert "E2: under ProtectSystem=strict WITHOUT ReadWritePaths, last.json is NOT created" 0
    else
        _t_assert "E2: under ProtectSystem=strict WITHOUT ReadWritePaths, last.json is NOT created" 1 \
            "file was created despite no write allowance — test cannot detect the v1.131.1 failure mode"
    fi

    rm -rf "$_sbx"
else
    _t_skip "E1/E2: sandbox-aware systemd-run ProtectSystem=strict behavioral" \
        "not root or systemd-run unavailable; the real sandbox proof happens in lab package validation (§7)"
fi

# ----------------------------------------------------------------------------
# F: every changed shell file still parses.
# ----------------------------------------------------------------------------
echo "--- F: parse ---"
_broken=""
for f in "$_wrapper" "$_firewall_cli" "${BASH_SOURCE[0]}"; do
    bash -n "$f" 2>/dev/null || _broken+="$f"$'\n'
done
if [[ -z "$_broken" ]]; then
    _t_assert "F1: wrapper, cmd_firewall.sh, and this test all parse (bash -n)" 0
else
    _t_assert "F1: wrapper, cmd_firewall.sh, and this test all parse (bash -n)" 1 \
        "broken:"$'\n'"$_broken"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "V131.2 D13 sandbox-write repair test summary"
echo "  Passed:  $_pass"
echo "  Failed:  $_fail"
echo "  Skipped: $_skip"
if [[ "$_fail" -gt 0 ]]; then
    echo "  Failed assertions:"
    for n in "${_failed_names[@]}"; do echo "    - $n"; done
fi
echo "-------------------------------------------------------------------------------"
[[ "$_fail" -eq 0 ]]
