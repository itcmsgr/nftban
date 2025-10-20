#!/usr/bin/env bash

# =============================================================================
# NFTBan Synchronization Module
# Version: 0.9.0
# Location: lib/nftban_sync_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Ensures file-based IP lists and nftables sets stay synchronized
# =============================================================================

set -euo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_SYNC_LOADED:-}" ]] && return 0
readonly NFTBAN_SYNC_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
readonly NFTBAN_SYNC_LOG="${NFTBAN_LOG_DIR}/sync.log"
readonly NFTBAN_SYNC_REPORT="${NFTBAN_DATA_DIR}/sync-report.txt"

# =============================================================================
# LOGGING
# =============================================================================
_nftban_sync_log() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$(dirname "$NFTBAN_SYNC_LOG")"
    echo "[$ts] [$level] $msg" | tee -a "$NFTBAN_SYNC_LOG"

    if command -v nftban_log_${level,,} >/dev/null 2>&1; then
        nftban_log_${level,,} "SYNC: $msg"
    fi
}

# =============================================================================
# DRIFT DETECTION
# =============================================================================

# Check if whitelist files and nftables sets are synchronized
nftban_sync_check_whitelist_drift() {
    local drift_found=false
    local file_ips_v4=0
    local file_ips_v6=0
    local nft_ips_v4=0
    local nft_ips_v6=0

    # Count IPs in files
    local whitelist_files=(
        "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
        "${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
        "${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"
    )

    for file in "${whitelist_files[@]}"; do
        [[ ! -f "$file" ]] && continue

        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue

            local ip
            ip=$(echo "$line" | awk '{print $1}')
            [[ -z "$ip" ]] && continue

            local ver
            ver=$(nftban_detect_ip_version "$ip")

            if [[ "$ver" == "4" ]]; then
                ((file_ips_v4++))
            elif [[ "$ver" == "6" ]]; then
                ((file_ips_v6++))
            fi
        done < "$file"
    done

    # Count IPs in nftables
    if nftban_check_nftables_table; then
        nft_ips_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" whitelist 2>/dev/null | \
                     grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | wc -l)
        nft_ips_v6=$(nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" whitelist 2>/dev/null | \
                     grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l)
    fi

    # Compare counts
    if [[ $file_ips_v4 -ne $nft_ips_v4 ]] || [[ $file_ips_v6 -ne $nft_ips_v6 ]]; then
        drift_found=true
    fi

    # Output result
    echo "WHITELIST|$file_ips_v4|$nft_ips_v4|$file_ips_v6|$nft_ips_v6|$drift_found"
}

# Check if blacklist files and nftables sets are synchronized
nftban_sync_check_blacklist_drift() {
    local drift_found=false
    local file_ips_v4=0
    local file_ips_v6=0
    local nft_ips_v4=0
    local nft_ips_v6=0

    # Count IPs in files
    local blacklist_files=(
        "${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf"
        "${NFTBAN_CONFIG_DIR}/blacklist-user.conf"
    )

    for file in "${blacklist_files[@]}"; do
        [[ ! -f "$file" ]] && continue

        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue

            local ip
            ip=$(echo "$line" | awk '{print $1}')
            [[ -z "$ip" ]] && continue

            local ver
            ver=$(nftban_detect_ip_version "$ip")

            if [[ "$ver" == "4" ]]; then
                ((file_ips_v4++))
            elif [[ "$ver" == "6" ]]; then
                ((file_ips_v6++))
            fi
        done < "$file"
    done

    # Count IPs in nftables
    if nftban_check_nftables_table; then
        nft_ips_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" user_blacklist 2>/dev/null | \
                     grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | wc -l)
        nft_ips_v6=$(nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" user_blacklist 2>/dev/null | \
                     grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l)
    fi

    # Compare counts
    if [[ $file_ips_v4 -ne $nft_ips_v4 ]] || [[ $file_ips_v6 -ne $nft_ips_v6 ]]; then
        drift_found=true
    fi

    # Output result
    echo "BLACKLIST|$file_ips_v4|$nft_ips_v4|$file_ips_v6|$nft_ips_v6|$drift_found"
}

# =============================================================================
# COMPREHENSIVE SYNC VERIFICATION
# =============================================================================

nftban_sync_verify() {
    local issues=0

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  File/nftables Synchronization Status"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    # Check whitelist sync
    echo "Checking whitelist sync..."
    local wl_result
    wl_result=$(nftban_sync_check_whitelist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$wl_result"

    printf "  Files:    IPv4: %3d  IPv6: %3d\n" "$file_v4" "$file_v6"
    printf "  nftables: IPv4: %3d  IPv6: %3d\n" "$nft_v4" "$nft_v6"

    if [[ "$drift" == "true" ]]; then
        echo -e "  ${NFTBAN_RED}✗ OUT OF SYNC${NFTBAN_NC}"
        ((issues++))
    else
        echo -e "  ${NFTBAN_GREEN}✓ SYNCHRONIZED${NFTBAN_NC}"
    fi
    echo ""

    # Check blacklist sync
    echo "Checking blacklist sync..."
    local bl_result
    bl_result=$(nftban_sync_check_blacklist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$bl_result"

    printf "  Files:    IPv4: %3d  IPv6: %3d\n" "$file_v4" "$file_v6"
    printf "  nftables: IPv4: %3d  IPv6: %3d\n" "$nft_v4" "$nft_v6"

    if [[ "$drift" == "true" ]]; then
        echo -e "  ${NFTBAN_RED}✗ OUT OF SYNC${NFTBAN_NC}"
        ((issues++))
    else
        echo -e "  ${NFTBAN_GREEN}✓ SYNCHRONIZED${NFTBAN_NC}"
    fi
    echo ""

    # Check nftables sets exist
    echo "Checking nftables sets..."
    local sets_ok=true
    local required_sets=(
        "whitelist"
        "temp_ban"
        "user_blacklist"
        "system_blacklist"
        "feeds"
    )

    for set_name in "${required_sets[@]}"; do
        if ! nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "$set_name" &>/dev/null; then
            echo -e "  ${NFTBAN_RED}✗ Missing IPv4 set: $set_name${NFTBAN_NC}"
            sets_ok=false
            ((issues++))
        fi

        if ! nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "$set_name" &>/dev/null; then
            echo -e "  ${NFTBAN_RED}✗ Missing IPv6 set: $set_name${NFTBAN_NC}"
            sets_ok=false
            ((issues++))
        fi
    done

    if [[ "$sets_ok" == "true" ]]; then
        echo -e "  ${NFTBAN_GREEN}✓ ALL SETS PRESENT${NFTBAN_NC}"
    fi
    echo ""

    # Summary
    if [[ $issues -eq 0 ]]; then
        echo -e "${NFTBAN_GREEN}✓ ALL CHECKS PASSED - SYSTEM SYNCHRONIZED${NFTBAN_NC}"
        return 0
    else
        echo -e "${NFTBAN_RED}$issues issue(s) found${NFTBAN_NC}"
        echo "Run: sudo nftban sync repair"
        return 1
    fi
}

# =============================================================================
# AUTOMATIC REPAIR
# =============================================================================

nftban_sync_repair() {
    _nftban_sync_log INFO "Starting synchronization repair..."

    local repaired=0
    local failed=0

    # Verify whitelist sync
    local wl_result
    wl_result=$(nftban_sync_check_whitelist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$wl_result"

    if [[ "$drift" == "true" ]]; then
        _nftban_sync_log WARN "Whitelist out of sync (files: ${file_v4}v4/${file_v6}v6, nft: ${nft_v4}v4/${nft_v6}v6)"

        if nftban_whitelist_sync_to_nftables; then
            _nftban_sync_log SUCCESS "Repaired whitelist synchronization"
            ((repaired++))
        else
            _nftban_sync_log ERROR "Failed to repair whitelist"
            ((failed++))
        fi
    else
        _nftban_sync_log INFO "Whitelist already synchronized"
    fi

    # Verify blacklist sync
    local bl_result
    bl_result=$(nftban_sync_check_blacklist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$bl_result"

    if [[ "$drift" == "true" ]]; then
        _nftban_sync_log WARN "Blacklist out of sync (files: ${file_v4}v4/${file_v6}v6, nft: ${nft_v4}v4/${nft_v6}v6)"

        if nftban_blacklist_sync_to_nftables; then
            _nftban_sync_log SUCCESS "Repaired blacklist synchronization"
            ((repaired++))
        else
            _nftban_sync_log ERROR "Failed to repair blacklist"
            ((failed++))
        fi
    else
        _nftban_sync_log INFO "Blacklist already synchronized"
    fi

    # Rebuild search index after repairs
    if [[ $repaired -gt 0 ]] && declare -f nftban_search_build_index &>/dev/null; then
        _nftban_sync_log INFO "Rebuilding search index..."
        nftban_search_build_index
    fi

    # Summary
    echo ""
    if [[ $failed -eq 0 ]]; then
        echo -e "${NFTBAN_GREEN}✓ Repair complete: $repaired item(s) synchronized${NFTBAN_NC}"
        return 0
    else
        echo -e "${NFTBAN_RED}✗ Repair incomplete: $failed failure(s), $repaired success(es)${NFTBAN_NC}"
        return 1
    fi
}

# =============================================================================
# AUTOMATIC SYNC (Called after file modifications)
# =============================================================================

nftban_sync_auto() {
    local sync_type="${1:-all}"  # whitelist, blacklist, or all

    case "$sync_type" in
        whitelist)
            _nftban_sync_log DEBUG "Auto-sync: whitelist"
            nftban_whitelist_sync_to_nftables
            ;;
        blacklist)
            _nftban_sync_log DEBUG "Auto-sync: blacklist"
            nftban_blacklist_sync_to_nftables
            ;;
        all)
            _nftban_sync_log DEBUG "Auto-sync: all lists"
            nftban_whitelist_sync_to_nftables
            nftban_blacklist_sync_to_nftables
            ;;
        *)
            _nftban_sync_log ERROR "Invalid sync type: $sync_type"
            return 1
            ;;
    esac
}

# =============================================================================
# HEALTH CHECK
# =============================================================================

nftban_sync_health() {
    local health_score=100
    local issues=()

    # Check if nftables tables exist
    if ! nft list table "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" &>/dev/null; then
        health_score=$((health_score - 30))
        issues+=("IPv4 table missing")
    fi

    if ! nft list table "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" &>/dev/null; then
        health_score=$((health_score - 30))
        issues+=("IPv6 table missing")
    fi

    # Check synchronization
    local wl_result
    wl_result=$(nftban_sync_check_whitelist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$wl_result"

    if [[ "$drift" == "true" ]]; then
        health_score=$((health_score - 20))
        issues+=("Whitelist out of sync")
    fi

    local bl_result
    bl_result=$(nftban_sync_check_blacklist_drift)
    IFS='|' read -r name file_v4 nft_v4 file_v6 nft_v6 drift <<< "$bl_result"

    if [[ "$drift" == "true" ]]; then
        health_score=$((health_score - 20))
        issues+=("Blacklist out of sync")
    fi

    # Output health report
    echo "HEALTH_SCORE=$health_score"

    if [[ ${#issues[@]} -gt 0 ]]; then
        echo "ISSUES=${issues[*]}"
        return 1
    fi

    return 0
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_sync_check_whitelist_drift
export -f nftban_sync_check_blacklist_drift
export -f nftban_sync_verify
export -f nftban_sync_repair
export -f nftban_sync_auto
export -f nftban_sync_health

_nftban_sync_log DEBUG "NFTBan Sync Module loaded (v1.0.0)"
