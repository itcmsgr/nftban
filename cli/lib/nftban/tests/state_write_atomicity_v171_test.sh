#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.171 state-write atomicity (§4.2/§4.3/§3.6) call-site lock
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="state_write_atomicity_v171_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-10"
# meta:description="Locks the v1.171 daemon-Go atomicity conversions so a future edit cannot regress them back to torn-on-crash raw writes. §4.2: suricata cache.go snapshot writes via safety.SafeWriteFile (no raw os.WriteFile on snapshotPath). §4.3a-c: limits.go SaveProtectionState/FilterState/PermanentBans use SafeWriteFile (no raw os.WriteFile on the three *StateFile/PermanentBansFile). §4.3d: panel_loader.go writes PanelStateFile via SafeWriteFile (no os.Create streaming). §3.6: daemon_init.go reconcile setNames seeds the ssh_ports counter. The atomic MECHANISM itself is proven by the Go test internal/safety/atomic_write_v171_test.go. Hermetic: greps repo source read-only; no build, no host, no root."
# meta:input="None (reads repo Go source read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="internal/suricata/stats/cache.go,internal/safety/limits.go,internal/ports/panel_loader.go,cmd/nftband/daemon_init.go"
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
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

CACHE="$REPO_ROOT/internal/suricata/stats/cache.go"
LIMITS="$REPO_ROOT/internal/safety/limits.go"
PANEL="$REPO_ROOT/internal/ports/panel_loader.go"
DINIT="$REPO_ROOT/cmd/nftband/daemon_init.go"
for f in "$CACHE" "$LIMITS" "$PANEL" "$DINIT"; do [[ -f "$f" ]] || { echo "missing: $f"; exit 1; }; done

echo "=== §4.2 suricata cache snapshot is atomic ==="
if grep -qE 'safety\.SafeWriteFile\(c\.snapshotPath' "$CACHE"; then ok "cache.go snapshot → SafeWriteFile"; else no "cache.go snapshot not SafeWriteFile"; fi
if grep -qE 'os\.WriteFile\(c\.snapshotPath' "$CACHE"; then no "cache.go still raw os.WriteFile(snapshotPath)"; else ok "cache.go: no raw os.WriteFile(snapshotPath)"; fi

echo "=== §4.3a-c safety state files are atomic ==="
for v in ProtectionStateFile FilterStateFile PermanentBansFile; do
  if grep -qE "SafeWriteFile\($v" "$LIMITS"; then ok "limits.go $v → SafeWriteFile"; else no "limits.go $v not SafeWriteFile"; fi
  if grep -qE "os\.WriteFile\($v" "$LIMITS"; then no "limits.go still raw os.WriteFile($v)"; fi
done

echo "=== §4.3d panel state file is atomic (no streamed os.Create) ==="
if grep -qE 'SafeWriteFile\(PanelStateFile' "$PANEL"; then ok "panel_loader.go → SafeWriteFile(PanelStateFile)"; else no "panel_loader.go not SafeWriteFile"; fi
if grep -qE 'os\.Create\(PanelStateFile' "$PANEL"; then no "panel_loader.go still os.Create(PanelStateFile) (non-atomic stream)"; else ok "panel_loader.go: no os.Create(PanelStateFile)"; fi

echo "=== §3.6 daemon seeds ssh_ports counter on startup ==="
if grep -qE '"ssh_ports"' "$DINIT"; then ok "daemon_init.go setNames includes ssh_ports"; else no "daemon_init.go setNames omits ssh_ports"; fi

echo "================================================================"
echo "state_write_atomicity_v171_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
