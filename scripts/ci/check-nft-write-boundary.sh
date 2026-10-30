#!/usr/bin/env bash
# =============================================================================
# NFTBan - nft write boundary guard (v1.236)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-nft-write-boundary"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-23"
# meta:description="v1.236 (design V1236_STAGE2_DESIGN_DRAFT.md §3.3). Every nft write made outside nftband must hold /run/nftban/nft_writers.lock EXCLUSIVE, so it can never land between a firewall replacement's kernel read and its commit. A write is covered when it goes through nftban_nft_write, when it sits in a function named *_held (run whole via nftban_writers_run), when it runs inside a section opened with nftban_writers_acquire and its line (or the line before) carries the marker 'nftban:held', or when the line itself takes the lock inline (`flock -w N .../nft_writers.lock nft ...`, scripts that run without the library). A write to a table that is never part of a replacement (a foreign table such as inet filter or the ip/ip6 raw table) is outside the boundary and must say so with the marker 'nftban:outside-boundary' on the line before. B-1 rejects any raw nft write in the CONVERTED files. B-2 is a RATCHET over the rest of the product shell: the count of raw writes is recorded in a baseline and may never increase. B-3 proves the helper still holds the lock. Static analysis only - reads files, invokes nothing."
# meta:input="cli/lib/nftban/**, cli/sbin/*, install/**, packaging/deb/*, packaging/build_nftban.sh, scripts/ci/nft-write-boundary-baseline.txt"
# meta:output="PASS/FAIL per rule; exit 0 on all-pass, 1 on any violation"
# meta:depends="bash,git,grep"
# meta:inventory.files="scripts/ci/nft-write-boundary-baseline.txt"
# meta:inventory.binaries="bash,git,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="check_nft_write_boundary"
# meta:ta.owner="cli"
# meta:ta.module="nft-write-boundary"
# meta:ta.execution_class="CI_STATIC"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO"

BASELINE="scripts/ci/nft-write-boundary-baseline.txt"
HELPER="cli/lib/nftban/lib/nft_writers.sh"

# Files whose every nft write is on the boundary. A raw write here fails outright.
CONVERTED=(
    "cli/lib/nftban/cli/cmd_firewall.sh"
    "cli/lib/nftban/cli/cmd_whitelist.sh"
    "cli/lib/nftban/cli/cmd_flush.sh"
    "cli/lib/nftban/cli/cmd_zabbix.sh"
    "cli/lib/nftban/cli/cmd_firewall_logs.sh"
    "cli/lib/nftban/lib/nft_ipc.sh"
    "cli/lib/nftban/lib/nft_fragment.sh"
    "cli/lib/nftban/lib/service_control.sh"
    "cli/lib/nftban/lib/commit_confirm.sh"
    "cli/lib/nftban/core/nftban_system_ip.sh"
    "cli/lib/nftban/core/nftban_ddos_classic.sh"
    "cli/lib/nftban/core/nftban_health_checks_security.sh"
    "cli/lib/nftban/core/nftban_health_fixes.sh"
    "cli/lib/nftban/core/nftban_firewall_conflicts.sh"
    "cli/lib/nftban/cron/maintenance.sh"
    "cli/lib/nftban/helpers/autoheal.sh"
)

# A raw mutating nft command: `nft` as a word, optional flags, then a write verb or -f.
WRITE_RE='(^|[[:space:];&|({!])nft[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*(add|insert|delete|flush|create|replace|destroy|-f)([[:space:]]|$)'

PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n         %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

scan_files(){
    git ls-files -- 'cli/lib/nftban/**/*.sh' 'cli/sbin/*' 'install/**/*.sh' \
        'packaging/deb/postinst' 'packaging/deb/postrm' 'packaging/build_nftban.sh' 2>/dev/null \
        | grep -v '/tests/' | grep -vx "$HELPER"
}

# raw_writes <file>: "file:line: text" for each uncovered raw write. Skips comments, check-only
# loads (-c), text that only mentions a command (echo/printf/log/arrays of advice), and lines
# marked nftban:held (on the line or the line before).
raw_writes(){
    awk -v f="$1" -v re="$WRITE_RE" '
        { cur = $0 }
        cur ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{.*\}[[:space:]]*$/ { fn = ""; prev = cur; next }
        cur ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/        { fn = $1 }
        cur ~ /^\}/                                              { fn = ""; prev = cur; next }
        fn ~ /_held\(\)$/ && cur ~ re                            { prev = cur; next }
        cur ~ /^[[:space:]]*#/                                   { prev = cur; next }
        cur !~ re                                                { prev = cur; next }
        cur ~ /nft[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-c/       { prev = cur; next }
        cur ~ /^[[:space:]]*(echo|printf|log|log_[a-z]+|_[a-z_]*log)[[:space:]]/ { prev = cur; next }
        cur ~ /^[[:space:]]*[A-Za-z_]+\+=\(/                     { prev = cur; next }
        cur ~ /nftban:held/ || prev ~ /nftban:held/              { prev = cur; next }
        cur ~ /flock[[:space:]]+-w[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]*nft_writers\.lock[[:space:]]+nft[[:space:]]/ { prev = cur; next }
        prev ~ /nftban:outside-boundary/                         { prev = cur; next }
        { printf "%s:%d: %s\n", f, NR, cur; prev = cur }
    ' "$1"
}

echo "=== B-1. converted files carry no raw nft write ==="
b1=0
for f in "${CONVERTED[@]}"; do
    [[ -f "$f" ]] || { no "B-1 $f exists" "converted file missing"; b1=1; continue; }
    hits=$(raw_writes "$f")
    if [[ -n "$hits" ]]; then
        no "B-1 $f routes every nft write through the boundary" \
           "raw nft write (use nftban_nft_write, or nftban_writers_acquire + 'nftban:held'):"$'\n'"$(sed 's/^/           /' <<<"$hits")"
        b1=1
    fi
done
[[ $b1 -eq 0 ]] && ok "B-1 all ${#CONVERTED[@]} converted files are on the boundary"

echo "=== B-2. remaining raw-write debt RATCHET ==="
current=0
while IFS= read -r f; do
    n=$(raw_writes "$f" | grep -c . || true)
    current=$((current + n))
done < <(scan_files)
recorded=$(awk -F= '/^RAW_NFT_WRITE_COUNT=/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' "$BASELINE" 2>/dev/null || true)
if [[ -z "$recorded" ]]; then
    no "B-2 baseline is parseable" "no RAW_NFT_WRITE_COUNT= line in $BASELINE"
elif [[ "$current" -gt "$recorded" ]]; then
    no "B-2 raw nft write debt did not increase" \
       "current=$current recorded=$recorded — $((current-recorded)) NEW raw nft write(s). Use nftban_nft_write."
elif [[ "$current" -lt "$recorded" ]]; then
    no "B-2 baseline is current" \
       "current=$current recorded=$recorded — debt was REDUCED. Lower $BASELINE to $current so the ratchet tightens."
else
    ok "B-2 raw nft write debt held at $current (ratchet: may decrease, never increase)"
fi

echo "=== B-3. the helper holds the lock exclusively and bounds its wait ==="
grep -q 'flock -w "${NFTBAN_BOUNDARY_WAIT:-60}"' "$HELPER" \
    && ok "B-3a bounded exclusive flock in $HELPER" \
    || no "B-3a bounded exclusive flock in $HELPER" "flock -w \"\${NFTBAN_BOUNDARY_WAIT:-60}\" not found"
grep -q 'nft_writers.lock' "$HELPER" \
    && ok "B-3b $HELPER locks nft_writers.lock" \
    || no "B-3b $HELPER locks nft_writers.lock" "lock path not found"

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
