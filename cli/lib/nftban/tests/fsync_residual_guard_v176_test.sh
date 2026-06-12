#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.176 — FSYNC-RESIDUAL durability-idiom CI guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="fsync_residual_guard_v176_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Locks the v1.176 FSYNC-RESIDUAL class: any hand-rolled temp+rename state writer in Go (os.Rename + CreateTemp/.tmp) OUTSIDE internal/safety must be either routed through safety.SafeWriteFile OR explicitly baselined here. FAILS on a NEW unguarded temp+rename writer (and on a regression of the v1.176-fixed set_counters.go / rebuild/marker.go, which are intentionally absent from the baseline). Pre-existing writers (13) are baselined as separate tech-debt, NOT v1.176 scope. Includes a positive-control self-test (a fixture bad file must be detected) and a negative self-test (a SafeWriteFile-style file must not)."
# meta:input="repo Go tree (read-only)"
# meta:output="pass/fail; exit 0 all-pass, 1 on a new unguarded writer"
# meta:depends="bash,grep,find,sort,comm"
# meta:inventory.files="internal/stats/set_counters.go,internal/rebuild/marker.go,internal/safety/file.go"
# meta:inventory.binaries="bash,grep,find,sort,comm,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# Detect hand-rolled temp+rename writers under <root>: a .go file (not *_test.go,
# not under internal/safety/) that contains BOTH os.Rename( AND a temp-write
# marker (CreateTemp or a "*.tmp" path). Prints repo-relative paths, sorted.
scan_temp_rename_writers() {
    local root="$1" f rel
    while IFS= read -r f; do
        case "$f" in
            *_test.go) continue ;;
            */internal/safety/*) continue ;;
        esac
        if grep -qE 'os\.Rename\(' "$f" 2>/dev/null \
           && grep -qE 'CreateTemp|\.tmp"' "$f" 2>/dev/null; then
            rel="${f#"$root"/}"
            echo "$rel"
        fi
    done < <(find "$root" -type f -name '*.go' 2>/dev/null) | sort -u
}

# -----------------------------------------------------------------------------
# BASELINE — pre-existing hand-rolled temp+rename writers (2026-06-12).
# These are SEPARATE tech debt (the "three durability idioms" sprawl), NOT in
# v1.176 scope. Adding a NEW file here requires review (prefer safety.SafeWriteFile).
# NOTE: internal/stats/set_counters.go and internal/rebuild/marker.go are
# DELIBERATELY ABSENT — v1.176 routed them through safety.SafeWriteFile, so if
# either reappears in the scan it is a REGRESSION and this guard fails.
# -----------------------------------------------------------------------------
read -r -d '' BASELINE <<'EOF' || true
cmd/nftban-core/cmd_feeds.go
cmd/nftban-core/cmd_geoip.go
internal/analytics/state.go
internal/installer/executor/real.go
internal/installer/history/history.go
internal/installer/state/file.go
internal/metrics/collector.go
internal/opqueue/source_index.go
internal/persistence/blacklistd.go
internal/rulefp/baseline.go
internal/stats/writer.go
internal/suricata/profile/applier.go
internal/suricata/stats/cache.go
internal/util/fileloader.go
EOF

echo "=== v1.176 FSYNC-RESIDUAL guard ==="

# T1: no NEW temp+rename writer outside the baseline (this is the class lock).
CURRENT="$(scan_temp_rename_writers "$REPO")"
NEWADDS="$(comm -13 <(printf '%s\n' "$BASELINE" | sort -u) <(printf '%s\n' "$CURRENT" | sort -u) | grep -vE '^$' || true)"
if [[ -z "$NEWADDS" ]]; then
    ok "T1 no NEW unguarded temp+rename writer (all current sites are baselined; route new state writers through safety.SafeWriteFile)"
else
    no "T1 NEW unguarded temp+rename writer(s) detected — route through safety.SafeWriteFile or justify+baseline" "$(echo "$NEWADDS" | tr '\n' ' ')"
fi

# T2: v1.176 regression check — the two fixed files must NOT be temp+rename writers.
if printf '%s\n' "$CURRENT" | grep -qxE 'internal/stats/set_counters\.go|internal/rebuild/marker\.go'; then
    no "T2 v1.176 FSYNC fix regressed (set_counters.go / marker.go re-introduced raw temp+rename)" "$(printf '%s\n' "$CURRENT" | grep -E 'set_counters|rebuild/marker' | tr '\n' ' ')"
else
    ok "T2 set_counters.go + rebuild/marker.go remain routed through safety.SafeWriteFile (no raw temp+rename)"
fi

# T3: positive-control self-test — a fixture introducing a temp+rename writer
# outside internal/safety MUST be detected by the scanner.
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/internal/badpkg" "$FIX/internal/safety"
cat > "$FIX/internal/badpkg/writer.go" <<'GO'
package badpkg
func bad() { _ = os.WriteFile(p+".tmp", b, 0640); _ = os.Rename(p+".tmp", p) }
GO
cat > "$FIX/internal/safety/file.go" <<'GO'
package safety
func ok() { f,_ := os.CreateTemp(d,"x"); _ = os.Rename(f.Name(), p) }
GO
SELF="$(scan_temp_rename_writers "$FIX")"
if printf '%s\n' "$SELF" | grep -qx 'internal/badpkg/writer.go'; then
    ok "T3 self-test: scanner detects a NEW temp+rename writer (positive control)"
else
    no "T3 self-test: scanner FAILED to detect a planted temp+rename writer" "scan=[$SELF]"
fi
# T4: negative self-test — an internal/safety file must NOT be flagged.
if printf '%s\n' "$SELF" | grep -qx 'internal/safety/file.go'; then
    no "T4 self-test: scanner wrongly flagged internal/safety (must be exempt)"
else
    ok "T4 self-test: internal/safety exempt (negative control)"
fi

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
