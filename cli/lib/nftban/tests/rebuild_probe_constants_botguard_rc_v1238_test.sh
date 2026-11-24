#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238: probe constants reach child processes; a failed BotGuard re-apply fails the rebuild
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="rebuild_probe_constants_botguard_rc_v1238_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-23"
# meta:description="v1.238 (owner GO 2026-11-23; lab4: 'environment: line 61: NFTBAN_NFT_PROBE_PRESENT: unbound variable' made BotGuard re-apply fail inside the rebuild, PortScan reload on 1.237.0, while the rebuild returned 0). A: the REAL lib/nft_probe.sh exports the functions AND their constants, so a child bash -u that inherited them runs the real redact path and reads PRESENT/ABSENT/CANNOT_READ; non-vacuity: the same file with the export line removed reproduces the lab4 unbound-variable failure. B: the REAL statement extracted from cmd_firewall.sh returns 1 and names BotGuard when BotGuard re-apply failed in a runtime rebuild with no result-file consumer, and returns 0 for install-deferred context, for a result-file consumer (installer / update apply: COMPLETE must pair with rc 0) and when BotGuard succeeded or was skipped. Sandbox only; no nft, no firewall change."
# meta:input="None (repo source read-only; temp dir)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,awk,grep,sed"
# meta:inventory.files="cli/lib/nftban/lib/nft_probe.sh,cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,awk,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_probe_constants_botguard_rc_v1238_test"
# meta:ta.owner="core"
# meta:ta.module="firewall-rebuild"
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"
PROBE="$LIB/lib/nft_probe.sh"; FW="$LIB/cli/cmd_firewall.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT

# Parent sources the library (as the CLI does); the child only INHERITS (as `nftban botguard
# apply` started by the rebuild does) and runs under set -u.
child() { # $1 = library file
    env -i PATH="$PATH" HOME="$T" bash -c '
        source "$1" >/dev/null 2>&1 || exit 90
        bash -u -c "x=\$(nftban_nft_probe_redact \"Error: No such file or directory\") || exit 3
                    echo \"\$NFTBAN_NFT_PROBE_PRESENT/\$NFTBAN_NFT_PROBE_ABSENT/\$NFTBAN_NFT_PROBE_CANNOT_READ \$x\"" 2>&1' _ "$1"
}

echo "=== A: probe constants travel with the exported functions ==="
rc=0; out=$(child "$PROBE") || rc=$?
[[ $rc -eq 0 && "$out" == "PRESENT/ABSENT/CANNOT_READ Error: No such file or directory" ]] \
    && ok "child bash -u: inherited redact path runs, constants readable" || no "child" "rc=$rc $out"
grep -v '^export NFTBAN_NFT_PROBE_PRESENT ' "$PROBE" > "$T/prefix_probe.sh"
cmp -s "$PROBE" "$T/prefix_probe.sh" && no "non-vacuity: export line not found in nft_probe.sh"
rc=0; out=$(child "$T/prefix_probe.sh") || rc=$?
[[ $rc -ne 0 && "$out" == *"unbound variable"* ]] \
    && ok "non-vacuity: without the export the child fails as on lab4 (unbound variable)" || no "non-vacuity" "rc=$rc $out"

echo "=== B: a failed BotGuard re-apply fails the operator's rebuild ==="
# Extract the REAL statement (from its guard line to the matching fi) and wrap it.
blk=$(awk '/if \[\[ -z "\$\{_NFTBAN_REBUILD_RESULT_FILE:-\}" && "\$\{_NFTBAN_REBUILD_CONTEXT:-runtime-required\}" == "runtime-required"/{c=1}
           c{print} c&&/^[[:space:]]*fi[[:space:]]*$/{exit}' "$FW")
[[ -n "$blk" && "$blk" == *"_REBUILD_MODULE_BOTGUARD"* ]] || { no "statement not found in cmd_firewall.sh"; echo "RESULTS: PASS=$PASS FAIL=$FAIL"; exit 1; }
eval "tail_check() { $blk
return 0; }"
arm() { # $1 result_file $2 context $3 botguard_result -> "rc|stderr"
    local o r=0
    # shellcheck disable=SC2034  # MR_FAILED is read by the eval'd statement
    o=$( _NFTBAN_REBUILD_RESULT_FILE="$1" _NFTBAN_REBUILD_CONTEXT="$2" _REBUILD_MODULE_BOTGUARD="$3" MR_FAILED=RESTORE_FAILED
         tail_check 2>&1 ) || r=$?
    echo "$r|$o"
}
r=$(arm "" runtime-required RESTORE_FAILED)
[[ "${r%%|*}" == 1 && "$r" == *"BotGuard rule re-apply failed"* && "$r" == *"nftban botguard apply"* ]] && ok "runtime, no result file, BotGuard failed -> rc 1, names BotGuard" || no "runtime fail" "$r"
r=$(arm "" runtime-required RESTORE_OK);   [[ "$r" == "0|" ]] && ok "BotGuard re-applied -> rc 0, silent" || no "ok arm" "$r"
r=$(arm "" runtime-required SKIPPED);      [[ "$r" == "0|" ]] && ok "BotGuard not enabled (skipped) -> rc 0" || no "skip arm" "$r"
r=$(arm "/x/res.json" runtime-required RESTORE_FAILED); [[ "$r" == "0|" ]] && ok "result-file consumer (update apply) -> rc 0 (COMPLETE pairs with 0)" || no "result file" "$r"
r=$(arm "" install-deferred RESTORE_FAILED); [[ "$r" == "0|" ]] && ok "install context -> rc 0 (installer contract unchanged)" || no "install" "$r"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
