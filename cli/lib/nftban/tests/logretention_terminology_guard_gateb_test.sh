#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.222.0 — Z8 retention terminology guard (no guaranteed elapsed days)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logretention_terminology_guard_gateb_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Z8 terminology guard. The forensic floor NFTBan enforces is a number of rotated GENERATIONS plus a BYTE budget; day figures are TARGETS (size pressure can rotate a family sooner, shortening elapsed days). This scans the Gate B log-retention surface (Go, CLI, config, templates, tests) for language that promises a GUARANTEED elapsed-day retention count — the misleading framing the audit rejects — and FAILS on any occurrence. Result: GUARANTEED_DAY_CLAIMS=0. The correct 'TARGET / NOT guaranteed under size pressure' phrasing is intentionally not matched."
# meta:input="Gate B log-retention source/config/template/test files"
# meta:output="Pass/fail; exit 0 if no guaranteed-day claim found, 1 otherwise"
# meta:depends="bash,grep"
# meta:inventory.files="internal/logretention,cmd/nftban-core/cmd_logretention.go,etc/nftban/conf.d/logs.conf,install/config/nftban.logrotate,install/config/nftban-suricata.logrotate"
# meta:inventory.binaries="grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files="etc/nftban/conf.d/logs.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (reads repo files)"
# meta:ta.id="logretention_terminology_guard_gateb_test"
# meta:ta.owner="core"
# meta:ta.module="logretention"
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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here"
while [ "$root" != "/" ] && [ ! -f "$root/etc/nftban/conf.d/logs.conf" ]; do root="$(dirname "$root")"; done
[ -f "$root/etc/nftban/conf.d/logs.conf" ] || { echo "FAIL: cannot locate repo root"; exit 1; }

# Files that make up the Gate B retention surface.
targets=(
    "$root/internal/logretention"
    "$root/cmd/nftban-core/cmd_logretention.go"
    "$root/etc/nftban/conf.d/logs.conf"
    "$root/install/config/nftban.logrotate"
    "$root/install/config/nftban-suricata.logrotate"
    "$root/cli/lib/nftban/tests/logrotate_behavioral_gateb_test.sh"
    "$root/cli/lib/nftban/tests/logretention_packaging_derivedstate_gateb_test.sh"
    "$root/cli/lib/nftban/tests/suricata_usr2_guard_gateb_test.sh"
)

# Forbidden = a promise of a GUARANTEED elapsed-day count. Each pattern requires a
# digit or an explicit "are guaranteed", so the correct negated phrasing
# ("NOT guaranteed under size pressure", "day figures are TARGETS", "may shorten
# elapsed days") is NOT matched.
patterns=(
    'guarantees?[[:space:]]+[0-9]+[[:space:]]*d(ays)?'
    'guaranteed[[:space:]]+[0-9]+[[:space:]]*d(ays)?'
    '[0-9]+[[:space:]]*d(ays)?[[:space:]]+guaranteed'
    'at least[[:space:]]+[0-9]+[[:space:]]*d(ays)?'
    'retained for[[:space:]]+[0-9]+[[:space:]]*d(ays)?'
    'keeps?[[:space:]]+[0-9]+[[:space:]]*d(ays)?'
    '[0-9]+[[:space:]]*days?[[:space:]]+of[[:space:]]+retention'
    '(elapsed[[:space:]]+)?days?[[:space:]]+are[[:space:]]+guaranteed'
    'guaranteed[[:space:]]+(elapsed[[:space:]]+)?days'
)

found=0
for pat in "${patterns[@]}"; do
    for tgt in "${targets[@]}"; do
        [ -e "$tgt" ] || continue
        # -r handles dirs; -I skips binaries; -n for line numbers.
        if hits=$(grep -rniIE "$pat" "$tgt" 2>/dev/null); then
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                echo "  FORBIDDEN day-guarantee claim: $line"
                found=$((found+1))
            done <<< "$hits"
        fi
    done
done

echo
if [ "$found" -ne 0 ]; then
    echo "RESULT: GUARANTEED_DAY_CLAIMS=$found (FAIL — the forensic floor is generations+bytes; days are TARGETS)"
    exit 1
fi
echo "RESULT: GUARANTEED_DAY_CLAIMS=0 (PASS)"
