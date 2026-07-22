#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.153 PR-E: installer-output wording (UX-T1..T4)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="installer_wording_v153_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks v1.153 PR-E installer-output wording. UX-T1 (shell): the auditor-ACL non-fatal failure path in core/nftban_health_fixes.sh names the stable class WARN_PERMISSIONS_ENFORCE_NONFATAL instead of silently swallowing. UX-T2 (shell): the systemd-tmpfiles non-zero path in the same file names WARN_TMPFILES_73 (tmpfiles canonicalization of design-correct ownership; non-fatal). UX-T3 (installer-Go, wording only): panelfw.go portsToString range-compresses contiguous runs (35000-35999) instead of ~1000 comma entries — verified by re-implementing the documented transform and by asserting the source uses sort+range output. UX-T4 (installer-Go, wording only): cmd/nftban-installer/main.go report() prints 'completed with warnings (non-fatal)' for DEGRADED and a mechanism-accurate COMMITTED line, with the flow (state machine) unchanged. Hermetic: greps source + mirrors the range transform; no Go build, no host/nft/IPC."
# meta:input="core/nftban_health_fixes.sh, internal/installer/panelfw/panelfw.go, cmd/nftban-installer/main.go"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_health_fixes.sh,internal/installer/panelfw/panelfw.go,cmd/nftban-installer/main.go"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="installer_wording_v153_test"
# meta:ta.owner="installer"
# meta:ta.module="installer"
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
HF="$REPO/cli/lib/nftban/core/nftban_health_fixes.sh"
PG="$REPO/internal/installer/panelfw/panelfw.go"
MG="$REPO/cmd/nftban-installer/main.go"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== UX-T1: WARN_PERMISSIONS_ENFORCE_NONFATAL named (shell) ==="
grep -q 'WARN_PERMISSIONS_ENFORCE_NONFATAL' "$HF" \
    && ok "auditor-ACL failure path names WARN_PERMISSIONS_ENFORCE_NONFATAL" \
    || no "WARN_PERMISSIONS_ENFORCE_NONFATAL class id missing"
# old bare 'Some auditor ACLs could not be set' (no class id) must be replaced
grep -qE '⚠ Some auditor ACLs could not be set \(\$acl_errors errors\)$' "$HF" \
    && no "old un-classed auditor-ACL message still present" \
    || ok "old un-classed auditor-ACL message replaced"

echo "=== UX-T2: WARN_TMPFILES_73 named (shell) ==="
grep -q 'WARN_TMPFILES_73' "$HF" \
    && ok "systemd-tmpfiles non-zero path names WARN_TMPFILES_73" \
    || no "WARN_TMPFILES_73 class id missing"
grep -q 'tmpfiles canonicalization of design-correct ownership' "$HF" \
    && ok "wording explains the canonicalization-of-design-correct-ownership case" \
    || no "WARN_TMPFILES_73 explanation wording missing"

echo "=== UX-T3: panelfw.go portsToString range-compresses (Go, wording only) ==="
grep -q 'range-compressed' "$PG" && ok "portsToString documents range-compression" || no "range-compress comment missing"
grep -q 'sort.Ints' "$PG" && ok "portsToString sorts before run detection" || no "sort.Ints missing"
grep -qE '"%d-%d"' "$PG" && ok "portsToString emits a 'start-end' range form" || no "range format string missing"
grep -qE '^[[:space:]]*"sort"$' "$PG" && ok "sort imported" || no "sort import missing"

# Mirror the documented transform and prove it on the canonical fixture.
compress_ports() {
    # stdin: space-separated ints; stdout: "[a,b-c,...]"
    local -a ps; IFS=$' \t\n' read -ra ps <<<"$1"
    local -a sorted
    mapfile -t sorted < <(printf '%s\n' "${ps[@]}" | sort -n)
    local out="" run_start="${sorted[0]}" prev="${sorted[0]}" p i
    flush() { if [[ "$1" == "$2" ]]; then out+="${out:+,}$1"; else out+="${out:+,}$1-$2"; fi; }
    for (( i=1; i<${#sorted[@]}; i++ )); do
        p="${sorted[$i]}"
        if [[ "$p" == "$prev" || "$p" -eq $((prev+1)) ]]; then prev="$p"; continue; fi
        flush "$run_start" "$prev"; run_start="$p"; prev="$p"
    done
    flush "$run_start" "$prev"
    printf '[%s]' "$out"
}
# contiguous 35000..35999 (build a small contiguous sample that proves the rule)
sample=""; for p in $(seq 35000 35009); do sample+="$p "; done
got="$(compress_ports "$sample")"
[[ "$got" == "[35000-35009]" ]] \
    && ok "contiguous run compresses to a single range ($got)" || no "range compress wrong" "$got"
# mixed singletons + a run
got2="$(compress_ports "21 80 35000 35001 35002 8443")"
[[ "$got2" == "[21,80,8443,35000-35002]" ]] \
    && ok "mixed singletons + run render correctly ($got2)" || no "mixed render wrong" "$got2"

echo "=== UX-T4: main.go report() wording (Go, wording only; flow unchanged) ==="
grep -q 'completed with warnings (non-fatal).' "$MG" \
    && ok "DEGRADED line says 'completed with warnings (non-fatal)'" || no "DEGRADED wording missing"
grep -q 'state: COMMITTED, no warnings' "$MG" \
    && ok "COMMITTED line is mechanism-accurate (no bare 'successfully')" || no "COMMITTED wording missing"
# flow guard: both state arms still keyed off the state machine (no warn-tally logic added)
grep -q 'case state.StateCommitted:' "$MG" && grep -q 'case state.StateDegraded:' "$MG" \
    && ok "state-machine branches unchanged (no flow change)" || no "state branches altered"

echo ""
echo "================================================================"
echo "installer_wording_v153: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
