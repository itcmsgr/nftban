#!/usr/bin/env bash
# NFTBan v1.0.0
# Web GUI Management Commands
# Author: Antonios Voulvoulis (itcmsgr)
# License: MPL-2.0
# SPDX-License-Identifier: MPL-2.0
# meta:version=1.0.0
# meta:homepage=https://github.com/itcmsgr/nftban

set -Eeuo pipefail

# Configuration
NFTBAN_UI_SERVICE="nftban-ui.service"
NFTBAN_UI_CONFIG="/etc/nftban/ui.conf"
NFTBAN_UI_WHITELIST="/etc/nftban/ui-whitelist.conf"
NFTBAN_UI_CERT="/etc/nftban/ssl/cert.pem"
NFTBAN_UI_KEY="/etc/nftban/ssl/key.pem"
NFTBAN_UI_PORT="${NFTBAN_UI_PORT:-3940}"

# cmd_ui_init - Initialize Web GUI
# Creates configuration, generates TLS certificates, sets up IP whitelist
cmd_ui_init() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║            NFTBan Web GUI Initialization                           ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo "❌ Error: This command must be run as root"
        exit 1
    fi

    # Create directories
    echo "📁 Creating directories..."
    mkdir -p /etc/nftban/ssl
    mkdir -p /var/log/nftban
    chmod 750 /etc/nftban/ssl

    # Generate self-signed TLS certificate if not exists
    if [[ ! -f "$NFTBAN_UI_CERT" ]] || [[ ! -f "$NFTBAN_UI_KEY" ]]; then
        echo "🔐 Generating self-signed TLS certificate..."

        openssl req -x509 -nodes -newkey rsa:4096 \
            -keyout "$NFTBAN_UI_KEY" \
            -out "$NFTBAN_UI_CERT" \
            -days 3650 \
            -subj "/C=US/ST=State/L=City/O=NFTBan/CN=$(hostname)" \
            2>/dev/null || {
            echo "❌ Error: Failed to generate TLS certificate"
            exit 1
        }

        chmod 600 "$NFTBAN_UI_KEY"
        chmod 644 "$NFTBAN_UI_CERT"
        echo "✅ TLS certificate generated"
    else
        echo "ℹ️  TLS certificate already exists"
    fi

    # Generate JWT secret
    JWT_SECRET=$(openssl rand -base64 32)

    # Create configuration file
    if [[ ! -f "$NFTBAN_UI_CONFIG" ]]; then
        echo "📝 Creating configuration file..."

        cat > "$NFTBAN_UI_CONFIG" << EOF
# NFTBan Web GUI Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')

# Server Settings
PORT=$NFTBAN_UI_PORT
TLS_CERT=$NFTBAN_UI_CERT
TLS_KEY=$NFTBAN_UI_KEY

# Security Settings
JWT_SECRET=$JWT_SECRET
SESSION_TIMEOUT=60
BLOCK_ROOT_LOGIN=true

# Authentication
REQUIRED_GROUP=nftban-web

# Access Control
IP_WHITELIST_FILE=$NFTBAN_UI_WHITELIST

# Audit Logging
AUDIT_LOG_FILE=/var/log/nftban/ui-access.log

# Rate Limiting
MAX_LOGIN_ATTEMPTS=5
LOCKOUT_DURATION=15

# Resource Limits (from safety package pattern)
NFTBAN_GOMAXPROCS=2
NFTBAN_MAX_CONCURRENT_CONNS=100
NFTBAN_REQUEST_TIMEOUT_SEC=30
NFTBAN_MAX_REQUEST_BODY_MB=10
EOF

        chmod 640 "$NFTBAN_UI_CONFIG"
        echo "✅ Configuration created at $NFTBAN_UI_CONFIG"
    else
        echo "ℹ️  Configuration already exists"
    fi

    # Create nftban-web group if not exists
    if ! getent group nftban-web >/dev/null 2>&1; then
        echo "👥 Creating nftban-web group..."
        groupadd -r nftban-web
        echo "✅ Group created"
    else
        echo "ℹ️  nftban-web group already exists"
    fi

    # Initialize IP whitelist
    cmd_ui_init_whitelist

    echo ""
    echo "✅ Web GUI initialization complete!"
    echo ""
    echo "📋 Next steps:"
    echo "   1. Add users to nftban-web group: usermod -aG nftban-web <username>"
    echo "   2. Start the GUI server: nftban ui start"
    echo "   3. Access GUI at: https://$(hostname -I | awk '{print $1}'):$NFTBAN_UI_PORT"
    echo ""
}

# cmd_ui_init_whitelist - Initialize IP whitelist with current SSH client IP
cmd_ui_init_whitelist() {
    echo "🔒 Initializing IP whitelist..."

    # Get current SSH client IP
    local current_ip=""
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        current_ip=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [[ -n "${SSH_CONNECTION:-}" ]]; then
        current_ip=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi

    # Create whitelist file
    if [[ ! -f "$NFTBAN_UI_WHITELIST" ]]; then
        cat > "$NFTBAN_UI_WHITELIST" << EOF
# NFTBan Web GUI IP Whitelist
# Only IPs listed here can access the web interface
# Format: One IP or CIDR per line
# Example: 192.168.1.100
# Example: 10.0.0.0/8

# Localhost
127.0.0.1
::1

EOF

        # Add current SSH client IP if detected
        if [[ -n "$current_ip" ]]; then
            echo "# Current SSH client IP (auto-detected)" >> "$NFTBAN_UI_WHITELIST"
            echo "$current_ip" >> "$NFTBAN_UI_WHITELIST"
            echo "✅ Added current SSH client IP to whitelist: $current_ip"
        fi

        chmod 640 "$NFTBAN_UI_WHITELIST"
        echo "✅ Whitelist created at $NFTBAN_UI_WHITELIST"
    else
        echo "ℹ️  Whitelist already exists"
    fi
}

# cmd_ui_add_ip - Add IP to GUI whitelist
cmd_ui_add_ip() {
    local ip="${1:-}"

    if [[ -z "$ip" ]]; then
        echo "❌ Error: IP address required"
        echo "Usage: nftban ui add-ip <IP>"
        exit 1
    fi

    # Validate IP format
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] && ! [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}(/[0-9]+)?$ ]]; then
        echo "❌ Error: Invalid IP address format: $ip"
        exit 1
    fi

    # Check if IP already exists
    if grep -qx "$ip" "$NFTBAN_UI_WHITELIST" 2>/dev/null; then
        echo "ℹ️  IP already whitelisted: $ip"
        return 0
    fi

    # Add IP to whitelist
    echo "$ip" >> "$NFTBAN_UI_WHITELIST"
    echo "✅ IP added to whitelist: $ip"

    # Reload service if running
    if systemctl is-active --quiet "$NFTBAN_UI_SERVICE"; then
        echo "🔄 Reloading web GUI service..."
        systemctl reload "$NFTBAN_UI_SERVICE" || {
            echo "⚠️  Warning: Failed to reload service (changes take effect on restart)"
        }
    fi
}

# cmd_ui_remove_ip - Remove IP from GUI whitelist
cmd_ui_remove_ip() {
    local ip="${1:-}"

    if [[ -z "$ip" ]]; then
        echo "❌ Error: IP address required"
        echo "Usage: nftban ui remove-ip <IP>"
        exit 1
    fi

    # Check if IP exists in whitelist
    if ! grep -qx "$ip" "$NFTBAN_UI_WHITELIST" 2>/dev/null; then
        echo "ℹ️  IP not found in whitelist: $ip"
        return 0
    fi

    # Remove IP from whitelist
    local temp_file
    temp_file=$(mktemp)
    grep -vx "$ip" "$NFTBAN_UI_WHITELIST" > "$temp_file" || true
    mv "$temp_file" "$NFTBAN_UI_WHITELIST"

    echo "✅ IP removed from whitelist: $ip"

    # Reload service if running
    if systemctl is-active --quiet "$NFTBAN_UI_SERVICE"; then
        echo "🔄 Reloading web GUI service..."
        systemctl reload "$NFTBAN_UI_SERVICE" || {
            echo "⚠️  Warning: Failed to reload service (changes take effect on restart)"
        }
    fi
}

# cmd_ui_list_ips - List whitelisted IPs
cmd_ui_list_ips() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║             NFTBan Web GUI IP Whitelist                            ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    if [[ ! -f "$NFTBAN_UI_WHITELIST" ]]; then
        echo "❌ Whitelist file not found: $NFTBAN_UI_WHITELIST"
        echo "Run: nftban ui init"
        exit 1
    fi

    local count=0
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        ((count++)) || true
        echo "  $count. $line"
    done < "$NFTBAN_UI_WHITELIST"

    if [[ $count -eq 0 ]]; then
        echo "  (empty)"
    fi

    echo ""
}

# cmd_ui_start - Start Web GUI service
cmd_ui_start() {
    echo "🚀 Starting NFTBan Web GUI..."

    if ! systemctl is-enabled --quiet "$NFTBAN_UI_SERVICE" 2>/dev/null; then
        echo "📌 Enabling service..."
        systemctl enable "$NFTBAN_UI_SERVICE" || {
            echo "❌ Error: Failed to enable service"
            exit 1
        }
    fi

    systemctl start "$NFTBAN_UI_SERVICE" || {
        echo "❌ Error: Failed to start service"
        echo "Check logs: journalctl -xeu $NFTBAN_UI_SERVICE"
        exit 1
    }

    sleep 2

    if systemctl is-active --quiet "$NFTBAN_UI_SERVICE"; then
        echo "✅ Web GUI started successfully"
        cmd_ui_status
    else
        echo "❌ Service failed to start"
        echo "Check logs: journalctl -xeu $NFTBAN_UI_SERVICE"
        exit 1
    fi
}

# cmd_ui_stop - Stop Web GUI service
cmd_ui_stop() {
    echo "🛑 Stopping NFTBan Web GUI..."

    systemctl stop "$NFTBAN_UI_SERVICE" || {
        echo "❌ Error: Failed to stop service"
        exit 1
    }

    echo "✅ Web GUI stopped"
}

# cmd_ui_restart - Restart Web GUI service
cmd_ui_restart() {
    echo "🔄 Restarting NFTBan Web GUI..."

    systemctl restart "$NFTBAN_UI_SERVICE" || {
        echo "❌ Error: Failed to restart service"
        echo "Check logs: journalctl -xeu $NFTBAN_UI_SERVICE"
        exit 1
    }

    sleep 2

    if systemctl is-active --quiet "$NFTBAN_UI_SERVICE"; then
        echo "✅ Web GUI restarted successfully"
        cmd_ui_status
    else
        echo "❌ Service failed to restart"
        exit 1
    fi
}

# cmd_ui_status - Show Web GUI service status
cmd_ui_status() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║             NFTBan Web GUI Status                                  ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Service status
    if systemctl is-active --quiet "$NFTBAN_UI_SERVICE"; then
        echo "Service Status:  ✅ Running"
    else
        echo "Service Status:  ❌ Stopped"
    fi

    # Enabled status
    if systemctl is-enabled --quiet "$NFTBAN_UI_SERVICE" 2>/dev/null; then
        echo "Auto-start:      ✅ Enabled"
    else
        echo "Auto-start:      ❌ Disabled"
    fi

    # Configuration
    if [[ -f "$NFTBAN_UI_CONFIG" ]]; then
        local port
        port=$(grep -E "^PORT=" "$NFTBAN_UI_CONFIG" | cut -d= -f2 || echo "$NFTBAN_UI_PORT")
        echo "Port:            $port"
    else
        echo "Port:            $NFTBAN_UI_PORT (default)"
    fi

    # Server IP
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    echo "Server IP:       $server_ip"
    echo "Access URL:      https://$server_ip:${port:-$NFTBAN_UI_PORT}"

    # Whitelist count
    if [[ -f "$NFTBAN_UI_WHITELIST" ]]; then
        local whitelist_count
        whitelist_count=$(grep -cvE "^[[:space:]]*(#|$)" "$NFTBAN_UI_WHITELIST" || echo "0")
        echo "Whitelisted IPs: $whitelist_count"
    fi

    # Recent logs
    echo ""
    echo "Recent Logs:"
    echo "────────────────────────────────────────────────────────────────────"
    journalctl -u "$NFTBAN_UI_SERVICE" -n 5 --no-pager 2>/dev/null || echo "  (no logs available)"
    echo ""
}

# cmd_ui_test - Test Web GUI connectivity
cmd_ui_test() {
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║             NFTBan Web GUI Connection Test                         ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Get configuration
    local port
    port=$(grep -E "^PORT=" "$NFTBAN_UI_CONFIG" 2>/dev/null | cut -d= -f2 || echo "$NFTBAN_UI_PORT")

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    local url="https://$server_ip:$port"

    echo "Testing connection to: $url"
    echo ""

    # Test 1: Service running
    echo "1. Checking service status..."
    if systemctl is-active --quiet "$NFTBAN_UI_SERVICE"; then
        echo "   ✅ Service is running"
    else
        echo "   ❌ Service is not running"
        echo "   Run: nftban ui start"
        return 1
    fi

    # Test 2: Port listening
    echo "2. Checking port $port..."
    if ss -tlnp | grep -q ":$port " 2>/dev/null; then
        echo "   ✅ Port $port is listening"
    else
        echo "   ❌ Port $port is not listening"
        return 1
    fi

    # Test 3: TLS certificate
    echo "3. Checking TLS certificate..."
    if [[ -f "$NFTBAN_UI_CERT" ]] && [[ -f "$NFTBAN_UI_KEY" ]]; then
        echo "   ✅ TLS certificate exists"
    else
        echo "   ❌ TLS certificate missing"
        echo "   Run: nftban ui init"
        return 1
    fi

    # Test 4: HTTP connectivity
    echo "4. Testing HTTPS connection..."
    if curl -k -s -o /dev/null -w "%{http_code}" "https://127.0.0.1:$port" --max-time 5 >/dev/null 2>&1; then
        echo "   ✅ HTTPS server responding"
    else
        echo "   ⚠️  HTTPS server not responding (may be IP whitelist blocked)"
    fi

    echo ""
    echo "✅ Connection test complete"
    echo ""
    echo "📋 Access Information:"
    echo "   URL:  $url"
    echo "   Note: You must add your IP to whitelist: nftban ui add-ip <your_ip>"
    echo ""
}

# Main command router
cmd_ui() {
    local subcommand="${1:-}"

    case "$subcommand" in
        init)
            shift
            cmd_ui_init "$@"
            ;;
        start)
            shift
            cmd_ui_start "$@"
            ;;
        stop)
            shift
            cmd_ui_stop "$@"
            ;;
        restart)
            shift
            cmd_ui_restart "$@"
            ;;
        status)
            shift
            cmd_ui_status "$@"
            ;;
        init-whitelist)
            shift
            cmd_ui_init_whitelist "$@"
            ;;
        add-ip)
            shift
            cmd_ui_add_ip "$@"
            ;;
        remove-ip)
            shift
            cmd_ui_remove_ip "$@"
            ;;
        list-ips)
            shift
            cmd_ui_list_ips "$@"
            ;;
        test)
            shift
            cmd_ui_test "$@"
            ;;
        "")
            echo "Usage: nftban ui <command> [options]"
            echo ""
            echo "Commands:"
            echo "  init               Initialize Web GUI (config, certs, whitelist)"
            echo "  start              Start Web GUI service"
            echo "  stop               Stop Web GUI service"
            echo "  restart            Restart Web GUI service"
            echo "  status             Show Web GUI status"
            echo "  init-whitelist     Initialize IP whitelist"
            echo "  add-ip <IP>        Add IP to whitelist"
            echo "  remove-ip <IP>     Remove IP from whitelist"
            echo "  list-ips           List whitelisted IPs"
            echo "  test               Test Web GUI connectivity"
            echo ""
            echo "Examples:"
            echo "  nftban ui init"
            echo "  nftban ui add-ip 192.168.1.100"
            echo "  nftban ui start"
            echo "  nftban ui status"
            echo ""
            ;;
        *)
            echo "Error: Unknown subcommand: $subcommand"
            echo "Run: nftban ui (without arguments) for usage"
            exit 1
            ;;
    esac
}

# Export function if sourced, or execute if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd_ui "$@"
fi
