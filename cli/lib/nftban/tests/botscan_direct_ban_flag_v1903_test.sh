#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan direct-ban flag guard (BUG-BOTSCAN-DIRECT-BAN-FLAG)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botscan_direct_ban_flag_v1903_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-16"
# meta:description="Hermetic guard for BUG-BOTSCAN-DIRECT-BAN-FLAG (v1.190.3): the direct/legacy branch of nftban_botscan_ban_ip (taken only when BOTSCAN_BATCH_SIGNAL_MODE != true) must invoke the CLI with the REAL flag --timeout, not the non-existent --duration (which cmd_ban.sh does not accept, so the ban was logged BANNED but never inserted). Stubs NFTBAN_BIN as a recorder, forces direct mode, and asserts the emitted args use --timeout and never --duration. Production uses the batch-signal path; this guards the standalone/legacy path."
#
# meta:inventory.files="botscan_direct_ban_flag_v1903_test.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_BIN,BOTSCAN_BATCH_SIGNAL_MODE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_direct_ban_flag_v1903_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-direct-ban-flag"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_DATA_DIR="$tmp/data" BOTSCAN_PATTERNS_DIR="$tmp/patterns" \
       BOTSCAN_STATE_FILE="$tmp/s.db" BOTSCAN_LOG_FILE="$tmp/b.log" \
       NFTBAN_CONFIG_DIR="$tmp/noetc" BOTSCAN_ENABLED=true \
       BOTSCAN_BATCH_SIGNAL_MODE=false BOTSCAN_VERIFY_CRAWLERS=false
mkdir -p "$NFTBAN_DATA_DIR/botscan" "$BOTSCAN_PATTERNS_DIR"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"; nftban_botscan_load_config

# Record the CLI invocation instead of running a real ban.
export NFTBAN_REC="$tmp/rec"; : > "$NFTBAN_REC"
cat > "$tmp/nftban" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$NFTBAN_REC"
EOF
chmod +x "$tmp/nftban"
export NFTBAN_BIN="$tmp/nftban"
# Force the CLI branch (not the internal nftban_ban function, if present).
unset -f nftban_ban 2>/dev/null || true

nftban_botscan_ban_ip 203.0.113.5 3600 botscan "direct-path guard" >/dev/null 2>&1 || true
rec="$(cat "$NFTBAN_REC" 2>/dev/null || true)"

[[ -n "$rec" ]] || fail "direct branch did not invoke NFTBAN_BIN (got empty; rec='$rec')"
grep -q -- "--timeout 3600" <<<"$rec" || fail "direct ban must use '--timeout 3600' (got: $rec)"
grep -q -- "--duration" <<<"$rec" && fail "direct ban must NOT use '--duration' — cmd_ban.sh has no such flag (got: $rec)"
echo "PASS: direct ban_ip path uses --timeout, never --duration (BUG-BOTSCAN-DIRECT-BAN-FLAG fixed)"
