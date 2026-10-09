#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - I3: the sendmail probe in MTA detection is bounded
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="mail_detect_probe_bounded_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-09"
# meta:description="I3 (Ubuntu 26.04 status/health 120 s timeout), reproduced 2026-10-09 in an ubuntu:26.04 container: nftban status -> mail status summary -> nftban_mail_detect_mta ran `sendmail -bv root` on a Postfix-compat sendmail with no running master; its postdrop child waited forever on the pickup socket. Drives the REAL nftban_mail_detect_mta with a fake sendmail that never answers and leaves a waiting child (postdrop shape): detection must return within the bound, must not report sendmail, and must leave no waiting child. Unchanged: a sendmail whose -bv answers is still detected as sendmail. v1.235 owner order (status/health must not queue or send mail): --passive detection never invokes the transport (recording fake), treats the compat wrapper of a stopped Postfix as no transport, the active control still probes, and every read-only caller (status, health, stats, metrics, mail status/help, mail test --dry-run) passes --passive. Hermetic: fake binaries in a temp dir, systemctl/pgrep stubbed, no mail, no network."
# meta:input="None"
# meta:output="PASS/FAIL per arm; exit 1 on any failure"
# meta:depends="bash,timeout"
# meta:inventory.files=""
# meta:inventory.binaries="bash,timeout,sleep"
# meta:inventory.env_vars="NFTBAN_SENDMAIL_BIN,NFTBAN_POSTFIX_BIN,NFTBAN_EXIM_BIN,NFTBAN_EXIM4_BIN,NFTBAN_MSMTP_BIN,NFTBAN_MAILX_BIN,NFTBAN_MAILX_ALT_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="mail_detect_probe_bounded_v1235_test"
# meta:ta.owner="comms"
# meta:ta.module="mail"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
MAIL="$REPO/cli/lib/nftban/core/nftban_mail.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
WORK="$(mktemp -d)"; trap 'pkill -f "$WORK/" 2>/dev/null; rm -rf "$WORK"' EXIT

# A sendmail that never answers -bv and leaves a waiting child, like postdrop.
cat > "$WORK/sendmail-hang" <<EOF
#!/bin/bash
sleep 600 &
echo \$! > "$WORK/child.pid"
wait
EOF
printf '#!/bin/sh\nexit 0\n' > "$WORK/sendmail-ok"
# Records every invocation: any line in $WORK/invoked means a transport was run.
printf '#!/bin/sh\necho "$*" >> "%s/invoked"\nexit 0\n' "$WORK" > "$WORK/sendmail-rec"
printf '#!/bin/sh\nexit 0\n' > "$WORK/postfix-stopped"
chmod +x "$WORK/sendmail-hang" "$WORK/sendmail-ok" "$WORK/sendmail-rec" "$WORK/postfix-stopped"

detect() {  # <sendmail binary> [mode arg] [postfix binary] -> prints "<method> <elapsed_s>"
    mkdir -p "$WORK/data" "$WORK/etc/conf.d" "$WORK/run" "$WORK/log"
    env -i PATH="/usr/bin:/bin" HOME="$WORK" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" \
        NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" \
        NFTBAN_SENDMAIL_BIN="$1" NFTBAN_POSTFIX_BIN="${3:-$WORK/none}" NFTBAN_EXIM_BIN="$WORK/none" \
        NFTBAN_EXIM4_BIN="$WORK/none" NFTBAN_MSMTP_BIN="$WORK/none" NFTBAN_MAILX_BIN="$WORK/none" \
        NFTBAN_MAILX_ALT_BIN="$WORK/none" \
        timeout 60 bash -c '
            source "$1" >/dev/null 2>&1 || true
            set +e +u +o pipefail
            systemctl() { return 1; }; pgrep() { return 1; }
            s=$(date +%s); m=$(nftban_mail_detect_mta $2 2>/dev/null); e=$(date +%s)
            echo "$m $((e - s))"' _ "$MAIL" "${2:-}"
}

echo "=== I3: bounded sendmail probe ==="
rc=0; out=$(detect "$WORK/sendmail-hang") || rc=$?
m=${out%% *}; t=${out##* }
if [[ $rc -eq 0 && -n "$t" && "$t" -le 15 ]]; then ok "detection returns within the bound with a hanging sendmail (${t}s)"
else no "detection did not return within the bound (rc=$rc out='$out'; the unbounded probe hangs)"; fi
[[ "$m" != "sendmail" ]] && ok "a sendmail that never answers is not reported as usable (got '$m')" \
    || no "a hanging sendmail was reported as the MTA"
sleep 1
cp=$(cat "$WORK/child.pid" 2>/dev/null || true)
if [[ -n "$cp" ]] && kill -0 "$cp" 2>/dev/null; then no "the waiting child (postdrop shape) was left running (pid $cp)"
else ok "no waiting child left behind"; fi

out=$(detect "$WORK/sendmail-ok"); m=${out%% *}
[[ "$m" == "sendmail" ]] && ok "unchanged: a sendmail whose -bv answers is still detected" \
    || no "a working sendmail is no longer detected (got '$out')"

echo "=== v1.235: read-only paths never run a transport (sendmail -bv queues mail on Postfix) ==="
rm -f "$WORK/invoked"
out=$(detect "$WORK/sendmail-rec" --passive); m=${out%% *}
[[ ! -s "$WORK/invoked" ]] && ok "passive detection never invoked sendmail" \
    || no "passive detection invoked sendmail: $(cat "$WORK/invoked")"
[[ "$m" == "sendmail" ]] && ok "passive: a sendmail binary without Postfix is reported as detected" \
    || no "passive: a plain sendmail binary is not reported (got '$out')"
rm -f "$WORK/invoked"
out=$(detect "$WORK/sendmail-hang" --passive "$WORK/postfix-stopped"); m=${out%% *}; t=${out##* }
[[ "$m" != "sendmail" && -n "$t" && "$t" -le 2 ]] && ok "passive: the compat wrapper of a stopped Postfix is not a transport, no wait (${t}s, got '$m')" \
    || no "passive: stopped-Postfix wrapper reported or waited (got '$out')"
rm -f "$WORK/invoked"
detect "$WORK/sendmail-rec" >/dev/null
grep -q -- '-bv' "$WORK/invoked" 2>/dev/null && ok "control: active detection (send paths) still runs the bounded probe" \
    || no "control: active detection did not probe — the passive arm above would be vacuous"

# Every read-only caller must request passive detection (status, health, stats, metrics,
# mail status/help, mail test --dry-run). A call without --passive there runs the probe.
LIB="$REPO/cli/lib/nftban"
chk() {  # <file> <function> : the detect call inside <function> passes --passive
    local body
    body=$(awk -v f="$2" '$0 ~ "^"f"\\(\\)" {p=1} p {print} p && /^}/ {exit}' "$1")
    if [[ -z "$body" ]]; then no "$2 not found in ${1#$REPO/}"; return; fi
    if grep -q 'nftban_mail_detect_mta' <<<"$body" && ! grep 'nftban_mail_detect_mta' <<<"$body" | grep -v 'declare -F' | grep -qv -- '--passive'; then
        ok "$2 uses passive detection"
    else
        no "$2 calls nftban_mail_detect_mta without --passive"
    fi
}
chk "$LIB/cli/cmd_status.sh" _status_section_communication
chk "$LIB/core/nftban_health_checks_modules.sh" nftban_health_check_communication
chk "$LIB/core/nftban_mail.sh" nftban_mail_check_status
chk "$LIB/core/nftban_mail.sh" nftban_mail_test_dryrun
chk "$LIB/core/nftban_mail.sh" nftban_mail_show_help
grep -q '&& nftban_mail_detect_mta --passive 2>/dev/null || true' "$LIB/cli/cmd_stats.sh" \
    && ok "cmd_stats uses passive detection" || no "cmd_stats calls nftban_mail_detect_mta without --passive"
grep -q 'transport_selected="$(nftban_mail_detect_mta --passive' "$LIB/core/nftban_mail.sh" \
    && ok "metrics writer uses passive detection" || no "metrics writer calls nftban_mail_detect_mta without --passive"

echo ""
echo "=== mail_detect_probe_bounded_v1235: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
