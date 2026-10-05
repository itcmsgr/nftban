#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - report generators escape the company name and version
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="report_company_name_escaping_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="Residual of BUG-REPORT-AMPERSAND-INJECTS-PLACEHOLDER-NAME and BUG-REPORT-HTML-NO-ESCAPING-SANITIZER-DEFINED-BUT-UNUSED (v1.235). v1.229.15 routed table rows, hostname, IP, date and time through _nftban_report_esc + _nftban_report_lit, but NFTBAN_COMPANY_NAME and NFTBAN_VERSION were still substituted raw in the module, FHS and port generators: in bash 5.2+ an & in the replacement expands to the matched text, so 'Smith & Co' rendered as 'Smith {COMPANY_NAME} Co', and markup in the name reached the document. Arms: E1 the REAL module generator with NFTBAN_COMPANY_NAME='Smith & <b>Co</b>' renders 'Smith &amp; &lt;b&gt;Co&lt;/b&gt;', never '{COMPANY_NAME}' and never a raw <b>; E2 a version string with & and < is escaped the same way; S1 all three generators (module, fhs, port) substitute {COMPANY_NAME}/{NFTBAN_VERSION} from the escaped locals, not from the raw variables; S2 the &-literal escape in the three generators and the email report is gated on patsub_replacement (bash 5.1 on EL9 printed the backslash: BUG-REPORT-AMP-ESCAPE-PRINTS-BACKSLASH-ON-BASH-5-1). E1/E2 must pass on both bash 5.1 and 5.2. Set REPORT_SUBJECT_ROOT to an older tree (e.g. e79a1173): E1, E2 and S1 must FAIL there."
# meta:inventory.files="report_company_name_escaping_v1235_test.sh"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars="REPORT_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="report_company_name_escaping_v1235_test"
# meta:ta.owner="core"
# meta:ta.module="report-generator-content-truth"
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
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${REPORT_SUBJECT_ROOT:-$REPO}"
CORE="$ROOT/cli/lib/nftban/core"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: report company name / version escaping ==="
for f in module fhs port; do
    [[ -f "$CORE/nftban_report_$f.sh" ]] || { echo "  NOT_EXECUTED: nftban_report_$f.sh missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
done

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
MODLIB="$SB/lib"; mkdir -p "$MODLIB/core" "$SB/tmpl/reports" "$SB/out"
cat > "$MODLIB/core/fixturemod.sh" <<'MOD'
#!/usr/bin/env bash
# meta:name="fixturemod"
# meta:version="1.0.0"
# meta:type="core"
# meta:created_date="2026-01-02"
# meta:depends="none"
# meta:owner="o"
# meta:homepage="h"
# meta:description="d"
MOD
{ echo '<html><body>'
  for ph in MODULE_TABLE_ROWS TOTAL_MODULES ENABLED_MODULES DISABLED_MODULES CORE_MODULES DATE TIME \
            HOSTNAME SERVER_IP NFTBAN_VERSION COMPANY_NAME LOGO_HTML VERSION_HTML DEPENDENCY_SECTION; do
      echo "  <div>{$ph}</div>"
  done
  echo '</body></html>'; } > "$SB/tmpl/reports/module_report.html"

# ---- E1/E2 · the real module generator --------------------------------------------
doc="$(env -i PATH="/usr/bin:/bin" HOME="$SB" \
        NFTBAN_TEMPLATE_DIR="$SB/tmpl" NFTBAN_REPORT_DIR="$SB/out" NFTBAN_LIB_DIR="$MODLIB" \
        NFTBAN_COMPANY_NAME='Smith & <b>Co</b>' NFTBAN_VERSION='1.2&3<x>' CORE="$CORE" \
        bash -c 'set -uo pipefail
                 source "$CORE/nftban_report_module.sh" >/dev/null 2>&1 || exit 90
                 nftban_module_generate_html_report >/dev/null 2>&1 || true
                 cat "$NFTBAN_REPORT_DIR"/module_report_*.html 2>/dev/null' || true)"
if [[ -z "$doc" ]]; then
    no "E1 module generator produced no document (harness)"
else
    if [[ "$doc" == *"Smith &amp; &lt;b&gt;Co&lt;/b&gt;"* && "$doc" != *"{COMPANY_NAME}"* && "$doc" != *"<b>Co</b>"* ]]; then
        ok "E1 company name escaped: '&' kept literally, markup rendered as entities"
    else
        no "E1 company name not escaped" "$(grep -o 'Smith[^<]*' <<<"$doc" | head -1)"
    fi
    if [[ "$doc" == *"1.2&amp;3&lt;x&gt;"* && "$doc" != *"{NFTBAN_VERSION}"* ]]; then
        ok "E2 version string escaped the same way"
    else
        no "E2 version string not escaped" "$(grep -o '1\.2[^<]*' <<<"$doc" | head -1)"
    fi
fi

# ---- S1 · all three generators substitute from the escaped locals -----------------
for f in module fhs port; do
    src="$CORE/nftban_report_$f.sh"
    raw="$(grep -cE '\{(COMPANY_NAME|NFTBAN_VERSION)\\\}/\$\{NFTBAN_(COMPANY_NAME|VERSION)' "$src" || true)"
    lit="$(grep -cE '_nftban_report_lit .*company_name version_str' "$src" || true)"
    if [[ "$raw" == 0 && "$lit" -ge 1 ]]; then
        ok "S1 $f: company name / version substituted from escaped locals"
    else
        no "S1 $f: raw substitution remains" "raw=$raw lit=$lit"
    fi
done

# ---- S2 · the & literal-escape only where & is special (bash >= 5.2) -------------
# CI runs bash 5.2, where an unconditional "\\&" is correct; on bash 5.1 (EL9) it is
# printed. This structural arm keeps the guard in place for the distro CI cannot see.
for f in module fhs port email; do
    src="$CORE/nftban_report_$f.sh"
    if grep -q 'shopt -q patsub_replacement' "$src"; then
        ok "S2 $f: &-escaping is gated on patsub_replacement (bash 5.1 safe)"
    else
        no "S2 $f: unconditional &-escaping (prints a backslash on bash < 5.2)"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
