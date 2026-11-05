#!/usr/bin/env bash
# =============================================================================
# NFTBan - boot set contents before the network (v1.236 RC-7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="boot_content_v1236_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-04"
# meta:description="Hermetic test of nftban-boot-early.sh content (nftban-boot-content.service): loads the renderer's durable set contents with nft -f only when NFTBan is enabled and the ip nftban table is present; a disabled switch, an absent table, a refused render or a refused load loads nothing, is recorded in boot-content.state and exits 0; the private work directory is removed; the bypass state file is untouched. The unit orders after nftables.service and before network-pre.target and carries the bypass and failed-rollback conditions. nft and nftban-core are stubs."
#
# meta:inventory.files="boot_content_v1236_test.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_BOOT_STATE_DIR,NFTBAN_SERVICES_CONF,NFTBAN_CORE,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-boot-content.service"
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="boot_content_v1236_test"
# meta:ta.owner="firewall"
# meta:ta.module="boot"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
HELPER="$REPO_ROOT/install/helpers/nftban-boot-early.sh"
UNIT="$REPO_ROOT/install/systemd/nftban-boot-content.service"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

mkdir -p "$tmp/bin" "$tmp/run" "$tmp/data"
mkdir -p "$tmp/writers"
export NFTBAN_BOOT_STATE_DIR="$tmp/run" NFTBAN_SERVICES_CONF="$tmp/services.conf" \
       NFTBAN_CORE="$tmp/bin/nftban-core" NFTBAN_DATA_DIR="$tmp/data" NFTBAN_WRITERS_DIR="$tmp/writers" STUB="$tmp" \
       NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban"
cat > "$tmp/bin/nft" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB/nft.calls"
case "$1 $2" in
    "list tables") [[ -f "$STUB/unreadable" ]] && { echo "Error: Operation not permitted" >&2; exit 1; }
                   echo "table inet filter"; [[ -f "$STUB/table_present" ]] && printf 'table ip nftban\ntable ip6 nftban\n'; exit 0 ;;
    "-f "*)        cp "$2" "$STUB/loaded.nft"; [[ -f "$STUB/load_fails" ]] && { echo "Error: No such file or directory" >&2; exit 1; }; exit 0 ;;
esac
exit 0
S
cat > "$tmp/bin/nftban-core" <<'S'
#!/usr/bin/env bash
[[ "$*" == "ruleset content" ]] || { echo "unexpected args: $*" >&2; exit 1; }
rc=$(cat "$STUB/render_rc" 2>/dev/null || echo 0)
if [[ "$rc" != 0 ]]; then echo "refused before any change: oversized" >&2; exit "$rc"; fi
echo 'add element ip nftban blacklist_manual_ipv4 { 192.0.2.10 }'
echo "RULESET_CONTENT elements=1 carried=0 expired=0 exempt=0 omitted=0 sets=[blacklist_manual_ipv4=1]" >&2
S
chmod 755 "$tmp/bin/nft" "$tmp/bin/nftban-core"
export PATH="$tmp/bin:$PATH"
echo 'NFTBAN_ENABLED="true"' > "$tmp/services.conf"
echo "outcome=primary" > "$tmp/run/boot-bypass.state"

run() { : > "$tmp/nft.calls"; rm -f "$tmp/loaded.nft" "$tmp/run/boot-content.state"; bash "$HELPER" content > "$tmp/out" 2>&1; }
state() { sed -n 's/^outcome=//p' "$tmp/run/boot-content.state"; }

# 1. enabled + table present -> the renderer's contents are loaded with nft -f
touch "$tmp/table_present"; run || fail "success path exit $?"
[[ "$(state)" == content-loaded ]] || fail "success: outcome=$(state)"
grep -q 'blacklist_manual_ipv4 { 192.0.2.10 }' "$tmp/loaded.nft" || fail "success: renderer output not loaded"
grep -q 'RULESET_CONTENT elements=1' "$tmp/run/boot-content.state" || fail "success: summary not recorded"
[[ -z "$(ls -A "$tmp/data")" ]] || fail "success: work directory left behind: $(ls -A "$tmp/data")"
pass "enabled + table present: contents loaded, summary recorded, work dir removed"

# 2. disabled stored choice -> nothing rendered or loaded
echo 'NFTBAN_ENABLED="false"' > "$tmp/services.conf"; run || fail "disabled exit $?"
[[ "$(state)" == content-skipped ]] && ! grep -q '^-f' "$tmp/nft.calls" || fail "disabled: outcome=$(state) calls=$(cat "$tmp/nft.calls")"
echo 'NFTBAN_ENABLED="true"' > "$tmp/services.conf"
pass "disabled: skipped, nothing loaded"

# 3. table absent (inert or bypassed projection) -> nothing loaded
rm -f "$tmp/table_present"; run || fail "no-table exit $?"
[[ "$(state)" == content-skipped ]] && ! grep -q '^-f' "$tmp/nft.calls" || fail "no table: outcome=$(state)"
touch "$tmp/table_present"
pass "no ip nftban table: skipped, nothing loaded"

# 3b. ruleset unreadable (typed probe CANNOT_READ) -> not treated as absent, nothing loaded, recorded
touch "$tmp/unreadable"; run || fail "unreadable exit $?"
[[ "$(state)" == content-failed ]] && ! grep -q '^-f' "$tmp/nft.calls" || fail "unreadable: outcome=$(state)"
grep -q 'not readable' "$tmp/run/boot-content.state" || fail "unreadable: reason not recorded"
rm -f "$tmp/unreadable"
pass "ruleset unreadable: CANNOT_READ recorded, nothing loaded"

# 4. renderer refused -> nothing loaded, recorded, exit 0
echo 3 > "$tmp/render_rc"; run || fail "refused exit $?"
[[ "$(state)" == content-refused ]] && ! grep -q '^-f' "$tmp/nft.calls" || fail "refused: outcome=$(state)"
grep -q 'oversized' "$tmp/run/boot-content.state" || fail "refused: reason not recorded"
rm -f "$tmp/render_rc"
pass "renderer refused: nothing loaded, reason recorded, exit 0"

# 5. nft -f refused -> recorded, exit 0 (boot never blocked)
touch "$tmp/load_fails"; run || fail "load-failed exit $?"
[[ "$(state)" == content-failed ]] || fail "load failed: outcome=$(state)"
rm -f "$tmp/load_fails"
pass "load refused: recorded, exit 0"

# 6. the bypass record is never overwritten by this mode
[[ "$(cat "$tmp/run/boot-bypass.state")" == "outcome=primary" ]] || fail "boot-bypass.state was modified"
pass "boot-bypass.state untouched"

# 7. unit: ordering and hold conditions
grep -qx 'After=local-fs.target systemd-tmpfiles-setup.service nftables.service nftban-boot-normal.service nftban-commit-confirm-boot.service' "$UNIT" || fail "unit: After="
grep -qx 'Before=network-pre.target nftband.socket nftband.service' "$UNIT" || fail "unit: Before="
grep -qx 'Wants=network-pre.target' "$UNIT" || fail "unit: Wants=network-pre.target"
grep -qx 'ConditionKernelCommandLine=!nftban=disabled' "$UNIT" || fail "unit: bypass condition"
grep -qx 'ConditionPathExists=!/var/lib/nftban/state/commit-confirm.rollback-failed' "$UNIT" || fail "unit: D10 condition"
grep -qx 'ExecStart=/usr/lib/nftban/helpers/nftban-boot-early.sh content' "$UNIT" || fail "unit: ExecStart"
pass "unit: after nftables.service, before network-pre.target, held by bypass and D10"
echo "ALL PASS"
