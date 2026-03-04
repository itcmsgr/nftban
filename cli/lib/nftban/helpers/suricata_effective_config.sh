#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="suricata_effective_config"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Generates effective Suricata config: Profile, Services, ModuleOverlaps, LocalOverrides"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_SURICATA_EFFECTIVE_CONFIG_LOADED:-}" ]] && return 0
_NFTBAN_SURICATA_EFFECTIVE_CONFIG_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_SURICATA_DIR:=${NFTBAN_CONFIG_DIR}/suricata}"
: "${NFTBAN_SURICATA_STATE_DIR:=${NFTBAN_SURICATA_DIR}/state}"
: "${SURICATA_CONFIG_DIR:=/etc/suricata}"
: "${SURICATA_RULES_DIR:=/var/lib/suricata/rules}"

# =============================================================================
# DISTRO DETECTION
# =============================================================================

_suricata_get_distro_family() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            rhel|centos|almalinux|rocky|fedora|ol)
                echo "rhel"
                ;;
            debian|ubuntu|pop|mint|linuxmint)
                echo "debian"
                ;;
            *)
                # Check ID_LIKE for derivatives
                case "${ID_LIKE:-}" in
                    *rhel*|*fedora*|*centos*)
                        echo "rhel"
                        ;;
                    *debian*|*ubuntu*)
                        echo "debian"
                        ;;
                    *)
                        echo "unknown"
                        ;;
                esac
                ;;
        esac
    else
        echo "unknown"
    fi
}

# =============================================================================
# PROFILE MANAGEMENT
# =============================================================================

# Ensure a profile is selected, auto-detect if missing
_suricata_ensure_profile_selected() {
    local profile_conf="${NFTBAN_SURICATA_DIR}/config/profile.conf"

    # If profile exists and is not "auto", use it
    if [[ -f "$profile_conf" ]]; then
        # shellcheck source=/dev/null
        source "$profile_conf"
        if [[ "${NFTBAN_SURICATA_PROFILE_MODE:-auto}" == "pinned" ]]; then
            echo "${NFTBAN_SURICATA_PROFILE:-standard}"
            return 0
        fi
        if [[ -n "${NFTBAN_SURICATA_PROFILE:-}" && "${NFTBAN_SURICATA_PROFILE}" != "auto" ]]; then
            echo "${NFTBAN_SURICATA_PROFILE}"
            return 0
        fi
    fi

    # Auto-detect based on resources
    local profile
    profile=$(_suricata_detect_optimal_profile)

    # Save it
    mkdir -p "$(dirname "$profile_conf")"
    cat > "$profile_conf" << EOF
# NFTBan Suricata Profile Configuration
# Auto-detected: $(date -Iseconds)
# Set NFTBAN_SURICATA_PROFILE_MODE="pinned" to prevent auto-detection
NFTBAN_SURICATA_PROFILE_MODE="auto"
NFTBAN_SURICATA_PROFILE="$profile"
EOF

    echo "$profile"
}

# Detect optimal profile based on system resources
_suricata_detect_optimal_profile() {
    local cpu_count mem_mb distro
    cpu_count=$(nproc 2>/dev/null || echo 2)
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)
    distro=$(_suricata_get_distro_family)

    # AlmaLinux/RHEL uses ~5x more memory per rule than Ubuntu
    # This is based on actual measurements: 37.9 MB/1000 rules (RHEL) vs 7.4 MB/1000 rules (Ubuntu)
    local mem_factor=1
    if [[ "$distro" == "rhel" ]]; then
        mem_factor=5
    fi

    # Effective memory = actual memory / overhead factor
    local effective_mem=$((mem_mb / mem_factor))

    # Decision matrix based on effective memory
    # minimal: <1500 MB effective (or <7.5GB on RHEL)
    # standard: 1500-3000 MB effective (7.5-15GB on RHEL)
    # maximum: >3000 MB effective (>15GB on RHEL)
    if [[ $cpu_count -le 2 || $effective_mem -lt 1500 ]]; then
        echo "minimal"
    elif [[ $cpu_count -le 4 && $effective_mem -lt 3000 ]]; then
        echo "standard"
    else
        echo "maximum"
    fi
}

# =============================================================================
# SERVER ROLE DETECTION
# =============================================================================

_suricata_get_server_role() {
    local cache_file="${NFTBAN_SURICATA_STATE_DIR}/role.cache"
    local cache_age=86400  # 24 hours

    mkdir -p "${NFTBAN_SURICATA_STATE_DIR}"

    # Use cache if fresh
    if [[ -f "$cache_file" ]]; then
        local file_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
        if [[ $file_age -lt $cache_age ]]; then
            cat "$cache_file"
            return 0
        fi
    fi

    # Detect role from running services
    local role="general"
    local features=""

    # Web server?
    if ss -tlnp 2>/dev/null | grep -qE ':80\s|:443\s|:8080\s|:8443\s'; then
        role="web"
        features+=",http"
    fi

    # Mail server?
    if ss -tlnp 2>/dev/null | grep -qE ':25\s|:465\s|:587\s|:993\s|:995\s|:110\s|:143\s'; then
        if [[ "$role" == "web" ]]; then
            role="hosting"  # web + mail = hosting panel
        else
            role="mail"
        fi
        features+=",mail"
    fi

    # DNS server?
    if ss -ulnp 2>/dev/null | grep -qE ':53\s'; then
        features+=",dns"
    fi

    # Database?
    if ss -tlnp 2>/dev/null | grep -qE ':3306\s|:5432\s|:27017\s|:6379\s'; then
        features+=",database"
    fi

    # FTP?
    if ss -tlnp 2>/dev/null | grep -qE ':21\s'; then
        features+=",ftp"
    fi

    # Save cache
    echo "${role}${features}" > "$cache_file"
    echo "${role}${features}"
}

# =============================================================================
# MODULE OVERLAP PREVENTION
# =============================================================================

_suricata_generate_module_overlap_disables() {
    local output="${SURICATA_CONFIG_DIR}/disable.conf.d/nftban-modules.conf"

    mkdir -p "$(dirname "$output")"

    # Load nftban module states
    local login_enabled="false"
    local login_ssh_enabled="true"
    local login_mail_enabled="true"
    local portscan_enabled="false"
    local portscan_mode="auto"
    local ddos_enabled="false"
    local ddos_mode="auto"

    # Source main config
    source "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null || true
    source "${NFTBAN_CONFIG_DIR}/nftban.conf.local" 2>/dev/null || true

    # Source module configs
    source "${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf" 2>/dev/null || true
    source "${NFTBAN_CONFIG_DIR}/conf.d/login/main.conf.local" 2>/dev/null || true
    source "${NFTBAN_CONFIG_DIR}/conf.d/portscan/main.conf" 2>/dev/null || true
    source "${NFTBAN_CONFIG_DIR}/conf.d/portscan/main.conf.local" 2>/dev/null || true
    source "${NFTBAN_CONFIG_DIR}/conf.d/ddos/main.conf" 2>/dev/null || true
    source "${NFTBAN_CONFIG_DIR}/conf.d/ddos/main.conf.local" 2>/dev/null || true

    # Map to variables
    login_enabled="${NFTBAN_LOGIN_ENABLED:-$login_enabled}"
    login_ssh_enabled="${NFTBAN_LOGIN_SSH_ENABLED:-$login_ssh_enabled}"
    login_mail_enabled="${NFTBAN_LOGIN_MAIL_ENABLED:-$login_mail_enabled}"
    portscan_enabled="${NFTBAN_PORTSCAN_ENABLED:-$portscan_enabled}"
    portscan_mode="${NFTBAN_PORTSCAN_MODE:-$portscan_mode}"
    ddos_enabled="${NFTBAN_DDOS_ENABLED:-$ddos_enabled}"
    ddos_mode="${NFTBAN_DDOS_MODE:-$ddos_mode}"

    cat > "$output" << 'EOF'
# =============================================================================
# NFTBan Module Overlap Prevention
# =============================================================================
# Auto-generated by nftban - DO NOT EDIT MANUALLY
# Disables Suricata rules for threats already handled by nftban modules
# Regenerated on every: nftban suricata rules update
# =============================================================================

EOF

    # LOGIN SSH module → disable Suricata SSH rules
    if [[ "$login_enabled" == "true" && "$login_ssh_enabled" == "true" ]]; then
        cat >> "$output" << 'EOF'
# Login SSH module enabled - nftban handles SSH brute-force detection
# Disabling overlapping Suricata SSH rules to prevent double detection
re:ssh
re:SSH
re:brute.*ssh
re:bruteforce.*ssh
# High-volume SSH SIDs that overlap with login module
2001219   # ET SCAN SSH BruteForce Tool
2019401   # ET SCAN SSH Auth Attempt
2019402   # ET SCAN SSH Auth Success
2003068   # ET SCAN Potential SSH Scan
2006546   # ET SCAN LibSSH Based SSH Connection
2024792   # ET SCAN OpenSSH Scanner

EOF
    fi

    # LOGIN MAIL module → disable Suricata mail auth rules
    if [[ "$login_enabled" == "true" && "$login_mail_enabled" == "true" ]]; then
        cat >> "$output" << 'EOF'
# Login Mail module enabled - nftban handles mail auth detection
# Disabling overlapping Suricata SASL/auth rules
re:SASL.*auth
re:dovecot.*auth
re:postfix.*auth

EOF
    fi

    # PORTSCAN in classic mode → disable Suricata scan rules
    if [[ "$portscan_enabled" == "true" && "$portscan_mode" == "classic" ]]; then
        cat >> "$output" << 'EOF'
# Portscan (classic mode) enabled - nftban handles scan detection
# Disabling overlapping Suricata scan rules
re:ET SCAN
re:nmap
re:masscan
re:zmap
re:portscan

EOF
    fi

    # DDOS in classic mode → disable Suricata flood rules
    if [[ "$ddos_enabled" == "true" && "$ddos_mode" == "classic" ]]; then
        cat >> "$output" << 'EOF'
# DDoS (classic mode) enabled - nftban handles flood detection
# Disabling overlapping Suricata flood rules
re:SYN.*flood
re:UDP.*flood
re:ICMP.*flood
re:amplification

EOF
    fi

    echo "# Generated: $(date -Iseconds)" >> "$output"
    echo "# Module states: login=$login_enabled ssh=$login_ssh_enabled mail=$login_mail_enabled" >> "$output"
    echo "# Portscan: enabled=$portscan_enabled mode=$portscan_mode" >> "$output"
    echo "# DDoS: enabled=$ddos_enabled mode=$ddos_mode" >> "$output"
}

# =============================================================================
# PROFILE-SPECIFIC DISABLES
# =============================================================================

_suricata_generate_profile_disables() {
    local profile="$1"
    local output="${SURICATA_CONFIG_DIR}/disable.conf.d/nftban-profile.conf"

    mkdir -p "$(dirname "$output")"

    cat > "$output" << EOF
# =============================================================================
# NFTBan Profile-Based Rule Disables
# =============================================================================
# Profile: $profile
# Generated: $(date -Iseconds)
# Purpose: Reduce rule count to match memory budget for profile
# =============================================================================

EOF

    case "$profile" in
        minimal)
            # Aggressive disabling for low-memory systems (2GB RAM / 2 cores)
            cat >> "$output" << 'EOF'
# MINIMAL PROFILE: Maximum rule reduction for low-memory systems
# Target: <10,000 rules, <600MB on RHEL, <150MB on Debian

# Informational/noise rules (no security value)
re:ET INFO
re:ET POLICY
re:SURICATA STREAM

# Windows-only protocols (not needed on Linux servers)
re:SMB
re:CIFS
re:NETBIOS
re:NetBIOS
re:DCE.*RPC
re:DCERPC
re:MSRPC
re:RDP
re:Remote.*Desktop
re:MS0

# Industrial/SCADA (not needed for standard servers)
re:SCADA
re:ICS
re:MODBUS
re:DNP3
re:BACnet
re:ENIP

# Chat/Gaming/P2P (not needed for servers)
re:ET GAMES
re:ET CHAT
re:IRC
re:P2P
re:BitTorrent
re:Steam

# VoIP (unless you run VoIP)
re:VOIP
re:VoIP
re:SIP
re:RTP

# Mobile-specific
re:ET MOBILE

# Classification-based disables for noise reduction
re:classtype:policy-violation
re:classtype:pup-activity
re:classtype:social-engineering
re:classtype:domain-c
re:classtype:not-suspicious
EOF
            ;;
        standard)
            # Moderate disabling for medium systems (4-8GB RAM / 4 cores)
            cat >> "$output" << 'EOF'
# STANDARD PROFILE: Balanced rule reduction
# Target: <25,000 rules, <1500MB on RHEL, <400MB on Debian

# Informational/noise rules
re:ET INFO
re:ET POLICY
re:SURICATA STREAM

# Windows protocols (unless running Samba)
re:SMB
re:CIFS
re:NETBIOS
re:DCE.*RPC
re:RDP

# Industrial/SCADA
re:SCADA
re:ICS
re:MODBUS

# Chat/Gaming/P2P
re:ET GAMES
re:ET CHAT
re:P2P

# VoIP (unless needed)
re:VOIP
re:VoIP

# Classification-based disables
re:classtype:policy-violation
re:classtype:pup-activity
EOF
            ;;
        maximum)
            # Minimal disabling for high-capacity systems (8+ cores, 16GB+ RAM)
            cat >> "$output" << 'EOF'
# MAXIMUM PROFILE: Minimal rule reduction, maximum coverage
# Target: <60,000 rules

# Only truly noisy/useless rules
re:ET INFO
re:ET GAMES
re:ET CHAT
re:P2P
EOF
            ;;
        *)
            echo "# Unknown profile: $profile - using standard defaults" >> "$output"
            ;;
    esac
}

# =============================================================================
# DEDUPE - RESTART ONLY IF CHANGED
# =============================================================================

_suricata_should_restart() {
    local state_file="${NFTBAN_SURICATA_STATE_DIR}/effective.json"
    local rules_file="${SURICATA_RULES_DIR}/suricata.rules"

    # Always restart if state file doesn't exist (first run)
    if [[ ! -f "$state_file" ]]; then
        return 0
    fi

    # Always restart if Suricata isn't running
    if ! systemctl is-active --quiet suricata 2>/dev/null; then
        return 0
    fi

    # Always restart if EVE log is stale (>60s)
    local eve_file="/var/log/suricata/eve.json"
    if [[ -f "$eve_file" ]]; then
        local eve_age=$(($(date +%s) - $(stat -c %Y "$eve_file" 2>/dev/null || echo 0)))
        if [[ $eve_age -gt 60 ]]; then
            return 0  # EVE stale, need restart
        fi
    fi

    # Check if rules file changed
    if [[ -f "$rules_file" ]]; then
        local current_hash stored_hash
        current_hash=$(sha256sum "$rules_file" 2>/dev/null | cut -d' ' -f1)
        stored_hash=$(grep -o '"rules_hash":"[^"]*"' "$state_file" 2>/dev/null | cut -d'"' -f4)

        if [[ "$current_hash" != "$stored_hash" ]]; then
            return 0  # Rules changed, need restart
        fi
    fi

    # No restart needed
    return 1
}

_suricata_record_effective_state() {
    local profile="$1"
    local role="$2"
    local state_file="${NFTBAN_SURICATA_STATE_DIR}/effective.json"
    local rules_file="${SURICATA_RULES_DIR}/suricata.rules"

    mkdir -p "${NFTBAN_SURICATA_STATE_DIR}"

    local rules_hash="" enable_hash="" disable_hash="" rule_count=0

    if [[ -f "$rules_file" ]]; then
        rules_hash=$(sha256sum "$rules_file" 2>/dev/null | cut -d' ' -f1)
        rule_count=$(grep -c "^alert\|^drop\|^reject" "$rules_file" 2>/dev/null || echo 0)
    fi

    if [[ -f "${SURICATA_CONFIG_DIR}/enable.conf" ]]; then
        enable_hash=$(sha256sum "${SURICATA_CONFIG_DIR}/enable.conf" 2>/dev/null | cut -d' ' -f1)
    fi

    if [[ -d "${SURICATA_CONFIG_DIR}/disable.conf.d" ]]; then
        disable_hash=$(cat "${SURICATA_CONFIG_DIR}/disable.conf.d"/*.conf 2>/dev/null | sha256sum | cut -d' ' -f1)
    fi

    local distro
    distro=$(_suricata_get_distro_family)

    cat > "$state_file" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "profile": "$profile",
  "role": "$role",
  "distro": "$distro",
  "rules_hash": "$rules_hash",
  "enable_hash": "$enable_hash",
  "disable_hash": "$disable_hash",
  "rule_count": $rule_count
}
EOF
}

# =============================================================================
# MAIN: GENERATE EFFECTIVE CONFIG
# =============================================================================

suricata_generate_effective_config() {
    local verbose="${1:-false}"

    # 1. Ensure profile is selected (auto-detect if missing)
    local profile
    profile=$(_suricata_ensure_profile_selected)
    [[ "$verbose" == "true" ]] && echo "  Profile: $profile"

    # 2. Get server role (cached)
    local role
    role=$(_suricata_get_server_role)
    [[ "$verbose" == "true" ]] && echo "  Role: $role"

    # 3. Generate module overlap disables
    _suricata_generate_module_overlap_disables
    [[ "$verbose" == "true" ]] && echo "  Generated: disable.conf.d/nftban-modules.conf"

    # 4. Generate profile-specific disables
    _suricata_generate_profile_disables "$profile"
    [[ "$verbose" == "true" ]] && echo "  Generated: disable.conf.d/nftban-profile.conf"

    # Return profile and role for caller
    echo "$profile:$role"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f _suricata_get_distro_family 2>/dev/null || true
export -f _suricata_ensure_profile_selected 2>/dev/null || true
export -f _suricata_detect_optimal_profile 2>/dev/null || true
export -f _suricata_get_server_role 2>/dev/null || true
export -f _suricata_generate_module_overlap_disables 2>/dev/null || true
export -f _suricata_generate_profile_disables 2>/dev/null || true
export -f _suricata_should_restart 2>/dev/null || true
export -f _suricata_record_effective_state 2>/dev/null || true
export -f suricata_generate_effective_config 2>/dev/null || true
