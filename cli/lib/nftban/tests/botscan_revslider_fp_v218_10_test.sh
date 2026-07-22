#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.218.10 EXP_REVSLIDER false-positive narrowing
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_revslider_fp_v218_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-08"
# meta:description="Verifies the v1.218.10 fix to the EXP_REVSLIDER botscan signature. The old pattern matched the bare substring 'revslider' (url-any), so legitimate WordPress pages loading RevSlider static assets (/wp-content/plugins/revslider/.../rs6.min.js, rbtools.min.js, *.css) tripped the 3/60s threshold and banned real visitors. The narrowed pattern matches only exploit-specific action/client_action tokens (revslider_show_image LFI, client_action=get_captions_css LFI, client_action=update_plugin RCE). Asserts: the record still parses via the anchored (|-bearing pattern) parse into exactly 8 fields with match_type/threshold/window/ban/enabled intact; the pattern is no longer the bare 'revslider'; legit asset URLs do NOT match; real exploit probe URLs DO match; threshold/window/ban/enabled unchanged (3/60/3600/true)."
# meta:input="None (reads the shipped exploit.patterns)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="etc/nftban/patterns.d/botscan/exploit.patterns"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="botscan_revslider_fp_v218_10_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-patterns"
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
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
PATTERNS="$REPO_ROOT/etc/nftban/patterns.d/botscan/exploit.patterns"

PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=== v1.218.10 EXP_REVSLIDER false-positive narrowing ==="

# Grab the EXP_REVSLIDER record line.
line=$(grep -E '^EXP_REVSLIDER\|' "$PATTERNS" | head -1)
[[ -n "$line" ]] && ok "EXP_REVSLIDER record present" || { no "EXP_REVSLIDER record present"; }

# Anchored parse (mirrors nftban_botscan.sh: peel NAME off front, 6 fields off back;
# the middle is the legally |-bearing pattern).
name="${line%%|*}"; rest="${line#*|}"
rest="${rest%|*}"                          # drop description (last field; unused here)
enabled="${rest##*|}";   rest="${rest%|*}"
ban="${rest##*|}";       rest="${rest%|*}"
window="${rest##*|}";    rest="${rest%|*}"
threshold="${rest##*|}"; rest="${rest%|*}"
match_type="${rest##*|}";rest="${rest%|*}"
pattern="$rest"

# >= 7 pipes (8 fields; a |-alternation pattern only adds more).
pipes="${line//[!|]/}"
[[ "${#pipes}" -ge 7 ]] && ok "record has >= 7 pipes (parseable into 8 fields)" || no "record has >= 7 pipes"

[[ "$name" == "EXP_REVSLIDER" ]] && ok "name field = EXP_REVSLIDER" || no "name field ($name)"
[[ "$match_type" == "url-any" ]] && ok "match_type field intact = url-any" || no "match_type ($match_type)"
[[ "$threshold" == "3" ]] && ok "threshold unchanged = 3" || no "threshold ($threshold)"
[[ "$window" == "60" ]] && ok "window unchanged = 60" || no "window ($window)"
[[ "$ban" == "3600" ]] && ok "ban unchanged = 3600" || no "ban ($ban)"
[[ "$enabled" == "true" ]] && ok "enabled unchanged = true" || no "enabled ($enabled)"

# The regression guard: pattern must NOT be the bare product token.
[[ "$pattern" != "revslider" ]] && ok "pattern narrowed (no longer bare 'revslider')" || no "pattern still bare 'revslider' — FALSE-POSITIVE REGRESSION"
[[ "$pattern" == *revslider_show_image* ]] && ok "pattern includes exploit indicator revslider_show_image" || no "missing revslider_show_image"

# Behavioural: legit RevSlider asset URLs must NOT match (the FP source).
legit_ok=true
for u in \
  '/wp-content/plugins/revslider/public/assets/js/rbtools.min.js' \
  '/wp-content/plugins/revslider/public/assets/js/rs6.min.js' \
  '/wp-content/plugins/revslider/public/assets/css/rs6.css' \
  '/wp-content/plugins/revslider/public/assets/fonts/revicons.woff' ; do
  if printf '%s' "$u" | grep -qE "$pattern"; then legit_ok=false; echo "        matched (bad): $u"; fi
done
$legit_ok && ok "legit RevSlider asset URLs do NOT match (visitors not banned)" || no "legit asset URL matched — FALSE POSITIVE"

# Behavioural: real RevSlider exploit probes must still match.
exploit_ok=true
for u in \
  '/wp-admin/admin-ajax.php?action=revslider_show_image&img=../../../wp-config.php' \
  '/wp-admin/admin-ajax.php?action=revslider_ajax_action&client_action=get_captions_css&data=..' \
  '/wp-admin/admin-ajax.php?action=revslider_ajax_action&client_action=update_plugin' ; do
  if ! printf '%s' "$u" | grep -qE "$pattern"; then exploit_ok=false; echo "        missed (bad): $u"; fi
done
$exploit_ok && ok "real RevSlider exploit probes still match (detection preserved)" || no "exploit probe missed — detection regression"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
