#!/usr/bin/env bash
# =============================================================================
# NFTBan - deprecated-unit retirement must clear the terminal failed-state latch
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="deprecated_unit_failed_latch_v1228_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-28"
# meta:description="v1.228.2 lab-gate regression (LAB2_DEB FAIL). The generated deprecated-unit cleanup retires a unit with stop + disable + remove-file (policy stop_disable_remove) or stop + disable + mask (policy stop_disable_mask_remove). Neither sequence clears a systemd failed-state latch. A unit that was already terminally failed when the upgrade began therefore survives as 'Loaded: not-found / Active: failed' once its file is gone - unreferenceable residue no operator can act on, but which still counts against NFTBan's own failed_units_postinstall_ok assertion and drives INSTALL_STATE=DEGRADED, NFTBAN_INSTALL_VERIFIED=NO on an upgrade whose package manager returned 0. Observed on lab2 where nftban-suricata-update.service was failed 226/NAMESPACE before the v1.228.2 upgrade. This test asserts both emitted helpers call 'systemctl reset-failed \$unit', that the call is ordered inside the helper body (hence before the caller's daemon-reload, while the unit is still loaded and the reset is unconditionally accepted), and that every one of the six generated artifacts carries it - so the fix cannot regress in the generator or drift in a checked-in output. Also locks the router one-liner for 'suricata' against advertising subcommands the dormant router rejects. Static analysis only - reads files, invokes nothing, never calls systemctl."
# meta:input="build/generate-systemd-maintainer-scripts.sh, install/packaging/{deb,rpm}/*.inc, packaging/deb/{preinst,prerm}, cli/sbin/nftban"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed"
# meta:inventory.files="build/generate-systemd-maintainer-scripts.sh,packaging/deb/preinst,packaging/deb/prerm,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="units listed in build/deprecated-units.yaml"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="deprecated_unit_failed_latch_v1228_2_test"
# meta:ta.owner="packaging"
# meta:ta.module="systemd-maintainer-scripts"
# meta:ta.execution_class="CI_STATIC"
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
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
GEN="$REPO/build/generate-systemd-maintainer-scripts.sh"
ROUTER="$REPO/cli/sbin/nftban"

[[ -f "$GEN" ]]    || { echo "FAIL: cannot find $GEN" >&2; exit 1; }
[[ -f "$ROUTER" ]] || { echo "FAIL: cannot find $ROUTER" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# The six artifacts the generator owns. All are checked in; the generator's
# --check mode guards regeneration parity, this list guards INTENT — a
# regenerated-but-wrong output would pass --check and fail here.
ARTIFACTS=(
    "install/packaging/deb/nftban-preinst-deprecated-cleanup.inc"
    "install/packaging/deb/nftban-prerm-systemd-cleanup.inc"
    "install/packaging/rpm/nftban-pre-deprecated-cleanup.inc"
    "install/packaging/rpm/nftban-preun-systemd-cleanup.inc"
    "packaging/deb/preinst"
    "packaging/deb/prerm"
)

echo "=== A. generator emits reset-failed in BOTH retirement helpers ==="

# Extract a single shell function body by name from a file.
fn_body(){ sed -n "/^$2() {/,/^}/p" "$1"; }

for helper in remove_unit_file_if_exists mask_if_exists; do
    body=$(fn_body "$GEN" "$helper" || true)
    if [[ -z "$body" ]]; then
        no "A1 $helper is emitted by the generator" "function body not found in $GEN"
        continue
    fi
    if grep -qF 'systemctl reset-failed "$unit"' <<<"$body"; then
        ok "A1 $helper clears the failed-state latch"
    else
        no "A1 $helper clears the failed-state latch" \
           "stop+disable+rm/mask does not clear a terminal failed latch; add: systemctl reset-failed \"\$unit\" 2>/dev/null || true"
    fi

    # The reset must be the LAST mutating action in the helper, so it runs while
    # the unit is still loaded and before the caller's daemon-reload.
    last=$(grep -n 'systemctl\|rm -f' <<<"$body" | tail -1 || true)
    if grep -q 'reset-failed' <<<"$last"; then
        ok "A2 $helper resets last (before caller daemon-reload)"
    else
        no "A2 $helper resets last (before caller daemon-reload)" "last mutating line: ${last:-none}"
    fi
done

echo "=== B. every generated artifact carries the reset in both helpers ==="

for rel in "${ARTIFACTS[@]}"; do
    f="$REPO/$rel"
    if [[ ! -f "$f" ]]; then
        no "B1 $rel exists" "not found"
        continue
    fi
    n=$(grep -cF 'systemctl reset-failed "$unit"' "$f" || true)
    if [[ "$n" -eq 2 ]]; then
        ok "B1 $rel carries the reset in both helpers"
    else
        no "B1 $rel carries the reset in both helpers" \
           "expected 2 occurrences (mask + remove), found $n — run: bash build/generate-systemd-maintainer-scripts.sh"
    fi
done

echo "=== C. router help must not advertise verbs the dormant router rejects ==="

# cmd_suricata.sh routes exactly `status` and `help|--help|-h`; everything else
# returns 1. The one-line description in the router must not contradict that.
line=$(grep -n 'suricata)\s*echo' "$ROUTER" | head -1 || true)
if [[ -z "$line" ]]; then
    no "C1 router carries a suricata description" "no 'suricata) echo' line in $ROUTER"
else
    bad=()
    for verb in install enable rules profile; do
        grep -qE "[( ,]${verb}[,)]" <<<"$line" && bad+=("$verb")
    done
    if [[ ${#bad[@]} -eq 0 ]]; then
        ok "C1 suricata description advertises no unrouted verb"
    else
        # IFS is \n\t here, so join explicitly rather than via ${bad[*]}.
        joined=$(printf '%s, ' "${bad[@]}"); joined=${joined%, }
        no "C1 suricata description advertises no unrouted verb" \
           "advertises ${joined} but nftban_cmd_suricata returns 1 for each — ${line}"
    fi
fi

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
