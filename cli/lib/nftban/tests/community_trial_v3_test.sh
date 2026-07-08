#!/usr/bin/env bash
# =============================================================================
# NFTBan - community trial v3 telemetry payload (privacy + shape)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="community_trial_v3_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-08"
# meta:description="nftban_community_build_payload_v3 emits a valid, minimal, privacy-safe schema_version 3 trial payload (buckets/class-labels/booleans only) with NO IP/hostname/domain/email/username/token/admin-port/log/ban-list; v2 stays frozen at schema_version 2; opt-in enable requires typed yes; send-test refuses when disabled. Hermetic: sources the lib, no network, no real send."
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
LIB="$REPO/cli/lib/nftban/lib/nftban_pro.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }

echo "=== community trial v3 payload ==="
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# assertions are best-effort greps; a 0-match grep must not abort the run
set +e; set +o pipefail

# Build the v3 payload in an isolated shell (server id stubbed; no real config).
V3="$WORK/v3.json"
bash -c '
  export NFTBAN_CONFIG_DIR="'"$WORK"'/etc" NFTBAN_COMMUNITY_CONF="'"$WORK"'/etc/community.conf"
  mkdir -p "$NFTBAN_CONFIG_DIR"
  source "'"$LIB"'" >/dev/null 2>&1
  nftban_pro_get_server_id() { echo "aaaabbbbccccdddd-11223344"; }
  nftban_community_build_payload_v3
' > "$V3" 2>/dev/null || true

# 1. valid JSON
if command -v jq >/dev/null 2>&1 && jq -e . "$V3" >/dev/null 2>&1; then ok "v3 payload is valid JSON"; else no "v3 payload is not valid JSON"; fi

# 2. schema_version 3 + trial flags
[[ "$(jq -r '.schema_version' "$V3" 2>/dev/null)" == "3" ]] && ok "schema_version == 3" || no "schema_version != 3"
[[ "$(jq -r '.trial_mode' "$V3" 2>/dev/null)" == "true" ]] && [[ "$(jq -r '.internal_analysis_only' "$V3" 2>/dev/null)" == "true" ]] && ok "trial_mode + internal_analysis_only = true" || no "trial flags missing"

# 3. 15 module keys, each a valid state class
mods=$(jq -r '.modules | keys | length' "$V3" 2>/dev/null)
[[ "$mods" == "15" ]] && ok "15 module keys present" || no "module count = $mods (want 15)"
bad=$(jq -r '.modules | to_entries[] | select(.value | test("^(unavailable|installed_disabled|enabled_ok|enabled_warn|enabled_degraded|enabled_fatal|unknown)$") | not) | .key' "$V3" 2>/dev/null | wc -l)
[[ "$bad" == "0" ]] && ok "every module value is a valid state class" || no "$bad module(s) with invalid state class"

# 4. payload_hash present (64 hex)
[[ "$(jq -r '.payload_hash' "$V3" 2>/dev/null | grep -cE '^[0-9a-f]{64}$')" == "1" ]] && ok "payload_hash is a sha256" || no "payload_hash missing/invalid"

# 5. health/api/rbl/suricata are CLASS/boolean only (values are from the allowed vocab)
[[ "$(jq -r '.api_metrics.api_bind_class' "$V3" 2>/dev/null | grep -cE '^(loopback|private_lan|public_or_all_interfaces|unix_socket|disabled|unknown)$')" == "1" ]] && ok "api_bind_class is a class label (no address)" || no "api_bind_class not a class"
[[ "$(jq -r '.communication.alert_transport_classes' "$V3" 2>/dev/null | grep -cE '^(none|local|email|webhook|mixed)$')" == "1" ]] && ok "alert_transport_classes is a class (no recipients)" || no "transport class invalid"

# 6. PRIVACY GATE — zero forbidden data anywhere in the payload
leak=$(grep -inE '([0-9]{1,3}\.){3}[0-9]{1,3}|@[a-z0-9.-]+\.[a-z]{2,}|[a-z0-9-]+\.(com|net|org|gr|io)|:(22|9580|55000)\b|"?(token|secret|password|passwd|bearer)"?[":= ]|/var/log|"hostname"' "$V3" | wc -l)
[[ "$leak" == "0" ]] && ok "PRIVACY: no IP/hostname/domain/email/token/admin-port/log in payload" || { no "PRIVACY LEAK ($leak):"; grep -inE '([0-9]{1,3}\.){3}[0-9]{1,3}|@|token|hostname|/var/log' "$V3" | head; }

# 7. no forbidden field NAMES (ban list / raw events / config / recipients)
fbad=$(jq -r 'paths | join(".")' "$V3" 2>/dev/null | grep -icE 'recipient|ban_?list|raw|event|signature|log_|config_content|source_ip|dest_ip|domain|email|hostname|token'); fbad=${fbad:-0}
[[ "$fbad" == "0" ]] && ok "no forbidden field names in schema" || no "$fbad forbidden field name(s)"

# 8. v2 stays FROZEN at schema_version 2 (grep the frozen literal in the lib)
[[ "$(grep -c '"schema_version": 2' "$LIB")" -ge 1 ]] && ok "v2 build_payload still emits schema_version 2 (frozen)" || no "v2 schema_version 2 literal missing"

# 9. opt-in enable requires typed 'yes' (declined input cancels, rc1)
r=$(bash -c '
  export NFTBAN_COMMUNITY_CONF="'"$WORK"'/etc/cc.conf"
  source "'"$LIB"'" >/dev/null 2>&1; set +e
  printf "no\n" | nftban_community_enable; echo "rc=$?"
' 2>/dev/null | tail -1)
echo "$r" | grep -q 'rc=1' && ok "enable without 'yes' cancels (rc1, no silent enablement)" || no "enable did not require confirmation: $r"

# 10. send-test refuses when disabled (opt-in required before any send)
r=$(bash -c '
  export NFTBAN_COMMUNITY_CONF="'"$WORK"'/etc/none.conf"
  source "'"$LIB"'" >/dev/null 2>&1; set +e
  nftban_community_send_test; echo "rc=$?"
' 2>&1 | tail -1)
echo "$r" | grep -q 'rc=1' && ok "send-test refuses when disabled (no send without opt-in)" || no "send-test did not refuse: $r"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
