#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.175 FHS LANE invariants
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="fhs_lane_v175_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Locks the v1.175 FHS-authority lane. (T1) GENERIC GUARD: no generated tmpfiles.d d/z entry is root-owned under a non-root-owned declared parent (the systemd-tmpfiles 'unsafe path transition' / exit-73 class), EXCEPT the documented security-exception allowlist (firewall-validate root-only-writer boundary) — prevents BUG-TMPFILES regressions structurally while permitting the reviewed exception. (T2) auditors created_by=package + absent from tmpfiles (AUDITORS unsafe-transition CLOSED). (T3) firewall-validate created_by=tmpfiles + PRESENT in tmpfiles as the accepted root-only-writer SECURITY EXCEPTION (exit-73 NOT closed; ExecStartPre-sole was lab-disproven 226/NAMESPACE) + unit +ExecStartPre belt-and-suspenders. (T4) /var/lib/nftban/alerts declared nftban:nftban + in tmpfiles (ALERT-THROTTLE-FHS). (T5) /var/lib/nftban/suricata/cache declared nftban:nftban + in tmpfiles (FHS-SMELL-SIDSTATS). (T6) cache.go snapshot uses DataDir not ConfigDir. (T7) nftban-service-alert throttle relocated under alerts/. Hermetic: reads committed generated files + spec; no root, no systemd."
# meta:input="None (reads repo files)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,yq"
# meta:inventory.files="build/fhs-spec.yaml,install/systemd/tmpfiles.d/nftban.conf,install/systemd/nftban-firewall-validate.service,internal/suricata/stats/cache.go,cli/sbin/nftban-service-alert"
# meta:inventory.binaries="bash,yq,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-firewall-validate.service,nftban-alert@.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="fhs_lane_v175_test"
# meta:ta.owner="packaging"
# meta:ta.module="fhs"
# meta:ta.execution_class="PACKAGE_BUILD"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
SPEC="$REPO/build/fhs-spec.yaml"
TMPFILES="$REPO/install/systemd/tmpfiles.d/nftban.conf"
UNIT="$REPO/install/systemd/nftban-firewall-validate.service"
CACHE="$REPO/internal/suricata/stats/cache.go"
ALERT="$REPO/cli/sbin/nftban-service-alert"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.175 FHS lane invariants ==="

# -----------------------------------------------------------------------------
# T1: GENERIC GUARD — no root-owned tmpfiles entry under a non-root declared
# parent (systemd-tmpfiles refuses that transition: exit 73 / "unsafe path
# transition"). This is the structural lock for the whole BUG-TMPFILES class.
# -----------------------------------------------------------------------------
# Intentional, security-reviewed exceptions: root-owned children DELIBERATELY kept
# under a non-root parent because the root-only-writer property IS the security
# boundary. These emit a NON-FATAL systemd-tmpfiles exit-73 that is ACCEPTED and
# documented (fhs-spec.yaml + the unit). T1 still FAILS for any OTHER (new)
# root-under-non-root transition — the guard is not weakened, only this exact path
# is allowlisted with its integrity reason.
declare -A TMPFILES_ROOT_EXCEPTION=(
    # only the audited root service may WRITE last.json; nftban group READS it 0640.
    # nftban:nftban would let a compromised daemon forge the independent validation
    # result. /run is tmpfs → must be tmpfiles-created at boot (ExecStartPre-sole was
    # lab-disproven: 226/NAMESPACE, ReadWritePaths binds before ExecStartPre runs).
    ["/run/nftban/firewall-validate"]="root-only-writer integrity boundary for last.json (BUG-TMPFILES-FIREWALL-VALIDATE-SECURITY-EXCEPTION)"
)

declare -A OWNER
# NOTE: explicit IFS=' ' for THIS read — the file-level IFS=$'\n\t' has no space,
# which would dump the whole line into $typ and silently build an EMPTY map
# (vacuous guard). Split tmpfiles columns on whitespace here.
while IFS=' ' read -r typ path _mode owner _group _rest; do
    [[ "$typ" =~ ^[dzZ]$ ]] || continue
    OWNER["$path"]="$owner"
done < <(grep -E '^[dzZ] ' "$TMPFILES")
[[ "${#OWNER[@]}" -gt 0 ]] || { no "T1 PRECONDITION: tmpfiles parse built a non-empty OWNER map" "0 entries — guard would be vacuous"; }

unsafe=""; accepted=""
for path in "${!OWNER[@]}"; do
    [[ "${OWNER[$path]}" == "root" ]] || continue   # only a root child can trip it
    p="$path"
    while [[ "$p" == */* ]]; do
        p="${p%/*}"
        [[ -z "$p" ]] && break
        if [[ -n "${OWNER[$p]:-}" ]]; then           # nearest declared ancestor
            if [[ "${OWNER[$p]}" != "root" ]]; then
                if [[ -n "${TMPFILES_ROOT_EXCEPTION[$path]:-}" ]]; then
                    accepted+="${path} [${TMPFILES_ROOT_EXCEPTION[$path]}]; "
                else
                    unsafe+="${path}(root) under ${p}(${OWNER[$p]}); "
                fi
            fi
            break
        fi
    done
done
if [[ -z "$unsafe" ]]; then
    ok "T1 no UNEXPECTED root-under-non-root tmpfiles transition (BUG-TMPFILES class guard; allowlisted exceptions excluded)"
    [[ -n "$accepted" ]] && echo "      accepted security exception(s): $accepted"
else
    no "T1 unexpected unsafe tmpfiles transition present (not in security-exception allowlist)" "$unsafe"
fi

# -----------------------------------------------------------------------------
# T2: auditors — created_by=package, absent from tmpfiles.
# -----------------------------------------------------------------------------
A_CB=$(yq -r '.directories.data[] | select(.path == "/var/lib/nftban/reports/auditors") | .created_by' "$SPEC")
[[ "$A_CB" == "package" ]] && ok "T2 auditors created_by=package" || no "T2 auditors created_by=package" "got $A_CB"
grep -qE '/var/lib/nftban/reports/auditors' "$TMPFILES" \
    && no "T2b auditors absent from tmpfiles" "still present" \
    || ok "T2b auditors absent from tmpfiles"

# -----------------------------------------------------------------------------
# T3: firewall-validate — ACCEPTED SECURITY EXCEPTION (NOT closed). created_by=
# tmpfiles (the boot creator; required because ReadWritePaths binds at mount-
# namespace setup on tmpfs — ExecStartPre-sole was lab-disproven, 226/NAMESPACE).
# PRESENT in tmpfiles as the allowlisted root-only-writer exception. The unit's
# +ExecStartPre remains as an idempotent per-start belt-and-suspenders.
# -----------------------------------------------------------------------------
F_CB=$(yq -r '.directories.runtime[] | select(.path == "/run/nftban/firewall-validate") | .created_by' "$SPEC")
[[ "$F_CB" == "tmpfiles" ]] && ok "T3 firewall-validate created_by=tmpfiles (security exception, boot creator)" || no "T3 firewall-validate created_by=tmpfiles" "got $F_CB"
grep -qE '^d /run/nftban/firewall-validate 2750 root nftban -' "$TMPFILES" \
    && ok "T3b firewall-validate present in tmpfiles (2750 root:nftban — accepted exit-73 security exception)" \
    || no "T3b firewall-validate in tmpfiles (security exception)" "missing"
grep -qE '^ExecStartPre=\+/usr/bin/install -d .*-m 2750 .*/run/nftban/firewall-validate' "$UNIT" \
    && ok "T3c unit +ExecStartPre also creates firewall-validate (2750, per-start belt-and-suspenders)" \
    || no "T3c unit +ExecStartPre present" "missing"

# -----------------------------------------------------------------------------
# T4: ALERT-THROTTLE-FHS — /var/lib/nftban/alerts declared nftban:nftban + tmpfiles.
# -----------------------------------------------------------------------------
AL=$(yq -r '.directories.data[] | select(.path == "/var/lib/nftban/alerts") | "\(.owner):\(.group):\(.created_by)"' "$SPEC")
[[ "$AL" == "nftban:nftban:tmpfiles" ]] && ok "T4 /var/lib/nftban/alerts is nftban:nftban tmpfiles" || no "T4 alerts dir spec" "got $AL"
grep -qE '^d /var/lib/nftban/alerts 0750 nftban nftban -' "$TMPFILES" \
    && ok "T4b alerts dir in tmpfiles (0750 nftban nftban)" || no "T4b alerts in tmpfiles" "missing"

# -----------------------------------------------------------------------------
# T5: FHS-SMELL-SIDSTATS — /var/lib/nftban/suricata/cache declared nftban:nftban.
# -----------------------------------------------------------------------------
SC=$(yq -r '.directories.data[] | select(.path == "/var/lib/nftban/suricata/cache") | "\(.owner):\(.group):\(.created_by)"' "$SPEC")
[[ "$SC" == "nftban:nftban:tmpfiles" ]] && ok "T5 /var/lib/nftban/suricata/cache is nftban:nftban tmpfiles" || no "T5 suricata/cache dir spec" "got $SC"
grep -qE '^d /var/lib/nftban/suricata/cache 0750 nftban nftban -' "$TMPFILES" \
    && ok "T5b suricata/cache dir in tmpfiles" || no "T5b suricata/cache in tmpfiles" "missing"

# -----------------------------------------------------------------------------
# T6: cache.go snapshot path uses DataDir (/var/lib), NOT ConfigDir (/etc).
# -----------------------------------------------------------------------------
if grep -qE 'snapshotPath := filepath\.Join\(cfg\.DataDir, "suricata/cache/sid-stats\.json"\)' "$CACHE" \
   && ! grep -qE 'snapshotPath := filepath\.Join\(cfg\.ConfigDir' "$CACHE"; then
    ok "T6 cache.go snapshot uses cfg.DataDir (not ConfigDir)"
else
    no "T6 cache.go snapshot uses DataDir" "still references ConfigDir or path changed"
fi
grep -qE 'func migrateLegacySnapshot' "$CACHE" \
    && ok "T6b cache.go has migrateLegacySnapshot (old /etc snapshot migrated)" \
    || no "T6b migrateLegacySnapshot present" "missing"

# -----------------------------------------------------------------------------
# T7: nftban-service-alert throttle relocated under the nftban-owned alerts dir.
# -----------------------------------------------------------------------------
if grep -qE 'ALERT_STATE_DIR="\$\{NFTBAN_DATA_DIR\}/alerts"' "$ALERT" \
   && grep -qE 'ALERT_THROTTLE_FILE="\$\{ALERT_STATE_DIR\}/throttle_' "$ALERT"; then
    ok "T7 alert worker throttle under \${DATA}/alerts/throttle_<svc>"
else
    no "T7 throttle relocated under alerts/" "still at bare data-dir root"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
