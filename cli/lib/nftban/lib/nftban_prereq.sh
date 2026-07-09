#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_prereq" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Shared prerequisite checking with distro-aware package suggestions"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Usage:
#   source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh"
#
#   nftban_prereq_init
#   nftban_prereq_require_cmd "suricata" "suricata" "IDS engine"
#   nftban_prereq_require_any_cmd "zabbix_sender ncat" "zabbix_sender ncat" "Zabbix transport"
#   if ! nftban_prereq_satisfied; then
#       nftban_prereq_report
#       return 1
#   fi
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_PREREQ_LOADED:-}" ]] && return 0
readonly _NFTBAN_PREREQ_LOADED=1

# =============================================================================
# PREREQ STATE (module-scoped arrays)
# =============================================================================

# These arrays are reset by nftban_prereq_init()
NFTBAN_PREREQ_MISSING=()
NFTBAN_PREREQ_HINTS=()
NFTBAN_PREREQ_WARNINGS=()

# =============================================================================
# CORE PRIMITIVES
# =============================================================================

nftban_have_cmd() {
    # Check if a binary exists on PATH
    # Args: <binary_name>
    # Returns: 0 if found, 1 if not
    command -v "$1" &>/dev/null
}

nftban_prereq_init() {
    # Reset all prereq tracking arrays. Call before a check sequence.
    NFTBAN_PREREQ_MISSING=()
    NFTBAN_PREREQ_HINTS=()
    NFTBAN_PREREQ_WARNINGS=()
}

# =============================================================================
# REQUIREMENT CHECKERS
# =============================================================================

nftban_prereq_require_cmd() {
    # Require a specific binary. If missing, record failure with distro hint.
    # Args: <binary> <distro_package_key> <description>
    # Returns: 0 if binary found, 1 if missing
    #
    # Example: nftban_prereq_require_cmd "suricata" "suricata" "IDS engine"
    #          nftban_prereq_require_cmd "host" "dns_utils" "DNS lookup"

    local binary="$1"
    local pkg_key="$2"
    local description="${3:-$binary}"

    if nftban_have_cmd "$binary"; then
        return 0
    fi

    # Resolve distro-correct package name
    local pkg_name="$pkg_key"
    if declare -F nftban_distro_get_package >/dev/null 2>&1; then
        pkg_name=$(nftban_distro_get_package "$pkg_key" 2>/dev/null) || pkg_name="$pkg_key"
    fi
    [[ -z "$pkg_name" ]] && pkg_name="$pkg_key"

    # Resolve distro install command
    local install_cmd
    install_cmd=$(_nftban_prereq_install_cmd)

    NFTBAN_PREREQ_MISSING+=("${description} (${binary})")
    NFTBAN_PREREQ_HINTS+=("sudo ${install_cmd} ${pkg_name}")
    return 1
}

nftban_prereq_require_any_cmd() {
    # Require at least ONE of several binaries. If none found, record failure.
    # Args: "<binary1> <binary2> ..." "<pkg_key1> <pkg_key2> ..." <description>
    # Returns: 0 if any binary found, 1 if all missing
    #
    # Example: nftban_prereq_require_any_cmd \
    #            "zabbix_sender ncat nc" \
    #            "zabbix_sender ncat ncat" \
    #            "Zabbix transport"

    local binaries_str="$1"
    local pkg_keys_str="$2"
    local description="${3:-transport}"

    # CONTRACT (v1.219.1): prereq helpers MUST be safe when sourced by strict-mode callers
    # that set IFS=$'\n\t' (e.g. cmd_rbl.sh). The space-separated "b1 b2 b3" args below rely on
    # whitespace word-splitting, so restore a whitespace IFS locally. Without this, a caller's
    # IFS=$'\n\t' makes `for bin in $binaries_str` iterate ONCE over the whole joined string
    # ("host dig nslookup") → false-MISSING even when a tool exists (the RBL enable hard-block).
    local IFS=$' \t\n'

    # Check each binary
    local bin
    for bin in $binaries_str; do
        if nftban_have_cmd "$bin"; then
            return 0
        fi
    done

    # None found — build suggestion list
    local install_cmd
    install_cmd=$(_nftban_prereq_install_cmd)

    local suggestions=""
    local -a bins keys
    read -r -a bins <<< "$binaries_str"
    read -r -a keys <<< "$pkg_keys_str"
    local i
    for i in "${!keys[@]}"; do
        local pkg="${keys[$i]}"
        if declare -F nftban_distro_get_package >/dev/null 2>&1; then
            pkg=$(nftban_distro_get_package "${keys[$i]}" 2>/dev/null) || pkg="${keys[$i]}"
        fi
        [[ -z "$pkg" ]] && pkg="${keys[$i]}"
        if [[ -n "$suggestions" ]]; then
            suggestions+=", "
        fi
        suggestions+="${bins[$i]} (${pkg})"
    done

    NFTBAN_PREREQ_MISSING+=("${description}")
    NFTBAN_PREREQ_HINTS+=("sudo ${install_cmd} <package>  — options: ${suggestions}")
    return 1
}

nftban_prereq_require_file() {
    # Require a file to exist (e.g. Go binary, database file)
    # Args: <path> <description>
    # Returns: 0 if exists, 1 if missing

    local filepath="$1"
    local description="${2:-$filepath}"

    if [[ -f "$filepath" ]] || [[ -x "$filepath" ]]; then
        return 0
    fi

    NFTBAN_PREREQ_MISSING+=("${description}")
    NFTBAN_PREREQ_HINTS+=("File not found: ${filepath}")
    return 1
}

nftban_prereq_warn() {
    # Add a non-blocking warning (does not fail prereq check)
    # Args: <message>
    NFTBAN_PREREQ_WARNINGS+=("$1")
}

nftban_prereq_have_mta() {
    # Check if any mail transport agent is available
    # Returns: 0 if any MTA found, 1 if none
    nftban_have_cmd sendmail || nftban_have_cmd postfix || \
    nftban_have_cmd msmtp || nftban_have_cmd mailx || \
    nftban_have_cmd mail || nftban_have_cmd s-nail
}

# =============================================================================
# RESULT CHECKING & REPORTING
# =============================================================================

nftban_prereq_satisfied() {
    # Check if all prerequisites are met
    # Returns: 0 if all satisfied, 1 if any missing
    [[ ${#NFTBAN_PREREQ_MISSING[@]} -eq 0 ]]
}

nftban_prereq_report() {
    # Print standardized prereq failure report
    # Returns: 0 if no issues, 1 if missing prereqs

    # Show warnings first (non-blocking)
    if [[ ${#NFTBAN_PREREQ_WARNINGS[@]} -gt 0 ]]; then
        for warn in "${NFTBAN_PREREQ_WARNINGS[@]}"; do
            echo "  [INFO] ${warn}"
        done
    fi

    # Show missing prereqs (blocking)
    if ! nftban_prereq_satisfied; then
        echo ""
        echo "Missing prerequisites:"
        local i
        for i in "${!NFTBAN_PREREQ_MISSING[@]}"; do
            echo "  [MISSING] ${NFTBAN_PREREQ_MISSING[$i]}"
            echo "    Install: ${NFTBAN_PREREQ_HINTS[$i]}"
        done
        echo ""
        return 1
    fi

    return 0
}

nftban_prereq_report_inline() {
    # Return prereq status as a single-line string (for embedding in banners)
    # Returns: empty string if all OK, or "Missing: x, y, z"

    if nftban_prereq_satisfied; then
        return 0
    fi

    local items=""
    for missing in "${NFTBAN_PREREQ_MISSING[@]}"; do
        [[ -n "$items" ]] && items+=", "
        items+="$missing"
    done
    echo "Missing: ${items}"
    return 1
}

# =============================================================================
# INTERNAL HELPERS
# =============================================================================

_nftban_prereq_install_cmd() {
    # Resolve distro install command (internal helper)
    local cmd="install"
    if declare -F nftban_distro_get_pkgmgr_cmd >/dev/null 2>&1; then
        cmd=$(nftban_distro_get_pkgmgr_cmd "install_cmd" 2>/dev/null) || cmd="install"
    fi
    [[ -z "$cmd" ]] && cmd="install"
    echo "$cmd"
}

# =============================================================================
# FEATURE PREREQUISITE DEFINITIONS
# =============================================================================
# Centralized mapping: Feature → Required capabilities
# Commands call these instead of implementing their own checks.
# =============================================================================

nftban_prereq_check_suricata() {
    # Prerequisites for Suricata IDS feature
    nftban_prereq_init
    nftban_prereq_require_cmd "suricata" "suricata" "Suricata IDS engine" || true
    nftban_prereq_require_cmd "suricata-update" "suricata_update" "Suricata rule updater" || true
}

nftban_prereq_check_zabbix() {
    # Prerequisites for Zabbix export feature
    nftban_prereq_init
    nftban_prereq_require_any_cmd \
        "zabbix_sender ncat nc" \
        "zabbix_sender ncat ncat" \
        "Zabbix transport (zabbix_sender preferred)" || true
}

nftban_prereq_check_rbl() {
    # Prerequisites for RBL checking feature
    nftban_prereq_init
    nftban_prereq_require_any_cmd \
        "host dig nslookup" \
        "dns_utils dns_utils dns_utils" \
        "DNS lookup tool" || true
}

nftban_prereq_check_mail() {
    # Prerequisites for email notifications
    nftban_prereq_init
    if ! nftban_prereq_have_mta; then
        NFTBAN_PREREQ_MISSING+=("Mail transport agent")
        NFTBAN_PREREQ_HINTS+=("Install one: postfix, sendmail, msmtp, or mailutils")
    fi
}

nftban_prereq_check_geoban() {
    # Prerequisites for GeoBan feature
    nftban_prereq_init
    local core_bin="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core"
    nftban_prereq_require_file "$core_bin" "nftban-core binary" || true
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_have_cmd
export -f nftban_prereq_init
export -f nftban_prereq_require_cmd
export -f nftban_prereq_require_any_cmd
export -f nftban_prereq_require_file
export -f nftban_prereq_warn
export -f nftban_prereq_have_mta
export -f nftban_prereq_satisfied
export -f nftban_prereq_report
export -f nftban_prereq_report_inline
export -f nftban_prereq_check_suricata
export -f nftban_prereq_check_zabbix
export -f nftban_prereq_check_rbl
export -f nftban_prereq_check_mail
export -f nftban_prereq_check_geoban
