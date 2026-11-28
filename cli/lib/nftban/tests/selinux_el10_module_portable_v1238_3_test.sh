#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.3: the SELinux module loads on every EL10 policy, and a load failure is visible
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="selinux_el10_module_portable_v1238_3_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="BUG-SELINUX-EL10-MODULE-NOT-LOADED-SYS-RESOURCE-TYPE (v1.238.2 RC acceptance, EL10 Rocky 10.1, selinux-policy 42.1.18). MEASURED: the el10 package builds nftban.pp in almalinux:10, whose selinux-policy-devel 42.1.27 makes corecmd_exec_bin() add `typeattribute $1 sys_resource_type`; on the 42.1.18 host semodule -i fails ('Failed to resolve typeattributeset'), %post hid it (2>/dev/null || true), nftband ran without nftband_t, BotGuard apply failed (fork/exec nft: permission denied) and the upgrade ended FAILED_REBUILD. Fixed: the policy uses corecmd_exec_bin_noattr() where the policy has it and corecmd_exec_bin() otherwise (lab: built with 42.1.27 headers -> 0 sys_resource_type refs, loads on 42.1.18; EL9 38.x compiles), and %post falls back to an on-host compile in a temp dir, then prints a WARNING when the module is still not loaded. Static checks on the shipped sources; non-vacuity: v1.238.2 fails each check."
# meta:input="install/selinux/nftban.te, packaging/build_nftban.sh (repo, read-only)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk"
# meta:inventory.files="install/selinux/nftban.te,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="selinux_el10_module_portable_v1238_3_test"
# meta:ta.owner="security"
# meta:ta.module="selinux-el10-module-portable"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TE="$ROOT/install/selinux/nftban.te"; SPEC="$ROOT/packaging/build_nftban.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== policy: no attribute-adding corecmd_exec_bin() outside the noattr guard ==="
# Policy lines only (comments stripped). A bare call outside an ifdef(`corecmd_exec_bin_noattr' ...)
# block is the defect: on newer EL10 policies it adds sys_resource_type.
body=$(sed -e 's/#.*$//' "$TE")
grep -q "ifdef(\`corecmd_exec_bin_noattr'" <<<"$body" && ok "ifdef guard on corecmd_exec_bin_noattr present" || no "no ifdef guard on corecmd_exec_bin_noattr"
grep -q 'corecmd_exec_bin_noattr(nftband_t)' <<<"$body" && ok "noattr variant used for nftband_t" || no "noattr variant not used"
bare=$(awk '
    /ifdef\(`corecmd_exec_bin_noattr'"'"'/ {g=1}
    g && /^[[:space:]]*'"'"'\)[[:space:]]*$/ {g=0; next}
    !g && /corecmd_exec_bin\(/ {print NR": "$0}
' <<<"$body")
[[ -z "$bare" ]] && ok "no bare corecmd_exec_bin() outside the guard" || no "bare corecmd_exec_bin() outside the guard" "$bare"
grep -qE 'policy_module\(nftban, 1\.2\.([6-9]|[1-9][0-9])\)' "$TE" && ok "module version raised (>= 1.2.6)" || no "module version not raised"

echo "=== %post: a failed load is not silent, and the fallback compiles in a temp dir ==="
post=$(awk '/Prefer the build-shipped nftban.pp/{f=1} f{print} f&&/^fi$/{exit}' "$SPEC")
grep -qE 'semodule -i "\\\$_nftban_sel/nftban\.pp" 2>/dev/null \|\| true' <<<"$post" \
    && no "the shipped-module load still ends in '|| true' (silent)" || ok "the shipped-module load result is used"
grep -q '_nftban_sel_ok=yes' <<<"$post" && ok "load success is tracked" || no "load success not tracked"
grep -q 'NFTBan WARNING\] The NFTBan SELinux policy module was NOT loaded' <<<"$post" && ok "visible WARNING when the module is not loaded" || no "no visible WARNING"
grep -q 'mktemp -d /var/tmp/nftban-selinux' <<<"$post" && ok "fallback compiles in a temp dir" || no "fallback does not use a temp dir"
grep -qE 'case "\\\$_nftban_selw" in /var/tmp/nftban-selinux\.\*\) rm -rf' <<<"$post" && ok "temp dir removal is path-guarded" || no "temp dir removal not path-guarded"
grep -qE 'cd "\\\$_nftban_sel" && make' <<<"$post" && no "fallback still compiles inside the package directory" || ok "no compile inside the package directory"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
