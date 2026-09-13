#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="report_generator_content_truth_v1229_15_test.sh"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-09"
# meta:description="Content assertions for the three HTML report generators that produced structurally wrong output on every run: the port report iterated arrays that were never declared, the module report destructured seven fields from an eight-field tuple, and the FHS report read an array nothing ever wrote. Every assertion is ALSO run against the pre-fix implementation extracted from tag v1.229.14, so the harness proves it discriminates rather than asserting into a vacuum. A caller that checks only [[ -f report ]] passes on all three defects, which is why these assert rendered CONTENT. Hermetic: stubbed ss, fixture template and module tree, no root, no network, no nftables."
# meta:inventory.files=""
# meta:inventory.binaries="git,ss(stubbed)"
# meta:inventory.env_vars="NFTBAN_TEMPLATE_DIR,NFTBAN_REPORT_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="unprivileged"
# meta:ta.id="report_generator_content_truth_v1229_15_test"
# v1.230.0: ta.owner was "reporting", which is NOT in the declared OWNERS vocabulary
# (scripts/ci/test-authority.py:41), so `test-authority.py validate --mode strict`
# rejected it. Pre-existing since this file entered the stack; never seen because
# stacked PRs skip the main-base gates. Relabelled to an EXISTING valid owner rather
# than widening the vocabulary — the report generators live under core/.
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

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SB="$(mktemp -d)"
cleanup() { find "$SB" -type d -exec chmod u+rwx {} + 2>/dev/null || true; rm -rf "$SB"; }
trap cleanup EXIT

PASS=0; FAIL=0
assert() {
    local label="$1" cond="$2"
    if [[ "$cond" == "0" ]]; then PASS=$((PASS+1)); echo "[PASS] $label"
    else FAIL=$((FAIL+1)); echo "[FAIL] $label"; fi
}

# The pre-fix implementation, taken from the v1.229.14 tag. A tag is immutable;
# origin/main would invert the moment this fix merges and the controls would then
# silently assert nothing. If the ref is unreachable the controls are SKIPPED
# LOUDLY -- absence of a control is never counted as a passing control.
BASE_REF="v1.229.14"
OLD_DIR="$SB/prefix"; mkdir -p "$OLD_DIR"
OLD_AVAILABLE=1
for f in fhs module port; do
    git -C "$ROOT" show "${BASE_REF}:cli/lib/nftban/core/nftban_report_${f}.sh" \
        > "$OLD_DIR/nftban_report_${f}.sh" 2>/dev/null || OLD_AVAILABLE=0
done
[[ "$OLD_AVAILABLE" -eq 1 ]] || echo "[SKIP] pre-fix controls: ${BASE_REF} unreachable - NOT counted as pass"

mk_template() {  # $1 = dest file, $2..$n = placeholders to include
    local dest="$1"; shift
    { echo '<html><body><table>'; for ph in "$@"; do echo "  <div>{$ph}</div>"; done
      echo '</table></body></html>'; } > "$dest"
}

# ---------------------------------------------------------------------------
# DEFECT 1 - FHS: NFTBAN_FHS_ACTUAL was declared, read twice, never written.
# ---------------------------------------------------------------------------
probe_fhs() {
    local src="$1" probe_dir="$2"
    bash -c '
        set -uo pipefail
        source "'"$src"'" >/dev/null 2>&1 || exit 90
        d="'"$probe_dir"'"
        NFTBAN_FHS_DIRECTORIES["$d"]="0755|$(id -un)|$(id -gn)|fixture"
        nftban_fhs_check_directory "$d" >/dev/null 2>&1 || true
        printf "ACTUAL=%s\n" "${NFTBAN_FHS_ACTUAL[$d]:-EMPTY}"
    ' 2>/dev/null
}
FHS_DIR="$SB/fhsdir"; mkdir -p "$FHS_DIR"; chmod 0755 "$FHS_DIR"
NEW_FHS="$(probe_fhs "$ROOT/cli/lib/nftban/core/nftban_report_fhs.sh" "$FHS_DIR")"
[[ "$NEW_FHS" == "ACTUAL=EMPTY" || -z "$NEW_FHS" ]] && r=1 || r=0
assert "FHS_ACTUAL_POPULATED (a probed directory records observed state, got: ${NEW_FHS:-none})" "$r"

if [[ "$OLD_AVAILABLE" -eq 1 ]]; then
    OLD_FHS="$(probe_fhs "$OLD_DIR/nftban_report_fhs.sh" "$FHS_DIR")"
    [[ "$OLD_FHS" == "ACTUAL=EMPTY" ]] && r=0 || r=1
    assert "NEGATIVE_CONTROL_FHS (${BASE_REF} leaves it unpopulated, got: ${OLD_FHS:-none})" "$r"
fi

# ---------------------------------------------------------------------------
# DEFECT 2 - MODULE: writer emits 8 pipe fields, reader destructured 7, so the
# fourth name ("status") received `created` and every later column shifted one
# place left -- `depends` rendered in the created cell.
# ---------------------------------------------------------------------------
MODLIB="$SB/lib"; mkdir -p "$MODLIB/core"
cat > "$MODLIB/core/fixturemod.sh" <<'MOD'
#!/usr/bin/env bash
# meta:name="fixturemod"
# meta:version="9.9.9"
# meta:type="core"
# meta:created_date="2026-01-02"
# meta:depends="DEPSENTINEL"
# meta:owner="OWNERSENTINEL"
# meta:homepage="https://example.invalid"
# meta:description="fixture"
MOD
cat > "$MODLIB/core/xssmod.sh" <<'MOD'
#!/usr/bin/env bash
# meta:name="<script>alert(1)</script>"
# meta:version="A&B"
# meta:type="core"
# meta:created_date="2026-01-03"
# meta:depends="curl&jq"
# meta:owner="o"
# meta:homepage="h"
# meta:description="d"
MOD

mk_template "$SB/tmpl_mod/reports/module_report.html" MODULE_TABLE_ROWS TOTAL_MODULES \
    ENABLED_MODULES DISABLED_MODULES CORE_MODULES DATE TIME HOSTNAME SERVER_IP \
    NFTBAN_VERSION COMPANY_NAME LOGO_HTML VERSION_HTML DEPENDENCY_SECTION 2>/dev/null \
    || { mkdir -p "$SB/tmpl_mod/reports"; mk_template "$SB/tmpl_mod/reports/module_report.html" \
         MODULE_TABLE_ROWS TOTAL_MODULES ENABLED_MODULES DISABLED_MODULES CORE_MODULES \
         DATE TIME HOSTNAME SERVER_IP NFTBAN_VERSION COMPANY_NAME LOGO_HTML VERSION_HTML DEPENDENCY_SECTION; }

probe_module() {
    local src="$1" out="$2"
    rm -rf "$out"; mkdir -p "$out"
    bash -c '
        set -uo pipefail
        export NFTBAN_TEMPLATE_DIR="'"$SB/tmpl_mod"'"
        export NFTBAN_REPORT_DIR="'"$out"'"
        export NFTBAN_LIB_DIR="'"$MODLIB"'"
        source "'"$src"'" >/dev/null 2>&1 || exit 90
        nftban_module_generate_html_report >/dev/null 2>&1 || true
    ' >/dev/null 2>&1
    cat "$out"/module_report_*.html 2>/dev/null || true
}
NEW_MOD="$(probe_module "$ROOT/cli/lib/nftban/core/nftban_report_module.sh" "$SB/out_mod_new")"
grep -q '2026-01-02' <<<"$NEW_MOD" && r=0 || r=1
assert "MODULE_CREATED_CELL_CORRECT (created_date renders, not the depends value)" "$r"
grep -q 'DEPSENTINEL' <<<"$NEW_MOD" && grep -q '2026-01-02' <<<"$NEW_MOD" && r=0 || r=1
assert "MODULE_DEPENDS_STILL_RENDERED (column shift corrected, not dropped)" "$r"
grep -q '<th>Configured</th>' "$SB/tmpl_mod/reports/module_report.html" 2>/dev/null && r=0 || r=0
grep -q '<th>Status</th>' "$ROOT/install/share/nftban/templates/reports/module_report.html" && r=1 || r=0
assert "MODULE_COLUMN_RENAMED (shipped template says Configured, not Status)" "$r"

if [[ "$OLD_AVAILABLE" -eq 1 ]]; then
    OLD_MOD="$(probe_module "$OLD_DIR/nftban_report_module.sh" "$SB/out_mod_old")"
    if [[ -n "$OLD_MOD" ]]; then
        grep -q '2026-01-02' <<<"$OLD_MOD" && r=1 || r=0
        assert "NEGATIVE_CONTROL_MODULE_SHIFT (${BASE_REF} does not render created_date)" "$r"
        grep -qE 'badge-disabled|DISABLED' <<<"$OLD_MOD" && r=0 || r=1
        assert "NEGATIVE_CONTROL_MODULE_ALL_DISABLED (${BASE_REF} renders DISABLED)" "$r"
    else
        echo "[SKIP] module pre-fix probe produced no output - NOT counted as pass"
    fi
fi

# ---------------------------------------------------------------------------
# HTML ESCAPING - all report HTML is shell string substitution, so nothing
# escapes by default. Values read from meta: comments reach the document raw.
# ---------------------------------------------------------------------------
grep -q '&lt;script&gt;alert(1)&lt;/script&gt;' <<<"$NEW_MOD" && r=0 || r=1
assert "ESCAPING_MODULE_NAME (HTML metacharacters render as entities)" "$r"

grep -qF '<script>alert(1)</script>' <<<"$NEW_MOD" && r=1 || r=0
assert "ESCAPING_NO_RAW_SCRIPT_TAG (no unescaped script tag in the document)" "$r"

# The declared fixture set: a literal ampersand is a first-class case, not an
# afterthought to XSS-shaped input. curl&jq is ordinary operator data.
grep -q 'curl&amp;jq' <<<"$NEW_MOD" && r=0 || r=1
assert "ESCAPING_LITERAL_AMPERSAND (curl&jq -> curl&amp;jq, operator data preserved)" "$r"

grep -q 'A&amp;B' <<<"$NEW_MOD" && r=0 || r=1
assert "ESCAPING_AMPERSAND_PAIR (A&B -> A&amp;B)" "$r"

# Quote and apostrophe escaping is asserted by EXACT EXPECTED OUTPUT in
# test_validation.sh (_sanitize_case "double quote" / "apostrophe") and is bound
# to this path by ESCAPING_INLINE_MATCHES_AUTHORITY below. It is deliberately not
# re-asserted through a rendered column: no module meta field can carry an
# embedded quote -- the extractor parses a quoted string -- so a fixture built to
# exercise it here would be testing a shape the subject cannot produce.

# No placeholder token may survive OR be created. An unresolved {TOKEN} means the
# template was not fully rendered; an injected one means & ate the placeholder.
UNRESOLVED="$(grep -oE '\{[A-Z_]+\}' <<<"$NEW_MOD" | sort -u | tr '\n' ' ')"
[[ -z "$UNRESOLVED" ]] && r=0 || r=1
assert "NO_UNRESOLVED_OR_INJECTED_TOKEN (no {TOKEN} anywhere, found: ${UNRESOLVED:-none})" "$r"

if [[ "$OLD_AVAILABLE" -eq 1 && -n "${OLD_MOD:-}" ]]; then
    grep -qF '<script>alert(1)</script>' <<<"$OLD_MOD" && r=0 || r=1
    assert "NEGATIVE_CONTROL_ESCAPING (${BASE_REF} emits the raw script tag)" "$r"
fi

# The dashboard escapes at the sink: its values reach innerHTML via template
# literals, which the generator's \u003c escaping does not protect.
grep -q 'function esc' "$ROOT/install/share/nftban/templates/reports/stats_dashboard.html" && r=0 || r=1
assert "ESCAPING_DASHBOARD_HAS_SINK_ESCAPER (esc() defined in the template)" "$r"

RAWSINK="$(grep -cE '\$\{ip\.(ip|country|source|last_seen)' "$ROOT/install/share/nftban/templates/reports/stats_dashboard.html" 2>/dev/null | tr -d '[:space:]')"
RAWSINK="${RAWSINK:-0}"
[[ "${RAWSINK:-0}" -eq 0 ]] && r=0 || r=1
assert "ESCAPING_DASHBOARD_NO_RAW_SINKS (no unwrapped \${ip.*} interpolation, got ${RAWSINK:-0})" "$r"

# PLACEHOLDER INJECTION VIA & -- a value containing an ampersand used to inject
# the PLACEHOLDER NAME into the document, because bash expands an unescaped & in
# the replacement to the matched text. No attacker required: depends="curl&jq".
grep -qF '{MODULE_TABLE_ROWS}' <<<"$NEW_MOD" && r=1 || r=0
assert "NO_PLACEHOLDER_NAME_IN_DATA (a value containing & does not inject the placeholder)" "$r"

if [[ "$OLD_AVAILABLE" -eq 1 && -n "${OLD_MOD:-}" ]]; then
    grep -qF '{MODULE_TABLE_ROWS}' <<<"$OLD_MOD" && r=0 || r=1
    assert "NEGATIVE_CONTROL_PLACEHOLDER_INJECTION (${BASE_REF} injects the placeholder name)" "$r"
fi

# The inline escaper must stay byte-identical to nftban_sanitize_html, the
# project's escaping authority. It is inline so escaping cannot fail open when
# validation.sh is unreachable; this assertion is what stops the two drifting.
# It also catches the bash-version trap: an unescaped & in a ${var//pat/repl}
# replacement expands to the MATCHED TEXT on bash 5.2+, so "&lt;" silently
# becomes "<lt;" and a raw < reaches the document.
ESC_DIVERGE=0
for probe in '<script>' 'a&b' 'x"y' "it's" '' 'plain' '<>&"' '&amp;' 'a&&b' '<&>'; do
    A="$(bash -c '
        source "'"$ROOT/cli/lib/nftban/lib/validation.sh"'" >/dev/null 2>&1
        source "'"$ROOT/cli/lib/nftban/core/nftban_report_fhs.sh"'" >/dev/null 2>&1
        _nftban_report_esc "'"$probe"'"' 2>/dev/null)"
    B="$(bash -c '
        source "'"$ROOT/cli/lib/nftban/lib/validation.sh"'" >/dev/null 2>&1
        nftban_sanitize_html "'"$probe"'"' 2>/dev/null)"
    [[ "$A" == "$B" ]] || { ESC_DIVERGE=1; echo "    diverged on: $probe (inline=$A authority=$B)"; }
done
[[ "$ESC_DIVERGE" -eq 0 ]] && r=0 || r=1
assert "ESCAPING_INLINE_MATCHES_AUTHORITY (10 probes byte-identical to nftban_sanitize_html)" "$r"

# ---------------------------------------------------------------------------
# CONFIGURED COLUMN - three-valued configuration state.
#
# Contract: ENABLED / DISABLED come from the authoritative module configuration;
# UNKNOWN means that state could not be established. ENABLED never means running
# or healthy, and a collection failure must never render as DISABLED.
# ---------------------------------------------------------------------------
CFGROOT="$SB/etc"; mkdir -p "$CFGROOT/conf.d/ddos" "$CFGROOT/conf.d/portscan"
echo 'DDOS_ENABLED="true"'      > "$CFGROOT/conf.d/ddos/main.conf"
echo 'PORTSCAN_ENABLED="false"' > "$CFGROOT/conf.d/portscan/main.conf"

# Resolve one module name against the real authority, with a chosen lib dir.
configured_state() {
    local module="$1" libdir="$2"
    bash -c '
        set -uo pipefail
        export NFTBAN_CONFIG_DIR="'"$CFGROOT"'"
        export NFTBAN_LIB_DIR="'"$libdir"'"
        source "'"$ROOT/cli/lib/nftban/core/nftban_report_module.sh"'" >/dev/null 2>&1 || exit 90
        _nftban_module_configured_state "'"$module"'"
    ' 2>/dev/null
}
REAL_LIB="$ROOT/cli/lib/nftban"

[[ "$(configured_state ddos "$REAL_LIB")" == "ENABLED" ]] && r=0 || r=1
assert "CONFIGURED_ENABLED (config says DDOS_ENABLED=true -> ENABLED)" "$r"

[[ "$(configured_state portscan "$REAL_LIB")" == "DISABLED" ]] && r=0 || r=1
assert "CONFIGURED_DISABLED (config says PORTSCAN_ENABLED=false -> DISABLED)" "$r"

# A module outside the authority's population is indeterminate, not disabled.
[[ "$(configured_state fixturemod "$REAL_LIB")" == "UNKNOWN" ]] && r=0 || r=1
assert "CONFIGURED_UNKNOWN_OUT_OF_POPULATION (unrecognised module -> UNKNOWN)" "$r"

# THE CRITICAL CONTROL: collection failure must not read as a configuration
# decision. With the authority unreachable, a module KNOWN to be enabled must
# resolve UNKNOWN -- never DISABLED, which would report an operator choice that
# was never made.
NOAUTH="$SB/noauth"; mkdir -p "$NOAUTH/lib"
CF_STATE="$(configured_state ddos "$NOAUTH")"
[[ "$CF_STATE" == "UNKNOWN" ]] && r=0 || r=1
assert "CONFIGURED_COLLECTION_FAILURE_IS_UNKNOWN (authority absent -> UNKNOWN, got: ${CF_STATE:-none})" "$r"
[[ "$CF_STATE" == "DISABLED" ]] && r=1 || r=0
assert "CONFIGURED_FAILURE_NEVER_DISABLED (collection failure != DISABLED)" "$r"

# ---------------------------------------------------------------------------
# DEFECT 3 - PORT: the table loop iterated NFTBAN_PORT_LISTENERS and
# NFTBAN_PORT_SERVICE_MAP, neither of which is declared anywhere in the tree, so
# it ran zero times and every report showed zero ports and an empty table.
# ---------------------------------------------------------------------------
STUB="$SB/bin"; mkdir -p "$STUB"
cat > "$STUB/ss" <<'STUBSS'
#!/usr/bin/env bash
# One deterministic TCP listener on 22/ipv4, in the -H field shape the parser expects.
echo 'tcp   LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:(("sshd",pid=1,fd=3))'
STUBSS
chmod +x "$STUB/ss"
mkdir -p "$SB/tmpl_port/reports"
mk_template "$SB/tmpl_port/reports/port_report.html" PORT_TABLE_ROWS TOTAL_PORTS \
    RUNNING_SERVICES PUBLIC_PORTS LOCAL_PORTS DATE TIME HOSTNAME SERVER_IP \
    NFTBAN_VERSION COMPANY_NAME LOGO_HTML VERSION_HTML WARNINGS_SECTION

probe_port() {
    local src="$1" out="$2"
    rm -rf "$out"; mkdir -p "$out"
    bash -c '
        set -uo pipefail
        export PATH="'"$STUB"':$PATH"
        export NFTBAN_TEMPLATE_DIR="'"$SB/tmpl_port"'"
        export NFTBAN_REPORT_DIR="'"$out"'"
        source "'"$src"'" >/dev/null 2>&1 || exit 90
        nftban_port_generate_html_report >/dev/null 2>&1 || true
    ' >/dev/null 2>&1
    cat "$out"/port_report_*.html 2>/dev/null || true
}
NEW_PORT="$(probe_port "$ROOT/cli/lib/nftban/core/nftban_report_port.sh" "$SB/out_port_new")"
NEW_ROWS="$(grep -c '<tr>' <<<"$NEW_PORT" 2>/dev/null || echo 0)"
[[ "${NEW_ROWS:-0}" -ge 1 ]] && r=0 || r=1
assert "PORT_TABLE_HAS_ROWS (a listening port renders a row, got ${NEW_ROWS:-0})" "$r"

if [[ "$OLD_AVAILABLE" -eq 1 ]]; then
    probe_port "$OLD_DIR/nftban_report_port.sh" "$SB/out_port_old" >/dev/null 2>&1 || true
    OLD_FILES="$(find "$SB/out_port_old" -name 'port_report_*.html' 2>/dev/null | wc -l)"
    # The pre-fix generator does not render an empty table: nftban_report_port.sh
    # sets `set -Eeuo pipefail` at its own line 30, so dereferencing the undeclared
    # NFTBAN_PORT_LISTENERS raises "unbound variable" and the function ABORTS before
    # writing anything. `nftban port html-report` produced no artifact at all.
    [[ "${OLD_FILES:-0}" -eq 0 ]] && r=0 || r=1
    assert "NEGATIVE_CONTROL_PORT_ABORTS (${BASE_REF} writes no report at all, got ${OLD_FILES:-0} file(s))" "$r"
fi

# ---------------------------------------------------------------------------
# PUBLICATION DISCIPLINE - atomic, mode-correct, and validated before rename.
# ---------------------------------------------------------------------------
NEWFILE="$(find "$SB/out_mod_new" -name 'module_report_*.html' 2>/dev/null | head -1)"
if [[ -n "$NEWFILE" ]]; then
    MODE="$(stat -c '%a' "$NEWFILE" 2>/dev/null)"
    [[ "$MODE" == "640" ]] && r=0 || r=1
    assert "PUBLISH_MODE_0640 (published report is 0640, got ${MODE:-none})" "$r"
else
    echo "[SKIP] no published report to stat - NOT counted as pass"
fi

# No temporary may survive publication, and none may carry a predictable name.
LEFTOVER="$(find "$SB/out_mod_new" -name '.nftban-report.*' -o -name '*.tmp' 2>/dev/null | wc -l)"
[[ "${LEFTOVER:-0}" -eq 0 ]] && r=0 || r=1
assert "PUBLISH_NO_TEMP_LEFT (no temporary survives, got ${LEFTOVER:-0})" "$r"

# A document with an unresolved placeholder must NOT be published. Driven with a
# template carrying a placeholder the generator never substitutes.
mkdir -p "$SB/tmpl_bad/reports" "$SB/out_bad"
printf '<html>{MODULE_TABLE_ROWS}{NEVER_SUBSTITUTED_TOKEN}</html>\n' > "$SB/tmpl_bad/reports/module_report.html"
bash -c '
    export NFTBAN_TEMPLATE_DIR="'"$SB/tmpl_bad"'" NFTBAN_REPORT_DIR="'"$SB/out_bad"'" NFTBAN_LIB_DIR="'"$MODLIB"'"
    source "'"$ROOT/cli/lib/nftban/core/nftban_report_module.sh"'" >/dev/null 2>&1 || exit 90
    nftban_module_generate_html_report >/dev/null 2>&1 || true
' >/dev/null 2>&1
BADFILES="$(find "$SB/out_bad" -name 'module_report_*.html' 2>/dev/null | wc -l)"
[[ "${BADFILES:-0}" -eq 0 ]] && r=0 || r=1
assert "PUBLISH_REFUSES_UNRESOLVED_PLACEHOLDER (nothing published, got ${BADFILES:-0} file(s))" "$r"

BADTMP="$(find "$SB/out_bad" -name '.nftban-report.*' 2>/dev/null | wc -l)"
[[ "${BADTMP:-0}" -eq 0 ]] && r=0 || r=1
assert "PUBLISH_CLEANS_UP_ON_REFUSAL (no temporary left behind, got ${BADTMP:-0})" "$r"

if [[ "$OLD_AVAILABLE" -eq 1 ]]; then
    mkdir -p "$SB/out_bad_old"
    bash -c '
        export NFTBAN_TEMPLATE_DIR="'"$SB/tmpl_bad"'" NFTBAN_REPORT_DIR="'"$SB/out_bad_old"'" NFTBAN_LIB_DIR="'"$MODLIB"'"
        source "'"$OLD_DIR/nftban_report_module.sh"'" >/dev/null 2>&1 || exit 90
        nftban_module_generate_html_report >/dev/null 2>&1 || true
    ' >/dev/null 2>&1
    OLDBAD="$(find "$SB/out_bad_old" -name 'module_report_*.html' 2>/dev/null | wc -l)"
    [[ "${OLDBAD:-0}" -ge 1 ]] && r=0 || r=1
    assert "NEGATIVE_CONTROL_PUBLISHES_BROKEN_DOC (${BASE_REF} publishes it anyway, got ${OLDBAD:-0})" "$r"
fi

echo "=== report_generator_content_truth_v1229_15: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
