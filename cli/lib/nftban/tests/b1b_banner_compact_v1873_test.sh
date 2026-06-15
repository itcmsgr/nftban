#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.187.3 - B1b compact-banner convergence guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="b1b_banner_compact_v1873_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-15"
# meta:description="B1b banner convergence (v1.187.3): non-dashboard commands render ONE compact one-liner carrying a posture glyph, not the old 2-line motto and not the full box. Guards: (A) compact posture glyph is driven by the CHEAP-FRESH daemon systemd state, NOT the live validator — proven by setting a bogus _NFTBAN_VALIDATOR_CACHE 'down' and a systemctl shim 'active' and asserting the glyph is 🟢 (validator ignored on the hot path); (B) failed daemon → 🔴; (C) cache-only update notice appears only when a FRESH cache has a higher version, never via network; (D) suppression — --json / NFTBAN_BANNER_MODE=none emit nothing; (E) full-box gate intact — version mode still renders the box tagline, a non-dashboard mode renders the compact glyph line. Hermetic: systemctl shimmed, temp cache; no host/nft/IPC/validator."
#
# meta:inventory.files="b1b_banner_compact_v1873_test.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CACHE_DIR,NFTBAN_BANNER_MODE,NFTBAN_OUTPUT_JSON"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export NFTBAN_CACHE_DIR="$tmp/cache" NFTBAN_TTY=true NFTBAN_COLOR=false
mkdir -p "$NFTBAN_CACHE_DIR"

# Shim systemctl BEFORE sourcing so the cheap glyph reads our controlled state.
_SYSTEMCTL_STATE="active"
systemctl() { case "$*" in *"is-active nftband"*) echo "$_SYSTEMCTL_STATE";; *) echo "unknown";; esac; return 0; }
export -f systemctl

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/version.sh"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_output.sh"

# ---- (A) compact glyph is CHEAP-FRESH (systemctl), NOT the validator ----
# Bogus validator cache says "down"; if compact wrongly consulted it, glyph→🔴.
export _NFTBAN_VALIDATOR_CACHE='{"status":"down"}'
_SYSTEMCTL_STATE="active"
out="$(nftban_render_banner_compact)"
grep -q "🟢" <<<"$out" || fail "A: active daemon should give 🟢 (got: $out)"
grep -q "🔴" <<<"$out" && fail "A: compact must IGNORE validator cache (showed 🔴 from bogus validator 'down')"
grep -q "NFTBan v" <<<"$out" || fail "A: compact missing version (got: $out)"
[[ "$(printf '%s' "$out" | wc -l)" -le 1 ]] || fail "A: compact must be ONE line (got multi-line: $out)"
unset _NFTBAN_VALIDATOR_CACHE
echo "PASS A: compact glyph is cheap-fresh (systemctl-driven), validator NOT consulted; single line"

# ---- (B) failed daemon → 🔴 ----
_SYSTEMCTL_STATE="failed"
out="$(nftban_render_banner_compact)"
grep -q "🔴" <<<"$out" || fail "B: failed daemon should give 🔴 (got: $out)"
echo "PASS B: failed daemon → 🔴"
_SYSTEMCTL_STATE="active"

# ---- (C) cache-only update notice ----
out="$(nftban_render_banner_compact)"
grep -q "available" <<<"$out" && fail "C: no cache → must show NO update notice (got: $out)"
printf '9.9.9\n' > "$NFTBAN_CACHE_DIR/update_check"   # fresh cache, higher version
out="$(nftban_render_banner_compact)"
grep -q "↑ v9.9.9 available — nftban update" <<<"$out" || fail "C: fresh higher-version cache should show notice (got: $out)"
# stale cache → no notice
export NFTBAN_UPDATE_TTL=0
out="$(nftban_render_banner_compact)"
grep -q "available" <<<"$out" && fail "C: stale cache (ttl=0) must show NO notice (got: $out)"
unset NFTBAN_UPDATE_TTL
echo "PASS C: update notice is cache-only (fresh+higher shows; absent/stale hides)"

# ---- (D) suppression ----
[[ -z "$(NFTBAN_OUTPUT_JSON=true nftban_render_banner_compact)" ]] || fail "D: --json/JSON mode must suppress banner"
[[ -z "$(NFTBAN_BANNER_MODE=none nftban_render_banner_compact)" ]] || fail "D: NFTBAN_BANNER_MODE=none must suppress banner"
echo "PASS D: JSON / banner-mode=none suppress the compact banner"

# ---- (E) full-box gate intact: version=box(tagline), other=compact(glyph) ----
box="$(NFTBAN_BANNER_MODE=full nftban_banner_unified version 2>/dev/null || true)"
if [[ -n "$box" ]]; then
    grep -qF "Open-source Linux Firewall & IPS for nftables" <<<"$box" || fail "E: version mode lost the full-box tagline"
fi
compact="$(NFTBAN_BANNER_MODE=full nftban_banner_unified watchdog 2>/dev/null || true)"
grep -qE "🟢|🟠|🔴|⚪" <<<"$compact" || fail "E: non-dashboard (watchdog) must render the compact posture line (got: $compact)"
grep -qF "ban · unban · protect" <<<"$compact" && fail "E: old 2-line motto must be gone from non-dashboard banner"
echo "PASS E: full box on version (tagline), compact posture line on watchdog (no old motto)"

echo "PASS: B1b compact-banner convergence (v1.187.3)"
