#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: exported plan/lock functions carry their callees into child shells;
#                    a failed DDoS/PortScan re-apply stays in the rebuild's final result
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="exported_function_closure_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="v1.238.2 (owner 2026-11-28, v1.238.1 RC EL9: rebuild after a PortScan mode switch). firewall rebuild runs `nftban <module> reload` as a child; the child inherits the EXPORTED nftban_module_resolve_plan, so nftban_portscan.sh/nftban_ddos.sh skip sourcing module_authority.sh and only exported functions exist. Measured: '_nftban_module_central_wins: command not found', portscan reload rc 1, yet 'Final status: IDLE (all checks passed)' rc 0. A: closure - every function exported by module_authority.sh (+ the nft_writers.sh it sources) that names another function defined there names an EXPORTED one. B: a child that only inherits runs nftban_module_effective_enabled without 'command not found' and has nftban_module_mode_unadmitted (else auto would resolve to the non-admitted suricata mode inside the child). C: non-vacuity - with the v1.238.2 export lines removed, A finds the violations and B reproduces the RC error. D: the REAL rebuild INCOMPLETE statement (extracted from cmd_firewall.sh) returns 1 and names PortScan/DDoS for a failed re-apply in runtime context, 0 for a result-file consumer or install context, 0 when all re-applies passed. E: static - the final-status line names failed module re-applies before 'all checks passed'. Sandbox only; no firewall change."
# meta:input="cli/lib/nftban/lib/module_authority.sh, cli/lib/nftban/lib/nft_writers.sh, cli/lib/nftban/cli/cmd_firewall.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,grep,awk"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/lib/nft_writers.sh,cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,mktemp,grep,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="exported_function_closure_v1238_2_test"
# meta:ta.owner="firewall"
# meta:ta.module="daemon-runtime-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$LIB/cli/cmd_firewall.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/etc/conf.d/portscan" "$T/lib_ok/lib" "$T/lib_old/lib"
cp "$LIB/lib/module_authority.sh" "$LIB/lib/nft_writers.sh" "$T/lib_ok/lib/"
# v1.238.1 shape: the same files without the v1.238.2 export lines.
grep -v '^export -f _nftban_module_central_wins nftban_module_mode_unadmitted$' "$LIB/lib/module_authority.sh" > "$T/lib_old/lib/module_authority.sh"
awk '/^export -f nftban_root_lock_path /{skip=1} skip&&!/\\$/{skip=0; next} !skip' "$LIB/lib/nft_writers.sh" > "$T/lib_old/lib/nft_writers.sh"
cmp -s "$LIB/lib/module_authority.sh" "$T/lib_old/lib/module_authority.sh" && no "setup: module_authority export line not found"
cmp -s "$LIB/lib/nft_writers.sh" "$T/lib_old/lib/nft_writers.sh" && no "setup: nft_writers export line not found"

# closure <libdir> -> one line per violation "<exported> -> <non-exported callee>"
closure() {
    env -i PATH="/usr/bin:/bin" HOME="$T" NFTBAN_LIB_DIR="$1" NFTBAN_CONFIG_DIR="$T/etc" bash -c '
        source "$1/lib/module_authority.sh" >/dev/null 2>&1 || { echo "SOURCE_FAILED"; exit 9; }
        declare -A isexp=()
        while read -r _ _ f; do isexp[$f]=1; done < <(declare -Fx)
        mapfile -t all < <(declare -F | awk "{print \$3}")
        for f in "${!isexp[@]}"; do
            body=$(declare -f "$f" | tail -n +2)
            for g in "${all[@]}"; do
                [[ -n "${isexp[$g]:-}" ]] && continue
                grep -qw -- "$g" <<<"$body" && echo "$f -> $g"
            done
        done | sort' _ "$1"
}
# child <libdir>: parent sources, child only inherits (as `nftban <module> reload` under rebuild)
child() {
    env -i PATH="/usr/bin:/bin" HOME="$T" NFTBAN_LIB_DIR="$1" NFTBAN_CONFIG_DIR="$T/etc" bash -c '
        source "$1/lib/module_authority.sh" >/dev/null 2>&1 || { echo "SOURCE_FAILED"; exit 9; }
        bash -c "nftban_module_effective_enabled portscan PORTSCAN_ENABLED; echo rc=\$?; echo unadmitted=\$(type -t nftban_module_mode_unadmitted || echo none)" 2>&1' _ "$1"
}
printf 'PORTSCAN_ENABLED="true"\n' > "$T/etc/conf.d/portscan/main.conf"

echo "=== A: exported functions name only exported library functions ==="
v=$(closure "$T/lib_ok")
[[ -z "$v" ]] && ok "closure holds (no exported function calls a non-exported one)" || no "closure violations" "${v//$'\n'/; }"

echo "=== B: a child that only inherits runs the plan/enable functions ==="
out=$(child "$T/lib_ok")
[[ "$out" != *"command not found"* && "$out" == *"rc=0"* && "$out" == *"unadmitted=function"* ]] \
    && ok "child: effective_enabled rc 0, mode_unadmitted present" || no "child" "${out//$'\n'/ }"

echo "=== C: non-vacuity — the v1.238.1 export set fails both ==="
v=$(closure "$T/lib_old")
[[ "$v" == *"nftban_module_effective_enabled -> _nftban_module_central_wins"* \
   && "$v" == *"nftban_module_resolve_plan -> nftban_module_mode_unadmitted"* \
   && "$v" == *"_nftban_plan_lock_acquire -> nftban_root_lock_path"* ]] \
    && ok "closure finds the RC violations without the exports" || no "closure non-vacuity" "${v//$'\n'/; }"
out=$(child "$T/lib_old")
[[ "$out" == *"_nftban_module_central_wins: command not found"* && "$out" == *"unadmitted=none"* ]] \
    && ok "child reproduces the RC error without the exports" || no "child non-vacuity" "${out//$'\n'/ }"

echo "=== D: a failed DDoS/PortScan re-apply fails the operator's rebuild ==="
blk=$(awk '/if \[\[ -z "\$\{_NFTBAN_REBUILD_RESULT_FILE:-\}" && "\$\{_NFTBAN_REBUILD_CONTEXT:-runtime-required\}" == "runtime-required"/{c=1}
           c{print} c&&/^[[:space:]]*fi[[:space:]]*$/{exit}' "$FW")
[[ -n "$blk" && "$blk" == *"_REBUILD_MODULE_PORTSCAN"* && "$blk" == *"_REBUILD_MODULE_DDOS"* ]] \
    || { no "INCOMPLETE statement with PortScan/DDoS not found in cmd_firewall.sh"; echo "RESULTS: PASS=$PASS FAIL=$FAIL"; exit 1; }
eval "tail_check() { $blk
return 0; }"
arm() { # $1 result_file $2 context $3 ddos $4 portscan $5 botguard -> "rc|stderr"
    local o r=0
    # shellcheck disable=SC2034  # read by the eval'd statement
    o=$( _NFTBAN_REBUILD_RESULT_FILE="$1" _NFTBAN_REBUILD_CONTEXT="$2" _REBUILD_MODULE_DDOS="$3" \
         _REBUILD_MODULE_PORTSCAN="$4" _REBUILD_MODULE_BOTGUARD="$5" MR_FAILED=RESTORE_FAILED tail_check 2>&1 ) || r=$?
    echo "$r|$o"
}
r=$(arm "" runtime-required RESTORE_OK RESTORE_FAILED RESTORE_OK)
[[ "${r%%|*}" == 1 && "$r" == *"PortScan re-apply failed"* && "$r" == *"nftban portscan reload"* && "$r" != *"BotGuard"* && "$r" != *"DDoS"* ]] \
    && ok "runtime, PortScan failed -> rc 1, names PortScan only" || no "portscan arm" "$r"
r=$(arm "" runtime-required RESTORE_FAILED RESTORE_OK SKIPPED)
[[ "${r%%|*}" == 1 && "$r" == *"DDoS re-apply failed"* && "$r" == *"nftban ddos reload"* ]] \
    && ok "runtime, DDoS failed -> rc 1, names DDoS" || no "ddos arm" "$r"
r=$(arm "" runtime-required RESTORE_OK RESTORE_OK RESTORE_OK);    [[ "$r" == "0|" ]] && ok "all re-applied -> rc 0, silent" || no "ok arm" "$r"
r=$(arm "" runtime-required SKIPPED SKIPPED SKIPPED);             [[ "$r" == "0|" ]] && ok "none enabled -> rc 0" || no "skip arm" "$r"
r=$(arm "/x/res.json" runtime-required RESTORE_OK RESTORE_FAILED RESTORE_OK); [[ "$r" == "0|" ]] && ok "result-file consumer -> rc 0 (record contract unchanged)" || no "result file" "$r"
r=$(arm "" install-deferred RESTORE_FAILED RESTORE_FAILED RESTORE_OK);       [[ "$r" == "0|" ]] && ok "install context -> rc 0 (installer contract unchanged)" || no "install" "$r"

echo "=== E: the final-status line names failed module re-applies ==="
code=$(grep -vE '^[[:space:]]*#' "$FW")
grep -q 'module re-apply FAILED: \${_rebuild_failed_modules}' <<<"$code" && ok "final-status wording for a failed re-apply exists" || no "final-status wording" "missing"
g=$(grep -B4 'echo "Final status: \${post_status^^} (all checks passed)"' <<<"$code" | grep -c '_rebuild_failed_modules')
[[ "$g" -ge 1 ]] && ok "'all checks passed' is guarded by the failed-module test" || no "'all checks passed' unguarded" "guard lines=$g"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
