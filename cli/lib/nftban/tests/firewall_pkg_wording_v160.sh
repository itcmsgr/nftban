#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.160: state-aware firewall package wording (CHECK 2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="firewall_pkg_wording_v160"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-07"
# meta:description="Locks the v1.160 PR-C fix for the prereq CHECK 2 vs CHECK 4 wording contradiction. Previously the install prerequisite CHECK 2 warned 'firewalld/ufw installed (conflicts)' purely on package PRESENCE, then CHECK 4 reported 'No conflicting firewall services detected' from SERVICE STATE — the two stages disagreed. The fix makes CHECK 2 state-aware via a nftban_fw_pkg_wording helper (mirrored verbatim in packaging/build_nftban.sh RPM-prereq and packaging/deb/preinst). This test exercises a faithful copy of that helper against mocked systemctl/ufw shims and asserts the wording matrix: installed+active => conflict WARNING (+LEGACY_FOUND); installed+enabled-inactive => startup-risk WARNING; installed+disabled => advisory INFO (no conflict); installed+masked => informational/acceptable INFO; absent => clean (helper not called). Covers both firewalld (systemctl-driven) and ufw (ufw-status-driven active override). Hermetic: TMPDIR PATH shims stand in for systemctl/ufw; no real services, no host mutation."
# meta:input="None (self-contained; mocks via PATH shims)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp,chmod"
# meta:inventory.files="packaging/build_nftban.sh,packaging/deb/preinst"
# meta:inventory.binaries="bash,grep,mktemp,chmod"
# meta:inventory.env_vars="PATH"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="firewalld,ufw"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# -----------------------------------------------------------------------------
# Reference copy of the v1.160 nftban_fw_pkg_wording helper.
# This MUST stay byte-equivalent in behaviour to the embedded copies in
# packaging/build_nftban.sh (RPM %pre prereq, '\$'-escaped in its heredoc) and
# packaging/deb/preinst. State classification is driven entirely by the mocked
# systemctl / ufw shims placed on PATH below.
# -----------------------------------------------------------------------------
nftban_fw_pkg_wording() {
    fw_name="$1"; fw_unit="$2"; fw_remove="$3"; fw_active_override="$4"
    fw_active=0; fw_enabled=0; fw_masked=0

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-masked "$fw_unit" >/dev/null 2>&1; then
            fw_masked=1
        fi
        if [ "$(systemctl is-enabled "$fw_unit" 2>/dev/null)" = "masked" ]; then
            fw_masked=1
        fi
        if systemctl is-enabled "$fw_unit" >/dev/null 2>&1; then
            fw_enabled=1
        fi
        if [ -z "$fw_active_override" ] && systemctl is-active "$fw_unit" >/dev/null 2>&1; then
            fw_active=1
        fi
    fi
    if [ "$fw_active_override" = "active" ]; then
        fw_active=1
    fi

    if [ "$fw_active" -eq 1 ]; then
        echo "[!] WARNING: $fw_name is installed and ACTIVE (conflicts with nftables)"
        echo "    NFTBan manages nftables directly. An active $fw_name will conflict."
        echo "    Recommended: $fw_remove (or stop/disable $fw_unit)"
        LEGACY_FOUND=1
    elif [ "$fw_masked" -eq 1 ]; then
        echo "[i] INFO: $fw_name is installed but masked — will not start; acceptable"
    elif [ "$fw_enabled" -eq 1 ]; then
        echo "[!] WARNING: $fw_name is installed and enabled but inactive"
        echo "    It will start on boot and may then conflict with NFTBan."
        echo "    Recommended: disable $fw_unit if unused"
    else
        echo "[i] INFO: $fw_name is installed but inactive — no conflict now"
        echo "    Remove ($fw_remove) or keep it disabled."
    fi
}

# -----------------------------------------------------------------------------
# Sandbox + mock shims for systemctl / ufw.
# State is conveyed via env files read by the shims (so PATH lookup is the only
# variable changed per case).
# -----------------------------------------------------------------------------
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"

cat > "$SB/bin/systemctl" <<'SHIM'
#!/usr/bin/env bash
# Mock systemctl. Reads desired state from $MOCK_STATE:
#   active | enabled-inactive | disabled | masked | absent
verb="$1"; # is-active|is-enabled|is-masked
st="${MOCK_STATE:-absent}"
case "$verb" in
    is-masked)
        [ "$st" = "masked" ] && exit 0 || exit 1
        ;;
    is-enabled)
        case "$st" in
            masked)            echo "masked";   exit 1 ;;  # most systemd: prints masked, rc!=0
            active|enabled-inactive) echo "enabled"; exit 0 ;;
            *)                 echo "disabled"; exit 1 ;;
        esac
        ;;
    is-active)
        [ "$st" = "active" ] && { echo "active"; exit 0; } || { echo "inactive"; exit 3; }
        ;;
    *)
        exit 1
        ;;
esac
SHIM
chmod +x "$SB/bin/systemctl"

cat > "$SB/bin/ufw" <<'SHIM'
#!/usr/bin/env bash
# Mock ufw status. Active iff $MOCK_UFW_ACTIVE=1.
if [ "$1" = "status" ]; then
    if [ "${MOCK_UFW_ACTIVE:-0}" = "1" ]; then
        echo "Status: active"
    else
        echo "Status: inactive"
    fi
fi
exit 0
SHIM
chmod +x "$SB/bin/ufw"

PATH="$SB/bin:$PATH"
export PATH

# Helper: run the wording function in a subshell with a fresh LEGACY_FOUND,
# capture stdout, and report whether LEGACY_FOUND was set.
run_case() {
    # $1=state env, $2..=args to nftban_fw_pkg_wording
    local state="$1"; shift
    local out lf
    out=$(
        MOCK_STATE="$state"
        export MOCK_STATE
        LEGACY_FOUND=0
        nftban_fw_pkg_wording "$@"
        echo "__LF=$LEGACY_FOUND"
    )
    CASE_LF=$(printf '%s\n' "$out" | sed -n 's/^__LF=//p')
    CASE_OUT=$(printf '%s\n' "$out" | grep -v '^__LF=' || true)
}

echo "=== firewalld (systemctl-driven) wording matrix ==="

run_case active firewalld firewalld "dnf remove firewalld" ""
{ echo "$CASE_OUT" | grep -q "installed and ACTIVE (conflicts" && [ "$CASE_LF" = "1" ]; } \
  && ok "active -> conflict WARNING + LEGACY_FOUND set" \
  || no "active case wrong" "out=[$CASE_OUT] lf=$CASE_LF"

run_case enabled-inactive firewalld firewalld "dnf remove firewalld" ""
{ echo "$CASE_OUT" | grep -q "enabled but inactive" && [ "$CASE_LF" = "0" ]; } \
  && ok "enabled-inactive -> startup-risk WARNING, no LEGACY_FOUND" \
  || no "enabled-inactive case wrong" "out=[$CASE_OUT] lf=$CASE_LF"

run_case disabled firewalld firewalld "dnf remove firewalld" ""
{ echo "$CASE_OUT" | grep -q "installed but inactive — no conflict now" && [ "$CASE_LF" = "0" ]; } \
  && ok "disabled -> advisory INFO (no conflict), no LEGACY_FOUND" \
  || no "disabled case wrong" "out=[$CASE_OUT] lf=$CASE_LF"

run_case masked firewalld firewalld "dnf remove firewalld" ""
{ echo "$CASE_OUT" | grep -q "installed but masked — will not start; acceptable" && [ "$CASE_LF" = "0" ]; } \
  && ok "masked -> informational/acceptable INFO, no LEGACY_FOUND" \
  || no "masked case wrong" "out=[$CASE_OUT] lf=$CASE_LF"

echo "=== ufw (ufw-status active override) wording ==="

# ufw active: caller passes "active" override (mirrors prereq: ufw status | grep active)
out=$(LEGACY_FOUND=0; MOCK_STATE=disabled; export MOCK_STATE; nftban_fw_pkg_wording "ufw" "ufw" "apt remove ufw" "active"; echo "__LF=$LEGACY_FOUND")
lf=$(printf '%s\n' "$out" | sed -n 's/^__LF=//p')
{ printf '%s\n' "$out" | grep -q "ufw is installed and ACTIVE" && [ "$lf" = "1" ]; } \
  && ok "ufw active override -> conflict WARNING + LEGACY_FOUND" \
  || no "ufw active override wrong" "out=[$out]"

# ufw inactive: caller passes "inactive", systemctl says disabled -> advisory
out=$(LEGACY_FOUND=0; MOCK_STATE=disabled; export MOCK_STATE; nftban_fw_pkg_wording "ufw" "ufw" "apt remove ufw" "inactive"; echo "__LF=$LEGACY_FOUND")
lf=$(printf '%s\n' "$out" | sed -n 's/^__LF=//p')
{ printf '%s\n' "$out" | grep -q "ufw is installed but inactive — no conflict now" && [ "$lf" = "0" ]; } \
  && ok "ufw inactive+disabled -> advisory INFO, no LEGACY_FOUND" \
  || no "ufw inactive case wrong" "out=[$out]"

# ufw inactive but enabled-on-boot -> startup-risk
out=$(LEGACY_FOUND=0; MOCK_STATE=enabled-inactive; export MOCK_STATE; nftban_fw_pkg_wording "ufw" "ufw" "apt remove ufw" "inactive"; echo "__LF=$LEGACY_FOUND")
lf=$(printf '%s\n' "$out" | sed -n 's/^__LF=//p')
{ printf '%s\n' "$out" | grep -q "ufw is installed and enabled but inactive" && [ "$lf" = "0" ]; } \
  && ok "ufw inactive+enabled -> startup-risk WARNING, no LEGACY_FOUND" \
  || no "ufw enabled-on-boot case wrong" "out=[$out]"

echo "=== absent package => helper not invoked (clean) ==="
# The packaging scripts only call the helper inside `command -v <pkg>` guards, so
# an absent package never reaches the helper. Assert the guard semantics against a
# PATH that contains ONLY the sandbox shims (no firewall-cmd present there), so the
# result is independent of whatever the build host happens to have installed.
mkdir -p "$SB/empty"
out=$(
    LEGACY_FOUND=0
    if PATH="$SB/empty" command -v firewall-cmd >/dev/null 2>&1; then
        nftban_fw_pkg_wording "firewalld" "firewalld" "dnf remove firewalld" ""
    fi
    echo "__LF=$LEGACY_FOUND"
)
lf=$(printf '%s\n' "$out" | sed -n 's/^__LF=//p')
body=$(printf '%s\n' "$out" | grep -v '^__LF=' || true)
{ [ -z "$body" ] && [ "$lf" = "0" ]; } \
  && ok "absent firewalld -> command -v guard skips helper (clean, LEGACY_FOUND untouched)" \
  || no "absent guard wrong" "body=[$body] lf=$lf"

echo ""
echo "Result: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
