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
# meta:description="I3 (Ubuntu 26.04 status/health 120 s timeout), reproduced 2026-10-09 in an ubuntu:26.04 container: nftban status -> mail status summary -> nftban_mail_detect_mta ran `sendmail -bv root` on a Postfix-compat sendmail with no running master; its postdrop child waited forever on the pickup socket. Drives the REAL nftban_mail_detect_mta with a fake sendmail that never answers and leaves a waiting child (postdrop shape): detection must return within the bound, must not report sendmail, and must leave no waiting child. Unchanged: a sendmail whose -bv answers is still detected as sendmail. Hermetic: fake binaries in a temp dir, systemctl/pgrep stubbed, no mail, no network."
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
chmod +x "$WORK/sendmail-hang" "$WORK/sendmail-ok"

detect() {  # <sendmail binary> -> prints "<method> <elapsed_s>"
    mkdir -p "$WORK/data" "$WORK/etc/conf.d" "$WORK/run" "$WORK/log"
    env -i PATH="/usr/bin:/bin" HOME="$WORK" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" \
        NFTBAN_DATA_DIR="$WORK/data" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_RUN_DIR="$WORK/run" NFTBAN_LOG_DIR="$WORK/log" \
        NFTBAN_SENDMAIL_BIN="$1" NFTBAN_POSTFIX_BIN="$WORK/none" NFTBAN_EXIM_BIN="$WORK/none" \
        NFTBAN_EXIM4_BIN="$WORK/none" NFTBAN_MSMTP_BIN="$WORK/none" NFTBAN_MAILX_BIN="$WORK/none" \
        NFTBAN_MAILX_ALT_BIN="$WORK/none" \
        timeout 60 bash -c '
            source "$1" >/dev/null 2>&1 || true
            set +e +u +o pipefail
            systemctl() { return 1; }; pgrep() { return 1; }
            s=$(date +%s); m=$(nftban_mail_detect_mta 2>/dev/null); e=$(date +%s)
            echo "$m $((e - s))"' _ "$MAIL"
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

echo ""
echo "=== mail_detect_probe_bounded_v1235: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
