#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.31.0 - Setup Wizard CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Interactive setup wizard for first-time installation
#
# meta:name=cmd_setup
# meta:type=cli
# meta:header=Setup Wizard CLI Handler
# meta:version=0.31.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# meta:created_date=2025-11-06
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
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

    local AUTO_MODE=false
    if [[ "${1:-}" == "--auto" ]]; then
        AUTO_MODE=true
    fi

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

    if echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*OK"; then
        echo "  ✅ System health: PERFECT"
        HEALTH_OK=true
    elif echo "$HEALTH_OUTPUT" | grep -q "Overall Status:.*WARNING"; then
        echo "  ✅ System health: OK (minor warnings)"
        HEALTH_OK=true
    else
        echo "  ⚠️  System health: Has issues"
        echo ""
        echo "$HEALTH_OUTPUT" | grep -A2 "Overall Status"
        HEALTH_OK=false
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
        echo "✅ NFTBan is now protecting your server!"
        echo ""
        echo "Next steps:"
        echo "  • Check status: nftban status"
        echo "  • View logs: journalctl -u nftban -f"
        echo "  • Test GeoBan: nftban geoban help"
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
🐧🛡️ NFTBan v0.31.0 - Setup Wizard
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
