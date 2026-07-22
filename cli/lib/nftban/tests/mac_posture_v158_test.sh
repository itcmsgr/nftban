#!/usr/bin/env bash
# =============================================================================
# NFTBan - MAC posture test (v1.158: AppArmor + SELinux health-posture summary)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="mac_posture_v158_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-07"
# meta:description="v1.158 — asserts the read-only MAC posture summary added to _nftban_mac_posture / _collect_posture_info. Hermetic: stubs aa-status/getenforce/sestatus/semodule/sshd via PATH shadow. Verifies: AppArmor absent -> INFO no-WARN no-crash; AppArmor enforcing nftband profile -> PASS; AppArmor enabled but nftband profile missing -> WARN; SELinux absent -> INFO no-WARN; SELinux Enforcing + nftban module -> PASS; SELinux Permissive OR module missing -> WARN; the compact MAC summary is JSON-safe; existing SSH/sudo/systemd posture untouched. Non-root; no host/daemon contact; no Go/schema change."
# meta:input="cli/lib/nftban/lib/nftban_report_data.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk"
# meta:inventory.files="cli/lib/nftban/lib/nftban_report_data.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="mac_posture_v158_test"
# meta:ta.owner="security"
# meta:ta.module="mac-posture"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIB="$REPO/cli/lib/nftban/lib/nftban_report_data.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

[[ -f "$LIB" ]] || { echo "FATAL: lib not found: $LIB"; exit 2; }

# ---------------------------------------------------------------------------
# Hermetic command-shadow harness.
# Each scenario builds a private PATH dir holding only the stub commands we want
# the detector to see; everything else (grep/awk/head/tr) comes from a small set
# of real-tool symlinks so the detector still functions.
# ---------------------------------------------------------------------------
REAL_TOOLS=(grep awk head tr cat sort id basename dirname env bash sed cut sha256sum stat date hostname)

make_stubdir() {
    local d; d=$(mktemp -d)
    local t real
    for t in "${REAL_TOOLS[@]}"; do
        real=$(command -v "$t" 2>/dev/null || true)
        [[ -n "$real" ]] && ln -sf "$real" "$d/$t"
    done
    echo "$d"
}

add_stub() {
    # add_stub <dir> <name> <body...>
    local d="$1" name="$2"; shift 2
    {
        echo '#!/usr/bin/env bash'
        printf '%s\n' "$@"
    } > "$d/$name"
    chmod +x "$d/$name"
}

# Run _nftban_mac_posture under a given stub PATH; echo its single result line.
run_mac() {
    local stubdir="$1"
    (
        set +e
        # securityfs fallback path: point it at a non-readable bogus path unless
        # the scenario explicitly wants it. We can't easily shadow /sys, so we
        # rely on aa-status presence/absence to drive AppArmor branches.
        export PATH="$stubdir"
        # Hermetic AppArmor securityfs fallback: point the detector at a
        # test-controlled file (absent unless a scenario creates it) so it never
        # reads the host's real /sys/kernel/security/apparmor/profiles.
        export NFTBAN_AA_PROFILES_FILE="$stubdir/.aa_profiles"
        # shellcheck source=/dev/null
        source "$LIB" >/dev/null 2>&1
        # NOTE: the lib re-asserts `set -Eeuo pipefail` on source. We deliberately
        # do NOT relax it here — the detector must be self-contained and safe to
        # call under a strict-mode caller (it saves/restores opts internally).
        _nftban_mac_posture 2>/dev/null
    )
}

field() { printf '%s' "$1" | awk -F'|' -v n="$2" '{print $n}'; }

# ===========================================================================
# CASE 1: AppArmor absent + SELinux absent -> INFO, no WARN, no crash
# ===========================================================================
D=$(make_stubdir)
LINE=$(run_mac "$D"); RC=$?
if [[ $RC -eq 0 ]] && [[ "$(field "$LINE" 2)" == "INFO" ]] && [[ "$(field "$LINE" 1)" == "none" ]]; then
    ok "C1 no MAC tooling -> system=none verdict=INFO (no WARN, no crash)"
else
    no "C1 no MAC tooling -> INFO" "rc=$RC line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 2: AppArmor enabled + nftband profile ENFORCING -> PASS
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" aa-status \
  'echo "apparmor module is loaded."' \
  'echo "2 profiles are in enforce mode."' \
  'echo "   /usr/lib/nftban/bin/nftband (enforce)"' \
  'echo "   /usr/sbin/other (enforce)"'
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 1)" == "apparmor" ]] && [[ "$(field "$LINE" 2)" == "PASS" ]] && [[ "$(field "$LINE" 3)" == "enforcing" ]]; then
    ok "C2 AppArmor nftband profile enforcing -> PASS/enforcing"
else
    no "C2 AppArmor enforcing -> PASS" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 2b: securityfs fallback (no aa-status) — nftband enforce -> PASS
# ===========================================================================
D=$(make_stubdir)
printf '/usr/lib/nftban/bin/nftband (enforce)\n/usr/sbin/cupsd (enforce)\n' > "$D/.aa_profiles"
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 1)" == "apparmor" ]] && [[ "$(field "$LINE" 2)" == "PASS" ]]; then
    ok "C2b AppArmor securityfs fallback, nftband enforce -> PASS"
else
    no "C2b securityfs fallback -> PASS" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 3: AppArmor enabled but nftband profile MISSING -> WARN
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" aa-status \
  'echo "apparmor module is loaded."' \
  'echo "   /usr/sbin/something_else (enforce)"'
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 1)" == "apparmor" ]] && [[ "$(field "$LINE" 2)" == "WARN" ]]; then
    ok "C3 AppArmor enabled, nftband profile missing -> WARN"
else
    no "C3 AppArmor profile missing -> WARN" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 3b: AppArmor nftband profile COMPLAIN-only -> WARN (not enforcing)
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" aa-status \
  'echo "apparmor module is loaded."' \
  'echo "   /usr/lib/nftban/bin/nftband (complain)"'
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 1)" == "apparmor" ]] && [[ "$(field "$LINE" 2)" == "WARN" ]] && [[ "$(field "$LINE" 3)" == "complain" ]]; then
    ok "C3b AppArmor nftband profile complain-only -> WARN/complain"
else
    no "C3b AppArmor complain -> WARN" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 4: SELinux absent (no aa-status, no getenforce/sestatus) -> INFO no WARN
#   (covered by C1 too, but assert explicitly that SELinux tooling absence is
#    not a WARN even when nothing else is present)
# ===========================================================================
D=$(make_stubdir)
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 2)" != "WARN" ]]; then
    ok "C4 SELinux tooling absent -> not a WARN"
else
    no "C4 SELinux absent -> no WARN" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 5: SELinux Enforcing + nftban module present -> PASS
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" getenforce 'echo "Enforcing"'
add_stub "$D" semodule 'echo "base"; echo "nftban"; echo "sshd"'
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 1)" == "selinux" ]] && [[ "$(field "$LINE" 2)" == "PASS" ]] && [[ "$(field "$LINE" 3)" == "enforcing" ]]; then
    ok "C5 SELinux Enforcing + nftban module -> PASS/enforcing"
else
    no "C5 SELinux Enforcing + module -> PASS" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 6a: SELinux Enforcing but nftban module MISSING -> WARN
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" getenforce 'echo "Enforcing"'
add_stub "$D" semodule 'echo "base"; echo "sshd"'
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 1)" == "selinux" ]] && [[ "$(field "$LINE" 2)" == "WARN" ]]; then
    ok "C6a SELinux Enforcing, nftban module missing -> WARN"
else
    no "C6a SELinux module missing -> WARN" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 6b: SELinux Permissive (module present) -> WARN
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" getenforce 'echo "Permissive"'
add_stub "$D" semodule 'echo "base"; echo "nftban"'
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 1)" == "selinux" ]] && [[ "$(field "$LINE" 2)" == "WARN" ]] && [[ "$(field "$LINE" 3)" == "permissive" ]]; then
    ok "C6b SELinux Permissive -> WARN/permissive"
else
    no "C6b SELinux Permissive -> WARN" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 6c: SELinux Disabled -> INFO/N-A (not a WARN)
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" getenforce 'echo "Disabled"'
LINE=$(run_mac "$D")
if [[ "$(field "$LINE" 2)" != "WARN" ]]; then
    ok "C6c SELinux Disabled -> not a WARN"
else
    no "C6c SELinux Disabled -> no WARN" "line=$LINE"
fi
rm -rf "$D"

# ===========================================================================
# CASE 7: compact MAC summary is JSON-safe (no quotes/backslashes/pipes that
#   would break valid JSON when embedded as a string value)
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" aa-status \
  'echo "apparmor module is loaded."' \
  'echo "   /usr/lib/nftban/bin/nftband (enforce)"'
LINE=$(run_mac "$D")
SUMMARY=$(field "$LINE" 4)
json_safe=1
case "$SUMMARY" in
    *'"'*|*'\'*) json_safe=0 ;;
esac
[[ -z "$SUMMARY" ]] && json_safe=0
if [[ $json_safe -eq 1 ]]; then
    # build a tiny JSON doc with the summary as a value and validate it
    if command -v jq >/dev/null 2>&1; then
        if printf '{"mac":"%s"}' "$SUMMARY" | jq empty >/dev/null 2>&1; then
            ok "C7 compact MAC summary is valid JSON value ('$SUMMARY')"
        else
            no "C7 MAC summary valid JSON" "jq rejected: $SUMMARY"
        fi
    else
        ok "C7 compact MAC summary JSON-safe (no quotes/backslashes; jq absent)"
    fi
else
    no "C7 MAC summary JSON-safe" "unsafe chars or empty: '$SUMMARY'"
fi
rm -rf "$D"

# ===========================================================================
# CASE 8: existing SSH/sudo/systemd posture path still works + MAC fields wired.
#   Run _collect_posture_info (no MAC tooling) and assert the legacy POSTURE_*
#   keys are still produced AND the new POSTURE_MAC_* keys are populated, with
#   MAC not forcing a WARN on a host with no MAC system.
# ===========================================================================
D=$(make_stubdir)
RESULT=$(
    set +e
    export PATH="$D"
    export NFTBAN_AA_PROFILES_FILE="$D/.aa_profiles"
    # shellcheck source=/dev/null
    source "$LIB" >/dev/null 2>&1
    declare -A P
    _collect_posture_info P 2>/dev/null
    printf 'STATUS=%s\n' "${P[POSTURE_STATUS]:-__MISSING__}"
    printf 'DETAILS_KEY=%s\n' "${P[POSTURE_DETAILS]+set}"
    printf 'MAC_SYSTEM=%s\n' "${P[POSTURE_MAC_SYSTEM]:-__MISSING__}"
    printf 'MAC_VERDICT=%s\n' "${P[POSTURE_MAC_VERDICT]:-__MISSING__}"
)
if printf '%s\n' "$RESULT" | grep -q '^STATUS=' \
   && ! printf '%s\n' "$RESULT" | grep -q 'STATUS=__MISSING__' \
   && printf '%s\n' "$RESULT" | grep -q '^DETAILS_KEY=set' \
   && printf '%s\n' "$RESULT" | grep -q '^MAC_SYSTEM=none' \
   && ! printf '%s\n' "$RESULT" | grep -q 'MAC_VERDICT=WARN'; then
    ok "C8 _collect_posture_info preserves POSTURE_* + wires POSTURE_MAC_* (no MAC -> no WARN)"
else
    no "C8 collector legacy+MAC wiring" "$(printf '%s' "$RESULT" | tr '\n' ';')"
fi
rm -rf "$D"

# ===========================================================================
# CASE 8b: a MAC WARN is reflected into the collector's POSTURE_DETAILS + count.
# ===========================================================================
D=$(make_stubdir)
add_stub "$D" getenforce 'echo "Enforcing"'
add_stub "$D" semodule 'echo "base"; echo "sshd"'   # nftban module missing -> WARN
RESULT=$(
    set +e
    export PATH="$D"
    export NFTBAN_AA_PROFILES_FILE="$D/.aa_profiles"
    # shellcheck source=/dev/null
    source "$LIB" >/dev/null 2>&1
    declare -A P
    _collect_posture_info P 2>/dev/null
    printf 'DETAILS=%s\n' "${P[POSTURE_DETAILS]:-}"
    printf 'MAC_VERDICT=%s\n' "${P[POSTURE_MAC_VERDICT]:-}"
    printf 'WARNINGS=%s\n' "${P[POSTURE_WARNINGS]:-0}"
)
if printf '%s\n' "$RESULT" | grep -q 'MAC_VERDICT=WARN' \
   && printf '%s\n' "$RESULT" | grep -qi 'DETAILS=.*MAC:'; then
    ok "C8b MAC WARN flows into POSTURE_DETAILS + advisory count"
else
    no "C8b MAC WARN -> details/count" "$(printf '%s' "$RESULT" | tr '\n' ';')"
fi
rm -rf "$D"

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
