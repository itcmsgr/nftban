#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.178.0 - BotScan read-authority collector (B1) tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_read_authority_v178_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Locks the v1.178-A BotScan read-authority B1 design: the separate privileged read-collector (cli/sbin/nftban-botscan-collector) and the scanner spool-first wiring. Hermetic (non-root, no CAP): the collector runs against fixtures the test user can read (proving the read→spool→scanner pipeline), with a test-only allowlist override. Covers collect-to-spool, allowlist enforcement, symlink-escape rejection, regular-file-only, incremental new-bytes, spool byte cap, spool mode 0640, MAX_FILES cap, scanner spool-first + fallback, and unit-hardening invariants (scanner stays User=nftban+NNP+RestrictSUIDSGID and capless; collector carries CAP_DAC_READ_SEARCH on its OWN unit). Real DAC-denial (nftban cannot read but the cap can) is proven in lab, not here."
# meta:input="None (builds temp fixtures)"
# meta:output="Pass/fail; exit 0 all-pass, 1 on any failure"
# meta:depends="bash,realpath,stat,tail,mkfifo"
# meta:inventory.files="cli/sbin/nftban-botscan-collector,cli/lib/nftban/core/nftban_botscan.sh,install/systemd/nftban-botscan.service,install/systemd/nftban-botscan-collector.service"
# meta:inventory.binaries="realpath,stat,tail,mkfifo"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,BOTSCAN_SPOOL_DIR,NFTBAN_BOTSCAN_COLLECTOR_OFFSET_DIR,NFTBAN_BOTSCAN_COLLECTOR_ALLOW_ROOTS,BOTSCAN_LOG_PATHS,BOTSCAN_COLLECTOR_MAX_FILES,BOTSCAN_COLLECTOR_SPOOL_MAX_BYTES"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="botscan_read_authority_v178_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-read-authority-collector"
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
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
COLLECTOR="$REPO/cli/sbin/nftban-botscan-collector"
CORE="$REPO/cli/lib/nftban/core/nftban_botscan.sh"
SCANNER_UNIT="$REPO/install/systemd/nftban-botscan.service"
COLLECTOR_UNIT="$REPO/install/systemd/nftban-botscan-collector.service"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ALLOW="$WORK/logs"; SPOOL="$WORK/spool"; OFF="$WORK/off"
mkdir -p "$ALLOW" "$WORK/outside"

# run_collector: invoke the collector against fixtures with a test-only allowlist.
run_collector(){
  NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" \
  BOTSCAN_SPOOL_DIR="$SPOOL" \
  NFTBAN_BOTSCAN_COLLECTOR_OFFSET_DIR="$OFF" \
  NFTBAN_BOTSCAN_COLLECTOR_ALLOW_ROOTS="$ALLOW" \
  BOTSCAN_LOG_PATHS="$1" \
  ${2:+BOTSCAN_COLLECTOR_MAX_FILES=$2} \
  ${3:+BOTSCAN_COLLECTOR_SPOOL_MAX_BYTES=$3} \
  bash "$COLLECTOR" 2>&1 || true
}
spool_of(){ printf '%s/%s' "$SPOOL" "$(realpath -- "$1" | tr '/' '_')"; }

echo "=== v1.178-A BotScan read-authority (collector + spool-first) ==="

# T1: collector reads an allowlisted fixture → spool file with content.
printf '203.0.113.7 - - [x] "GET /a HTTP/1.1" 200 1\n203.0.113.7 - - [x] "POST /xmlrpc.php HTTP/1.1" 200 1\n' > "$ALLOW/site.log"
run_collector "$ALLOW/*.log" >/dev/null
sf="$(spool_of "$ALLOW/site.log")"
[[ -f "$sf" ]] && grep -q 'xmlrpc.php' "$sf" && ok "T1 collector reads allowlisted source → spool populated" || no "T1 collect→spool" "sf=$sf"

# T2: candidate OUTSIDE the allowlist is skipped (not spooled).
printf 'secret\n' > "$WORK/outside/evil.log"
out="$(run_collector "$WORK/outside/*.log")"
[[ ! -f "$(spool_of "$WORK/outside/evil.log")" ]] && echo "$out" | grep -q 'outside-allowlist' && ok "T2 outside-allowlist source skipped + audited" || no "T2 allowlist enforce" "$out"

# T3: symlink-escape — link inside allowlist resolving OUTSIDE is rejected.
ln -s "$WORK/outside/evil.log" "$ALLOW/escape.log"
out="$(run_collector "$ALLOW/escape.log")"
[[ ! -f "$(spool_of "$WORK/outside/evil.log")" ]] && echo "$out" | grep -qE 'outside-allowlist|not-regular' && ok "T3 symlink-escape rejected (canonical path outside allowlist)" || no "T3 symlink escape" "$out"
rm -f "$ALLOW/escape.log"

# T4: non-regular (fifo) candidate rejected.
mkfifo "$ALLOW/fifo.log" 2>/dev/null || true
run_collector "$ALLOW/fifo.log" >/dev/null
[[ ! -f "$(spool_of "$ALLOW/fifo.log")" ]] && ok "T4 non-regular (fifo) skipped" || no "T4 fifo skip"
rm -f "$ALLOW/fifo.log"

# T5: incremental — second run emits only NEW bytes.
rm -rf "$SPOOL" "$OFF"; printf '203.0.113.7 - - [x] "GET /first HTTP/1.1" 200 1\n' > "$ALLOW/inc.log"
run_collector "$ALLOW/inc.log" >/dev/null
printf '203.0.113.7 - - [x] "GET /second HTTP/1.1" 200 1\n' >> "$ALLOW/inc.log"
run_collector "$ALLOW/inc.log" >/dev/null
sf="$(spool_of "$ALLOW/inc.log")"
[[ "$(grep -c first "$sf")" -eq 1 && "$(grep -c second "$sf")" -eq 1 ]] && ok "T5 incremental: new bytes appended once (no re-read of old)" || no "T5 incremental" "$(cat "$sf" 2>/dev/null)"

# T6: v1.209.3 — the per-file blind `tail -c` trim is REMOVED (it desynced the
# scanner's byte-offset cursor). A source larger than the legacy per-file cap is now
# spooled WITHOUT being shortened; bounding moved to the total-dir cap + reaping
# (covered by botscan_spool_oom_v2093_test.sh). Lock in the removal: the spool keeps
# the full source (NOT trimmed to the old 512-byte cap).
rm -rf "$SPOOL" "$OFF"; yes '203.0.113.7 - - [x] "GET / HTTP/1.1" 200 1' 2>/dev/null | head -c 5200 > "$ALLOW/big.log" || true   # head closes → yes SIGPIPE; pipefail-safe
printf '\n' >> "$ALLOW/big.log"
NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" BOTSCAN_SPOOL_DIR="$SPOOL" \
  NFTBAN_BOTSCAN_COLLECTOR_OFFSET_DIR="$OFF" NFTBAN_BOTSCAN_COLLECTOR_ALLOW_ROOTS="$ALLOW" \
  BOTSCAN_LOG_PATHS="$ALLOW/big.log" BOTSCAN_COLLECTOR_SPOOL_MAX_BYTES=512 \
  bash "$COLLECTOR" >/dev/null 2>&1 || true
sf="$(spool_of "$ALLOW/big.log")"
sz="$(stat -c %s "$sf" 2>/dev/null || echo 0)"
[[ "$sz" -ge 5000 ]] && ok "T6 per-file blind trim removed — full source spooled (size=$sz, not cursor-desyncing trim)" || no "T6 trim-removed" "size=$sz (expected ≥5000)"

# T7: spool file mode 0640.
rm -rf "$SPOOL" "$OFF"; printf '203.0.113.7 - - [x] "GET / HTTP/1.1" 200 1\n' > "$ALLOW/mode.log"; run_collector "$ALLOW/mode.log" >/dev/null
m="$(stat -c %a "$(spool_of "$ALLOW/mode.log")" 2>/dev/null || echo '')"
[[ "$m" == "640" ]] && ok "T7 spool file mode 0640" || no "T7 spool mode" "mode=$m"

# T8: scanner SPOOL-FIRST — discover returns spool files when spool populated.
rm -rf "$SPOOL" "$OFF"; printf '203.0.113.7 - - [x] "GET / HTTP/1.1" 200 1\n' > "$ALLOW/s1.log"; run_collector "$ALLOW/s1.log" >/dev/null
# shellcheck source=/dev/null
( export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" BOTSCAN_SPOOL_DIR="$SPOOL"
  # shellcheck source=/dev/null
  source "$CORE" >/dev/null 2>&1
  nftban_botscan_load_config >/dev/null 2>&1 || true
  got="$(nftban_botscan_discover_logs 2>/dev/null)"
  [[ "$got" == "$SPOOL"/* ]] && exit 0 || { echo "got=$got"; exit 1; }
) && ok "T8 scanner spool-first: discover returns spool when populated" || no "T8 spool-first"

# T9: scanner FALLBACK — empty spool → does NOT return spool paths (falls back).
rm -rf "$SPOOL"; mkdir -p "$SPOOL"
( export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" BOTSCAN_SPOOL_DIR="$SPOOL"
  # shellcheck source=/dev/null
  source "$CORE" >/dev/null 2>&1
  nftban_botscan_load_config >/dev/null 2>&1 || true
  got="$(BOTSCAN_LOG_PATHS="$ALLOW/s1.log" nftban_botscan_discover_logs 2>/dev/null || true)"
  [[ "$got" != "$SPOOL"/* ]] && exit 0 || { echo "got=$got"; exit 1; }
) && ok "T9 scanner fallback when spool empty (no stale spool paths)" || no "T9 fallback"

# T10: MAX_FILES cap.
rm -rf "$SPOOL" "$OFF"; for i in 1 2 3 4; do printf '203.0.113.7 - - [x] "GET / HTTP/1.1" 200 1\n' > "$ALLOW/m$i.log"; done
out="$(run_collector "$ALLOW/m*.log" 2)"
echo "$out" | grep -q 'MAX_FILES=2' && ok "T10 MAX_FILES cap enforced + audited" || no "T10 max-files" "$out"

# T11: scanner unit stays hardened + capless.
if grep -q '^User=nftban' "$SCANNER_UNIT" && grep -q '^NoNewPrivileges=true' "$SCANNER_UNIT" && grep -q '^RestrictSUIDSGID=true' "$SCANNER_UNIT" && ! grep -q 'CAP_DAC_READ_SEARCH' "$SCANNER_UNIT"; then
  ok "T11 scanner unit: User=nftban + NNP + RestrictSUIDSGID + NO read-cap"
else no "T11 scanner unit invariants"; fi

# T12: collector unit carries the single read cap (and stays User=nftban + NNP).
if grep -q '^User=nftban' "$COLLECTOR_UNIT" && grep -q '^AmbientCapabilities=CAP_DAC_READ_SEARCH$' "$COLLECTOR_UNIT" && grep -q '^CapabilityBoundingSet=CAP_DAC_READ_SEARCH$' "$COLLECTOR_UNIT" && grep -q '^NoNewPrivileges=true' "$COLLECTOR_UNIT" && grep -q '^RestrictSUIDSGID=true' "$COLLECTOR_UNIT"; then
  ok "T12 collector unit: User=nftban + ONLY CAP_DAC_READ_SEARCH + NNP + RestrictSUIDSGID"
else no "T12 collector unit invariants"; fi

# T13: audit trail emitted (read-authority observability).
rm -rf "$SPOOL" "$OFF"; printf '203.0.113.7 - - [x] "GET / HTTP/1.1" 200 1\n' > "$ALLOW/audit.log"
out="$(run_collector "$ALLOW/audit.log")"
echo "$out" | grep -qE 'botscan-collector.*(collected|sources=)' && ok "T13 collector emits audit trail" || no "T13 audit" "$out"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
