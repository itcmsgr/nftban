#!/usr/bin/env bash
# =============================================================================
# NFTBan - nft probe authority guard (G-1 / G-2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-nft-probe-authority"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-29"
# meta:description="v1.228.4 PR-3. Prevents reintroduction of the untyped nft probe defect class. G-1 rejects any direct boolean nft existence probe on the PROTECTED maintenance path, which must route every presence question through nftban_nft_probe_table or nftban_nft_probe_set. G-2 rejects new code anywhere that converts a generic nft command failure directly into absence, rebuild authority, or a healthy verdict - specifically an if-not-nft guard leading to a rebuild, command substitution around the typed probe (which runs it in a subshell and silently discards every diagnostic variable), and any stored MAY_REBUILD boolean (dual authority that can go stale). A RATCHET bounds the legacy debt: the repo-wide count of untyped probes is recorded in a baseline file and may never increase, so the remaining sites can be migrated over time while no new ones can be added. Static analysis only - reads files, invokes nothing, contacts no host."
# meta:input="cli/lib/nftban/**, install/**, scripts/ci/nft-probe-debt-baseline.txt"
# meta:output="PASS/FAIL per rule; exit 0 on all-pass, 1 on any violation"
# meta:depends="bash,git,grep"
# meta:inventory.files="scripts/ci/nft-probe-debt-baseline.txt"
# meta:inventory.binaries="bash,git,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="check_nft_probe_authority"
# meta:ta.owner="cli"
# meta:ta.module="nft-probe-authority"
# meta:ta.execution_class="CI_STATIC"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
cd "$REPO"

BASELINE="scripts/ci/nft-probe-debt-baseline.txt"

# The converted path. Every presence question here MUST be typed.
PROTECTED=(
    "cli/lib/nftban/cron/maintenance.sh"
    "cli/lib/nftban/helpers/autoheal.sh"
    "cli/lib/nftban/lib/ssh_port_detect.sh"
)

# A boolean nft read whose result is used as a truth value. This is the shape that
# collapses "cannot read" into "absent".
UNTYPED_RE='nft (-a )?list (table|tables|set|sets|chain|chains)[^|]*(>/dev/null 2>&1|&>/dev/null)'

PASS=0; FAIL=0
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n         %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Product code only: tests legitimately construct these patterns as fixtures, and
# this guard itself necessarily contains them as strings.
scan_files(){
    git ls-files -- 'cli/lib/nftban/**/*.sh' 'cli/sbin/*' 'install/**/*.sh' 2>/dev/null \
        | grep -v '/tests/' | grep -v 'check-nft-probe-authority' | grep -v 'lib/nft_probe.sh'
}

echo "=== G-1. protected maintenance path must be fully typed ==="
g1=0
for f in "${PROTECTED[@]}"; do
    [[ -f "$f" ]] || { no "G-1 $f exists" "protected file missing"; continue; }
    hits=$(grep -nE "$UNTYPED_RE" "$f" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        no "G-1 $f routes every presence question through the typed probe" \
           "untyped boolean nft probe found:"$'\n'"$(printf '%s' "$hits" | sed 's/^/           /')"
        g1=1
    fi
done
[[ $g1 -eq 0 ]] && ok "G-1 all ${#PROTECTED[@]} protected files are fully typed"

# The protected path must actually USE the authority — a file could be "clean"
# simply by not probing at all, which would silently drop the check.
for f in "${PROTECTED[@]}"; do
    grep -q 'nftban_nft_probe_' "$f" 2>/dev/null \
        && ok "G-1b $(basename "$f") calls the typed probe authority" \
        || no "G-1b $(basename "$f") calls the typed probe authority" \
              "no nftban_nft_probe_* call — is this file still on the path?"
done

echo "=== G-2. no new failure-to-absence or failure-to-authority conversion ==="

# G-2a: `if ! nft ...` immediately followed by a rebuild. This is the literal
# defect: a generic command failure authorising a mutation.
# NOTE ON PRECISION: an earlier revision used awk with \? and \s, which awk does
# not support, and matched far too broadly — it flagged `echo "Try: nftban
# firewall rebuild"` (advice TEXT, not a rebuild) and `if nftban firewall rebuild`
# (a POSITIVE conditional, the opposite shape). A guard that cries wolf on correct
# code gets disabled, so this is deliberately narrow:
#   guard  = literally `if ! nft ` — a NEGATED nft command used as a condition
#   action = an actual rebuild INVOCATION within 4 lines, excluding echo/printf/log
#            lines, which merely mention a rebuild rather than performing one
g2a=$(scan_files | while read -r f; do
    grep -nA4 -E 'if[[:space:]]+![[:space:]]*nft[[:space:]]' "$f" 2>/dev/null \
      | grep -E '(firewall rebuild|firewall reset|nft_ipc_apply_ruleset)' \
      | grep -vE '(echo|printf|log_[a-z]+|log ")' \
      | sed "s|^|$f:|" || true
done)
# Pre-existing sites are ALLOWLISTED as recorded debt, not exempted — see the
# G2A_ALLOWLIST block in the baseline file. Any site NOT on that list is a new
# instance and fails.
g2a_allow=$(grep -E '^G2A_ALLOWLIST=' "$BASELINE" 2>/dev/null | head -1 | cut -d= -f2)
g2a_new=""
if [[ -n "$g2a" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        matched=0
        IFS=',' read -ra allow <<< "$g2a_allow"
        for a in "${allow[@]}"; do
            [[ -z "$a" ]] && continue
            [[ "$line" == *"${a%%:*}"* ]] && matched=1 && break
        done
        [[ $matched -eq 0 ]] && g2a_new+="$line"$'\n'
    done <<< "$g2a"
fi
if [[ -z "$g2a_new" ]]; then
    n_allow=$(awk -F, '{print NF}' <<< "$g2a_allow")
    ok "G-2a no NEW failure-to-mutation site (${n_allow} pre-existing allowlisted as debt)"
else
    no "G-2a no NEW failure-to-mutation site" \
       "a failed nft READ authorises a MUTATION here — use nftban_nft_probe_table and act only on a verified ABSENT:"$'\n'"$g2a_new"
fi

# G-2b: command substitution around the typed probe. It runs in a SUBSHELL, so the
# verdict string survives but EVERY diagnostic variable is discarded — the exact
# lost-evidence failure this PR removes.
g2b=$(scan_files | xargs grep -nE '\$\(\s*nftban_nft_probe_(table|set)' 2>/dev/null || true)
[[ -z "$g2b" ]] && ok "G-2b typed probe is never called in command substitution" \
                || no "G-2b typed probe is never called in command substitution" "$g2b"

# G-2c: a stored rebuild boolean. Dual authority that can go stale or be set
# directly without ever consulting the verdict it mirrors.
g2c=$(scan_files | xargs grep -nE '^[[:space:]]*(export[[:space:]]+)?NFTBAN_NFT_PROBE_MAY_REBUILD=' 2>/dev/null || true)
[[ -z "$g2c" ]] && ok "G-2c no stored MAY_REBUILD state (derived live from VERDICT)" \
                || no "G-2c no stored MAY_REBUILD state" "$g2c"

echo "=== G-3. legacy debt RATCHET — the count may never increase ==="
current=$(scan_files | xargs grep -cE "$UNTYPED_RE" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')

if [[ ! -f "$BASELINE" ]]; then
    no "G-3 baseline exists" "$BASELINE missing — create it with the current count"
else
    recorded=$(grep -E '^UNTYPED_PROBE_COUNT=' "$BASELINE" | head -1 | cut -d= -f2 | tr -d '[:space:]')
    if [[ -z "$recorded" ]]; then
        no "G-3 baseline is parseable" "no UNTYPED_PROBE_COUNT= line in $BASELINE"
    elif [[ "$current" -gt "$recorded" ]]; then
        no "G-3 untyped probe debt did not increase" \
           "current=$current recorded=$recorded — $((current-recorded)) NEW untyped probe(s) added. Use nftban_nft_probe_table/_set instead."
    elif [[ "$current" -lt "$recorded" ]]; then
        no "G-3 baseline is current" \
           "current=$current recorded=$recorded — debt was REDUCED. Update $BASELINE to $current so the ratchet tightens and cannot slip back."
    else
        ok "G-3 untyped probe debt held at $current (ratchet: may decrease, never increase)"
    fi
fi

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
