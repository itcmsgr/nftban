#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.227 Lane-1 — MAIL-F2 subject authority (producers no longer mislabel "Report")
# =============================================================================
# meta:name="mail_subject_authority_v1227_test"
# meta:type="test"
# meta:version="1.227.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="MAIL-F2: report/alert producers set NFTBAN_MAIL_SUBJECT_OVERRIDE before nftban_mail_send so each report is delivered with an honest, path-specific subject instead of the generic default. Behavioral proof via the emulate sink (the override reaches the resolved subject; without it, the default 'Report from' subject is used) + static coverage that every enumerated producer send carries a non-empty override."
# meta:input="None (sources nftban_mail.sh read-only + greps producer sources; emulate transport, no network)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,jq,mktemp"
# meta:inventory.files="cli/lib/nftban/core/nftban_mail.sh,cli/lib/nftban/cli/cmd_fhs.sh,cli/lib/nftban/cli/cmd_module.sh,cli/lib/nftban/cli/cmd_port.sh,cli/lib/nftban/cli/cmd_report.sh,cli/lib/nftban/cli/cmd_mail.sh"
# meta:inventory.binaries="bash,grep,jq,mktemp"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_SUBJECT_OVERRIDE,NFTBAN_MAIL_EMULATE_SINK"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="mail_subject_authority_v1227_test"
# meta:ta.owner="mail"
# meta:ta.module="mail-subject-authority"
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
MAIL_LIB="$ROOT/cli/lib/nftban/core/nftban_mail.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

echo "=== mail_subject_authority_v1227 ==="

# --- behavioral: the override reaches the delivered subject via the emulate sink ---
sent_subject() {
    # $1 = override value ("" = none) ; echoes the subject the send resolved to
    local override="$1" SB; SB="$(mktemp -d)"; mkdir -p "$SB/data"
    local sink="$SB/sink.jsonl"
    (
        export NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" NFTBAN_DATA_DIR="$SB/data" \
               NFTBAN_MAIL_METHOD="emulate" NFTBAN_MAIL_EMULATE_SINK="$sink" \
               NFTBAN_MAIL_VALIDATE_RECIPIENTS="NO"
        # shellcheck disable=SC1090
        source "$MAIL_LIB"
        if [[ -n "$override" ]]; then
            NFTBAN_MAIL_SUBJECT_OVERRIDE="$override" nftban_mail_send "body" "to@example.test" >/dev/null 2>&1 || true
        else
            nftban_mail_send "body" "to@example.test" >/dev/null 2>&1 || true
        fi
    )
    jq -r '.subject' "$sink" 2>/dev/null | tail -1
    rm -rf "$SB"
}

# shellcheck disable=SC2034  # consumed by assert eval
SUBJ_FHS="$(sent_subject 'NFTBan FHS Report')"
# shellcheck disable=SC2034  # consumed by assert eval
SUBJ_PORT="$(sent_subject 'NFTBan Port Report')"
# shellcheck disable=SC2034  # consumed by assert eval
SUBJ_DEFAULT="$(sent_subject '')"

assert "OVERRIDE_REACHES_SUBJECT[fhs]"        '[[ "$SUBJ_FHS" == "NFTBan FHS Report" ]]'
assert "OVERRIDE_REACHES_SUBJECT[port]"       '[[ "$SUBJ_PORT" == "NFTBan Port Report" ]]'
assert "SUBJECT_DISTINCT_PER_PATH"            '[[ "$SUBJ_FHS" != "$SUBJ_PORT" ]]'
# pre-fix behavior: with NO override the subject is the generic default ("... Report from <host>")
assert "DEFAULT_WITHOUT_OVERRIDE_IS_GENERIC"  '[[ "$SUBJ_DEFAULT" == *"Report from"* ]]'
assert "OVERRIDDEN_SUBJECT_NOT_THE_GENERIC"   '[[ "$SUBJ_FHS" != *"Report from"* ]]'

# --- static coverage: every enumerated producer send carries a non-empty override ---
# file : expected number of overridden nftban_mail_send producer sites
declare -A EXPECT=(
  ["cli/lib/nftban/cli/cmd_fhs.sh"]=2
  ["cli/lib/nftban/cli/cmd_module.sh"]=11
  ["cli/lib/nftban/cli/cmd_port.sh"]=2
  ["cli/lib/nftban/cli/cmd_report.sh"]=1
  ["cli/lib/nftban/cli/cmd_mail.sh"]=1
  ["cli/lib/nftban/core/nftban_report_email.sh"]=1
  ["cli/lib/nftban/core/nftban_portscan_suricata.sh"]=1
  ["cli/lib/nftban/core/nftban_portscan_classic.sh"]=1
)
for f in "${!EXPECT[@]}"; do
    want="${EXPECT[$f]}"
    # shellcheck disable=SC2034  # consumed by assert eval
    got=$(grep -cE 'NFTBAN_MAIL_SUBJECT_OVERRIDE="[^"]+" nftban_mail_send ' "$ROOT/$f" || true)
    assert "COVERAGE[$(basename "$f")]=$want" '[[ "$got" -ge "$want" ]]'
    # no override may be empty
    if grep -qE 'NFTBAN_MAIL_SUBJECT_OVERRIDE="" nftban_mail_send' "$ROOT/$f"; then
        bad "EMPTY_OVERRIDE in $(basename "$f")"
    fi
done

echo ""
echo "=== mail_subject_authority_v1227: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
