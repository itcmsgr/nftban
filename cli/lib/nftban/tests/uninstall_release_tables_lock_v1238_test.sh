#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238: package uninstall removes the nftban tables under the canonical write boundary
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="uninstall_release_tables_lock_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-24"
# meta:description="v1.238 (owner 2026-11-24; audit KERNEL_WRITER_AUDIT_d016f838 V2). DEB postrm and RPM postun flush/delete the nftban tables through _nftban_release_tables, which holds /run/nftban-writers/nft_writers.lock EXCLUSIVE (bounded) instead of the unused /run/nftban/nft_writers.lock (RPM postun removed /run/nftban first). Checks: the two copies are byte-identical (RPM unescaped); no code line uses the legacy lock path; running the REAL DEB copy under sh with the lock dir redirected to a sandbox and nft replaced by a recording stub: free lock -> flush+delete ip and ip6, every nft call made while the lock is held and the intent published, own intent removed after; busy lock (another holder that publishes its own intent meanwhile) -> bounded wait, NO nft call, rc 0, WARN says the existing rules stay active (no SSH claim), the foreign intent is left intact, and the printed retry holds the same lock for both deletes (run as printed: busy -> no nft call, free -> both deletes under the lock). Sandbox only; no firewall change."
# meta:input="None (repo source read-only; temp dir)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,awk,flock"
# meta:inventory.files="packaging/deb/postrm,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,awk,flock,sh"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="uninstall_release_tables_lock_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="packaging"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DEB="$REPO/packaging/deb/postrm"; RPM="$REPO/packaging/build_nftban.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); HOLDER=""
trap '[[ -n "$HOLDER" ]] && kill "$HOLDER" 2>/dev/null; rm -rf "${W:?}"' EXIT
block(){ awk '/^# >>> NFTBAN_RELEASE_TABLES_BEGIN >>>/{c=1} c{print} /^# <<< NFTBAN_RELEASE_TABLES_END <<</{exit}' "$1"; }

echo "=== copies and call sites ==="
deb=$(block "$DEB"); rpm=$(block "$RPM" | sed 's/\\\$/$/g')
[[ -n "$deb" && "$deb" == "$rpm" ]] && ok "DEB and RPM copies are byte-identical (RPM unescaped)" || no "copies differ or missing"
legacy=$(grep -nE '^[^#]*/run/nftban/nft_writers\.lock' "$DEB" "$RPM" || true)
[[ -z "$legacy" ]] && ok "no code line uses the legacy /run/nftban/nft_writers.lock" || no "legacy lock path in code" "$legacy"
n=$(grep -cE '^[[:space:]]+_nftban_release_tables$' "$DEB"); [[ "$n" == 2 ]] && ok "DEB postrm: purge and remove both call it" || no "DEB call sites" "$n"
n=$(grep -cE '^[[:space:]]+_nftban_release_tables$' "$RPM"); [[ "$n" == 1 ]] && ok "RPM postun calls it" || no "RPM call sites" "$n"
code=$(grep -v '^[[:space:]]*#' <<<"$deb")
[[ "$code" != *"/run/nftban/"* ]] && ok "function does not depend on /run/nftban (RPM postun removes it first)" || no "uses /run/nftban"

echo "=== behaviour (REAL DEB copy under sh, sandbox lock dir, recording nft stub) ==="
SB="$W/writers"; mkdir -m 0700 "$SB"; mkdir "$W/bin"
cat > "$W/bin/nft" <<STUB
#!/bin/sh
held=free; flock -n "$SB/nft_writers.lock" true || held=held
intent=none; [ -s "$SB/nft_writers.intent" ] && intent=published
echo "\$* \$held \$intent" >> "$W/nft.log"
STUB
chmod +x "$W/bin/nft"
fn="${deb//\/run\/nftban-writers/$SB}"
run(){ # $1 wait seconds -> rc; stderr to $W/err
    local f="${fn//flock -w 60 9/flock -w $1 9}"
    : > "$W/nft.log"; local rc=0
    PATH="$W/bin:$PATH" sh -c "$f
_nftban_release_tables" 2> "$W/err" || rc=$?
    echo "$rc"
}
rc=$(run 5)
want=$'flush table ip nftban held published\ndelete table ip nftban held published\nflush table ip6 nftban held published\ndelete table ip6 nftban held published'
[[ "$rc" == 0 && "$(cat "$W/nft.log")" == "$want" ]] && ok "free: flush+delete ip and ip6, each while the lock is held and the intent published" \
    || no "free" "rc=$rc log=$(tr '\n' '|' < "$W/nft.log")"
[[ ! -e "$SB/nft_writers.intent" ]] && ok "free: own intent removed afterwards" || no "intent left (free)"
flock -n "$SB/nft_writers.lock" true && ok "free: lock released afterwards" || no "lock still held"

# Another writer holds the boundary and, while we wait, publishes ITS intent (overwriting ours).
FOREIGN="pid=999999 boot=foreign-writer"
flock -s "$SB/nft_writers.lock" sh -c "sleep 0.3; echo '$FOREIGN' > '$SB/nft_writers.intent'; sleep 30" & HOLDER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$SB/nft_writers.lock" true || break; sleep 0.1; done
start=$SECONDS; rc=$(run 1); el=$((SECONDS-start))
[[ "$rc" == 0 && ! -s "$W/nft.log" ]] && ok "busy: NO nft call without the lock (rc 0, removal not aborted)" || no "busy" "rc=$rc log=$(tr '\n' '|' < "$W/nft.log")"
grep -q "NOT removed; the existing nftban rules stay active" "$W/err" && ok "busy: WARN says NOT removed, existing rules stay active" || no "busy message" "$(cat "$W/err")"
grep -qi "ssh" "$W/err" && no "busy: WARN makes an SSH claim" "$(cat "$W/err")" || ok "busy: WARN makes no SSH claim"
(( el <= 5 )) && ok "busy: wait is bounded (${el}s with a 1s bound)" || no "busy wait" "${el}s"
[[ "$(cat "$SB/nft_writers.intent" 2>/dev/null)" == "$FOREIGN" ]] && ok "busy: the other writer's intent is left intact" || no "foreign intent" "$(cat "$SB/nft_writers.intent" 2>/dev/null || echo '<removed>')"
retry=$(sed -n 's/.*holding the same lock for the whole step: //p' "$W/err")
[[ "$retry" == "flock -w 60 $SB/nft_writers.lock sh -c 'nft delete table ip nftban; nft delete table ip6 nftban'" ]] \
    && ok "busy: WARN gives a retry that holds the canonical lock (flock … sh -c 'both deletes')" || no "retry text" "$retry"
# The retry, run as printed (bound shortened), while the lock is still busy: nothing runs.
: > "$W/nft.log"; rrc=0; PATH="$W/bin:$PATH" sh -c "${retry/flock -w 60/flock -w 1}" 2>/dev/null || rrc=$?
[[ "$rrc" != 0 && ! -s "$W/nft.log" ]] && ok "retry while busy: no nft call (flock rc $rrc)" || no "retry busy" "rc=$rrc log=$(tr '\n' '|' < "$W/nft.log")"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null || true; HOLDER=""
# The retry once the lock is free: both deletes run, each while the lock is held.
rm -f "$SB/nft_writers.intent"; : > "$W/nft.log"; rrc=0; PATH="$W/bin:$PATH" sh -c "$retry" 2>/dev/null || rrc=$?
[[ "$rrc" == 0 && "$(cut -d' ' -f1-5 "$W/nft.log")" == $'delete table ip nftban held\ndelete table ip6 nftban held' ]] \
    && ok "retry when free: both deletes run, each under the same lock" || no "retry free" "rc=$rrc log=$(tr '\n' '|' < "$W/nft.log")"

# Success path with a pre-existing stale intent of someone else: replaced by ours, ours removed.
echo "$FOREIGN" > "$SB/nft_writers.intent"; rc=$(run 5)
[[ "$rc" == 0 && ! -e "$SB/nft_writers.intent" ]] && ok "success: own intent removed" || no "own intent" "rc=$rc $(cat "$SB/nft_writers.intent" 2>/dev/null)"

echo "=== non-vacuity ==="
old=$(git -C "$REPO" show origin/main:packaging/deb/postrm 2>/dev/null | grep -c 'flock -w 60 /run/nftban/nft_writers.lock nft' || true)
if [[ -n "$old" && "$old" != 0 ]]; then ok "main's postrm locked the legacy path ($old lines)"; else echo "  - (origin/main not available; non-vacuity reference skipped)"; fi

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
