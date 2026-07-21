#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.223.0 — mail recipient/subject/help fix guard (static)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="mail_recipient_subject_help_v1223_test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-21"
# meta:description="Locks three mail fixes that misbehaved on panel (DirectAdmin/cPanel/Plesk) hosts. (1) `nftban mail test` must gate the panel-admin auto-detect on BOTH an empty CLI arg AND an empty NFTBAN_MAIL_RECIPIENT, so a configured recipient is never overridden by the panel address. (2) the delivered test subject must be set via NFTBAN_MAIL_SUBJECT_OVERRIDE to 'Test Email' (was: hardcoded 'Report' while the CLI printed 'Test Email'). (3) the `nftban mail` help must NOT pipe nftban_mail_check_status into `head` inside its heredoc (SIGPIPE/exit 141 under pipefail) — it must slice a precomputed variable. Plus the setup --show Sender must expand hostname, not print a literal \$(hostname). Static guard (grep-based, like the fsync/heredoc guards) — the mail library exits at source-time without the full runtime, so behavioral coverage is provided by the lab/host validation; this locks the fix text against regression. Includes negative controls that FAIL if the original buggy patterns reappear."
# meta:input="cli/lib/nftban source (read-only)"
# meta:output="pass/fail; exit 0 all-pass, 1 on a regressed fix"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_mail.sh,cli/lib/nftban/core/nftban_mail.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"          # .../cli/lib/nftban
CM="$LIB_DIR/cli/cmd_mail.sh"
NM="$LIB_DIR/core/nftban_mail.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
have(){ grep -qF "$2" "$1"; }          # fixed-string present
lacks(){ ! grep -qF "$2" "$1"; }       # fixed-string absent

echo "=== v1.223.0 mail recipient/subject/help fix guard ==="
[[ -f "$CM" && -f "$NM" ]] || { echo "  ✗ source files not found"; exit 2; }

# T1: `mail test` panel auto-detect gated on empty CLI arg AND empty config recipient.
if have "$CM" 'if [[ -z "$recipient" && -z "${NFTBAN_MAIL_RECIPIENT:-}" ]] && declare -f nftban_panel_get_admin_email'; then
    ok "T1 panel auto-detect gated on empty NFTBAN_MAIL_RECIPIENT (config recipient wins)"
else
    no "T1 recipient-precedence fix MISSING (config recipient can be overridden by panel)"
fi
# T1-neg: the original bare form must be gone.
if grep -qE 'if \[\[ -z "\$recipient" \]\] && declare -f nftban_panel_get_admin_email' "$CM"; then
    no "T1-neg ORIGINAL bare panel-override reintroduced (panel overrides config again)"
else
    ok "T1-neg original bare panel-override removed"
fi

# T2: nftban_mail_send honors a NFTBAN_MAIL_SUBJECT_OVERRIDE (not hardcoded 'Report').
if have "$NM" 'subject="${NFTBAN_MAIL_SUBJECT_OVERRIDE:-'; then
    ok "T2 nftban_mail_send honors NFTBAN_MAIL_SUBJECT_OVERRIDE"
else
    no "T2 subject override plumbing MISSING (every mail still labeled 'Report')"
fi

# T3: send_test sets the override to a 'Test Email' subject before delivering.
if grep -qE 'NFTBAN_MAIL_SUBJECT_OVERRIDE="?\$\{NFTBAN_MAIL_SUBJECT_PREFIX.*Test Email' "$NM"; then
    ok "T3 send_test labels the delivered message 'Test Email'"
else
    no "T3 send_test does NOT set the Test Email subject override"
fi

# T4: help must NOT pipe check_status into head inside the heredoc (SIGPIPE fix).
if grep -qE 'nftban_mail_check_status 2>&1 \| head' "$NM"; then
    no "T4 help still pipes check_status | head (SIGPIPE/exit 141 under pipefail)"
else
    ok "T4 help no longer pipes check_status into head"
fi
if have "$NM" 'mail_status_line="${mail_status_line%%'; then
    ok "T4b help slices a precomputed status line (no pipe)"
else
    no "T4b precomputed mail_status_line slice MISSING"
fi

# T5: setup --show Sender expands hostname (not a literal \$(hostname)).
if grep -qE 'Sender:.*nftban@\$\(hostname' "$CM" && lacks "$CM" 'nftban@\$(hostname)'; then
    ok "T5 setup --show Sender expands hostname"
else
    no "T5 setup --show Sender still prints a literal \$(hostname)"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
