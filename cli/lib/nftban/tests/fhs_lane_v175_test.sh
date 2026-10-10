#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.175 FHS LANE invariants
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="fhs_lane_v175_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Locks the v1.175 FHS-authority lane. (T1) GENERIC GUARD, no exceptions since v1.235: no generated tmpfiles.d d/z entry is root-owned under a non-root-owned declared parent (the systemd-tmpfiles 'unsafe path transition' / exit-73 class) — prevents BUG-TMPFILES regressions structurally (the allowlist is empty). (T2) auditors created_by=package + absent from tmpfiles (AUDITORS unsafe-transition CLOSED). (T3) the firewall-validate handoff dir is /run/nftban-firewall-validate (root:nftban 2750 under the root-owned /run), created ONLY by tmpfiles; the old /run/nftban/firewall-validate is declared nowhere; the unit has no ExecStartPre creator and ReadWritePaths points at the new path. (T4) /var/lib/nftban/alerts declared nftban:nftban + in tmpfiles (ALERT-THROTTLE-FHS). (T5) /var/lib/nftban/suricata/cache declared nftban:nftban + in tmpfiles (FHS-SMELL-SIDSTATS). (T6) cache.go snapshot uses DataDir not ConfigDir. (T7) nftban-service-alert throttle relocated under alerts/. Hermetic: reads committed generated files + spec; no root, no systemd."
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
# v1.235 (owner 2026-10-07): NO exceptions. The single former exception,
# /run/nftban/firewall-validate (root-owned under the nftban-owned /run/nftban), was
# moved to /run/nftban-firewall-validate (root-owned under the root-owned /run). Any
# root-under-non-root transition now FAILS T1. Do not re-add entries here: move the
# directory under a root-owned parent instead.
declare -A TMPFILES_ROOT_EXCEPTION=()

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
# T3: firewall-validate handoff dir (v1.235): /run/nftban-firewall-validate, root:nftban
# 2750 under the root-owned /run. tmpfiles is its SINGLE creator (boot + package
# install, before any service, so ReadWritePaths always finds it); the unit has no
# ExecStartPre creator; the old root-under-nftban path is gone everywhere.
# -----------------------------------------------------------------------------
F_CB=$(yq -r '.directories.runtime[] | select(.path == "/run/nftban-firewall-validate") | .created_by' "$SPEC")
[[ "$F_CB" == "tmpfiles" ]] && ok "T3 /run/nftban-firewall-validate created_by=tmpfiles (single creator)" || no "T3 firewall-validate spec entry" "got '$F_CB'"
grep -qE '^d /run/nftban-firewall-validate 2750 root nftban -$' "$TMPFILES" \
    && ok "T3b tmpfiles creates /run/nftban-firewall-validate 2750 root nftban (root parent: no unsafe transition)" \
    || no "T3b firewall-validate tmpfiles line" "missing"
if ! grep -qE '/run/nftban/firewall-validate' "$TMPFILES" && [[ -z "$(yq -r '.directories.runtime[] | select(.path == "/run/nftban/firewall-validate") | .path' "$SPEC")" ]]; then
    ok "T3c the old /run/nftban/firewall-validate is declared nowhere (spec, tmpfiles)"
else
    no "T3c old root-under-nftban path still declared"
fi
if ! grep -qE '^ExecStartPre=.*firewall-validate' "$UNIT" && grep -qxE 'ReadWritePaths=/run/nftban-firewall-validate' "$UNIT"; then
    ok "T3d unit: no ExecStartPre creator; ReadWritePaths=/run/nftban-firewall-validate"
else
    no "T3d unit creator/ReadWritePaths" "$(grep -E '^(ExecStartPre|ReadWritePaths)=' "$UNIT" | tr '\n' ' ')"
fi

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
