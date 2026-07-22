#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.165 guard: no bare RPM section macro in a generated-spec comment
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rpm_spec_no_section_macro_in_comment_v165_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Hermetic regression guard for the twice-fatal RPM-spec-comment-macro class (v1.157 FIX_V157_PR_A_DUPLICATE_RPM_INSTALL + v1.164 PR-C revert). Ground-truth on srv2 rpm 4.16.1.3: a bare unescaped %install token anywhere in a generated-spec COMMENT (even mid-sentence, e.g. '# see %install below') is parsed by rpm 4.16/EL9+EL10 as a SECOND %install section -> 'error: line N: second %install' -> Build RPM el9/el10 fails deterministically; rpm 4.18 (lab2) + rpm 6.x are lenient and miss it. The other section macros (%prep %build %check %clean %files %post %pre %changelog %package) are tolerated in comments by rpm 4.16 but are still forbidden here defensively so the spec cannot drift toward another rpmbuild-only failure. Statically lints the spec heredoc inside packaging/build_nftban.sh; no rpmbuild, no host - runs on lab2 and in CI before the expensive el9/el10 build."
# meta:inventory.files="packaging/build_nftban.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rpm_spec_no_section_macro_in_comment_v165_test"
# meta:ta.owner="packaging"
# meta:ta.module="rpm-spec"
# meta:ta.execution_class="PACKAGE_BUILD"
# meta:ta.gate="policy-gates"
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
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
BS="$REPO_ROOT/packaging/build_nftban.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$BS" ]] || { echo "build_nftban.sh not found at $BS"; exit 1; }

# Canonical RPM section macros (no-arg script sections + scriptlets + manifest).
# Longer tokens first so the alternation is unambiguous; a trailing negative
# lookahead for an ASCII letter keeps '%prefix'/'%description'-substrings honest.
SECTIONS='install|prep|build|check|clean|files|changelog|package|description|posttrans|postun|post|pretrans|preun|pre|verifyscript|triggerpostun|triggerin|triggerun|trigger|sepolicy'

# extract_heredoc: print the body of the nftban-core.spec heredoc only
# (between `... <<EOF` that targets nftban-core.spec and the next bare `EOF`).
extract_heredoc(){
    awk '
        /SPECS\/nftban-core\.spec/ && /<<EOF/ { grab=1; next }
        grab && /^EOF$/            { exit }
        grab                       { print }
    ' "$1"
}

# scan_comment_violations <file>: print "section macro in a spec COMMENT" hits.
# A comment line starts with optional whitespace then '#'. We flag an UNescaped
# '%<section>' (not '%%...', not '%{...}') with no trailing ASCII letter.
scan_comment_violations(){
    extract_heredoc "$1" \
        | grep -nE '^[[:space:]]*#' \
        | grep -P "(?<!%)%(${SECTIONS})(?![A-Za-z])" || true
}

# scan_stray_install <file>: every UNescaped '%install' token in the heredoc
# that is NOT the single canonical section header line.
scan_stray_install(){
    extract_heredoc "$1" \
        | grep -nP '(?<!%)%install(?![A-Za-z])' \
        | grep -vE '^[0-9]+:%install[[:space:]]*$' || true
}

echo "rpm-spec comment-macro guard (v1.165):"

# --- (1) the spec heredoc is actually found -----------------------------------
body_lines=$(extract_heredoc "$BS" | wc -l)
[[ "$body_lines" -gt 100 ]] \
    && ok "located nftban-core.spec heredoc ($body_lines lines)" \
    || no "could not locate the nftban-core.spec heredoc (got $body_lines lines)"

# --- (2) exactly one real %install section header -----------------------------
n_install_hdr=$(extract_heredoc "$BS" | grep -cE '^%install[[:space:]]*$' || true)
[[ "$n_install_hdr" == "1" ]] \
    && ok "exactly one %install section header (got $n_install_hdr)" \
    || no "expected exactly one %install section header, got $n_install_hdr"

# --- (3) NO stray %install token anywhere else in the heredoc (proven-fatal) ---
stray=$(scan_stray_install "$BS")
if [[ -z "$stray" ]]; then
    ok "no stray unescaped %install token outside the section header"
else
    no "stray %install token(s) in the spec heredoc (rpm 4.16 -> 'second %install')" "$(printf '%s' "$stray" | head -1)"
fi

# --- (4) NO section macro in any spec comment (defensive breadth) --------------
viol=$(scan_comment_violations "$BS")
if [[ -z "$viol" ]]; then
    ok "no bare RPM section macro in any generated-spec comment"
else
    no "section macro(s) found in spec comment(s) — reword or %%-escape" "$(printf '%s' "$viol" | head -1)"
    printf '%s\n' "$viol" | sed 's/^/      /'
fi

# --- (5) self-test: the detector must FLAG a planted regression ----------------
# Copy the build script, inject a poisoned comment INSIDE the heredoc, and assert
# the scanner catches it (so a future real %install-in-comment cannot pass mute).
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
awk '
    { print }
    /SPECS\/nftban-core\.spec/ && /<<EOF/ { print "# poisoned regression probe: see %install sandbox note" }
' "$BS" > "$tmp"
planted_install=$(scan_stray_install "$tmp")
planted_comment=$(scan_comment_violations "$tmp")
if [[ -n "$planted_install" && -n "$planted_comment" ]]; then
    ok "self-test: detector flags a planted '%install' comment (guard is live)"
else
    no "self-test FAILED: detector did NOT flag a planted '%install' comment" "install='${planted_install:-}' comment='${planted_comment:-}'"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
