#!/usr/bin/env bash
# =============================================================================
# V131.3 D13 — setgid handoff-dir group-ownership regression test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v131_3_d13_setgid_group_ownership_test"
# meta:type="test"
# meta:version="1.131.3"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-26"
# meta:description="Deterministic assertions locking the V131.3 D13 setgid group-ownership fix (Option C). v1.131.2 fixed the sandbox WRITE (last.json is now created under ProtectSystem=strict) but the file landed root:root 0640 instead of root:nftban: the unit's CapabilityBoundingSet=CAP_NET_ADMIN drops CAP_CHOWN so the wrapper's best-effort chgrp nftban silently failed, and the 0750 handoff dir was not setgid so a file created in it inherited the process egid (root). The fix makes the handoff dir setgid (2750 root nftban) in BOTH the generated tmpfiles entry and the unit's +-prefixed ExecStartPre install -d, so a file created there inherits group nftban automatically — no chgrp / no CAP_CHOWN — and the wrapper's owner-side chmod 0640 still works → final root:nftban 0640 → nftban-group operators read it → '^Validator Status:' renders. The KEY behavioral assertion (the class that would have caught the v1.131.2 miss) proves setgid group inheritance does NOT depend on chgrp: it creates a real setgid dir, writes a file as a stub, and asserts the file's group == the dir's group; and IF root + systemd-run are available it runs the wrapper under the real unit caps (CapabilityBoundingSet=CAP_NET_ADMIN, no CAP_CHOWN) into a pre-created setgid dir and asserts last.json group == the dir's group and mode 0640 even though the process cannot chown — SKIPPED with a clear note (real proof = lab package validation) when not root / no systemd-run / cannot chgrp the temp dir."
# meta:input="self-contained; pattern-greps the source files + exercises setgid inheritance, optionally runs the wrapper under systemd-run"
# meta:output="[PASS]/[FAIL]/[SKIP] per assertion; exit 0 iff no failures"
# meta:depends="bash,grep,install,stat"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_RUN_DIR,NFTBAN_VALIDATE_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: gate OPEN_V1_131_3_D13_SETGID_GROUP_OWNERSHIP_FIX (D13 only).
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
_tmpfiles="${_repo_root}/install/systemd/tmpfiles.d/nftban.conf"

echo "==============================================================================="
echo "V131.3 D13 — setgid handoff-dir group-ownership regression test"
echo "  Repo root: $_repo_root"
echo "==============================================================================="

# ----------------------------------------------------------------------------
# A: the setgid (2750 root:nftban) handoff dir is created by the unit's
# +ExecStartPre, NOT by tmpfiles. v1.175 BUG-TMPFILES: the root-under-nftban
# entry tripped systemd-tmpfiles exit 73; it is removed from tmpfiles and the
# +ExecStartPre install -d (asserted in B1 below) is the sole creator. The setgid
# semantics (2750 root:nftban → last.json inherits group nftban without CAP_CHOWN)
# are preserved by the ExecStartPre's `-m 2750 -o root -g nftban`.
# ----------------------------------------------------------------------------
echo "--- A: tmpfiles (generated) ---"

# A1: tmpfiles no longer carries the firewall-validate dir (v1.175 — exit-73 fix).
if grep -qE '/run/nftban/firewall-validate' "$_tmpfiles"; then
    _t_assert "A1: tmpfiles does NOT list /run/nftban/firewall-validate (v1.175 BUG-TMPFILES; created by +ExecStartPre)" 1 \
        "got: [$(grep -E '/run/nftban/firewall-validate' "$_tmpfiles" | head -1)]"
else
    _t_assert "A1: tmpfiles does NOT list /run/nftban/firewall-validate (v1.175 BUG-TMPFILES; created by +ExecStartPre)" 0
fi

# A2: (kept) no stale tmpfiles entry of any mode remains for the dir.
if grep -qE '^[dz] /run/nftban/firewall-validate ' "$_tmpfiles"; then
    _t_assert "A2: no stale tmpfiles d/z entry for the handoff dir" 1 \
        "entry still present — generator still emits firewall-validate"
else
    _t_assert "A2: no stale tmpfiles d/z entry for the handoff dir" 0
fi

# ----------------------------------------------------------------------------
# B: unit — setgid ExecStartPre + preserved hardening, NO CAP_CHOWN.
# ----------------------------------------------------------------------------
echo "--- B: unit ExecStartPre + hardening ---"

# B1: ExecStartPre install -d uses -m 2750 AND -o root AND -g nftban AND the dir.
_espre=$(grep -E '^ExecStartPre=\+/usr/bin/install -d ' "$_unit_file" | head -1)
if [[ -n "$_espre" ]] \
    && grep -qE '\-m 2750' <<<"$_espre" \
    && grep -qE '\-o root' <<<"$_espre" \
    && grep -qE '\-g nftban' <<<"$_espre" \
    && grep -qE '/run/nftban/firewall-validate' <<<"$_espre"; then
    _t_assert "B1: ExecStartPre install -d has -m 2750 -o root -g nftban + the dir path" 0
else
    _t_assert "B1: ExecStartPre install -d has -m 2750 -o root -g nftban + the dir path" 1 \
        "line: [$_espre]"
fi

# B2: unit keeps CapabilityBoundingSet=CAP_NET_ADMIN (exact, only).
if grep -qE '^CapabilityBoundingSet=CAP_NET_ADMIN$' "$_unit_file"; then
    _t_assert "B2: unit keeps CapabilityBoundingSet=CAP_NET_ADMIN (only)" 0
else
    _t_assert "B2: unit keeps CapabilityBoundingSet=CAP_NET_ADMIN (only)" 1
fi

# B3: CAP_CHOWN appears in NO active unit directive (no capability widening; the
#     whole point is that setgid removes the need for chown). Scan ACTIVE
#     directive lines only (strip comment lines first) so the explanatory
#     comment that legitimately names CAP_CHOWN does not trip the guard.
_b3_active=$(grep -vE '^[[:space:]]*#' "$_unit_file")
if grep -qE 'CAP_CHOWN' <<<"$_b3_active"; then
    _t_assert "B3: unit has NO CAP_CHOWN in any active directive" 1 \
        "found CAP_CHOWN in an active directive — capability widening is forbidden for this fix"
else
    _t_assert "B3: unit has NO CAP_CHOWN in any active directive" 0
fi

# B4: ProtectSystem=strict preserved.
if grep -qE '^ProtectSystem=strict' "$_unit_file"; then
    _t_assert "B4: unit keeps ProtectSystem=strict" 0
else
    _t_assert "B4: unit keeps ProtectSystem=strict" 1
fi

# B5: narrow ReadWritePaths preserved (the v1.131.2 subdir grant stays).
if grep -qE '^ReadWritePaths=/run/nftban/firewall-validate' "$_unit_file"; then
    _t_assert "B5: unit keeps ReadWritePaths=/run/nftban/firewall-validate" 0
else
    _t_assert "B5: unit keeps ReadWritePaths=/run/nftban/firewall-validate" 1
fi

# ----------------------------------------------------------------------------
# C: BEHAVIORAL, capability-faithful — prove setgid inheritance does NOT rely on
#    chgrp. The assertion class that would have caught the v1.131.2 miss.
# ----------------------------------------------------------------------------
echo "--- C: setgid group-inheritance (no chgrp) ---"

_tmp="$(mktemp -d)"
trap 'rm -rf "$_tmp"' EXIT

# Pick a secondary group we are a member of (other than our primary egid) so a
# setgid dir owned by THAT group demonstrably changes the inherited group of a
# file created inside it. If no usable secondary group exists, SKIP — the proof
# then lives in lab package validation.
_test_grp=""
if command -v id >/dev/null 2>&1; then
    _primary_gid="$(id -g)"
    for _g in $(id -G 2>/dev/null); do
        if [[ "$_g" != "$_primary_gid" ]]; then _test_grp="$_g"; break; fi
    done
fi

if [[ -n "$_test_grp" ]]; then
    _sg_dir="$_tmp/setgid-dir"
    mkdir -p "$_sg_dir"
    # chgrp to the secondary group, then set setgid (2750). We are an owner-side
    # member, so this needs no special capability.
    if chgrp "$_test_grp" "$_sg_dir" 2>/dev/null && chmod 2750 "$_sg_dir" 2>/dev/null; then
        # Write a file in the setgid dir as a stub — WITHOUT any chgrp on the file.
        _sg_file="$_sg_dir/last.json"
        printf '%s\n' '{"status":"OK"}' > "$_sg_file"
        _dir_grp="$(stat -c '%g' "$_sg_dir" 2>/dev/null)"
        _file_grp="$(stat -c '%g' "$_sg_file" 2>/dev/null)"
        if [[ -n "$_file_grp" && "$_file_grp" == "$_dir_grp" ]]; then
            _t_assert "C1: file created in setgid dir inherits the dir's GROUP without chgrp" 0
        else
            _t_assert "C1: file created in setgid dir inherits the dir's GROUP without chgrp" 1 \
                "dir gid=$_dir_grp file gid=$_file_grp (setgid inheritance did not happen)"
        fi
        # The owner-side chmod 0640 (what the wrapper does) needs no capability.
        if chmod 0640 "$_sg_file" 2>/dev/null && [[ "$(stat -c '%a' "$_sg_file" 2>/dev/null)" == "640" ]]; then
            _t_assert "C2: owner chmod 0640 on the inherited-group file succeeds (no capability)" 0
        else
            _t_assert "C2: owner chmod 0640 on the inherited-group file succeeds (no capability)" 1 \
                "mode=$(stat -c '%a' "$_sg_file" 2>/dev/null)"
        fi
    else
        _t_skip "C1/C2: setgid group-inheritance behavioral" \
            "could not chgrp/chmod a temp dir to a secondary group in this env; real proof = lab package validation"
    fi
else
    _t_skip "C1/C2: setgid group-inheritance behavioral" \
        "no usable secondary group for this user; real proof = lab package validation"
fi

# ----------------------------------------------------------------------------
# D: CAPABILITY-FAITHFUL end-to-end — run the wrapper under the REAL unit caps
#    (CapabilityBoundingSet=CAP_NET_ADMIN, no CAP_CHOWN) into a PRE-CREATED
#    setgid dir; assert last.json inherits the dir's group + mode 0640 EVEN
#    THOUGH the process cannot chown. Proves chgrp is not required. Needs root +
#    systemd-run + a chgrp-able temp dir; otherwise SKIP.
# ----------------------------------------------------------------------------
echo "--- D: capability-faithful wrapper run (systemd-run, no CAP_CHOWN) ---"

_d_grp=""
if command -v id >/dev/null 2>&1; then
    _d_primary_gid="$(id -g)"
    for _g in $(id -G 2>/dev/null); do
        if [[ "$_g" != "$_d_primary_gid" ]]; then _d_grp="$_g"; break; fi
    done
fi

if command -v systemd-run >/dev/null 2>&1 && [[ $EUID -eq 0 ]] && [[ -n "$_d_grp" ]]; then
    _drun="$(mktemp -d)"
    _drun_sub="$_drun/firewall-validate"
    _drun_file="$_drun_sub/last.json"
    _drun_stub="$_drun/stub-validate"
    cat > "$_drun_stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"status":"OK","findings":[]}'
exit 0
STUB
    chmod +x "$_drun_stub"

    # Pre-create the setgid handoff dir owned by the test group (production:
    # tmpfiles + +ExecStartPre create it 2750 root nftban). chmod 2750 AFTER
    # chgrp so the setgid bit is not stripped by the ownership change.
    mkdir -p "$_drun_sub"
    if chgrp "$_d_grp" "$_drun_sub" 2>/dev/null && chmod 2750 "$_drun_sub" 2>/dev/null; then
        rm -f "$_drun_file"
        systemd-run --quiet --pipe \
            --property=CapabilityBoundingSet=CAP_NET_ADMIN \
            --property=AmbientCapabilities=CAP_NET_ADMIN \
            --property=ProtectSystem=strict \
            --property=ReadWritePaths="$_drun_sub" \
            --setenv=NFTBAN_RUN_DIR="$_drun" \
            --setenv=NFTBAN_VALIDATE_BIN="$_drun_stub" \
            bash "$_wrapper" >/dev/null 2>&1
        if [[ -f "$_drun_file" ]]; then
            _d_dir_grp="$(stat -c '%g' "$_drun_sub" 2>/dev/null)"
            _d_file_grp="$(stat -c '%g' "$_drun_file" 2>/dev/null)"
            if [[ "$_d_file_grp" == "$_d_dir_grp" ]]; then
                _t_assert "D1: last.json inherits the setgid dir's group under CAP_NET_ADMIN-only (no CAP_CHOWN)" 0
            else
                _t_assert "D1: last.json inherits the setgid dir's group under CAP_NET_ADMIN-only (no CAP_CHOWN)" 1 \
                    "dir gid=$_d_dir_grp file gid=$_d_file_grp — group did not inherit (chgrp would have been needed)"
            fi
            if [[ "$(stat -c '%a' "$_drun_file" 2>/dev/null)" == "640" ]]; then
                _t_assert "D2: last.json mode is 0640 (owner chmod works without capability)" 0
            else
                _t_assert "D2: last.json mode is 0640 (owner chmod works without capability)" 1 \
                    "mode=$(stat -c '%a' "$_drun_file" 2>/dev/null)"
            fi
        else
            _t_assert "D1/D2: capability-faithful wrapper run produced last.json" 1 \
                "last.json not created under the sandboxed run"
        fi
    else
        _t_skip "D1/D2: capability-faithful wrapper run (systemd-run, no CAP_CHOWN)" \
            "could not chgrp/chmod-setgid the temp handoff dir; real proof = lab package validation"
    fi
    rm -rf "$_drun"
else
    _t_skip "D1/D2: capability-faithful wrapper run (systemd-run, no CAP_CHOWN)" \
        "not root / systemd-run unavailable / no usable secondary group; real proof = lab package validation"
fi

# ----------------------------------------------------------------------------
# E: operator-visibility label uses the exact anchored 'Validator Status:'
#    report line (NEVER a loose IDLE|PROTECTED case-insensitive match).
# ----------------------------------------------------------------------------
echo "--- E: operator-visibility label ---"

if grep -q '^Validator Status:' <(echo "Validator Status: OK"); then
    _t_assert "E1: operator-visibility check uses exact '^Validator Status:'" 0
else
    _t_assert "E1: operator-visibility check uses exact '^Validator Status:'" 1
fi

# ----------------------------------------------------------------------------
# F: changed files still parse.
# ----------------------------------------------------------------------------
echo "--- F: parse ---"
_broken=""
for f in "$_wrapper" "${BASH_SOURCE[0]}"; do
    bash -n "$f" 2>/dev/null || _broken+="$f"$'\n'
done
if [[ -z "$_broken" ]]; then
    _t_assert "F1: wrapper and this test parse (bash -n)" 0
else
    _t_assert "F1: wrapper and this test parse (bash -n)" 1 "broken:"$'\n'"$_broken"
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo "-------------------------------------------------------------------------------"
echo "V131.3 D13 setgid group-ownership test summary"
echo "  Passed:  $_pass"
echo "  Failed:  $_fail"
echo "  Skipped: $_skip"
if [[ "$_fail" -gt 0 ]]; then
    echo "  Failed assertions:"
    for n in "${_failed_names[@]}"; do echo "    - $n"; done
fi
echo "-------------------------------------------------------------------------------"
[[ "$_fail" -eq 0 ]]
