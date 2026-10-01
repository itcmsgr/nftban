#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - Uninstall Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="uninstall"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Complete removal of NFTBan from system"
# meta:input="--purge flag (optional)"
# meta:output="Removed NFTBan installation"
# meta:depends="systemd, nft"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Usage: ./uninstall.sh [--purge]
#        --purge: Remove ALL data including configs, logs, and databases
# =============================================================================

set -Eeuo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log()   { echo -e "${BLUE}[UNINSTALL]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK   ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ WARN  ]${NC} $*"; }
error() { echo -e "${RED}[ ERROR ]${NC} $*"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Parse options
PURGE_DATA=false
if [[ "${1:-}" == "--purge" ]]; then
    PURGE_DATA=true
fi

# =============================================================================
# LOAD SCHEMA FOR TABLE/SET NAMES
# =============================================================================

load_schema() {
    if [[ -f "$SCRIPT_DIR/cli/lib/nftban/lib/nft_schema.sh" ]]; then
        source "$SCRIPT_DIR/cli/lib/nftban/lib/nft_schema.sh"
        ok "Loaded NFT schema"
    else
        warn "NFT schema not found, using fallback table names"
        # Fallback definitions
        export NFTBAN_TABLE_IPV4="ip nftban"
        export NFTBAN_TABLE_IPV6="ip6 nftban"
    fi
}

# =============================================================================
# LOAD DISTRO CONFIG FOR SERVICE NAMES
# =============================================================================

load_distro_config() {
    if [[ -f "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh" ]]; then
        export NFTBAN_DISTRO_CONF_DIR="$SCRIPT_DIR/etc/nftban/distros"
        source "$SCRIPT_DIR/cli/lib/nftban/lib/nftban_distro_config.sh"

        if nftban_distro_init; then
            ok "Loaded distro config: ${DISTRO_INFO[name]} ${DISTRO_INFO[version]}"
        else
            warn "Failed to load distro config, using defaults"
        fi
    else
        warn "Distro config system not found, using defaults"
    fi
}

# =============================================================================
# SAFETY FUNCTIONS
# =============================================================================

# Safe rm -rf wrapper with multiple guards to prevent catastrophic deletion
safe_rm_rf() {
    local path="$1"
    local expected_prefix="${2:-}"  # Optional: enforce path prefix (e.g., "/var/")

    # Guard 1: Path must not be empty
    if [[ -z "$path" ]]; then
        error "CRITICAL: Attempted rm -rf with empty path"
        exit 1
    fi

    # Guard 2: Path must not be root directory
    if [[ "$path" == "/" ]]; then
        error "CRITICAL: Attempted rm -rf on root directory (/)"
        exit 1
    fi

    # Guard 3: Block critical system directories
    local critical_paths=("/" "/bin" "/boot" "/dev" "/etc" "/home" "/lib" "/lib64" "/opt" "/proc" "/root" "/sbin" "/sys" "/usr")
    for critical in "${critical_paths[@]}"; do
        if [[ "$path" == "$critical" ]]; then
            error "CRITICAL: Attempted rm -rf on critical system path: $path"
            exit 1
        fi
    done

    # Guard 4: Enforce expected prefix if provided
    if [[ -n "$expected_prefix" ]] && [[ "$path" != ${expected_prefix}* ]]; then
        error "CRITICAL: Path $path does not start with expected prefix $expected_prefix"
        exit 1
    fi

    # Guard 5: Path must not contain directory traversal
    if [[ "$path" == *..* ]]; then
        error "CRITICAL: Path contains directory traversal: $path"
        exit 1
    fi

    # All guards passed - safe to delete
    rm -rf "$path"
}

# =============================================================================
# UNINSTALL FUNCTIONS
# =============================================================================

# >>> NFTBAN_SYNPROXY_RAW_CLEANUP_BEGIN >>>
# v1.233.1 BUG-UNINSTALL-DOES-NOT-REMOVE-SYNPROXY-RAW-NOTRACK-RULES.
# NFTBan's SYNPROXY notrack rules live in the FOREIGN tables ip/ip6 raw, chain
# prerouting, outside the nftban tables that uninstall deletes. Until v1.233.0
# they disappeared at uninstall only as a side effect of the daemon Stop()
# re-running the DDoS reconcile; Stop() no longer does that (Stop != Disable).
# SCOPE: delete ONLY rules in <family> raw prerouting whose comment carries the
# NFTBan marker "SYNPROXY: - the comment scope of _nft_cleanup_synproxy_raw
# (cli/lib/nftban/lib/nft_fragment.sh) - by handle, after a successful listing.
# The raw tables, their chains and every other rule are never touched.
# SELF-CONTAINED: DEB postrm and RPM postun run after the payload is gone, so nothing
# here may source a product library. Needs only nft and awk.
# REPORT, DO NOT ABORT: when the kernel cannot be observed (nft missing, listing
# refused) or a delete fails, a WARN naming the residue goes to stderr and the
# function still returns 0 - the package removal itself must not fail on it.
# Byte-identical copies: packaging/deb/postrm, packaging/build_nftban.sh
# (RPM postun), uninstall.sh - drift-checked by
# cli/lib/nftban/tests/uninstall_synproxy_raw_cleanup_v1233_1_test.sh.
_nftban_uninstall_synproxy_raw() {
    _nsr_handles_prog='
        $1 == "chain" && $2 == "prerouting" { inchain = 1; next }
        inchain && $1 == "}" { inchain = 0; next }
        inchain && tolower($0) ~ /comment.*"synproxy:/ && NF >= 3 && $(NF-2) == "#" && $(NF-1) == "handle" && $NF ~ /^[0-9]+$/ { print $NF }'
    if ! command -v nft >/dev/null 2>&1; then
        echo "nftban: WARN: SYNPROXY raw notrack cleanup NOT_OBSERVED: nft not found - check with: nft -a list chain ip raw prerouting; nft -a list chain ip6 raw prerouting" >&2
        return 0
    fi
    if ! _nsr_tables=$(nft list tables 2>&1); then
        echo "nftban: WARN: SYNPROXY raw notrack cleanup NOT_OBSERVED: nft list tables failed: $_nsr_tables" >&2
        return 0
    fi
    for _nsr_fam in ip ip6; do
        _nsr_present=$(awk -v want="table $_nsr_fam raw" '$0 == want { found = 1 } END { print found + 0 }' <<_NFTBAN_NSR_
$_nsr_tables
_NFTBAN_NSR_
)
        [ "$_nsr_present" = 1 ] || continue
        if ! _nsr_list=$(nft -a list table "$_nsr_fam" raw 2>&1); then
            echo "nftban: WARN: SYNPROXY raw notrack cleanup NOT_OBSERVED ($_nsr_fam raw): $_nsr_list" >&2
            continue
        fi
        _nsr_handles=$(awk "$_nsr_handles_prog" <<_NFTBAN_NSR_
$_nsr_list
_NFTBAN_NSR_
)
        [ -n "$_nsr_handles" ] || continue
        _nsr_removed=0
        _nsr_failed=0
        for _nsr_h in $_nsr_handles; do
            if _nsr_err=$(nft delete rule "$_nsr_fam" raw prerouting handle "$_nsr_h" 2>&1); then
                _nsr_removed=$((_nsr_removed + 1))
            else
                _nsr_failed=$((_nsr_failed + 1))
                echo "nftban: WARN: could not delete NFTBan SYNPROXY rule ($_nsr_fam raw prerouting handle $_nsr_h): $_nsr_err" >&2
            fi
        done
        if ! _nsr_list=$(nft -a list table "$_nsr_fam" raw 2>&1); then
            echo "nftban: WARN: SYNPROXY raw notrack cleanup ($_nsr_fam): removed=$_nsr_removed failed=$_nsr_failed remaining=NOT_OBSERVED: $_nsr_list" >&2
            continue
        fi
        _nsr_rest=$(awk "$_nsr_handles_prog" <<_NFTBAN_NSR_
$_nsr_list
_NFTBAN_NSR_
)
        _nsr_left=0
        for _nsr_h in $_nsr_rest; do
            _nsr_left=$((_nsr_left + 1))
        done
        if [ "$_nsr_left" -eq 0 ] && [ "$_nsr_failed" -eq 0 ]; then
            echo "nftban: removed $_nsr_removed NFTBan SYNPROXY notrack rule(s) from $_nsr_fam raw prerouting; other raw rules left untouched."
        else
            echo "nftban: WARN: SYNPROXY raw notrack cleanup ($_nsr_fam): removed=$_nsr_removed failed=$_nsr_failed remaining=$_nsr_left - remove manually: nft -a list chain $_nsr_fam raw prerouting" >&2
        fi
    done
    return 0
}
# <<< NFTBAN_SYNPROXY_RAW_CLEANUP_END <<<


uninstall_package_manager() {
    log "Removing package from system package manager..."

    # Check if installed via RPM (RHEL/AlmaLinux/Rocky/Fedora/CentOS)
    if command -v rpm &>/dev/null; then
        if rpm -q nftban-core &>/dev/null; then
            log "  Found RPM package, removing from database..."
            # Use --nodeps to remove just the database entry, files will be cleaned separately
            # This prevents "file already removed" warnings
            rpm -e --nodeps --noscripts nftban-core 2>/dev/null || true
            ok "Removed nftban-core from RPM database"
        else
            ok "No RPM package found in database"
        fi
    fi

    # Check if installed via DEB (Debian/Ubuntu)
    if command -v dpkg &>/dev/null; then
        if dpkg -l nftban-core 2>/dev/null | grep -qE '^ii|^iU|^iF|^iH'; then
            # D2 (UNINSTALL-PR1): `dpkg --purge` is gated behind PURGE_DATA.
            #
            # Both commands used to run unconditionally, so STANDARD mode always
            # purged. `dpkg --purge` fires `postrm purge)`, which rm -rf's all
            # five trees — including whitelist.d/*.conf, the durable
            # management-IP whitelist that is the SSH-lockout safety invariant —
            # while this same script printed "Configuration preserved" (:379),
            # "Data preserved" (:415) and "Configuration and data preserved"
            # (:512). The operator was told the exact opposite of what happened.
            #
            # This script's own config/data steps were already PURGE_DATA-gated;
            # only the package-level purge was not. Standard mode now matches
            # `apt remove` semantics.
            if [[ "$PURGE_DATA" == true ]]; then
                log "  Found DEB package, PURGING from database (config+data will be removed)..."
                dpkg --remove --force-remove-reinstreq nftban-core 2>/dev/null || true
                dpkg --purge nftban-core 2>/dev/null || true
                ok "Purged nftban-core from dpkg database"
            else
                log "  Found DEB package, removing from database (config+data preserved)..."
                dpkg --remove --force-remove-reinstreq nftban-core 2>/dev/null || true
                ok "Removed nftban-core from dpkg database"
            fi
        else
            ok "No DEB package found in database"
        fi
    fi
}

uninstall_services() {
    log "Stopping and disabling NFTBan services..."

    # List of service patterns to remove
    local service_patterns=(
        "nftban-*.service"
        "nftban-*.timer"
        "nftband.service"
        "nftband.socket"
    )

    local stopped=0

    # Find and stop all NFTBan services
    for pattern in "${service_patterns[@]}"; do
        # Get list of matching units
        local units
        units=$(systemctl list-units --all --no-legend "$pattern" 2>/dev/null | awk '{print $1}' || true)

        for unit in $units; do
            [[ -z "$unit" ]] && continue

            # Stop service
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                echo "  Stopping: $unit"
                systemctl stop "$unit" 2>/dev/null || true
                stopped=$((stopped + 1))
            fi

            # Disable service
            if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
                echo "  Disabling: $unit"
                systemctl disable "$unit" 2>/dev/null || true
            fi
        done
    done

    if [[ $stopped -gt 0 ]]; then
        ok "Stopped $stopped service(s)"
    else
        ok "No running services found"
    fi
}

uninstall_systemd_units() {
    log "Removing systemd units..."

    local removed=0

    # Remove service and timer files
    for file in /etc/systemd/system/nftban-*.service /etc/systemd/system/nftban-*.timer; do
        if [[ -f "$file" ]]; then
            echo "  Removing: $(basename "$file")"
            rm -f "$file"
            removed=$((removed + 1))
        fi
    done

    # Reload systemd
    if [[ $removed -gt 0 ]]; then
        systemctl daemon-reload
        ok "Removed $removed systemd unit(s)"
    else
        ok "No systemd units found"
    fi
}

uninstall_binaries() {
    log "Removing binaries..."

    # ==========================================================================
    # v1.234 (PR #1439): remove ONLY immutable flags NFTBan can PROVE it set
    # (shared library: ownership record or pre-v1.234 installer.log proof).
    # An administrator's flag is never removed; what it keeps is reported below.
    # ==========================================================================
    local immut_lib=""
    for immut_lib in /usr/lib/nftban/lib/nftban_immutable_owned.sh \
                     "$(dirname "${BASH_SOURCE[0]}")/cli/lib/nftban/lib/nftban_immutable_owned.sh"; do
        [[ -r "$immut_lib" ]] && break
        immut_lib=""
    done
    if [[ -n "$immut_lib" ]]; then
        # shellcheck source=cli/lib/nftban/lib/nftban_immutable_owned.sh
        . "$immut_lib"
        local st p
        while read -r st p; do
            case "$st" in
                UNLOCKED)   ok "Removed NFTBan's own immutable protection: $p" ;;
                NOT_PROVEN) warn "Immutable flag on $p is not provably NFTBan's - left in place (its administrator decides)" ;;
            esac
        done < <(nftban_immut_unlock_owned)
    else
        warn "Immutable-ownership library not found - no immutable flag is removed"
    fi

    local removed=0
    local binaries=(
        "/usr/sbin/nftban"
        "/usr/sbin/nftban-ui"
        "/usr/libexec/nftban-ui-auth"
        "/usr/lib/nftban"
    )

    for binary in "${binaries[@]}"; do
        if [[ -e "$binary" ]]; then
            echo "  Removing: $binary"
            safe_rm_rf "$binary" "/usr/"  # Enforce /usr/ prefix for safety
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        ok "Removed $removed binary/library location(s)"
    else
        ok "No binaries found"
    fi
    # v1.234: no false success — report what immutable/append-only flags kept.
    local left=""
    for binary in "${binaries[@]}"; do
        [[ -e "$binary" ]] || continue
        left+=$(lsattr -Rad "$binary" 2>/dev/null | awk '$1 !~ /[\/:]/ && $1 ~ /[ia]/ {print "    " $2}')$'\n'
        [[ -e "$binary" ]] && warn "Removal INCOMPLETE: $binary still exists"
    done
    if [[ -n "${left//[$'\n']/}" ]]; then
        warn "These paths carry an immutable/append-only flag NFTBan did not set and were left in place:"
        printf '%s' "$left" | sed '/^$/d'
    fi
}

uninstall_bash_completion() {
    log "Removing bash completion..."

    if [[ -f "/usr/share/bash-completion/completions/nftban" ]]; then
        rm -f /usr/share/bash-completion/completions/nftban
        ok "Bash completion removed"
    else
        ok "No bash completion found"
    fi
}

uninstall_nftables() {
    log "Removing nftables rules..."

    local removed=0

    # Use schema-defined table names
    local tables=("${NFTBAN_TABLE_IPV4}" "${NFTBAN_TABLE_IPV6}")

    for table in "${tables[@]}"; do
        if nft list table "$table" >/dev/null 2>&1; then
            echo "  Deleting table: $table"
            nft delete table "$table" 2>/dev/null || true
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        ok "Removed $removed nftables table(s)"
    else
        ok "No NFTBan nftables found"
    fi

    # v1.233.1: NFTBan SYNPROXY notrack rules live in the FOREIGN ip/ip6 raw
    # tables, not in the tables deleted above. `rpm -e --noscripts` (see
    # uninstall_package_manager) never runs the RPM postun that removes them,
    # so this script removes them itself. Comment-scoped; reports NOT_OBSERVED
    # and continues when the kernel cannot be read.
    _nftban_uninstall_synproxy_raw

    # Remove nftables.conf if it looks like NFTBan's
    if [[ -f "/etc/nftables.conf" ]] && grep -q "NFTBan" /etc/nftables.conf 2>/dev/null; then
        warn "NFTBan nftables.conf found at /etc/nftables.conf"
        echo "    Leaving in place (may contain user modifications)"
        echo "    Remove manually if needed: sudo rm /etc/nftables.conf"
    fi
}

uninstall_polkit() {
    log "Removing polkit policies..."

    local removed=0

    # Remove polkit action files
    for file in /usr/share/polkit-1/actions/com.nftban.*; do
        if [[ -f "$file" ]]; then
            echo "  Removing: $(basename "$file")"
            rm -f "$file"
            removed=$((removed + 1))
        fi
    done

    # Remove polkit rules
    for file in /etc/polkit-1/rules.d/*nftban*.rules; do
        if [[ -f "$file" ]]; then
            echo "  Removing: $(basename "$file")"
            rm -f "$file"
            removed=$((removed + 1))
        fi
    done

    if [[ $removed -gt 0 ]]; then
        ok "Removed $removed polkit policy/rule(s)"
    else
        ok "No polkit policies found"
    fi
}

uninstall_tmpfiles() {
    log "Removing tmpfiles.d configuration..."

    local removed=0
    for file in /etc/tmpfiles.d/nftban.conf /usr/lib/tmpfiles.d/nftban.conf; do
        if [[ -f "$file" ]]; then
            echo "  Removing: $file"
            rm -f "$file"
            removed=$((removed + 1))
        fi
    done

    # Remove logrotate config
    if [[ -f /etc/logrotate.d/nftban ]]; then
        echo "  Removing: /etc/logrotate.d/nftban"
        rm -f /etc/logrotate.d/nftban
        removed=$((removed + 1))
    fi

    if [[ $removed -gt 0 ]]; then
        ok "Removed $removed system config(s)"
    else
        ok "No tmpfiles.d configs found"
    fi
}

uninstall_configs() {
    if [[ "$PURGE_DATA" == true ]]; then
        log "Purging configuration files..."

        if [[ -d "/etc/nftban" ]]; then
            echo "  Removing: /etc/nftban"
            rm -rf /etc/nftban
            ok "Configuration directory purged"
        else
            ok "No configuration directory found"
        fi
    else
        log "Keeping configuration files..."
        echo "    Config directory: /etc/nftban"
        echo "    (Use --purge to remove)"
        ok "Configuration preserved"
    fi
}

uninstall_data() {
    if [[ "$PURGE_DATA" == true ]]; then
        log "Purging data directories..."

        # D4 (UNINSTALL-PR1): each directory carries its OWN expected prefix.
        #
        # /usr/share/nftban used to sit in this list while every entry was passed
        # "/var/" as expected_prefix. safe_rm_rf Guard 4 then fired
        # `CRITICAL: Path /usr/share/nftban does not start with expected prefix
        # /var/` and `exit 1` — AFTER /var/lib, /var/log and /var/cache had
        # already been deleted. The operator saw a CRITICAL failure and no
        # summary, with the evidence corpus already gone.
        #
        #     PARTIAL_PROGRESS != SAFE_INTERMEDIATE_STATE
        #
        # Pairing the prefix with the path keeps Guard 4 at full strength (it is
        # never widened to a permissive prefix) while making it impossible for a
        # correctly-listed directory to abort the run.
        local data_dirs=(
            "/var/lib/nftban|/var/"
            "/var/log/nftban|/var/"
            "/var/cache/nftban|/var/"
            "/usr/share/nftban|/usr/share/"
        )

        local removed=0

        for entry in "${data_dirs[@]}"; do
            local dir="${entry%%|*}"
            local prefix="${entry##*|}"
            if [[ -d "$dir" ]]; then
                echo "  Removing: $dir"
                safe_rm_rf "$dir" "$prefix"
                removed=$((removed + 1))
            fi
        done

        if [[ $removed -gt 0 ]]; then
            ok "Purged $removed data directory/directories"
        else
            ok "No data directories found"
        fi
    else
        log "Keeping data directories..."
        echo "    Data: /var/lib/nftban"
        echo "    Logs: /var/log/nftban"
        echo "    Cache: /var/cache/nftban"
        echo "    (Use --purge to remove)"
        ok "Data preserved"
    fi
}

# =============================================================================
# MAIN UNINSTALL LOGIC
# =============================================================================

echo ""
log "════════════════════════════════════════════════════════════"
log "  NFTBan Uninstall"
log "════════════════════════════════════════════════════════════"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root"
    echo "Try: sudo $0 ${1:-}"
    exit 1
fi

# Show mode
if [[ "$PURGE_DATA" == true ]]; then
    warn "PURGE MODE: All data will be removed"
else
    log "STANDARD MODE: Configs and data will be preserved"
    echo "    Use --purge to remove everything"
fi
echo ""

# Confirmation
if [[ "$PURGE_DATA" == true ]]; then
    warn "⚠️  WARNING: This will remove ALL NFTBan files and data"
    echo ""
    echo "This includes:"
    echo "  • All binaries and libraries"
    echo "  • All configuration files (/etc/nftban)"
    echo "  • All data and logs (/var/lib/nftban, /var/log/nftban)"
    echo "  • All nftables rules (tables: ip nftban, ip6 nftban)"
    echo "  • All systemd services"
    echo ""
    read -p "Type 'YES' to confirm purge: " confirm

    if [[ "$confirm" != "YES" ]]; then
        echo "Cancelled."
        exit 0
    fi
    echo ""
fi

# Load configurations
load_schema
load_distro_config
echo ""

# Execute uninstall steps
# CRITICAL: Remove from package manager FIRST to prevent "already installed" issues on reinstall
uninstall_package_manager
echo ""

uninstall_services
echo ""

uninstall_systemd_units
echo ""

uninstall_binaries
echo ""

uninstall_bash_completion
echo ""

uninstall_nftables
echo ""

uninstall_polkit
echo ""

uninstall_tmpfiles
echo ""

uninstall_configs
echo ""

uninstall_data
echo ""

# Summary
log "════════════════════════════════════════════════════════════"
if [[ "$PURGE_DATA" == true ]]; then
    ok "NFTBan completely removed (purged)"
    echo ""
    echo "✅ All NFTBan components have been removed"
else
    ok "NFTBan uninstalled (data preserved)"
    echo ""
    echo "✅ NFTBan binaries and services removed"
    echo "📁 Configuration and data preserved:"
    echo "   • /etc/nftban (configs)"
    echo "   • /var/lib/nftban (data)"
    echo "   • /var/log/nftban (logs)"
    echo ""
    echo "To completely remove everything:"
    echo "   sudo $0 --purge"
fi
echo ""

# D5 (UNINSTALL-PR1): tell the truth about firewall state after removal.
#
# This script deletes NFTBan's nft tables in BOTH modes and never re-probes,
# yet printed NOTHING about firewall state. The packaging scriptlets did worse:
# they asserted "Other firewall rules ... were NOT modified and may still be
# active" — which was FALSE on the proven EL9 host, where no other firewall
# existed and the nftables tooling itself had been cascade-removed by package
# dependency cleanup.
#
#     OBSERVATION_FAILURE_MUST_NEVER_BE_INTERPRETED_AS_SECURITY_STATE
#
# The wording below is deliberately unconditional and claims NOTHING this
# script has not done itself. It does not assert another firewall is active,
# because that was never probed. Upgrading to a real post-condition probe is
# UNINSTALL-PR2/PR3 scope; asserting an unverified positive is never acceptable.
echo "⚠️  FIREWALL STATE — REVIEW REQUIRED"
echo "   NFTBan no longer protects this host."
echo "   Review your firewall state after removal."
echo "   nftables tooling may also have been removed by package-manager"
echo "   dependency cleanup."
echo ""
log "════════════════════════════════════════════════════════════"
