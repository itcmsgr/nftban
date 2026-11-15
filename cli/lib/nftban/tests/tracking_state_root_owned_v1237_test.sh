#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.237 permanent-ban tracking state stays root-owned (spec ↔ Go ↔ repair ↔ generated parity)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="tracking_state_root_owned_v1237_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-15"
# meta:description="Cleanup authorizes permanent removal from the tracking state, so the nftban service account must not own it (owner 2026-11-15, v1.237 acceptance condition). The canonical FHS spec declares /var/lib/nftban/permanent_bans.json root:nftban 0640 (writer-owned) and excludes it and the atomic-write temps (.nftban-safe-*) from the nftban:nftban /var/lib/nftban sweep; the Go constants name that path and mode; both hand-written repair consumers (perms_enforce_var_files, autoheal) exclude it from the service-account sweep and restore root:nftban 0640 with chown/chmod only; the generated install script carries the exclusions; no product reader uses the legacy state/ path. Hermetic: greps repo source read-only; no build, no host, no root."
# meta:input="None (reads repo source read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk"
# meta:inventory.files="build/fhs-spec.yaml,internal/safety/limits.go,internal/safety/tracking_integrity_v1237.go,cli/lib/nftban/core/nftban_permissions.sh,cli/lib/nftban/helpers/autoheal.sh,cli/lib/nftban/setup/fhs-permissions.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="tracking_state_root_owned_v1237_test"
# meta:ta.owner="core"
# meta:ta.module="tracking-state-integrity"
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
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

SPEC="$REPO_ROOT/build/fhs-spec.yaml"
LIM="$REPO_ROOT/internal/safety/limits.go"
INT="$REPO_ROOT/internal/safety/tracking_integrity_v1237.go"
PERMS="$REPO_ROOT/cli/lib/nftban/core/nftban_permissions.sh"
HEAL="$REPO_ROOT/cli/lib/nftban/helpers/autoheal.sh"
GEN="$REPO_ROOT/cli/lib/nftban/setup/fhs-permissions.sh"
for f in "$SPEC" "$LIM" "$INT" "$PERMS" "$HEAL" "$GEN"; do [[ -f "$f" ]] || { echo "missing: $f"; exit 1; }; done
TRK=/var/lib/nftban/permanent_bans.json

echo "=== canonical FHS spec ==="
block=$(awk '
  /^  - path:/ { if (inb) exit; buf=$0; next }
  /^    pattern: "permanent_bans\.json"/ { inb=1; print buf; print; next }
  inb && /^    [a-z_]+:/ { print }
  inb && !/^    / { exit }' "$SPEC")
field(){ awk -v k="$1" '$1==k":" {gsub(/"/,"",$2); print $2; exit}' <<<"$block"; }
s_path=$(awk '$2=="path:" {print $3; exit}' <<<"$block")
[[ "$s_path/permanent_bans.json" == "$TRK" ]] && ok "spec declares $TRK" || no "spec entry" "path='$s_path'"
[[ "$(field mode) $(field owner):$(field group) $(field install_enforce)" == "0640 root:nftban false" ]] && ok "spec triple 0640 root:nftban, writer-owned" || no "spec triple" "$(field mode) $(field owner):$(field group) $(field install_enforce)"
sweep=$(awk '/^  - path: \/var\/lib\/nftban$/ {f=1; next} f && /^  - path:/ {exit} f {print}' "$SPEC")
grep -qF '"/var/lib/nftban/permanent_bans.json"' <<<"$sweep" && ok "nftban:nftban sweep excludes the tracking file" || no "sweep does not exclude the tracking file"
grep -qF '"/var/lib/nftban/.nftban-safe-*"' <<<"$sweep" && ok "sweep excludes the atomic-write temps" || no "sweep does not exclude .nftban-safe-*"

echo "=== Go writer ==="
grep -qE "PermanentBansFile = \"$TRK\"" "$LIM" && ok "PermanentBansFile = $TRK" || no "Go PermanentBansFile differs"
grep -qE 'PermanentBansFileMode os\.FileMode = 0640' "$INT" && ok "written 0640" || no "Go file mode differs"
grep -qE 'SafeWriteFile\(permanentBansPath, data, PermanentBansFileMode\)' "$LIM" && ok "SavePermanentBans writes with that mode" || no "SavePermanentBans mode not the spec mode"
grep -qE 'LoadPermanentBansForCleanup' "$REPO_ROOT/cmd/nftband/daemon_cleanup_v1237.go" && ok "cleanup loads through the integrity check" || no "cleanup bypasses the integrity check"

echo "=== repair consumers ==="
fn=$(awk '/^perms_enforce_var_files\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$PERMS")
n_ex=$(grep -cF -- '-not -path "$PERMS_VAR/permanent_bans.json" -not -path "$PERMS_VAR/.nftban-safe-*"' <<<"$fn" || true)
[[ "$n_ex" -eq 2 ]] && ok "perms_enforce_var_files: both sweeps exclude it" || no "perms_enforce_var_files exclusions" "found $n_ex of 2"
grep -qF 'perms_run chown root:nftban "$PERMS_VAR/permanent_bans.json"' <<<"$fn" && grep -qF 'perms_run chmod 0640 "$PERMS_VAR/permanent_bans.json"' <<<"$fn" && ok "perms_enforce_var_files restores root:nftban 0640" || no "perms_enforce_var_files does not restore the triple"
n_h=$(grep -cF -- '-not -path "${NFTBAN_DATA_DIR}/permanent_bans.json"' "$HEAL" || true)
[[ "$n_h" -eq 2 ]] && ok "autoheal: both sweeps exclude it" || no "autoheal exclusions" "found $n_h of 2"
grep -qF 'chown root:nftban "${NFTBAN_DATA_DIR}/permanent_bans.json"' "$HEAL" && ok "autoheal restores root:nftban" || no "autoheal does not restore the owner"
if grep -qE 'permanent_bans\.json.*(\bmv\b|\bcp\b|\brm\b|install )' "$PERMS" "$HEAL"; then no "a repair consumer replaces/removes the tracking file"; else ok "repair only chown/chmod (inode kept)"; fi

echo "=== generated install script ==="
n_g=$(grep -cF -- "-not -path \"$TRK\"" "$GEN" || true)
[[ "$n_g" -eq 2 ]] && ok "fhs-permissions.sh: both /var/lib/nftban sweeps exclude it (generated)" || no "generated script exclusions" "found $n_g of 2 (regenerate: build/generate-fhs-outputs.sh)"

echo "=== no product reader of the legacy path ==="
hits=$(grep -rlF '/var/lib/nftban/state/permanent_bans.json' "$REPO_ROOT/cli/lib/nftban" --include='*.sh' --exclude-dir=tests || true)
[[ -z "$hits" ]] && ok "no shell reader uses state/permanent_bans.json" || no "legacy path still read" "$hits"

echo "================================================================"
echo "tracking_state_root_owned_v1237_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
