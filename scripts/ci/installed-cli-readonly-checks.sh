#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# NFTBan v1.235 - read-only CLI checks against the INSTALLED package
# =============================================================================
# meta:name="installed-cli-readonly-checks"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="GATE-CLI-INSTALLED-PACKAGE-ONLY-RUNS-VERSION (v1.235 batch C). The package install jobs ran only `nftban version` against the installed package; every other CLI test ran from the source tree. This runs read-only commands through the installed entry point (/usr/sbin/nftban, as root): help (rc 0, usage text), status --json (one valid JSON object after the dispatcher's '# NFTBAN_CMD_EXIT' lines), status (text, non-empty), health brief (non-empty). status and health may return a verdict code 0-2 (a container has no nftables kernel and no systemd); rc >= 3, a timeout, the ERR-trap banner or a shell/Go crash pattern is a FAIL. Each check prints its verdict; exit 1 if any FAILED."
# meta:inventory.files=""
# meta:inventory.binaries="bash,timeout,grep,jq,mktemp,sed"
# meta:inventory.env_vars="NFTBAN_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="none"
# meta:inventory.privileges="root"
# =============================================================================
# errexit is off on purpose: every check records its own verdict.
set -uo pipefail
NFTBAN="${NFTBAN_BIN:-/usr/sbin/nftban}"
# Crash signatures only. "No such file or directory" is NOT here: a container
# legitimately lacks /run/nftban, nft state and systemd, and the CLI reports that.
FATAL='ERROR: Script failed|unbound variable|command not found|syntax error|bad array subscript|panic:|nil pointer dereference|SIGSEGV'
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0

ok(){ PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
no(){ FAIL=$((FAIL + 1)); printf '[FAIL] %s — %s\n' "$1" "$2"; }
show(){ # id
    printf -- '----- %s stdout (first 40 lines) -----\n' "$1"; sed -n '1,40p' "$W/$1.out"
    printf -- '----- %s stderr (first 40 lines) -----\n' "$1"; sed -n '1,40p' "$W/$1.err"
}

# run <id> <max rc> <args...> -> sets RC; FAILs on timeout, rc > max, or a crash signature.
run(){
    local id="$1" max="$2"; shift 2
    RC=0
    timeout 120 "$NFTBAN" "$@" > "$W/$id.out" 2> "$W/$id.err" < /dev/null || RC=$?
    if [[ "$RC" -eq 124 ]]; then no "$id: nftban $*" "timed out after 120s"; show "$id"; return 1; fi
    if [[ "$RC" -gt "$max" ]]; then no "$id: nftban $*" "rc=$RC (allowed 0-$max)"; show "$id"; return 1; fi
    if grep -qE -- "$FATAL" "$W/$id.out" "$W/$id.err"; then
        no "$id: nftban $*" "crash signature: $(grep -hE -m1 -- "$FATAL" "$W/$id.out" "$W/$id.err")"
        show "$id"; return 1
    fi
    return 0
}

[[ -x "$NFTBAN" ]] || { no "R0 installed entry point" "$NFTBAN missing or not executable"; echo "RESULT: PASS=$PASS FAIL=$FAIL"; exit 1; }

if run R1 0 help; then
    if grep -qiE 'usage|commands' "$W/R1.out"; then ok "R1: nftban help (rc 0, usage text, no crash)"
    else no "R1: nftban help" "no usage text in the output"; show R1; fi
fi

if run R2 2 status --json; then
    grep -v '^#' "$W/R2.out" > "$W/R2.json" || true
    if [[ -s "$W/R2.json" ]] && jq -e 'type == "object"' "$W/R2.json" > /dev/null 2>&1; then
        ok "R2: nftban status --json (rc $RC, one valid JSON object, no crash)"
    else no "R2: nftban status --json" "rc=$RC, stdout is not one valid JSON object"; show R2; fi
fi

if run R2T 2 status; then
    if [[ -s "$W/R2T.out" ]]; then ok "R2T: nftban status (rc $RC, output present, no crash)"
    else no "R2T: nftban status" "rc=$RC, empty stdout"; show R2T; fi
fi

if run R3 2 health brief; then
    if [[ -s "$W/R3.out" ]]; then ok "R3: nftban health brief (rc $RC, output present, no crash)"
    else no "R3: nftban health brief" "rc=$RC, empty stdout"; show R3; fi
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
