#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.237 blacklist.d persistence lockfile policy (spec ↔ creator ↔ repair parity)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="blacklistd_lockfile_policy_v1237_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-15"
# meta:description="The blacklist.d/<reason>.conf.lock sibling locks (D-UXV-17, v1.237 cleanup repair) are 0600 root:root for their whole lifecycle: the canonical FHS spec declares that triple (writer-owned, install_enforce:false); internal/persistence creates every lockfile at 0600; the permission-repair consumer (perms_enforce_etc_files) excludes *.conf.lock from the 0640 root:nftban config mode and restores the spec triple with chown/chmod (in place, inode kept). A group-readable lock would let an nftban-group process take flock(LOCK_EX) on a read-only fd and stall every reason-file writer. Config files keep 0640 root:nftban. Hermetic: greps repo source read-only; no build, no host, no root."
# meta:input="None (reads repo source read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk"
# meta:inventory.files="build/fhs-spec.yaml,internal/persistence/blacklistd.go,cli/lib/nftban/core/nftban_permissions.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="blacklistd_lockfile_policy_v1237_test"
# meta:ta.owner="core"
# meta:ta.module="persistence-lock-policy"
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
GO="$REPO_ROOT/internal/persistence/blacklistd.go"
PERMS="$REPO_ROOT/cli/lib/nftban/core/nftban_permissions.sh"
for f in "$SPEC" "$GO" "$PERMS"; do [[ -f "$f" ]] || { echo "missing: $f"; exit 1; }; done

echo "=== canonical FHS spec declares the lockfile triple ==="
# The file_permissions entry whose pattern is "*.conf.lock": print its key: value lines.
block=$(awk '
  /^  - path:/ { if (inb) exit; buf=$0; next }
  /^    pattern: "\*\.conf\.lock"/ { inb=1; print buf; print; next }
  inb && /^    [a-z_]+:/ { print }
  inb && !/^    / { exit }' "$SPEC")
field(){ awk -v k="$1" '$1==k":" {gsub(/"/,"",$2); print $2; exit}' <<<"$block"; }
[[ -n "$block" ]] && ok "spec has a *.conf.lock file_permissions entry" || no "spec has no *.conf.lock entry"
s_path=$(awk '$2=="path:" {print $3; exit}' <<<"$block")
s_mode=$(field mode); s_owner=$(field owner); s_group=$(field group); s_enf=$(field install_enforce)
[[ "$s_path" == "/etc/nftban/blacklist.d" ]] && ok "path /etc/nftban/blacklist.d" || no "spec path" "got '$s_path'"
[[ "$s_mode" == "0600" && "$s_owner" == "root" && "$s_group" == "root" ]] && ok "triple 0600 root:root" || no "spec triple" "got $s_mode $s_owner:$s_group"
[[ "$s_enf" == "false" ]] && ok "writer-owned (install_enforce: false)" || no "install_enforce" "got '$s_enf'"
[[ "${s_mode:1}" =~ ^[0-7]00$ ]] && ok "no group/other bits (flock on a read-only fd)" || no "group/other bits present in $s_mode"

echo "=== creator: every persistence lockfile is opened 0600 ==="
n_lock=$(grep -cE 'lockPath := (targetFile|filePath) \+ "\.lock"' "$GO" || true)
n_0600=$(grep -cE 'OpenFile\(filepath\.Clean\(lockPath\), os\.O_RDWR\|os\.O_CREATE, 0600\)' "$GO" || true)
[[ "$n_lock" -ge 2 && "$n_lock" == "$n_0600" ]] && ok "$n_lock lockfile creators, all mode 0600 (= spec ${s_mode#0})" || no "lockfile creators" "lockPath=$n_lock open0600=$n_0600"

echo "=== repair consumer: excluded from 0640, restored to the spec triple ==="
fn=$(awk '/^perms_enforce_etc_files\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$PERMS")
[[ -n "$fn" ]] || { no "perms_enforce_etc_files not found"; fn=""; }
loop_chown=$(grep -E 'find "\$PERMS_ETC/\$subdir" -type f .*-exec chown root:nftban' <<<"$fn" || true)
loop_chmod=$(grep -E 'find "\$PERMS_ETC/\$subdir" -type f .*-exec chmod 0640' <<<"$fn" || true)
grep -qF '! -name "*.conf.lock"' <<<"$loop_chown" && ok "subdir config chown excludes *.conf.lock" || no "subdir chown root:nftban still matches lockfiles"
grep -qF '! -name "*.conf.lock"' <<<"$loop_chmod" && ok "subdir config chmod 0640 excludes *.conf.lock" || no "subdir chmod 0640 still matches lockfiles"
grep -qE "find \"\\\$PERMS_ETC/blacklist\.d\" .*-name \"\*\.conf\.lock\" -exec chown ${s_owner}:${s_group} " <<<"$fn" && ok "lockfiles restored to ${s_owner}:${s_group}" || no "no chown ${s_owner}:${s_group} for lockfiles"
grep -qE "find \"\\\$PERMS_ETC/blacklist\.d\" .*-name \"\*\.conf\.lock\" -exec chmod ${s_mode} " <<<"$fn" && ok "lockfiles restored to ${s_mode}" || no "no chmod ${s_mode} for lockfiles"
grep -qE 'blacklist\.d.*\.conf\.lock.*(\bmv\b|\bcp\b|\brm\b|install )' <<<"$fn" && no "repair replaces/removes lockfiles (inode must be kept)" || ok "repair only chown/chmod (inode kept)"
grep -qE 'find "\$PERMS_ETC/conf\.d" -type f -name "\*\.conf" -exec chmod 0640' <<<"$fn" && ok "conf.d/*.conf keep 0640 (config unchanged)" || no "conf.d config mode changed"

echo "================================================================"
echo "blacklistd_lockfile_policy_v1237_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
