#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1a-5 unshipped-file cleanup (8.2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_file_cleanup_r1a5_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-22"
# meta:description="Guards the R1a-5 proven-safe deletions and prevents regressions: (1) the cli/etc/nftban/conf.d shadow tree must not re-duplicate a file that IS shipped from root etc/nftban/conf.d (trust.conf was the only such shadow dup, now removed); (2) install/pam.d/nftban-api (orphan PAM config for the deprecated nftban-api service) stays deleted and unreferenced by packaging/installer. The three UNCLEAR cli/etc top-level configs (login_alert/recovery/services) are intentionally NOT deleted (ownership undecided) — asserted present."
# meta:input="None (filesystem + grep over repo)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,comm"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,comm"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nftban_file_cleanup_r1a5_test"
# meta:ta.owner="packaging"
# meta:ta.module="shipped-config-hygiene"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
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
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
CLI_CONF="${REPO_ROOT}/cli/etc/nftban/conf.d"
ROOT_CONF="${REPO_ROOT}/etc/nftban/conf.d"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

echo "R1a-5 unshipped-file cleanup (8.2) — guard tests"

# (1) trust.conf shadow duplicate removed; root shipped copy intact
[[ ! -e "${CLI_CONF}/trust.conf" ]] && ok "cli/etc shadow trust.conf removed" || bad "cli/etc/conf.d/trust.conf still present (shadow dup)"
[[ -f "${ROOT_CONF}/trust.conf" ]] && ok "root etc shipped trust.conf intact (package source untouched)" || bad "root etc/conf.d/trust.conf MISSING — shipped config lost!"

# (2) no shadow duplicate of any shipped top-level conf reappears in cli/etc
_list_conf() { local d="$1" f; [[ -d "$d" ]] || return 0; for f in "$d"/*.conf; do [[ -e "$f" ]] && basename "$f"; done | sort; }
dups=$(comm -12 <(_list_conf "$CLI_CONF") <(_list_conf "$ROOT_CONF"))
if [[ -z "$dups" ]]; then ok "no cli/etc shadow duplicate of a root-shipped conf"; else bad "shadow duplicate(s) of shipped conf reintroduced: $dups"; fi

# (3) the orphan PAM config is deleted and stays unreferenced by packaging/installer
[[ ! -e "${REPO_ROOT}/install/pam.d/nftban-api" ]] && ok "install/pam.d/nftban-api removed" || bad "install/pam.d/nftban-api still present"
if grep -rqE 'pam\.d/nftban-api' "${REPO_ROOT}/install/packaging" "${REPO_ROOT}/packaging" "${REPO_ROOT}/install/download-binaries.sh" 2>/dev/null; then
    bad "pam.d/nftban-api referenced by packaging/installer (should be zero)"
else
    ok "pam.d/nftban-api unreferenced by packaging/installer"
fi

# (4) UNCLEAR resolution — all three UNCLEAR cli/etc configs are now decided:
#   login_alert + services (structural-hygiene PR-A): real SHIPPING GAPS → shipped at
#   the live root read path /etc/nftban/conf.d/*.conf; cli/etc shadows removed.
#   recovery (RECOVERY_LEGACY_RECONCILE, v1.201.2): phantom 14-key surface (unsourced) →
#   trimmed to the 3 live commit-confirm knobs, SHIPPED + sourced at root recovery.conf;
#   the 11 dead keys deprecated in schema; the unshipped cli/etc copy removed.
for c in login_alert services recovery; do
    [[ -f "${ROOT_CONF}/${c}.conf" ]] && ok "shipped at live read path: /etc/nftban/conf.d/${c}.conf present" || bad "${c}.conf missing from shipped root conf.d (must ship at the live read path)"
    [[ ! -f "${CLI_CONF}/${c}.conf" ]] && ok "cli/etc shadow of ${c}.conf removed (now canonical in root)" || bad "${c}.conf shadow still in cli/etc (should be moved to root)"
done
# recovery.conf must be TRIMMED to only the 3 live knobs (no dead keys shipped).
recov_keys="$(grep -cE '^NFTBAN_[A-Z_]+=' "${ROOT_CONF}/recovery.conf" 2>/dev/null || echo 0)"
[[ "$recov_keys" -eq 3 ]] && ok "shipped recovery.conf carries exactly 3 live keys (no dead keys)" || bad "recovery.conf has $recov_keys keys (expected 3 live commit-confirm knobs)"
for dead in NFTBAN_RECOVERY_ENABLED NFTBAN_ROLLBACK_ALERT NFTBAN_BACKUP_RULES NFTBAN_RESET_ON_BOOT NFTBAN_EMERGENCY_RESET_ENABLED; do
    grep -qE "^${dead}=" "${ROOT_CONF}/recovery.conf" 2>/dev/null && bad "dead key ${dead} still shipped in recovery.conf" || true
done
ok "spot-checked dead keys absent from shipped recovery.conf"

echo "-----------------------------------------------"
printf 'R1a-5 cleanup tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
