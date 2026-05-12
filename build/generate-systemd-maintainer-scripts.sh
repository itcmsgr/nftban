#!/usr/bin/env bash
# =============================================================================
# NFTBan - Systemd Maintainer-Script Generator (MFST-C3 / Layer 3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="generate-systemd-maintainer-scripts"
# meta:type="build"
# meta:header="Systemd Maintainer-Script Generator"
# meta:version="1.106.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Generate RPM %preun and DEB prerm systemd cleanup snippets from C1 active list + deprecated-units.yaml; closes D6 + Lane L10 F7_LOW"
# meta:inventory.files="install/packaging/systemd/nftban-systemd-install.list,build/deprecated-units.yaml"
# meta:inventory.binaries="awk,sort,diff,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-05-06"
# meta:updated_date="2026-05-06"
#
# Inputs:
#   install/packaging/systemd/nftban-systemd-install.list  (C1 active units, generated)
#   build/deprecated-units.yaml                            (deprecated units + per-unit policy)
#
# Outputs:
#   install/packaging/rpm/nftban-preun-systemd-cleanup.inc      (RPM %preun body — full cleanup, uninstall-only)
#   install/packaging/deb/nftban-prerm-systemd-cleanup.inc      (DEB prerm sentinel-region body — full cleanup, remove-only)
#   install/packaging/rpm/nftban-pre-deprecated-cleanup.inc     (RPM %pre body — deprecated-only, runs on install + upgrade)
#   install/packaging/deb/nftban-preinst-deprecated-cleanup.inc (DEB preinst sentinel-region body — deprecated-only, runs on install + upgrade)
#
# Why the second pair (v108-item7c):
#   Hosts upgrading from packages that pre-date v1.100.1b.A (the GOTH PR-D4
#   stage 1 retirement of nftban-ui) never had cleanup logic in their OLD
#   %preun/prerm. Only the NEW package's %pre/preinst can purge their stale
#   deprecated unit residue. Closes srv1-class lingering nftban-ui.service
#   surfaced during v1.107.2 rollout. Deprecated-only — touches NO active units.
#
# Templates with policy stop_disable_mask_remove use mask_if_exists() helper that
# only modifies /etc/systemd/system/$unit if its existing symlink targets /dev/null.
# Operator-created custom aliases (target != /dev/null) are preserved.
#
# Templates ending in @.service are skipped from the static stop loop because
# the template itself is not a runnable unit; only instances are.
#
# Usage:
#   ./build/generate-systemd-maintainer-scripts.sh           # regenerate
#   ./build/generate-systemd-maintainer-scripts.sh --check   # CI parity check
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly ACTIVE_LIST="${PROJECT_ROOT}/install/packaging/systemd/nftban-systemd-install.list"
readonly DEPRECATED_YAML="${PROJECT_ROOT}/build/deprecated-units.yaml"
readonly RPM_OUT="${PROJECT_ROOT}/install/packaging/rpm/nftban-preun-systemd-cleanup.inc"
readonly DEB_OUT="${PROJECT_ROOT}/install/packaging/deb/nftban-prerm-systemd-cleanup.inc"
# v108-item7c: NEW-package-side pre-install/pre-upgrade deprecated-only cleanup snippets.
readonly RPM_PRE_OUT="${PROJECT_ROOT}/install/packaging/rpm/nftban-pre-deprecated-cleanup.inc"
readonly DEB_PREINST_OUT="${PROJECT_ROOT}/install/packaging/deb/nftban-preinst-deprecated-cleanup.inc"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_info()  { echo -e "${YELLOW}[INFO]${NC} $*"; }
print_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Read active units from the C1 list. Skip blanks/comments. LC_ALL=C deterministic.
read_active_units() {
    if [[ ! -f "$ACTIVE_LIST" ]]; then
        print_error "Active list not found: $ACTIVE_LIST"
        return 1
    fi
    LC_ALL=C grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ACTIVE_LIST" | LC_ALL=C sort -u
}

# Parse deprecated-units.yaml. Emits one line per unit:  <name>|<policy>
# Schema-strict awk parse — no yq dependency.
read_deprecated_units() {
    if [[ ! -f "$DEPRECATED_YAML" ]]; then
        print_error "Deprecated yaml not found: $DEPRECATED_YAML"
        return 1
    fi
    awk '
        /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            name = $0
            policy = ""
            next
        }
        /^[[:space:]]+policy:[[:space:]]*/ {
            sub(/^[[:space:]]+policy:[[:space:]]*/, "")
            gsub(/[[:space:]]+$/, "")
            policy = $0
            if (name != "" && policy != "") {
                print name "|" policy
                name = ""; policy = ""
            }
        }
    ' "$DEPRECATED_YAML"
}

# Emit the shared mask_if_exists helper body. Identical between RPM/DEB.
emit_mask_helper() {
    cat <<'HELPER'
# /etc territory boundary (A2): package only modifies /etc/systemd/system/$unit
# when the existing symlink targets /dev/null (i.e., it is a mask).
# Operator-created custom aliases (target != /dev/null) are preserved.
mask_if_exists() {
    local unit="$1"
    if [ -e "/usr/lib/systemd/system/$unit" ] || [ -e "/lib/systemd/system/$unit" ]; then
        # Real unit file exists — full retire (legacy host)
        systemctl mask "$unit" 2>/dev/null || true
        rm -f "/usr/lib/systemd/system/$unit" "/lib/systemd/system/$unit" 2>/dev/null || true
    elif [ -L "/etc/systemd/system/$unit" ]; then
        # Symlink at /etc — remove only if it is a /dev/null mask (residue);
        # operator-created custom aliases (target != /dev/null) are preserved.
        if [ "$(readlink "/etc/systemd/system/$unit" 2>/dev/null)" = "/dev/null" ]; then
            rm -f "/etc/systemd/system/$unit" 2>/dev/null || true
        fi
    fi
    # else: clean host — no /etc residue created
}
HELPER
}

# Generate RPM %preun cleanup body. Stop+disable uses systemctl directly.
generate_rpm() {
    local target="${1:-$RPM_OUT}"
    local active deprecated_lines

    active=$(read_active_units)
    deprecated_lines=$(read_deprecated_units)

    mkdir -p "$(dirname "$target")"

    {
        cat <<'HEADER'
# =============================================================================
# NFTBan RPM %preun systemd cleanup — DO NOT EDIT
# =============================================================================
# Generated by build/generate-systemd-maintainer-scripts.sh from:
#   install/packaging/systemd/nftban-systemd-install.list  (active units)
#   build/deprecated-units.yaml                            (deprecated units)
#
# Consumed by packaging/build_nftban.sh::create_rpm_spec_nftban_core() and
# inlined into the spec %preun body via heredoc-write-time interpolation.
#
# Caller is responsible for surrounding "if [ $1 -eq 0 ]; then ... fi" gating
# (cleanup must run only on complete uninstall, not upgrade).
# =============================================================================

HEADER
        emit_mask_helper
        echo
        cat <<'STOP_HEADER'
# Active units (sourced from install/packaging/systemd/nftban-systemd-install.list).
# Stop + disable. No mask, no file removal — package files are owned by RPM and
# will be removed by the package manager.
# Templates (*@.service) are skipped: the template itself is not a runnable unit;
# only instances (e.g., nftban-alert@INSTANCE.service) are stoppable.
for unit in \
STOP_HEADER

        # Emit active units, skipping @.service templates
        local first=1
        while IFS= read -r unit; do
            [[ -z "$unit" ]] && continue
            case "$unit" in
                *@.service) continue ;;  # skip templates
            esac
            if [[ $first -eq 1 ]]; then
                printf '    %s' "$unit"
                first=0
            else
                printf ' \\\n    %s' "$unit"
            fi
        done <<< "$active"
        printf '; do\n'
        cat <<'STOP_BODY'
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done

STOP_BODY

        # Deprecated stop_only group
        echo "# Deprecated units (policy: stop_only) — stop + disable, no mask, no rm."
        echo "for unit in \\"
        local first_so=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_only" ]] && continue
            if [[ $first_so -eq 1 ]]; then
                printf '    %s' "$name"
                first_so=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'STOPONLY_BODY'
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done

STOPONLY_BODY

        # Deprecated stop_disable_mask_remove group
        echo "# Deprecated units (policy: stop_disable_mask_remove) — stop + disable + mask_if_exists."
        echo "# Closes Lane L10 F7_LOW: clean hosts no longer accumulate /etc/systemd/system mask residue."
        echo "for unit in \\"
        local first_sm=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_disable_mask_remove" ]] && continue
            if [[ $first_sm -eq 1 ]]; then
                printf '    %s' "$name"
                first_sm=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'SDMR_BODY'
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    mask_if_exists "$unit"
done

systemctl daemon-reload 2>/dev/null || true
SDMR_BODY
    } > "$target"

    print_ok "Wrote RPM cleanup snippet to $target"
}

# Generate DEB prerm cleanup body. Stop uses deb-systemd-invoke.
generate_deb() {
    local target="${1:-$DEB_OUT}"
    local active deprecated_lines

    active=$(read_active_units)
    deprecated_lines=$(read_deprecated_units)

    mkdir -p "$(dirname "$target")"

    {
        cat <<'HEADER'
# =============================================================================
# NFTBan DEB prerm systemd cleanup — DO NOT EDIT
# =============================================================================
# Generated by build/generate-systemd-maintainer-scripts.sh from:
#   install/packaging/systemd/nftban-systemd-install.list  (active units)
#   build/deprecated-units.yaml                            (deprecated units)
#
# Inlined between BEGIN/END sentinel markers in packaging/deb/prerm.
#
# Caller is responsible for surrounding case "$1" in remove|deconfigure) gating
# (cleanup must NOT run on upgrade or failed-upgrade).
# =============================================================================

HEADER
        emit_mask_helper
        echo
        cat <<'STOP_HEADER'
# Active units (sourced from install/packaging/systemd/nftban-systemd-install.list).
# DEB convention: deb-systemd-invoke for stop (upgrade-safe).
# Templates (*@.service) are skipped: the template itself is not a runnable unit;
# only instances are stoppable.
for unit in \
STOP_HEADER

        local first=1
        while IFS= read -r unit; do
            [[ -z "$unit" ]] && continue
            case "$unit" in
                *@.service) continue ;;
            esac
            if [[ $first -eq 1 ]]; then
                printf '    %s' "$unit"
                first=0
            else
                printf ' \\\n    %s' "$unit"
            fi
        done <<< "$active"
        printf '; do\n'
        cat <<'STOP_BODY'
    deb-systemd-invoke stop "$unit" >/dev/null 2>&1 || true
done

STOP_BODY

        # Deprecated stop_only
        echo "# Deprecated units (policy: stop_only) — stop + disable, no mask, no rm."
        echo "for unit in \\"
        local first_so=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_only" ]] && continue
            if [[ $first_so -eq 1 ]]; then
                printf '    %s' "$name"
                first_so=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'STOPONLY_BODY'
    deb-systemd-invoke stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" 2>/dev/null || true
done

STOPONLY_BODY

        # Deprecated stop_disable_mask_remove
        echo "# Deprecated units (policy: stop_disable_mask_remove) — stop + disable + mask_if_exists."
        echo "# Closes Lane L10 F7_LOW on the DEB side."
        echo "for unit in \\"
        local first_sm=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_disable_mask_remove" ]] && continue
            if [[ $first_sm -eq 1 ]]; then
                printf '    %s' "$name"
                first_sm=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'SDMR_BODY'
    deb-systemd-invoke stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" 2>/dev/null || true
    mask_if_exists "$unit"
done

# DEB-specific orphan binary cleanup (preserved from prior prerm)
rm -f /usr/sbin/nftban-ui /usr/libexec/nftban-ui-auth 2>/dev/null || true
rm -rf /run/nftban-ui 2>/dev/null || true

systemctl daemon-reload 2>/dev/null || true
SDMR_BODY
    } > "$target"

    print_ok "Wrote DEB cleanup snippet to $target"
}

# v108-item7c: Generate RPM %pre deprecated-only cleanup body.
# Runs on install + upgrade (NEW package side). Touches ONLY deprecated units
# from build/deprecated-units.yaml; never stops/disables active NFTBan units.
# Idempotent, silent on absence. Closes srv1-class stale residue from
# pre-v1.100.1b.A hosts upgrading to v1.107.2+.
generate_rpm_pre() {
    local target="${1:-$RPM_PRE_OUT}"
    local deprecated_lines
    deprecated_lines=$(read_deprecated_units)

    mkdir -p "$(dirname "$target")"

    {
        cat <<'HEADER'
# =============================================================================
# NFTBan RPM %pre deprecated-unit cleanup — DO NOT EDIT
# =============================================================================
# Generated by build/generate-systemd-maintainer-scripts.sh from:
#   build/deprecated-units.yaml                            (deprecated units)
#
# Consumed by packaging/build_nftban.sh::create_rpm_spec_nftban_core() and
# inlined into the spec %pre body via heredoc-write-time interpolation.
#
# RUNS UNCONDITIONALLY on install + upgrade.
# Touches ONLY deprecated units. Active units are NOT stopped/disabled here
# (active-unit cleanup remains in %preun, gated for complete uninstall).
#
# v108-item7c rationale:
#   Hosts upgrading from packages that pre-date v1.100.1b.A never had cleanup
#   logic in their OLD %preun. The NEW package's %pre is the only place that
#   can purge stale deprecated unit residue (e.g. nftban-ui.service) on those
#   hosts. Closes srv1-class lingering nftban-ui.service from v1.107.2 rollout.
# =============================================================================

HEADER
        emit_mask_helper
        echo

        # Deprecated stop_only group
        echo "# Deprecated units (policy: stop_only) — stop + disable, no mask, no rm."
        echo "for unit in \\"
        local first_so=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_only" ]] && continue
            if [[ $first_so -eq 1 ]]; then
                printf '    %s' "$name"
                first_so=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'STOPONLY_BODY'
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done

STOPONLY_BODY

        # Deprecated stop_disable_mask_remove group
        echo "# Deprecated units (policy: stop_disable_mask_remove) — stop + disable + mask_if_exists."
        echo "# Purges stale unit-file residue (e.g. nftban-ui.service) from hosts upgrading"
        echo "# from packages that pre-date v1.100.1b.A (GOTH PR-D4 stage 1)."
        echo "for unit in \\"
        local first_sm=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_disable_mask_remove" ]] && continue
            if [[ $first_sm -eq 1 ]]; then
                printf '    %s' "$name"
                first_sm=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'SDMR_BODY'
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    mask_if_exists "$unit"
done

systemctl daemon-reload 2>/dev/null || true
SDMR_BODY
    } > "$target"

    print_ok "Wrote RPM %pre deprecated-cleanup snippet to $target"
}

# v108-item7c: Generate DEB preinst deprecated-only cleanup body.
# Same goal as generate_rpm_pre: clean stale deprecated unit residue on the
# NEW package's preinst, before postinst validation can observe leftover units.
# DEB convention: deb-systemd-invoke for stop where possible; falls back to
# systemctl when deb-systemd-invoke isn't available on the running host.
generate_deb_preinst() {
    local target="${1:-$DEB_PREINST_OUT}"
    local deprecated_lines
    deprecated_lines=$(read_deprecated_units)

    mkdir -p "$(dirname "$target")"

    {
        cat <<'HEADER'
# =============================================================================
# NFTBan DEB preinst deprecated-unit cleanup — DO NOT EDIT
# =============================================================================
# Generated by build/generate-systemd-maintainer-scripts.sh from:
#   build/deprecated-units.yaml                            (deprecated units)
#
# Inlined between BEGIN/END sentinel markers in packaging/deb/preinst.
#
# RUNS UNCONDITIONALLY on install + upgrade (DEB preinst is invoked on every
# install/upgrade transaction). Touches ONLY deprecated units. Active units
# are NOT stopped/disabled here (active-unit cleanup remains in prerm, gated
# for remove|deconfigure).
#
# v108-item7c rationale (mirror of RPM %pre):
#   Hosts upgrading from packages that pre-date v1.100.1b.A never had cleanup
#   logic in their OLD prerm. The NEW package's preinst is the only place that
#   can purge stale deprecated unit residue on those hosts. Closes srv1-class.
# =============================================================================

HEADER
        emit_mask_helper
        echo

        # Deprecated stop_only group
        echo "# Deprecated units (policy: stop_only) — stop + disable, no mask, no rm."
        echo "for unit in \\"
        local first_so=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_only" ]] && continue
            if [[ $first_so -eq 1 ]]; then
                printf '    %s' "$name"
                first_so=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'STOPONLY_BODY'
    if command -v deb-systemd-invoke >/dev/null 2>&1; then
        deb-systemd-invoke stop "$unit" >/dev/null 2>&1 || true
    else
        systemctl stop "$unit" 2>/dev/null || true
    fi
    systemctl disable "$unit" 2>/dev/null || true
done

STOPONLY_BODY

        # Deprecated stop_disable_mask_remove group
        echo "# Deprecated units (policy: stop_disable_mask_remove) — stop + disable + mask_if_exists."
        echo "# Purges stale unit-file residue (e.g. nftban-ui.service) from hosts upgrading"
        echo "# from packages that pre-date v1.100.1b.A (GOTH PR-D4 stage 1)."
        echo "for unit in \\"
        local first_sm=1
        while IFS='|' read -r name policy; do
            [[ "$policy" != "stop_disable_mask_remove" ]] && continue
            if [[ $first_sm -eq 1 ]]; then
                printf '    %s' "$name"
                first_sm=0
            else
                printf ' \\\n    %s' "$name"
            fi
        done <<< "$deprecated_lines"
        printf '; do\n'
        cat <<'SDMR_BODY'
    if command -v deb-systemd-invoke >/dev/null 2>&1; then
        deb-systemd-invoke stop "$unit" >/dev/null 2>&1 || true
    else
        systemctl stop "$unit" 2>/dev/null || true
    fi
    systemctl disable "$unit" 2>/dev/null || true
    mask_if_exists "$unit"
done

systemctl daemon-reload 2>/dev/null || true
SDMR_BODY
    } > "$target"

    print_ok "Wrote DEB preinst deprecated-cleanup snippet to $target"
}

# v108-item7c: Replace BEGIN/END sentinel region in packaging/deb/preinst.
# Mirror of update_deb_prerm_sentinel().
update_deb_preinst_sentinel() {
    local preinst="${PROJECT_ROOT}/packaging/deb/preinst"
    local snippet="${1:-$DEB_PREINST_OUT}"

    if [[ ! -f "$preinst" ]]; then
        print_error "packaging/deb/preinst not found"
        return 1
    fi
    if ! grep -q '^[[:space:]]*# == BEGIN GENERATED deprecated-unit cleanup ==' "$preinst" \
       || ! grep -q '^[[:space:]]*# == END GENERATED deprecated-unit cleanup ==' "$preinst"; then
        print_error "packaging/deb/preinst missing BEGIN/END sentinel markers"
        print_error "Add the following before prereq checks:"
        print_error "    # == BEGIN GENERATED deprecated-unit cleanup =="
        print_error "    # == END GENERATED deprecated-unit cleanup =="
        return 1
    fi

    local tmp; tmp=$(mktemp)
    awk -v snip="$snippet" '
        /^[[:space:]]*# == BEGIN GENERATED deprecated-unit cleanup ==/ {
            print
            match($0, /^[[:space:]]*/)
            indent = substr($0, RSTART, RLENGTH)
            while ((getline line < snip) > 0) {
                if (line == "") print ""; else print indent line
            }
            close(snip)
            inblock = 1
            next
        }
        /^[[:space:]]*# == END GENERATED deprecated-unit cleanup ==/ {
            inblock = 0
        }
        !inblock { print }
    ' "$preinst" > "$tmp"

    mv "$tmp" "$preinst"
    chmod 0755 "$preinst"
    print_ok "Updated packaging/deb/preinst sentinel region"
}

# Replace BEGIN/END sentinel region in packaging/deb/prerm with generated DEB content.
update_deb_prerm_sentinel() {
    local prerm="${PROJECT_ROOT}/packaging/deb/prerm"
    local snippet="${1:-$DEB_OUT}"

    if [[ ! -f "$prerm" ]]; then
        print_error "packaging/deb/prerm not found"
        return 1
    fi
    if ! grep -q '^[[:space:]]*# == BEGIN GENERATED systemd cleanup ==' "$prerm" \
       || ! grep -q '^[[:space:]]*# == END GENERATED systemd cleanup ==' "$prerm"; then
        print_error "packaging/deb/prerm missing BEGIN/END sentinel markers"
        print_error "Add the following inside case 'remove|deconfigure' branch:"
        print_error "    # == BEGIN GENERATED systemd cleanup =="
        print_error "    # == END GENERATED systemd cleanup =="
        return 1
    fi

    local tmp; tmp=$(mktemp)
    awk -v snip="$snippet" '
        /^[[:space:]]*# == BEGIN GENERATED systemd cleanup ==/ {
            print
            # Replicate leading whitespace of BEGIN line on each generated line
            match($0, /^[[:space:]]*/)
            indent = substr($0, RSTART, RLENGTH)
            while ((getline line < snip) > 0) {
                if (line == "") print ""; else print indent line
            }
            close(snip)
            inblock = 1
            next
        }
        /^[[:space:]]*# == END GENERATED systemd cleanup ==/ {
            inblock = 0
        }
        !inblock { print }
    ' "$prerm" > "$tmp"

    mv "$tmp" "$prerm"
    chmod 0755 "$prerm"
    print_ok "Updated packaging/deb/prerm sentinel region"
}

generate_all() {
    local rpm_t="${1:-$RPM_OUT}"
    local deb_t="${2:-$DEB_OUT}"
    local rpm_pre_t="${3:-$RPM_PRE_OUT}"
    local deb_preinst_t="${4:-$DEB_PREINST_OUT}"
    generate_rpm "$rpm_t"
    generate_deb "$deb_t"
    # v108-item7c: emit new NEW-package-side deprecated-only snippets.
    generate_rpm_pre "$rpm_pre_t"
    generate_deb_preinst "$deb_preinst_t"
    if [[ "$rpm_t" = "$RPM_OUT" && "$deb_t" = "$DEB_OUT" ]]; then
        # Only update sentinels in real run, not check-mode temp dirs
        update_deb_prerm_sentinel "$deb_t" || true
        update_deb_preinst_sentinel "$deb_preinst_t" || true
    fi
}

check_mode() {
    print_info "Running in check mode — verifying generated files..."

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "${temp_dir:-}"' EXIT

    local temp_rpm="${temp_dir}/nftban-preun-systemd-cleanup.inc"
    local temp_deb="${temp_dir}/nftban-prerm-systemd-cleanup.inc"
    # v108-item7c
    local temp_rpm_pre="${temp_dir}/nftban-pre-deprecated-cleanup.inc"
    local temp_deb_preinst="${temp_dir}/nftban-preinst-deprecated-cleanup.inc"

    generate_rpm "$temp_rpm" >/dev/null
    generate_deb "$temp_deb" >/dev/null
    generate_rpm_pre "$temp_rpm_pre" >/dev/null
    generate_deb_preinst "$temp_deb_preinst" >/dev/null

    local fail=0

    if [[ ! -f "$RPM_OUT" ]]; then
        print_error "Committed RPM artifact missing: $RPM_OUT"
        fail=1
    elif ! diff -q "$RPM_OUT" "$temp_rpm" >/dev/null 2>&1; then
        print_error "DRIFT: $RPM_OUT is stale"
        diff -u "$RPM_OUT" "$temp_rpm" | head -40 || true
        fail=1
    else
        print_ok "OK: nftban-preun-systemd-cleanup.inc matches generator"
    fi

    if [[ ! -f "$DEB_OUT" ]]; then
        print_error "Committed DEB artifact missing: $DEB_OUT"
        fail=1
    elif ! diff -q "$DEB_OUT" "$temp_deb" >/dev/null 2>&1; then
        print_error "DRIFT: $DEB_OUT is stale"
        diff -u "$DEB_OUT" "$temp_deb" | head -40 || true
        fail=1
    else
        print_ok "OK: nftban-prerm-systemd-cleanup.inc matches generator"
    fi

    # v108-item7c: NEW-package-side deprecated-cleanup parity checks.
    if [[ ! -f "$RPM_PRE_OUT" ]]; then
        print_error "Committed RPM %pre artifact missing: $RPM_PRE_OUT"
        fail=1
    elif ! diff -q "$RPM_PRE_OUT" "$temp_rpm_pre" >/dev/null 2>&1; then
        print_error "DRIFT: $RPM_PRE_OUT is stale"
        diff -u "$RPM_PRE_OUT" "$temp_rpm_pre" | head -40 || true
        fail=1
    else
        print_ok "OK: nftban-pre-deprecated-cleanup.inc matches generator"
    fi

    if [[ ! -f "$DEB_PREINST_OUT" ]]; then
        print_error "Committed DEB preinst artifact missing: $DEB_PREINST_OUT"
        fail=1
    elif ! diff -q "$DEB_PREINST_OUT" "$temp_deb_preinst" >/dev/null 2>&1; then
        print_error "DRIFT: $DEB_PREINST_OUT is stale"
        diff -u "$DEB_PREINST_OUT" "$temp_deb_preinst" | head -40 || true
        fail=1
    else
        print_ok "OK: nftban-preinst-deprecated-cleanup.inc matches generator"
    fi

    # Also verify sentinel region in packaging/deb/prerm matches generated content
    local prerm="${PROJECT_ROOT}/packaging/deb/prerm"
    if grep -q '^[[:space:]]*# == BEGIN GENERATED systemd cleanup ==' "$prerm" 2>/dev/null; then
        # Extract sentinel region content (without leading indent) and compare to generator output
        local sentinel_extract
        sentinel_extract=$(awk '
            /^[[:space:]]*# == BEGIN GENERATED systemd cleanup ==/ { inblock=1; next }
            /^[[:space:]]*# == END GENERATED systemd cleanup ==/ { inblock=0; next }
            inblock {
                # Strip leading whitespace consistent with sentinel indent
                sub(/^        /, "")  # 8-space indent inside case branch
                print
            }
        ' "$prerm")

        if ! diff -q <(printf '%s\n' "$sentinel_extract") <(cat "$temp_deb") >/dev/null 2>&1; then
            print_error "DRIFT: packaging/deb/prerm sentinel region is stale vs generator"
            diff -u <(printf '%s\n' "$sentinel_extract") <(cat "$temp_deb") | head -40 || true
            fail=1
        else
            print_ok "OK: packaging/deb/prerm sentinel region matches generator"
        fi
    else
        print_error "packaging/deb/prerm missing BEGIN GENERATED sentinel"
        fail=1
    fi

    # v108-item7c: packaging/deb/preinst sentinel region parity check.
    local preinst="${PROJECT_ROOT}/packaging/deb/preinst"
    if [[ -f "$preinst" ]]; then
        if grep -q '^[[:space:]]*# == BEGIN GENERATED deprecated-unit cleanup ==' "$preinst" 2>/dev/null; then
            local preinst_sentinel_extract
            preinst_sentinel_extract=$(awk '
                /^[[:space:]]*# == BEGIN GENERATED deprecated-unit cleanup ==/ { inblock=1; next }
                /^[[:space:]]*# == END GENERATED deprecated-unit cleanup ==/ { inblock=0; next }
                inblock {
                    sub(/^/, "")  # no surrounding indent — top-level in preinst
                    print
                }
            ' "$preinst")

            if ! diff -q <(printf '%s\n' "$preinst_sentinel_extract") <(cat "$temp_deb_preinst") >/dev/null 2>&1; then
                print_error "DRIFT: packaging/deb/preinst sentinel region is stale vs generator"
                diff -u <(printf '%s\n' "$preinst_sentinel_extract") <(cat "$temp_deb_preinst") | head -40 || true
                fail=1
            else
                print_ok "OK: packaging/deb/preinst sentinel region matches generator"
            fi
        else
            print_error "packaging/deb/preinst missing BEGIN GENERATED deprecated-unit cleanup sentinel"
            fail=1
        fi
    else
        print_error "packaging/deb/preinst not present"
        fail=1
    fi

    if [[ $fail -eq 1 ]]; then
        print_error "Run 'bash build/generate-systemd-maintainer-scripts.sh' to regenerate"
        return 1
    fi
    print_ok "All systemd-maintainer-script outputs are up to date"
    return 0
}

main() {
    case "${1:-}" in
        --check)
            check_mode
            return $?
            ;;
        ""|--write)
            generate_all
            return $?
            ;;
        -h|--help)
            sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            return 0
            ;;
        *)
            print_error "Unknown option: $1"
            return 2
            ;;
    esac
}

main "$@"
