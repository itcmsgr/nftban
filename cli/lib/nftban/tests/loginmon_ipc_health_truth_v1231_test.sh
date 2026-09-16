#!/usr/bin/env bash
# =============================================================================
# NFTBan - the LoginMon IPC check may only say OK if it actually probed
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="loginmon-ipc-health-truth-v1231-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="loginmon_ipc_health_truth_v1231_test"
# meta:ta.owner="health"
# meta:ta.module="login-monitor"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="P1S-D (v1.231.0). nftban_health_check_login_monitor_ipc exists to detect that the Go LoginMon cannot ban IPs, and reported OK in exactly that condition. Two defects compounded: (1) status was initialised to HEALTH_OK and the IPC probe was skipped unless a grep matched, so config-unreadable, key-absent, module-disabled and probe-passed all rendered 'Login Monitor IPC .......... OK'; (2) the grep read the WRONG KEY FROM THE WRONG FILE — NFTBAN_LOGIN_MONITOR_ENABLED in conf.d/login/main.conf, which ships LOGIN_ENABLED and never defined that key — so the probe essentially never ran. NFTBAN_LOGIN_MONITOR_ENABLED is declared in the central /etc/nftban/nftban.conf and read by the Go loader into cfg.LoginMonitorEnabled; internal/nftbanconf/loader.go:342 records that the two facts are deliberately NOT aliased, and the identical grep was already corrected in cli/sbin/nftban under V127 UX-1 while this check was never migrated. AUTHORITY: the subject is the GO LoginMon inside nftband.service that bans over nftband.sock, NOT the cursor-driven shell-classic monitor gated by LOGIN_ENABLED — same feature name, different runtime authority, and this test pins that distinction so a future 'simplification' back to the conf.d gate fails. Drives the check through six states with a stubbed systemctl/stat and a real unix socket, and asserts OK is reachable ONLY from a probe that ran and passed."
# meta:inventory.files="cli/lib/nftban/core/nftban_health_checks_services.sh,cli/lib/nftban/core/nftban_health_render.sh,cli/lib/nftban/core/nftban_health.sh"
# meta:inventory.binaries="bash,awk,python3"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== loginmon_ipc_health_truth_v1231 ==="

HS="$ROOT/cli/lib/nftban/core/nftban_health_checks_services.sh"
HR="$ROOT/cli/lib/nftban/core/nftban_health_render.sh"
HC="$ROOT/cli/lib/nftban/core/nftban_health.sh"
for f in "$HS" "$HR" "$HC"; do [[ -f "$f" ]] || { echo "  FATAL: $f missing"; exit 2; }; done
command -v python3 >/dev/null 2>&1 || { echo "  FATAL: python3 needed to create a unix socket"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

fn(){ awk -v f="$2" '$0 ~ "^[[:space:]]*"f"\\(\\)[[:space:]]*\\{"{d=1}
      d{print; n=gsub(/\{/,"{"); m=gsub(/\}/,"}"); depth+=n-m; if(depth<=0&&NR>1)exit}' "$1"; }

# ⛔ SUBJECT-EXECUTION GUARD: every arm reads captured stdout, and a subject
#    that failed to extract produces the same empty output as one that printed
#    nothing. Without this the whole file could pass while testing nothing.
    # v1.231.0: DRAIN, never `| grep -q`. grep -q exits on the first MATCH, the producer
    # takes SIGPIPE, and pipefail reports 141 — a SUCCESSFUL match read as failure. These
    # arms are POSITIVE, so the inversion fails a healthy tree rather than passing a broken
    # one; a flaky red in the lane's own evidence is still a defect, and the first arm here
    # is the vacuity guard.
if fn "$HS" nftban_health_check_login_monitor_ipc | grep -F 'NFTBAN_HEALTH_RESULTS' >/dev/null; then
    ok "subject extracted from source (arms below are not vacuous)"
else
    no "could not extract nftban_health_check_login_monitor_ipc"
    echo "  FATAL: refusing to report on a subject that never executed"; exit 2
fi

# drive <daemon_active> <nftban.conf body|-> <conf.d/login body|-> <socket:yes|no> <sockgroup> <sockmode>
# Emits: "rc|result|render|issues"
drive(){
    local d_active="$1" main_conf="$2" login_conf="$3" want_sock="$4" sgrp="$5" smode="$6"
    local w; w="$(mktemp -d "$WORK/case.XXXXXX")"
    mkdir -p "$w/etc/conf.d/login" "$w/run"
    [[ "$main_conf"  != "-" ]] && printf '%s\n' "$main_conf"  > "$w/etc/nftban.conf"
    [[ "$login_conf" != "-" ]] && printf '%s\n' "$login_conf" > "$w/etc/conf.d/login/main.conf"
    if [[ "$want_sock" == "yes" ]]; then
        python3 -c "
import socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.bind('$w/run/nftband.sock')
" 2>/dev/null || { echo "SOCKFAIL|||"; return; }
    fi
    {
        echo 'set -uo pipefail'
        echo 'HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2; HEALTH_CRITICAL=3; HEALTH_DISABLED=5'
        echo 'declare -A NFTBAN_HEALTH_RESULTS; declare -A NFTBAN_HEALTH_ISSUES'
        echo 'NFTBAN_HEALTH_ERRORS=()'
        if [[ "$d_active" == "yes" ]]; then
            echo 'systemctl() { return 0; }'
        else
            echo 'systemctl() { return 3; }'
        fi
        # stat is stubbed so socket ownership is a controlled INPUT, not an
        # accident of whatever uid/gid runs CI.
        printf 'stat() { case "$1" in -c) case "$2" in %%a) printf %s;; %%G) printf %s;; esac;; esac; }\n' "$smode" "$sgrp"
        echo "NFTBAN_CONFIG_DIR='$w/etc'"
        echo "NFTBAN_RUN_DIR='$w/run'"
        fn "$HS" "nftban_health_check_login_monitor_ipc"
        cat <<'DRV'
nftban_health_check_login_monitor_ipc; rc=$?
r="${NFTBAN_HEALTH_RESULTS[login_monitor_ipc]:-MISSING}"
case "$r" in 0) t=OK;; 1) t=WARNING;; 2) t=ERROR;; 3) t=CRITICAL;; 5) t=DISABLED;; *) t=UNKNOWN;; esac
printf '%s|%s|%s|%s\n' "$rc" "$r" "$t" "${NFTBAN_HEALTH_ISSUES[login_monitor_ipc]:-}"
DRV
    } > "$w/h.sh"
    bash "$w/h.sh" 2>/dev/null | tail -1
}

GO_ON='NFTBAN_LOGIN_MONITOR_ENABLED="true"'
GO_OFF='NFTBAN_LOGIN_MONITOR_ENABLED="false"'
CLASSIC='LOGIN_ENABLED="true"'

echo "--- A. OK is reachable ONLY from a probe that ran and passed ---"
r=$(drive yes "$GO_ON" "$CLASSIC" yes nftban 660); t=$(echo "$r" | cut -d'|' -f3)
[[ "$t" == "OK" ]] && ok "A1 enabled + socket present + 660 nftban -> OK (the one legitimate OK)" \
                   || no "A1 a healthy IPC path no longer reports OK" "$r"

r=$(drive yes "$GO_ON" "$CLASSIC" no nftban 660); t=$(echo "$r" | cut -d'|' -f3)
[[ "$t" == "ERROR" ]] && ok "A2 enabled + socket MISSING -> ERROR (the reproduced false green)" \
                      || no "A2 LoginMon cannot ban and the check did not say ERROR" "$r"

r=$(drive yes "$GO_ON" "$CLASSIC" yes wheel 660); t=$(echo "$r" | cut -d'|' -f3)
[[ "$t" == "WARNING" ]] && ok "A3 enabled + socket wrong group -> WARNING" \
                        || no "A3 wrong socket group not surfaced" "$r"

echo "--- B. every path that does NOT probe is reported as not-evaluated ---"
r=$(drive no "$GO_ON" "$CLASSIC" no nftban 660); t=$(echo "$r" | cut -d'|' -f3); i=$(echo "$r" | cut -d'|' -f4)
if [[ "$t" != "OK" && "$i" == *"not active"* ]]; then
    ok "B1 daemon inactive -> $t, reason stated (not OK)"
else
    no "B1 daemon inactive still reports OK / no reason" "$r"
fi

r=$(drive yes "$GO_OFF" "$CLASSIC" no nftban 660); t=$(echo "$r" | cut -d'|' -f3); i=$(echo "$r" | cut -d'|' -f4)
if [[ "$t" != "OK" && -n "$i" ]]; then
    ok "B2 LoginMon disabled -> $t, reason stated (not OK)"
else
    no "B2 disabled module reported OK" "$r"
fi

# The motivating case: the gate cannot be established at all.
r=$(drive yes "-" "$CLASSIC" no nftban 660); t=$(echo "$r" | cut -d'|' -f3); i=$(echo "$r" | cut -d'|' -f4)
if [[ "$t" == "WARNING" && "$i" == *UNDETERMINED* ]]; then
    ok "B3 gate unreadable -> WARNING/UNDETERMINED (an unread config is not a healthy one)"
else
    no "B3 an unestablished gate did not surface as UNDETERMINED" "$r"
fi

echo "--- C. the right authority is consulted (Go, not shell-classic) ---"
# conf.d/login/main.conf carries the SHELL-CLASSIC gate. On its own it must not
# enable the Go IPC probe, and it must not be mistaken for the Go gate.
r=$(drive yes "-" 'NFTBAN_LOGIN_MONITOR_ENABLED="true"' no nftban 660); t=$(echo "$r" | cut -d'|' -f3)
if [[ "$t" != "ERROR" ]]; then
    ok "C1 the Go gate is NOT read from conf.d/login/main.conf (rendered $t)"
else
    no "C1 the check still reads the Go gate out of the shell-classic config"
fi
r=$(drive yes "$CLASSIC" "$CLASSIC" no nftban 660); t=$(echo "$r" | cut -d'|' -f3)
if [[ "$t" != "ERROR" ]]; then
    ok "C2 LOGIN_ENABLED alone does not activate the Go IPC probe (rendered $t)"
else
    no "C2 shell-classic LOGIN_ENABLED was treated as the Go gate"
fi
# An UNQUOTED value must still parse. The old `cut -d'"' -f2` returned the whole
# line here, so a legitimately-enabled module read as "not true".
r=$(drive yes 'NFTBAN_LOGIN_MONITOR_ENABLED=true' "$CLASSIC" no nftban 660); t=$(echo "$r" | cut -d'|' -f3)
[[ "$t" == "ERROR" ]] && ok "C3 unquoted gate value parses as enabled (probe runs)" \
                      || no "C3 an unquoted but enabled gate was not honoured" "$r"

echo "--- D. the verdict survives rendering and error accounting ---"
if awk '/for check in binaries/,/esac/' "$HR" | grep -F '5) status_text="DISABLED"' >/dev/null; then
    ok "D1 the SYSTEM CHECKS render loop knows code 5 (was rendered 'UNKNOWN')"
else
    no "D1 code 5 still renders as UNKNOWN in the SYSTEM CHECKS loop"
fi
if grep -A3 'nftban_health_check_login_monitor_ipc ||' "$HC" | grep -F '5' >/dev/null; then
    ok "D2 not-evaluated (5) is not counted as an IPC error at the dispatch site"
else
    no "D2 the dispatch site still counts not-evaluated as an error"
fi

echo "--- E. structural: OK must not be the fall-through default ---"
BODY="$(fn "$HS" nftban_health_check_login_monitor_ipc)"
# Comments are allowed (and required) to NAME the wrong path in order to
# explain it. Only EXECUTABLE lines are the subject here, so strip comment
# lines before asserting — otherwise the rationale would trip its own guard.
BODY_CODE="$(printf '%s\n' "$BODY" | sed 's/[[:space:]]*#.*$//')"
if printf '%s' "$BODY_CODE" | grep -q 'NFTBAN_LOGIN_MONITOR_ENABLED' \
   && ! printf '%s' "$BODY_CODE" | grep -q "conf\.d/login"; then
    ok "E1 no executable line reads the Go gate from the shell-classic path"
else
    no "E1 the shell-classic config path is back in the Go gate lookup" \
       "$(printf '%s' "$BODY_CODE" | grep -n 'conf\.d/login' | head -2 | tr '\n' ' ')"
fi
if printf '%s' "$BODY" | grep -q '_skip_reason'; then
    ok "E2 a stated reason accompanies every non-probed verdict"
else
    no "E2 the not-evaluated reason was removed"
fi

echo
echo "=== PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
