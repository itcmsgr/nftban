#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.223.0 — mail recipient-precedence / subject / help-SIGPIPE guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="mail_recipient_subject_help_v1223_test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-21"
# meta:description="Regression guard for three mail bugs seen on panel (DirectAdmin/cPanel/Plesk) hosts: (1) `nftban mail test` must honor the configured NFTBAN_MAIL_RECIPIENT and use the panel admin email ONLY as a last-resort fallback (was: panel email overrode config, misrouting every test); (2) the DELIVERED test subject must say 'Test Email' (was: hardcoded 'Report' while the CLI printed 'Test Email'); (3) `nftban mail` help must not SIGPIPE (exit 141) under set -o pipefail from a `| head -1` inside the help heredoc. All stubbed — sends nothing."
# meta:input="repo cli/lib/nftban (read-only, sourced with stubs)"
# meta:output="pass/fail; exit 0 all-pass, 1 on regression"
# meta:depends="bash"
# meta:inventory.files="cli/lib/nftban/cli/cmd_mail.sh,cli/lib/nftban/core/nftban_mail.sh"
# meta:inventory.privileges="none"
# =============================================================================
# NOTE: intentionally NOT run under `set -Eeuo pipefail` at file scope — the
# production mail library is not written to be sourced under errexit/nounset.
# The help-SIGPIPE case (T5) enables `set -o pipefail`+errexit locally, which is
# exactly the runtime condition under which the original bug crashed.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"          # .../cli/lib/nftban
export NFTBAN_LIB_DIR="$LIB_DIR"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.223.0 mail recipient/subject/help guard ==="

# --- Stubs (defined BEFORE sourcing so load-time refs resolve) ----------------
_source_local(){ :; }                                  # skip /etc config overlay
nftban_banner(){ :; }
nftban_mail_detect_mta(){ echo "sendmail"; }
nftban_module_loaded(){ :; }
nftban_panel_get_admin_email(){ echo "panel-admin@example.com"; }   # what a panel host returns

# These production files call exit at source-time without the full nftban runtime
# (lib/strict.sh, version.sh, JSON helper, etc.). Probe in a subshell first; if they
# are not sourceable here (e.g. a bare dev box), SKIP cleanly — this test is meant to
# run in the lab/CI on an nftban host, with NFTBAN_LIB_DIR pointed at the lib tree
# under test (drop the fixed cmd_mail.sh/nftban_mail.sh into an isolated copy).
if ! ( source "$LIB_DIR/core/nftban_mail.sh" && source "$LIB_DIR/cli/cmd_mail.sh" \
       && declare -f nftban_cmd_mail >/dev/null ) >/dev/null 2>&1; then
    echo "  ⊘ SKIP: nftban runtime not sourceable here (needs installed lib env)."
    echo "         Run on an nftban host: NFTBAN_LIB_DIR=<lib-tree-with-fix> bash $0"
    exit 0
fi
# shellcheck source=/dev/null
source "$LIB_DIR/core/nftban_mail.sh" >/dev/null 2>&1
# shellcheck source=/dev/null
source "$LIB_DIR/cli/cmd_mail.sh"    >/dev/null 2>&1

# Re-declare the controlling stubs AFTER sourcing so they win over any real
# definitions the sourced files pulled in (e.g. the real nftban_panel_get_admin_email
# from nftban_panel_common.sh, which on a live panel host returns the panel address).
nftban_panel_get_admin_email(){ echo "panel-admin@example.com"; }
nftban_mail_detect_mta(){ echo "sendmail"; }
nftban_banner(){ :; }

# Capturing stub for the actual sender (defined AFTER sourcing so it wins).
CAP_RECIPIENT=""; CAP_SUBJECT=""
nftban_mail_send(){
    CAP_RECIPIENT="${2:-${NFTBAN_MAIL_RECIPIENT:-}}"
    CAP_SUBJECT="${NFTBAN_MAIL_SUBJECT_OVERRIDE:-[NFTBan] Report from host}"
    return 0
}
# helper: run `nftban mail test [arg]` in-process, echo the captured recipient|subject
run_test_capture(){ CAP_RECIPIENT=""; CAP_SUBJECT=""; nftban_cmd_mail test "$@" >/dev/null 2>&1; printf '%s|%s' "$CAP_RECIPIENT" "$CAP_SUBJECT"; }

# T1: configured NFTBAN_MAIL_RECIPIENT WINS over the panel admin email.
NFTBAN_MAIL_RECIPIENT="configured@itcms.gr"; export NFTBAN_MAIL_RECIPIENT
r="$(run_test_capture)"; got="${r%%|*}"
[[ "$got" == "configured@itcms.gr" ]] \
  && ok "T1 configured recipient wins over panel admin (no misroute)" \
  || no "T1 recipient MISROUTED to panel despite NFTBAN_MAIL_RECIPIENT set" "got=[$got]"

# T4: the DELIVERED subject says "Test Email" (uses the same run as T1).
subj="${r#*|}"
[[ "$subj" == *"Test Email"* ]] \
  && ok "T4 sent subject labeled 'Test Email' (matches on-screen)" \
  || no "T4 sent subject NOT 'Test Email'" "got=[$subj]"

# T3: an explicit CLI recipient arg still wins over everything.
r="$(run_test_capture "cli-arg@example.net")"; got="${r%%|*}"
[[ "$got" == "cli-arg@example.net" ]] \
  && ok "T3 explicit CLI recipient wins" \
  || no "T3 CLI recipient arg ignored" "got=[$got]"

# T2: with NO configured recipient AND no CLI arg, panel admin is the fallback.
unset NFTBAN_MAIL_RECIPIENT
r="$(run_test_capture)"; got="${r%%|*}"
[[ "$got" == "panel-admin@example.com" ]] \
  && ok "T2 panel admin used as fallback when nothing configured" \
  || no "T2 panel fallback broken" "got=[$got]"

# T5: `nftban mail` help must NOT SIGPIPE (exit 141) under pipefail, even when
#     nftban_mail_check_status emits MANY lines (the original crash trigger).
nftban_mail_check_status(){ printf '%s\n' "line-1-status" "line-2" "line-3" "line-4"; }
help_out="$( set -o pipefail; set -e; nftban_mail_show_help 2>&1 )"; help_rc=$?
[[ "$help_rc" -eq 0 ]] \
  && ok "T5 help renders without SIGPIPE (exit 0 under pipefail+errexit)" \
  || no "T5 help crashed (SIGPIPE/pipefail regression)" "exit=$help_rc"
grep -q "Status: line-1-status" <<<"$help_out" \
  && ok "T5b help Status shows the first status line" \
  || no "T5b help Status line missing/incorrect"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
