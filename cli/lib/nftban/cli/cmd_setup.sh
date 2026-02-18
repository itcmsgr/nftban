#!/usr/bin/env bash
# =============================================================================

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi
# NFTBan v1.0.0 - Setup Wizard CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Interactive setup wizard for first-time installation
#
# meta:name="cmd_setup"
# meta:type="cli"
# meta:header="Setup Wizard CLI Handler"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Interactive setup wizard for first-time installation"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-06"
# meta:updated_date="2025-11-24"
# =============================================================================


# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_SETUP_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_SETUP_LOADED=1

# =============================================================================

# MAIN CLI HANDLER
# =============================================================================


nftban_cmd_setup() {
    # Interactive setup wizard for first-time installation
    # Args: [--auto] for non-interactive mode

    # CLI-004 fix: Handle --help before interactive mode
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
        echo "Usage: nftban setup [--auto]"
        echo ""
        echo "Interactive setup wizard for first-time NFTBan installation."
        echo ""
        echo "Options:"
        echo "  --auto    Non-interactive mode (auto-fix everything)"
        echo "  --help    Show this help message"
        echo ""
        echo "The wizard will:"
        echo "  1. Fix all permissions"
        echo "  2. Create missing directories"
        echo "  3. Run health check"
        echo "  4. Enable NFTBan services (optional)"
        return 0
    fi

    local AUTO_MODE=false
    if [[ "${1:-}" == "--auto" ]]; then
        AUTO_MODE=true
    fi

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚀 NFTBan First-Time Setup Wizard"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This wizard will:"
    echo "  ✓ Fix all permissions"
    echo "  ✓ Create missing directories"
    echo "  ✓ Verify system configuration"
    echo "  ✓ Enable NFTBan (optional)"
    echo ""

    if [[ "$AUTO_MODE" == false ]]; then
        read -p "Continue? (y/n) [y]: " CONTINUE
        CONTINUE=${CONTINUE:-y}
        if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
            echo "Setup cancelled."
            return 0
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 1/4: Fixing Permissions"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if nftban permissions enforce; then
        echo "  ✅ Permissions fixed"
    else
        echo "  ⚠️  Permission fix had warnings (may be OK)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 2/4: Creating Missing Directories"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if nftban health check --auto-heal >/dev/null 2>&1; then
        echo "  ✅ All directories created"
    else
        echo "  ⚠️  Auto-heal completed with warnings"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 3/4: Running Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Run health check and capture output
    HEALTH_OUTPUT=$(nftban health check 2>&1 || true)

    # Check if only optional stuff is missing (GeoIP, mail, modules)
    # These are NOT critical - firewall works without them
    HAS_GEOIP_WARNING=$(echo "$HEALTH_OUTPUT" | grep -c "GeoIP" || true)
    HAS_MAIL_WARNING=$(echo "$HEALTH_OUTPUT" | grep -c "mail\|sendmail" || true)
    HAS_MODULE_WARNING=$(echo "$HEALTH_OUTPUT" | grep -c "disabled" || true)
    HAS_CRITICAL_ERROR=$(echo "$HEALTH_OUTPUT" | grep -E "Services.*ERROR|Config.*ERROR|Binaries.*ERROR" || true)

    # If only optional warnings, treat as OK
    if echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*OK"; then
        echo "  ✅ System health: PERFECT!"
        HEALTH_OK=true
    elif echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*WARNING"; then
        echo "  ✅ System health: READY! (optional features not installed)"
        HEALTH_OK=true
    elif [[ -z "$HAS_CRITICAL_ERROR" ]] && [[ $HAS_GEOIP_WARNING -gt 0 || $HAS_MAIL_WARNING -gt 0 ]]; then
        # Only optional stuff missing - this is OK!
        echo "  ✅ System health: READY!"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "✅ Good news! Your firewall is READY and WORKING!"
        echo ""
        echo "Everything important is installed:"
        echo "  ✅ Firewall protection: Working"
        echo "  ✅ SSH port protected: Yes"
        echo "  ✅ Core security: Active"
        echo ""
        echo "Some optional extras are not installed (don't worry about these):"
        [[ $HAS_GEOIP_WARNING -gt 0 ]] && echo "  ⊘ Country lookup tool (optional - you can add later)"
        [[ $HAS_MAIL_WARNING -gt 0 ]] && echo "  ⊘ Email alerts (optional - you can add later)"
        [[ $HAS_MODULE_WARNING -gt 0 ]] && echo "  ⊘ Extra features (optional - you can add later)"
        echo ""
        echo "👉 Your server is PROTECTED right now!"
        echo "👉 You don't need to install anything else!"
        echo ""
        HEALTH_OK=true
    else
        echo "  ⚠️  Found some small issues (don't worry, we can fix them!)"
        echo ""

        # Show what the issues are
        if echo "$HEALTH_OUTPUT" | grep -q "FHS:"; then
            echo "Issues found:"
            echo "$HEALTH_OUTPUT" | grep -E "❌|⚠️" | head -5
            echo ""
        fi

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "OK my friend, what do you want to do?"
        echo ""
        echo "  A) Auto-fix everything now (recommended - takes 10 seconds)"
        echo "  B) Continue anyway (skip the optional stuff)"
        echo "  C) Show me details"
        echo ""

        if [[ "$AUTO_MODE" == true ]]; then
            CHOICE="A"
            echo "Auto mode: Choosing A (auto-fix)"
        else
            read -p "Choose A, B, or C [A]: " CHOICE
            CHOICE=${CHOICE:-A}
        fi

        case "$CHOICE" in
            A|a)
                echo ""
                echo "Great! Auto-fixing issues..."
                nftban health check --auto-heal >/dev/null 2>&1 || true
                echo "  ✅ Auto-fix complete!"
                HEALTH_OK=true
                ;;
            C|c)
                echo ""
                echo "Here are the details:"
                echo ""
                echo "$HEALTH_OUTPUT"
                echo ""
                read -p "Press ENTER to continue setup..."
                HEALTH_OK=true
                ;;
            B|b|*)
                echo ""
                echo "  ⊘ OK, continuing anyway..."
                HEALTH_OK=true
                ;;
        esac
    fi

    # Always show "what to do next" after health check
    if [[ "$HEALTH_OK" == true ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "✅ Good news! Your system is ready!"
        echo ""
        echo "What to do next:"
        echo "  👉 Continue to Step 4 to ENABLE your firewall"
        echo "  👉 Then you're PROTECTED! That's it!"
        echo ""
        if [[ "$AUTO_MODE" == false ]]; then
            read -p "Press ENTER to continue to Step 4..."
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Step 4/4: Enable NFTBan Firewall"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$AUTO_MODE" == true ]]; then
        ENABLE_NOW="n"
    else
        echo "Enable NFTBan firewall now?"
        echo ""
        echo "  • yes - Enable and start firewall (recommended for new servers)"
        echo "  • no  - Skip for now (configure manually later)"
        echo ""
        read -p "Enable now? (y/n) [n]: " ENABLE_NOW
        ENABLE_NOW=${ENABLE_NOW:-n}
    fi

    if [[ "$ENABLE_NOW" == "y" || "$ENABLE_NOW" == "Y" ]]; then
        echo ""
        if nftban enable; then
            echo ""
            echo "  ✅ NFTBan enabled and running!"
        else
            echo ""
            echo "  ⚠️  Enable had issues - check output above"
        fi
    else
        echo "  ⊘ Skipped (you can enable later with: nftban enable)"
    fi

    # =============================================================================
    # Summary
    # =============================================================================
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 Setup Complete!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$ENABLE_NOW" == "y" || "$ENABLE_NOW" == "Y" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "✅ SUCCESS! Your server is now PROTECTED!"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "What we're protecting you from:"
        echo "  🛡️  SSH brute force attacks (bad login attempts blocked)"
        echo "  🛡️  Port scanning attacks (hackers scanning your server)"
        echo "  🛡️  Known bad IPs (threat intelligence feeds)"
        echo "  🛡️  Unauthorized access attempts"
        echo ""
        echo "What I protected for you automatically:"
        echo "  ✅ SSH (port 22) - Protected with fail2ban (brute force protection)"
        echo "  ✅ Basic firewall - Only allows what you need"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "✅ You're safe! Bad guys can't break in via SSH!"
        echo "✅ You can close this window and sleep well! 😴"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Want to explore more later? (Optional)"
        echo ""
        echo "Running other services? I have ready-made profiles!"
        echo "  • Web server (nginx/Apache):     nftban profile enable web-server"
        echo "  • Mail server (Postfix/Dovecot): nftban profile enable mail-server"
        echo "  • Database (MySQL/PostgreSQL):   nftban profile enable database"
        echo "  • Everything (maximum):          nftban profile enable maximum"
        echo ""
        echo "Or open a port manually:"
        echo "  • nftban port add 80 tcp    (allow web traffic)"
        echo "  • nftban port add 3306 tcp  (allow MySQL)"
        echo ""
        echo "Quick commands:"
        echo "  • Check status: nftban status"
        echo "  • Block a country: nftban geoban ban CN"
        echo "  • Get help: nftban help"
    else
        echo "NFTBan is installed but NOT enabled."
        echo ""
        echo "To enable manually:"
        echo "  1. Review config: /etc/nftban/nftban.conf"
        echo "  2. Enable firewall: nftban enable"
        echo "  3. Check status: nftban status"
    fi

    echo ""
    echo "📖 Documentation: /usr/share/nftban/docs/"
    echo "🆘 Help: nftban help"
    echo "🩺 Health check: nftban health check"
    echo ""

    return 0
}

# =============================================================================

# HELP
# =============================================================================


nftban_setup_help() {
    cat <<'EOF'
🐧🛡️ NFTBan v1.0.0 - Setup Wizard
ban · unban · protect

Usage:
  nftban setup              # Interactive setup wizard
  nftban setup --auto       # Non-interactive mode
  nftban setup help         # Show this help

Description:
  First-time setup wizard that automatically:
    • Fixes all permission issues
    • Creates missing directories
    • Verifies system health
    • Optionally enables NFTBan

  Perfect for first-time installation or after upgrades.

Examples:
  nftban setup              # Run interactive setup
  nftban setup --auto       # Run without prompts

When to use:
  • Right after fresh installation
  • After upgrading NFTBan
  • When health check shows errors
  • If "nftban enable" fails

What it does:
  1. Runs: nftban permissions enforce
  2. Runs: nftban health check --auto-heal
  3. Checks system health
  4. Asks if you want to enable NFTBan

EOF
}

# Handle help
if [[ "${1:-}" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    nftban_setup_help
    exit 0
fi

# Export the main function
export -f nftban_cmd_setup
