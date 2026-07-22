#!/usr/bin/env bash
# =============================================================================
# NFTBan - port reload-hint canonicalization test (v1.144.0 PR-C D-UXV-15)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_port_reload_hint_v144_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-01"
# meta:description="v1.144.0 PR-C D-UXV-15 closure — asserts cmd_port.sh no longer emits the four broken reload-hint strings ('nftban reload' / 'nftban port reload'). Neither is a real command at main: cli/sbin/nftban has no cmd_reload.sh autoload target, no 'reload' alias case in lines 1187-1280, and 'reload' is absent from _nftban_canonical_commands at lines 911-995. The canonical reload command is 'nftban firewall reload' (cmd_firewall.sh:1490 firewall_reload). The original 2026-06-01 audit proposed migrating :558 to 'nftban reload' — challenge-verified to ALSO be broken; corrected here. All 4 sites (:260, :558, :689, :693) now emit 'nftban firewall reload'. Hermetic — file-content assertions only; no daemon, no nft, no host contact."
# meta:input="cli/lib/nftban/cli/cmd_port.sh, cli/sbin/nftban, cli/lib/nftban/cli/cmd_firewall.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,wc"
# meta:inventory.files="cli/lib/nftban/cli/cmd_port.sh,cli/sbin/nftban,cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,grep,wc"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_port_reload_hint_v144_test"
# meta:ta.owner="cli"
# meta:ta.module="port-reload-hint"
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
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
PORT="$REPO/cli/lib/nftban/cli/cmd_port.sh"
DISP="$REPO/cli/sbin/nftban"
FW="$REPO/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

for f in "$PORT" "$DISP" "$FW"; do
    [[ -f "$f" ]] || { echo "FAIL: missing $f"; exit 1; }
done

# ──────────────────────────────────────────────────────────────────────────
# Section 1: cmd_port.sh — broken hints fully removed
# ──────────────────────────────────────────────────────────────────────────
# T1: no echo line emits 'nftban reload' (without 'firewall'). Use a
# negative-lookahead-style grep: any 'nftban reload' that is NOT preceded
# by 'firewall '.
bad_reload=$(grep -nE 'nftban reload\b' "$PORT" || true)
if [[ -z "$bad_reload" ]]; then
    ok "T1: no 'nftban reload' literal in cmd_port.sh (top-level reload is not a real command)"
else
    no "T1: no 'nftban reload' literal in cmd_port.sh (top-level reload is not a real command)" \
       "$(echo "$bad_reload" | head -1)"
fi

# T2: no echo line emits 'nftban port reload' (port has no reload arm)
bad_port_reload=$(grep -nE 'nftban port reload\b' "$PORT" || true)
if [[ -z "$bad_port_reload" ]]; then
    ok "T2: no 'nftban port reload' literal in cmd_port.sh (port dispatch has no reload arm)"
else
    no "T2: no 'nftban port reload' literal in cmd_port.sh (port dispatch has no reload arm)" \
       "$(echo "$bad_port_reload" | head -1)"
fi

# T3: exactly 4 sites now emit 'nftban firewall reload' (the canonical form)
fw_reload_count=$(grep -cnE 'nftban firewall reload\b' "$PORT" || true)
if [[ "$fw_reload_count" -ge 4 ]]; then
    ok "T3: at least 4 'nftban firewall reload' canonical hints in cmd_port.sh (got $fw_reload_count)"
else
    no "T3: at least 4 'nftban firewall reload' canonical hints in cmd_port.sh" \
       "got $fw_reload_count, expected ≥4"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 2: code-truth — assert 'nftban reload' is NOT a real top-level
#            command (this is what was wrong with the audit's proposed fix)
# ──────────────────────────────────────────────────────────────────────────
# T4: no cmd_reload.sh file exists (autoloader would source it if present)
if [[ -f "$REPO/cli/lib/nftban/cli/cmd_reload.sh" ]]; then
    no "T4: no cli/lib/nftban/cli/cmd_reload.sh exists (autoloader target)" \
       "file present at $REPO/cli/lib/nftban/cli/cmd_reload.sh"
else
    ok "T4: no cli/lib/nftban/cli/cmd_reload.sh exists (autoloader target)"
fi

# T5: 'reload' is NOT in _nftban_canonical_commands() in cli/sbin/nftban
if awk '/^_nftban_canonical_commands\(\)/,/^EOF$/' "$DISP" | grep -E '^reload$' >/dev/null 2>&1; then
    no "T5: 'reload' not in _nftban_canonical_commands (typo-suggestion list)" \
       "$(awk '/^_nftban_canonical_commands\(\)/,/^EOF$/' "$DISP" | grep -nE '^reload$' | head -1)"
else
    ok "T5: 'reload' not in _nftban_canonical_commands (typo-suggestion list)"
fi

# T6: 'reload)' is NOT an alias case in cli/sbin/nftban (lines ~1187-1280)
if grep -nE '^[[:space:]]+reload\)|\|reload\)' "$DISP" >/dev/null 2>&1; then
    no "T6: no 'reload' alias case in cli/sbin/nftban dispatcher" \
       "$(grep -nE '^[[:space:]]+reload\)|\|reload\)' "$DISP" | head -1)"
else
    ok "T6: no 'reload' alias case in cli/sbin/nftban dispatcher"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 3: positive control — 'nftban firewall reload' IS a real command
# ──────────────────────────────────────────────────────────────────────────
# T7: firewall_reload() function exists at cmd_firewall.sh:1490 (the
# canonical implementation the new port hints point to)
if grep -nE '^firewall_reload\(\)' "$FW" >/dev/null 2>&1; then
    ok "T7: firewall_reload() function defined in cmd_firewall.sh (canonical reload exists)"
else
    no "T7: firewall_reload() function defined in cmd_firewall.sh (canonical reload exists)" \
       "no definition found"
fi

# T8: firewall dispatch has a 'reload)' arm
if awk '/^nftban_cmd_firewall\(\)|^_cmd_firewall_dispatch\(\)/,/^}/' "$FW" | grep -nE '^\s*reload\)|\|reload\)' >/dev/null 2>&1; then
    ok "T8: firewall dispatch has 'reload)' arm"
else
    # Fallback: just look for `reload)` somewhere in the file's case arms
    if grep -nE '^[[:space:]]+reload\)' "$FW" >/dev/null 2>&1; then
        ok "T8: firewall dispatch has 'reload)' arm"
    else
        no "T8: firewall dispatch has 'reload)' arm" \
           "no reload arm found"
    fi
fi

echo
echo "═══════════════════════════════════════════════════════════════"
echo "  cli_port_reload_hint_v144_test: ${PASS} PASS / ${FAIL} FAIL"
echo "═══════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
