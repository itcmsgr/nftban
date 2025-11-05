#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Firewall Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Firewall table initialization and management
#
# meta:name=cmd_firewall
# meta:type=cli
# meta:header=Firewall CLI Command
# meta:version=0.31.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Initialize and manage nftables firewall architecture
# meta:input=Firewall subcommands
# meta:output=Table status and initialization results
#
# **Inventory & Requirements**
# meta:depends=bash,nftban-complete,nftables
#
# meta:created_date=2025-11-05
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# SSH PORT AUTO-DETECTION (v0.9.5 compatibility)
# =============================================================================

detect_ssh_port() {
    # Auto-detect SSH port from sshd_config
    # Returns: SSH port number (default: 22)
    local ssh_port=22

    if [[ -f "/etc/ssh/sshd_config" ]]; then
        # Look for uncommented Port directive
        local detected_port
        detected_port=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)

        if [[ -n "$detected_port" ]] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
            ssh_port=$detected_port
        fi
    fi

    echo "$ssh_port"
}

detect_ssh_client_ip() {
    # Auto-detect connecting SSH client IP using multiple methods
    # Returns: Client IP address or empty string

    # Method 1: SSH_CLIENT environment variable (works in interactive sessions)
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        local ip="${SSH_CLIENT%% *}"
        echo "$ip"
        return 0
    fi

    # Method 2: Parse active SSH connections from ss command
    local ssh_ip=$(ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | \
                   awk 'NR>1 {print $5}' | \
                   grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f:]+:+)+[0-9a-f]+' | \
                   grep -v '^127\.' | \
                   grep -v '^::1' | \
                   head -1)

    if [[ -n "$ssh_ip" ]]; then
        echo "$ssh_ip"
        return 0
    fi

    # Method 3: who command (shows current logins)
    local who_ip=$(who | awk '{print $NF}' | tr -d '()' | grep -v '^:' | grep -v '^0.0.0.0' | head -1)
    if [[ -n "$who_ip" ]]; then
        echo "$who_ip"
        return 0
    fi

    # Method 4: w command (shows logged in users)
    local w_ip=$(w -h | awk '{print $3}' | grep -v '^-' | grep -v '^:' | head -1)
    if [[ -n "$w_ip" ]]; then
        echo "$w_ip"
        return 0
    fi

    echo ""
}

# =============================================================================
# FIREWALL COMMAND HANDLER
# =============================================================================

nftban_cmd_firewall() {
    # Handle firewall subcommands
    # Args: $@ = firewall subcommand and arguments

    local subcmd="${1:-status}"
    shift || true

    # Check root for firewall operations
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Firewall management requires root privileges" >&2
        echo "Please run: sudo nftban firewall $subcmd" >&2
        exit 1
    fi

    case "$subcmd" in
        init)
            # Initialize complete firewall architecture
            firewall_init
            return $?
            ;;

        reload)
            # Rebuild main table from config files
            firewall_reload
            return $?
            ;;

        status)
            # Show firewall health and status
            firewall_status
            return $?
            ;;

        check)
            # Comprehensive health check
            firewall_check
            return $?
            ;;

        reset)
            # Reset to defaults (dangerous!)
            echo "⚠️  WARNING: This will reset firewall to defaults"
            echo "   All custom rules will be lost!"
            echo ""
            read -p "Type 'yes' to confirm: " confirm
            if [[ "$confirm" == "yes" ]]; then
                firewall_reset
            else
                echo "Cancelled."
                return 1
            fi
            return $?
            ;;

        help|--help|-h)
            # Show help
            firewall_help
            return 0
            ;;

        *)
            echo "ERROR: Unknown firewall command: $subcmd" >&2
            echo "Run 'nftban firewall help' for available commands" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# FIREWALL INITIALIZATION
# =============================================================================

firewall_init() {
    # Initialize complete NFTBan firewall architecture
    # Creates both runtime and main tables

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Firewall Initialization"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check for startup delay configuration (CRITICAL SAFETY FEATURE)
    local startup_delay="${NFTBAN_STARTUP_DELAY:-0}"

    # Source config file if it exists
    if [[ -f "/etc/nftban/nftban.conf" ]]; then
        source /etc/nftban/nftban.conf 2>/dev/null || true
        startup_delay="${NFTBAN_STARTUP_DELAY:-0}"
    fi

    # Check if we should delay (only during system boot, not manual init)
    if [[ "$startup_delay" -gt 0 ]] && [[ -n "${NFTBAN_SYSTEMD_BOOT:-}" ]]; then
        echo "⏱️  STARTUP DELAY: Waiting $startup_delay seconds before activating firewall"
        echo "   This gives you time to login if something goes wrong"
        echo "   (Configured via NFTBAN_STARTUP_DELAY in /etc/nftban/nftban.conf)"
        echo ""
        sleep "$startup_delay"
        echo "✓ Startup delay complete, proceeding with firewall initialization..."
        echo ""
    fi

    # Check if nftban-complete exists
    if [[ ! -x "/usr/sbin/nftban-complete" ]]; then
        echo "❌ ERROR: nftban-complete not found or not executable" >&2
        echo "   Expected: /usr/sbin/nftban-complete" >&2
        return 1
    fi

    # Step 1: Ensure nftables service is running
    echo "Step 1: Checking nftables service..."
    if systemctl is-active --quiet nftables 2>/dev/null; then
        echo "✓ nftables service is active"
    else
        echo "⚠ nftables service not active, attempting to start..."
        if systemctl start nftables 2>/dev/null; then
            echo "✓ nftables service started"
        else
            echo "⚠ Could not start nftables service (might not be needed)"
        fi
    fi
    echo ""

    # Step 2: Create runtime table (temporary bans)
    echo "Step 2: Creating runtime table (temporary bans)..."
    if nft list table inet nftban_runtime &>/dev/null; then
        echo "✓ Runtime table already exists"
    else
        if [[ -f "/usr/lib/nftban/nft-runtime.nft" ]]; then
            nft -f /usr/lib/nftban/nft-runtime.nft
            echo "✓ Runtime table created"
        else
            echo "❌ ERROR: Runtime table template not found" >&2
            echo "   Expected: /usr/lib/nftban/nft-runtime.nft" >&2
            return 1
        fi
    fi
    echo ""

    # Step 3: Create main table (permanent rules)
    echo "Step 3: Creating main table (permanent whitelist/blacklist/ports)..."
    /usr/sbin/nftban-complete nftables reload
    if [[ $? -eq 0 ]]; then
        echo "✓ Main table created successfully"
    else
        echo "❌ ERROR: Failed to create main table" >&2
        return 1
    fi
    echo ""

    # Step 4: Verify architecture
    echo "Step 4: Verifying architecture..."
    local tables_found=0
    local tables_expected=0

    # Check for nftban_runtime
    tables_expected=$((tables_expected + 1))
    if nft list table inet nftban_runtime &>/dev/null; then
        echo "✓ inet nftban_runtime"
        tables_found=$((tables_found + 1))
    else
        echo "✗ inet nftban_runtime (missing!)"
    fi

    # Check for nftban_main
    tables_expected=$((tables_expected + 1))
    if nft list table inet nftban_main &>/dev/null; then
        echo "✓ inet nftban_main"
        tables_found=$((tables_found + 1))
    else
        echo "✗ inet nftban_main (missing!)"
    fi

    echo ""

    if [[ $tables_found -eq $tables_expected ]]; then
        # Step 5: Auto-whitelist system IPs & SSH port (LOCKOUT PREVENTION)
        echo "Step 5: Auto-whitelisting system IPs & SSH port (LOCKOUT PREVENTION)..."

        # CRITICAL: Auto-detect SSH port from sshd_config
        local ssh_port
        ssh_port=$(detect_ssh_port)
        echo "→ Detected SSH port: $ssh_port (from sshd_config)"

        # CRITICAL: Write SSH port directly to config file (NOT via nftban command)
        mkdir -p /etc/nftban/ports.d
        cat > /etc/nftban/ports.d/00-ssh.conf << EOF
# SSH port auto-added during firewall init (DO NOT DELETE - LOCKOUT RISK!)
# Port format: PORT|PROTO where PROTO = T(tcp), U(udp), B(both)
$ssh_port|T
EOF
        chown nftban:nftban /etc/nftban/ports.d/00-ssh.conf 2>/dev/null || true
        chmod 644 /etc/nftban/ports.d/00-ssh.conf 2>/dev/null || true
        echo "  ✓ SSH port $ssh_port written to /etc/nftban/ports.d/00-ssh.conf"

        # CRITICAL: Collect all IPs to whitelist
        local -a ips_to_whitelist=()

        # 1. SSH client IP (current connection)
        local ssh_client_ip
        ssh_client_ip=$(detect_ssh_client_ip)
        if [[ -n "$ssh_client_ip" ]]; then
            echo "→ Detected SSH client IP: $ssh_client_ip"
            ips_to_whitelist+=("$ssh_client_ip")
        fi

        # 2. Public IPv4
        local current_ipv4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        if [[ -n "$current_ipv4" ]]; then
            echo "→ Detected public IPv4: $current_ipv4"
            # Add if not already in list
            if [[ ! " ${ips_to_whitelist[*]} " =~ " $current_ipv4 " ]]; then
                ips_to_whitelist+=("$current_ipv4")
            fi
        fi

        # 3. Public IPv6
        local current_ipv6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        if [[ -n "$current_ipv6" ]]; then
            echo "→ Detected public IPv6: $current_ipv6"
            # Add if not already in list
            if [[ ! " ${ips_to_whitelist[*]} " =~ " $current_ipv6 " ]]; then
                ips_to_whitelist+=("$current_ipv6")
            fi
        fi

        # CRITICAL: Write ALL detected IPs to whitelist config file (NOT via nftban command)
        if [[ ${#ips_to_whitelist[@]} -gt 0 ]]; then
            mkdir -p /etc/nftban/whitelist.d
            cat > /etc/nftban/whitelist.d/00-system.conf << EOF
# System IPs auto-added during firewall init (DO NOT DELETE - LOCKOUT RISK!)
# Format: One IP per line (IPv4 or IPv6)
EOF
            for ip in "${ips_to_whitelist[@]}"; do
                echo "$ip" >> /etc/nftban/whitelist.d/00-system.conf
            done
            chown nftban:nftban /etc/nftban/whitelist.d/00-system.conf 2>/dev/null || true
            chmod 644 /etc/nftban/whitelist.d/00-system.conf 2>/dev/null || true
            echo "  ✓ Whitelisted ${#ips_to_whitelist[@]} IP(s) in /etc/nftban/whitelist.d/00-system.conf"
        else
            echo "  ⚠ WARNING: Could not detect any IP addresses to whitelist"
            echo "    You should manually add your IP to /etc/nftban/whitelist.d/00-system.conf"
        fi

        # CRITICAL: Rebuild nftban_main table with new config
        echo "→ Rebuilding nftban_main table with SSH port and IPs..."
        if /usr/sbin/nftban-complete nftables reload 2>/dev/null; then
            echo "  ✓ nftban_main table rebuilt successfully"
        else
            echo "  ⚠ WARNING: Failed to rebuild table (but configs are saved)"
        fi
        echo ""

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ Firewall initialization SUCCESSFUL"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Architecture:"
        echo "  • inet nftban_runtime  - Temporary bans (Fail2ban)"
        echo "  • inet nftban_main     - Permanent whitelist/blacklist/ports"
        echo ""
        echo "Next steps:"
        echo "  • Add ports: Edit /etc/nftban/ports.d/*.conf"
        echo "  • Add whitelist: Edit /etc/nftban/whitelist.d/*.conf"
        echo "  • Add blacklist: Edit /etc/nftban/blacklist.d/*.conf"
        echo "  • Then run: nftban firewall reload"
        echo ""
        echo "Check status: nftban firewall status"
        echo "Check health: nftban firewall check"
        echo ""
        return 0
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  Firewall initialization INCOMPLETE"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Tables found: $tables_found / $tables_expected"
        echo ""
        echo "Run: nftban firewall check (for detailed diagnostics)"
        echo ""
        return 1
    fi
}

# =============================================================================
# FIREWALL RELOAD
# =============================================================================

firewall_reload() {
    # Rebuild main table from config files
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Firewall Reload"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Rebuilding main table from configuration files..."
    echo "  • /etc/nftban/whitelist.d/*.conf"
    echo "  • /etc/nftban/blacklist.d/*.conf"
    echo "  • /etc/nftban/ports.d/*.conf"
    echo ""

    /usr/sbin/nftban-complete nftables reload
    local result=$?

    echo ""
    if [[ $result -eq 0 ]]; then
        echo "✅ Firewall reloaded successfully"
        echo ""
        echo "Run: nftban firewall status (to verify)"
    else
        echo "❌ Firewall reload failed"
        echo ""
        echo "Check logs: /var/log/nftban/"
        return 1
    fi
    echo ""

    return $result
}

# =============================================================================
# FIREWALL STATUS
# =============================================================================

firewall_status() {
    # Show firewall status
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Firewall Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # nftables service
    echo "nftables Service:"
    if systemctl is-active --quiet nftables 2>/dev/null; then
        echo "  ✓ Active"
    else
        echo "  ✗ Inactive"
    fi
    echo ""

    # Tables
    echo "NFTBan Tables:"
    if nft list table inet nftban_runtime &>/dev/null; then
        echo "  ✓ inet nftban_runtime (temporary bans)"
    else
        echo "  ✗ inet nftban_runtime (missing!)"
    fi

    if nft list table inet nftban_main &>/dev/null; then
        echo "  ✓ inet nftban_main (permanent rules)"
    else
        echo "  ✗ inet nftban_main (missing!)"
    fi
    echo ""

    # Sets in runtime table
    if nft list table inet nftban_runtime &>/dev/null; then
        echo "Runtime Ban Sets:"
        local temp_v4_count=$(nft list set inet nftban_runtime temp_ban_v4 2>/dev/null | grep -c "elements" || echo 0)
        local temp_v6_count=$(nft list set inet nftban_runtime temp_ban_v6 2>/dev/null | grep -c "elements" || echo 0)

        echo "  • temp_ban_v4: $(nft list set inet nftban_runtime temp_ban_v4 2>/dev/null | grep "elements" | wc -w) IPs"
        echo "  • temp_ban_v6: $(nft list set inet nftban_runtime temp_ban_v6 2>/dev/null | grep "elements" | wc -w) IPs"
        echo ""
    fi

    # Sets in main table
    if nft list table inet nftban_main &>/dev/null; then
        echo "Main Table Sets:"
        echo "  • whitelist_v4: $(nft list set inet nftban_main whitelist_v4 2>/dev/null | grep -c "{" || echo 0) IPs"
        echo "  • whitelist_v6: $(nft list set inet nftban_main whitelist_v6 2>/dev/null | grep -c "{" || echo 0) IPs"
        echo "  • blacklist_v4: $(nft list set inet nftban_main blacklist_v4 2>/dev/null | grep -c "{" || echo 0) IPs"
        echo "  • blacklist_v6: $(nft list set inet nftban_main blacklist_v6 2>/dev/null | grep -c "{" || echo 0) IPs"
        echo "  • tcp_ports: $(nft list set inet nftban_main tcp_ports 2>/dev/null | grep -c "{" || echo 0) ports"
        echo "  • udp_ports: $(nft list set inet nftban_main udp_ports 2>/dev/null | grep -c "{" || echo 0) ports"
        echo ""
    fi

    # Chains
    echo "Chains:"
    if nft list chain inet nftban_runtime input_tempban &>/dev/null; then
        echo "  ✓ nftban_runtime.input_tempban"
    fi
    if nft list chain inet nftban_main input &>/dev/null; then
        echo "  ✓ nftban_main.input"
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "For comprehensive health check, run: nftban firewall check"
    echo ""
}

# =============================================================================
# FIREWALL HEALTH CHECK
# =============================================================================

firewall_check() {
    # Comprehensive health check
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Firewall Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local errors=0
    local warnings=0

    # Check 0: System dependencies (CRITICAL)
    echo "[0/13] Checking system dependencies..."
    local dep_missing=0

    # REQUIRED dependencies
    if command -v nft &>/dev/null; then
        echo "  ✓ nftables: $(nft --version 2>&1 | head -1)"
    else
        echo "  ✗ FAIL: nftables (nft command) NOT FOUND"
        echo "     → INSTALL: dnf install nftables (RHEL) OR apt install nftables (Debian)"
        dep_missing=$((dep_missing + 1))
        errors=$((errors + 1))
    fi

    if command -v bash &>/dev/null; then
        echo "  ✓ bash: $BASH_VERSION"
    else
        echo "  ✗ FAIL: bash NOT FOUND"
        dep_missing=$((dep_missing + 1))
        errors=$((errors + 1))
    fi

    if command -v systemctl &>/dev/null; then
        echo "  ✓ systemd: $(systemctl --version | head -1)"
    else
        echo "  ⚠ WARNING: systemd NOT FOUND (services won't work)"
        warnings=$((warnings + 1))
    fi

    if command -v curl &>/dev/null; then
        echo "  ✓ curl: $(curl --version 2>&1 | head -1 | awk '{print $1, $2}')"
    else
        echo "  ⚠ WARNING: curl NOT FOUND (IP detection won't work)"
        echo "     → INSTALL: dnf install curl (RHEL) OR apt install curl (Debian)"
        warnings=$((warnings + 1))
    fi

    if command -v ss &>/dev/null; then
        echo "  ✓ iproute (ss): available"
    else
        echo "  ⚠ WARNING: ss command NOT FOUND (SSH IP detection won't work)"
        echo "     → INSTALL: dnf install iproute (RHEL) OR apt install iproute2 (Debian)"
        warnings=$((warnings + 1))
    fi

    if command -v awk &>/dev/null; then
        echo "  ✓ awk: available"
    else
        echo "  ✗ FAIL: awk NOT FOUND (coreutils)"
        dep_missing=$((dep_missing + 1))
        errors=$((errors + 1))
    fi

    # OPTIONAL dependencies
    if command -v fail2ban-client &>/dev/null; then
        echo "  ✓ fail2ban: $(fail2ban-client version 2>&1 | head -1)"
    else
        echo "  ⓘ INFO: fail2ban not installed (optional)"
    fi

    if command -v jq &>/dev/null; then
        echo "  ✓ jq: available"
    else
        echo "  ⓘ INFO: jq not installed (optional, needed for JSON processing)"
    fi

    if command -v mail &>/dev/null || command -v mailx &>/dev/null; then
        echo "  ✓ mail: available"
    else
        echo "  ⓘ INFO: mailx not installed (optional, needed for email alerts)"
    fi

    if [[ $dep_missing -gt 0 ]]; then
        echo ""
        echo "  ❌ CRITICAL: $dep_missing required dependencies missing!"
        echo "     NFTBan CANNOT function without these dependencies"
        echo "     Install missing packages and run this check again"
    fi
    echo ""

    # Check 1: nftables service
    echo "[1/13] Checking nftables service..."
    if systemctl is-active --quiet nftables 2>/dev/null; then
        echo "  ✓ PASS: nftables service is active"
    else
        echo "  ⚠ WARN: nftables service not active"
        warnings=$((warnings + 1))
    fi
    echo ""

    # Check 2: Runtime table exists
    echo "[2/10] Checking runtime table..."
    if nft list table inet nftban_runtime &>/dev/null; then
        echo "  ✓ PASS: inet nftban_runtime exists"
    else
        echo "  ✗ FAIL: inet nftban_runtime missing"
        errors=$((errors + 1))
    fi
    echo ""

    # Check 3: Main table exists
    echo "[3/10] Checking main table..."
    if nft list table inet nftban_main &>/dev/null; then
        echo "  ✓ PASS: inet nftban_main exists"
    else
        echo "  ✗ FAIL: inet nftban_main missing"
        errors=$((errors + 1))
        echo "  → FIX: Run 'nftban firewall init'"
    fi
    echo ""

    # Check 4: Runtime chains
    echo "[4/10] Checking runtime chains..."
    if nft list chain inet nftban_runtime input_tempban &>/dev/null; then
        echo "  ✓ PASS: input_tempban chain exists"
    else
        echo "  ✗ FAIL: input_tempban chain missing"
        errors=$((errors + 1))
    fi
    echo ""

    # Check 5: Main chains
    echo "[5/10] Checking main table chains..."
    if nft list chain inet nftban_main input &>/dev/null; then
        echo "  ✓ PASS: input chain exists"
    else
        echo "  ✗ FAIL: input chain missing"
        errors=$((errors + 1))
    fi
    echo ""

    # Check 6: Runtime sets
    echo "[6/10] Checking runtime sets..."
    if nft list set inet nftban_runtime temp_ban_v4 &>/dev/null && \
       nft list set inet nftban_runtime temp_ban_v6 &>/dev/null; then
        echo "  ✓ PASS: Runtime ban sets exist"
    else
        echo "  ✗ FAIL: Runtime ban sets missing"
        errors=$((errors + 1))
    fi
    echo ""

    # Check 7: Main sets
    echo "[7/10] Checking main table sets..."
    local sets_ok=true
    for set in whitelist_v4 whitelist_v6 blacklist_v4 blacklist_v6 tcp_ports udp_ports; do
        if ! nft list set inet nftban_main "$set" &>/dev/null; then
            echo "  ✗ FAIL: Set $set missing"
            sets_ok=false
            errors=$((errors + 1))
        fi
    done
    if $sets_ok; then
        echo "  ✓ PASS: All main table sets exist"
    fi
    echo ""

    # Check 8: Priority order
    echo "[8/10] Checking chain priorities..."
    local runtime_prio=$(nft list chain inet nftban_runtime input_tempban 2>/dev/null | grep "priority" | awk '{print $5}')
    local main_prio=$(nft list chain inet nftban_main input 2>/dev/null | grep "priority" | awk '{print $5}')

    if [[ -n "$runtime_prio" && -n "$main_prio" ]]; then
        echo "  ✓ PASS: Priorities set (runtime: $runtime_prio, main: $main_prio)"
    else
        echo "  ⚠ WARN: Could not verify priorities"
        warnings=$((warnings + 1))
    fi
    echo ""

    # Check 9: Configuration directories
    echo "[9/10] Checking configuration directories..."
    local dirs_ok=true
    for dir in /etc/nftban/whitelist.d /etc/nftban/blacklist.d /etc/nftban/ports.d; do
        if [[ ! -d "$dir" ]]; then
            echo "  ⚠ WARN: $dir missing"
            dirs_ok=false
            warnings=$((warnings + 1))
        fi
    done
    if $dirs_ok; then
        echo "  ✓ PASS: All config directories exist"
    fi
    echo ""

    # Check 10: Fail2ban integration
    echo "[10/11] Checking Fail2ban integration..."
    if nft list table inet f2b-table &>/dev/null; then
        echo "  ✓ PASS: Fail2ban table exists"
    else
        echo "  ⚠ INFO: Fail2ban table not found (optional)"
    fi
    echo ""

    # Check 11: SSH Port Protection (CRITICAL FOR LOCKOUT PREVENTION)
    local ssh_port
    ssh_port=$(detect_ssh_port)
    echo "[11/12] Checking SSH port $ssh_port is whitelisted (CRITICAL)..."

    # Check if SSH port is allowed in tcp_ports set
    if nft list set inet nftban_main tcp_ports 2>/dev/null | grep -qw "$ssh_port"; then
        echo "  ✓ PASS: SSH port $ssh_port is whitelisted"
    else
        warnings=$((warnings + 1))
        echo "  ⚠️  WARNING: SSH port $ssh_port NOT whitelisted!"
        echo "     LOCKOUT RISK! Add it immediately:"
        echo "     → nftban port allow $ssh_port tcp"
    fi
    echo ""

    # Check 12: System IP protection (CRITICAL FOR SAFETY)
    echo "[12/12] Checking system IP protection (LOCKOUT PREVENTION)..."

    # Get current IPs
    local current_ipv4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
    local current_ipv6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "")

    # Check IPv4
    if [[ -n "$current_ipv4" ]]; then
        if nft list set inet nftban_main whitelist_v4 2>/dev/null | grep -q "$current_ipv4"; then
            echo "  ✓ PASS: Current IPv4 ($current_ipv4) is whitelisted"
        else
            warnings=$((warnings + 1))
            echo "  ⚠️  WARNING: Current IPv4 ($current_ipv4) NOT whitelisted!"
            echo "     LOCKOUT RISK! Add it immediately with:"
            echo "     → nftban whitelist-system add $current_ipv4"
        fi
    else
        echo "  ⚠ INFO: Could not detect current IPv4 (offline or IPv6-only network)"
    fi

    # Check IPv6
    if [[ -n "$current_ipv6" ]]; then
        if nft list set inet nftban_main whitelist_v6 2>/dev/null | grep -q "$current_ipv6"; then
            echo "  ✓ PASS: Current IPv6 ($current_ipv6) is whitelisted"
        else
            warnings=$((warnings + 1))
            echo "  ⚠️  WARNING: Current IPv6 ($current_ipv6) NOT whitelisted!"
            echo "     LOCKOUT RISK! Add it immediately with:"
            echo "     → nftban whitelist-system add $current_ipv6"
        fi
    else
        echo "  ⚠ INFO: No IPv6 address detected (IPv4-only network)"
    fi
    echo ""

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Health Check Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Errors:   $errors"
    echo "  Warnings: $warnings"
    echo ""

    if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
        echo "✅ RESULT: HEALTHY - No issues detected"
        echo ""
        return 0
    elif [[ $errors -eq 0 ]]; then
        echo "⚠️  RESULT: HEALTHY (with warnings)"
        echo ""
        return 0
    else
        echo "❌ RESULT: UNHEALTHY - $errors critical error(s) found"
        echo ""
        echo "Recommended action: nftban firewall init"
        echo ""
        return 1
    fi
}

# =============================================================================
# FIREWALL RESET
# =============================================================================

firewall_reset() {
    # Reset firewall to defaults (dangerous!)
    echo "Resetting NFTBan firewall..."
    echo ""

    # Delete main table
    nft delete table inet nftban_main 2>/dev/null || true
    echo "✓ Deleted main table"

    # Recreate
    /usr/sbin/nftban-complete nftables reload
    echo "✓ Recreated with defaults"

    echo ""
    echo "✅ Firewall reset complete"
    echo ""
}

# =============================================================================
# HELP
# =============================================================================

firewall_help() {
    echo ""
    echo "Usage: nftban firewall <command>"
    echo ""
    echo "Commands:"
    echo "  init      - Initialize complete firewall architecture"
    echo "  reload    - Rebuild main table from config files"
    echo "  status    - Show firewall status and statistics"
    echo "  check     - Run comprehensive health check"
    echo "  reset     - Reset to defaults (DANGEROUS!)"
    echo "  help      - Show this help"
    echo ""
    echo "Examples:"
    echo "  nftban firewall init       # First-time setup"
    echo "  nftban firewall status     # Check current state"
    echo "  nftban firewall check      # Full health check"
    echo "  nftban firewall reload     # After editing config files"
    echo ""
    echo "Architecture:"
    echo "  NFTBan uses a two-table design:"
    echo "    • inet nftban_runtime - Temporary bans (Fail2ban integration)"
    echo "    • inet nftban_main    - Permanent whitelist/blacklist/ports"
    echo ""
    echo "Configuration:"
    echo "  • Whitelist:  /etc/nftban/whitelist.d/*.conf"
    echo "  • Blacklist:  /etc/nftban/blacklist.d/*.conf"
    echo "  • Ports:      /etc/nftban/ports.d/*.conf"
    echo ""
    echo "After editing config files, run: nftban firewall reload"
    echo ""
}

# Export function for auto-loading
export -f nftban_cmd_firewall
