#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.227 Lane-1 — MAIL-F4 report HTML JSON-in-<script> breakout safety
# =============================================================================
# meta:name="report_html_json_script_safe_v1227_test"
# meta:type="test"
# meta:version="1.227.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="MAIL-F4 behavioral proof: nftban_report_generate_html injects the stats JSON into a <script> block. A data value containing </script> must NOT break out. Drives the real function with a stub template + stubbed stats export whose value is </script><script>alert(1)</script>; asserts no data-origin </script>, the payload is \\uXXXX-escaped (NOT HTML-entity escaped) and stays valid JSON that decodes back to the original text. No network."
# meta:input="None (sources cmd_report.sh read-only; stub template + stub stats export; no network)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_report.sh"
# meta:inventory.binaries="bash,jq,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_REPORT_TEMPLATE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="report_html_json_script_safe_v1227_test"
# meta:ta.owner="mail"
# meta:ta.module="report-html-script-safe"
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

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== report_html_json_script_safe_v1227 ==="

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB"/{data,run,log,state}
HOSTILE='</script><script>alert(1)</script>'

# stub template: the data line is isolated so its own </script> is on a separate line
TMPL="$SB/tmpl.html"
{
  echo '<html><body>'
  echo '<script>'
  echo 'window.__NFTBAN_DATA__ = {            // Placeholder - will be replaced        }'
  echo '</script>'
  echo '</body></html>'
} > "$TMPL"

# export the harness vars so the child bash -c reads them from the environment
export ROOT HOSTILE SB TMPL
export NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" NFTBAN_DATA_DIR="$SB/data" NFTBAN_RUN_DIR="$SB/run"
export NFTBAN_LOG_DIR="$SB/log" NFTBAN_STATE_DIR="$SB/state" NFTBAN_REPORT_TEMPLATE="$TMPL"
OUT="$(
    bash -c '
        set -Eeuo pipefail
        # shellcheck disable=SC1090
        source "$ROOT/cli/lib/nftban/cli/cmd_report.sh" 2>/dev/null || true
        # stub the stats export: write JSON carrying the hostile value + &,<,> chars
        nftban_stats_export_json() { jq -cn --arg h "$HOSTILE" "{host:\$h, note:\"a & b < c > d\"}" > "$1"; }
        out="$SB/report.html"
        nftban_report_generate_html "$out" "" "" dark >/dev/null 2>&1 || true
        cat "$out" 2>/dev/null
    '
)"

[[ -n "$OUT" ]] || { echo "  [FATAL] no HTML produced"; exit 1; }

# the injected data line
DATALINE="$(grep -F 'window.__NFTBAN_DATA__' <<<"$OUT" | head -1)"
# the JSON payload = everything after "= "
# shellcheck disable=SC2034  # PAYLOAD is consumed by the assert eval expressions below
PAYLOAD="${DATALINE#*= }"

assert "HTML produced with data line"          '[[ -n "$DATALINE" ]]'
# injection correctness: the data line is exactly `window.__NFTBAN_DATA__ = {…}` with no leaked
# substitution delimiter / template-tail garbage (the pre-fix ${var//…} brace-parse malformed it)
assert "INJECTION_WELL_FORMED"                 '[[ "$DATALINE" =~ ^window\.__NFTBAN_DATA__\ =\ \{.*\}$ ]]'
assert "NO_LEAKED_TEMPLATE_TAIL_IN_DATALINE"   '! grep -qF "</body>" <<<"$DATALINE"'
assert "SCRIPT_BREAKOUT_NEUTRALIZED"           '! grep -qF "</script>" <<<"$DATALINE"'
assert "LT_ESCAPED_AS_u003c"                   'grep -qF "\\u003c" <<<"$DATALINE"'
assert "GT_ESCAPED_AS_u003e"                   'grep -qF "\\u003e" <<<"$DATALINE"'
assert "AMP_ESCAPED_AS_u0026"                  'grep -qF "\\u0026" <<<"$DATALINE"'
assert "NO_HTML_ENTITY_CORRUPTION"             '! grep -qE "&lt;|&gt;|&amp;" <<<"$DATALINE"'
assert "PAYLOAD_STILL_VALID_JSON"              'jq -e . <<<"$PAYLOAD" >/dev/null'
assert "PAYLOAD_DECODES_BACK_TO_ORIGINAL"      '[[ "$(jq -r .host <<<"$PAYLOAD")" == "$HOSTILE" ]]'
assert "NOTE_FIELD_DECODES_BACK"               '[[ "$(jq -r .note <<<"$PAYLOAD")" == "a & b < c > d" ]]'
# whole-document: the only </script> is the template's own closing tag (1), none from data
assert "ONLY_TEMPLATE_CLOSING_SCRIPT_TAG"      '[[ "$(grep -cF "</script>" <<<"$OUT")" == "1" ]]'

echo ""
echo "=== report_html_json_script_safe_v1227: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
