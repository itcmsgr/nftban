#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.227 Lane-1 — MAIL-F3 `config show` secret-value redaction
# =============================================================================
# meta:name="config_show_secret_redaction_v1227_test"
# meta:type="test"
# meta:version="1.227.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="MAIL-F3 behavioral proof: nftban_cmd_config_show redacts credential VALUES in both text and --json renders. Authority = schema sensitive:true; suffix fail-safe only for schema-unknown keys. Asserts secret literal never leaks, JSON stays valid, and in-schema non-secrets (SINGLE_PASS, API_KEY_HEADER) are NOT over-redacted."
# meta:input="None (sources config schema + cmd_config read-only; stubbed effective config; no network)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_config_schema.sh,cli/lib/nftban/cli/cmd_config.sh,cli/lib/nftban/data/config-schema.json"
# meta:inventory.binaries="bash,jq,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="config_show_secret_redaction_v1227_test"
# meta:ta.owner="mail"
# meta:ta.module="config-secret-redaction"
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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
export NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== config_show_secret_redaction_v1227 ==="

SECRET='p@$$"&<>|`'                       # quotes, ampersand, angle brackets, pipe, backtick
# shellcheck source=/dev/null
source "$ROOT/cli/lib/nftban/core/nftban_config_schema.sh"
# shellcheck source=/dev/null
source "$ROOT/cli/lib/nftban/cli/cmd_config.sh" 2>/dev/null || true

command -v nftban_config_sensitive_keys_json >/dev/null 2>&1 || { echo "  [FATAL] helper missing"; exit 1; }
command -v nftban_cmd_config_show          >/dev/null 2>&1 || { echo "  [FATAL] nftban_cmd_config_show missing"; exit 1; }

# crafted effective config: real secret / normal value / in-schema non-secret flag /
# schema-unknown suffix secret / schema-marked-sensitive-without-suffix / empty secret
EFF=$(jq -cn --arg s "$SECRET" '{
  NFTBAN_SMTP_PASS: $s,
  NFTBAN_SMTP_HOST: "smtp.example.test",
  NFTBAN_COLLECT_LOG_SINGLE_PASS: "true",
  FOO_TOKEN: "unknown-suffix-secret",
  NFTBAN_CONNECTOR_WEBHOOK_API_KEY: "connector-key-should-mask",
  NFTBAN_CONNECTOR_WEBHOOK_API_KEY_HEADER: "X-Api-Key",
  NFTBAN_SMTP_USER: ""
}')
nftban_config_load_effective() { printf '%s' "$EFF"; }

# shellcheck disable=SC2034  # TEXT/JSON are consumed by the assert eval expressions below
TEXT="$(nftban_cmd_config_show 2>/dev/null)"
# shellcheck disable=SC2034
JSON="$(nftban_cmd_config_show --json 2>/dev/null)"

assert "TEXT_SHOW_SECRET_REDACTED"        'grep -qE "NFTBAN_SMTP_PASS[[:space:]]+= \[REDACTED\]" <<<"$TEXT"'
assert "JSON_SHOW_SECRET_REDACTED"        '[[ "$(jq -r ".NFTBAN_SMTP_PASS" <<<"$JSON")" == "[REDACTED]" ]]'
assert "JSON_STILL_VALID"                 'jq -e . <<<"$JSON" >/dev/null'
assert "RAW_SECRET_OCCURRENCES = 0 (text)" '! grep -qF "$SECRET" <<<"$TEXT"'
assert "RAW_SECRET_OCCURRENCES = 0 (json)" '! grep -qF "$SECRET" <<<"$JSON"'
assert "SPECIAL_CHAR_SECRET_NOT_LEAKED"    '[[ "$(grep -cF "$SECRET" <<<"$TEXT$JSON")" == "0" ]]'
assert "NONSECRET_VALUES_UNCHANGED (text)" 'grep -qE "NFTBAN_SMTP_HOST[[:space:]]+= smtp.example.test" <<<"$TEXT"'
assert "NONSECRET_VALUES_UNCHANGED (json)" '[[ "$(jq -r ".NFTBAN_SMTP_HOST" <<<"$JSON")" == "smtp.example.test" ]]'
assert "SINGLE_PASS_NOT_REDACTED"          '[[ "$(jq -r ".NFTBAN_COLLECT_LOG_SINGLE_PASS" <<<"$JSON")" == "true" ]]'
assert "API_KEY_HEADER_NAME_NOT_REDACTED"  '[[ "$(jq -r ".NFTBAN_CONNECTOR_WEBHOOK_API_KEY_HEADER" <<<"$JSON")" == "X-Api-Key" ]]'
assert "UNKNOWN_SECRET_SUFFIX_FAILSAFE"    '[[ "$(jq -r ".FOO_TOKEN" <<<"$JSON")" == "[REDACTED]" ]]'
assert "SCHEMA_SENSITIVE_KEY_REDACTED"     '[[ "$(jq -r ".NFTBAN_CONNECTOR_WEBHOOK_API_KEY" <<<"$JSON")" == "[REDACTED]" ]]'
assert "EMPTY_SECRET_HANDLED (no crash)"   '[[ -n "$JSON" ]] && jq -e . <<<"$JSON" >/dev/null'

# schema authority sanity: the 8 credential VALUES are flagged, the 2 lookalikes are not
assert "SCHEMA_FLAGS_8_CREDENTIALS"        '[[ "$(jq "[.properties|to_entries[]|select(.value.sensitive==true)]|length" "$ROOT/cli/lib/nftban/data/config-schema.json")" == "8" ]]'
assert "SINGLE_PASS_NOT_SCHEMA_SENSITIVE"  '! nftban_config_key_is_sensitive NFTBAN_COLLECT_LOG_SINGLE_PASS'
assert "API_KEY_HEADER_NOT_SCHEMA_SENSITIVE" '! nftban_config_key_is_sensitive NFTBAN_CONNECTOR_WEBHOOK_API_KEY_HEADER'

echo ""
echo "=== config_show_secret_redaction_v1227: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
