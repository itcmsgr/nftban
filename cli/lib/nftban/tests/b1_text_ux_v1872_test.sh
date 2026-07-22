#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.187.2 - B1 CLI/text-UX guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="b1_text_ux_v1872_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-15"
# meta:description="B1 CLI/text-UX lane (v1.187.2) guards: (1) UX-BANNER-TEXT — the unified banner tagline is the Firewall-first wording 'Open-source Linux Firewall & IPS for nftables' and the old IPS-first 'Open-source Linux IPS & nftables FW' is gone; NFTBAN_VERSION_NAME is 'Linux Firewall & IPS for nftables'. (2) UX-UPDATE-LOCK — the lock-contention message points the user to 'tail -f .../update.log', explains 'nftban update force' clears only a STALE lock, and best-effort names the in-progress PID; the old terse 'Another update is in progress / clear stale lock' wording is gone. Hermetic: behavioral banner render + source-content guards; no host/nft/IPC."
#
# meta:inventory.files="b1_text_ux_v1872_test.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_BANNER_MODE,NFTBAN_TTY"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="b1_text_ux_v1872_test"
# meta:ta.owner="cli"
# meta:ta.module="banner"
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

NEW_TAGLINE="Open-source Linux Firewall & IPS for nftables"
OLD_TAGLINE="Open-source Linux IPS & nftables FW"
NEW_VNAME="Linux Firewall & IPS for nftables"

# ---- (1a) NFTBAN_VERSION_NAME ----
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/version.sh"
[[ "${NFTBAN_VERSION_NAME:-}" == "$NEW_VNAME" ]] \
    || fail "version_name = '${NFTBAN_VERSION_NAME:-}' (expected '$NEW_VNAME')"
echo "PASS 1a: NFTBAN_VERSION_NAME is Firewall-first"

# ---- (1b) unified banner tagline (behavioral render) ----
export NFTBAN_BANNER_MODE=full NFTBAN_TTY=true NFTBAN_COLOR=false
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_output.sh"
banner_out="$(NFTBAN_BANNER_MODE=full nftban_banner_unified status 2>/dev/null || true)"
if [[ -n "$banner_out" ]]; then
    grep -qF -- "$NEW_TAGLINE" <<<"$banner_out" || fail "rendered banner missing new tagline; got: $(printf '%s' "$banner_out" | head -2)"
    grep -qF -- "$OLD_TAGLINE" <<<"$banner_out" && fail "rendered banner still has OLD tagline"
    echo "PASS 1b: rendered unified banner carries the Firewall-first tagline"
else
    echo "INFO 1b: banner render empty in this env — falling back to source guard"
fi

# ---- (1c) source-content guard: new tagline present, old absent ----
out_src="$NFTBAN_LIB_DIR/core/nftban_output.sh"
grep -qF -- "$NEW_TAGLINE" "$out_src" || fail "new tagline not in nftban_output.sh"
grep -qF -- "$OLD_TAGLINE" "$out_src" && fail "OLD tagline still in nftban_output.sh"
echo "PASS 1c: nftban_output.sh tagline source is Firewall-first"

# ---- (2) UX-UPDATE-LOCK friendly message ----
upd="$NFTBAN_LIB_DIR/cli/cmd_update.sh"
# the contention block must point to the log tail + explain STALE-only force
grep -qF -- "tail -f \${UPDATE_LOG_FILE}" "$upd" || fail "update-lock message missing 'tail -f \${UPDATE_LOG_FILE}' hint"
grep -qiF -- "clears a STALE lock" "$upd" || fail "update-lock message missing STALE-only clarification"
grep -qF -- "In-progress update: PID" "$upd" || fail "update-lock message missing best-effort PID line"
# old terse wording gone
grep -qF -- "If no update is running, use 'nftban update force' to clear stale lock" "$upd" \
    && fail "old terse update-lock wording still present"
echo "PASS 2: UX-UPDATE-LOCK message is friendly (PID + tail -f + STALE-only force)"

echo "PASS: B1 CLI/text-UX (tagline + version_name + update-lock) v1.187.2"
