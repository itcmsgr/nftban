#!/usr/bin/env bash
# =============================================================================
# NFTBan - firewall projection authority guard (v1.229.12 P12-FPA Phase 1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-firewall-projection-authority"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-28"
# meta:description="BLOCKING guard for the firewall projection invariants that hold on the CURRENT tree. NFTBan ships two executable nft artifacts that both reach the kernel: the canonical schema (placeholder template, rendered at rebuild) and the pre-rendered shipped copy. RULES ENFORCED HERE: P1 exactly ONE placeholder-bearing canonical schema. P3 the shipped copy is ENFORCEMENT-IDENTICAL to the canonical schema rendered with the install-time fallbacks read FROM the render authority itself. P5 the rendered projection parses under nft -c in a user+net namespace. NOT ENFORCED HERE, deliberately: single-substitution-authority (two render paths exist on this tree today and collapsing them is the FPA lane, not an exception to register), rule-comment/operator-truth drift (several current comments claim per-IP scope over global enforcement; adjudicating them belongs to the A02 lane), and every boot-projection rule (that subject does not exist on this tree). This guard states what it protects TODAY and reserves no arm for a future subject."
# meta:input="install/nftables/nftables.conf.tpl, install/nftables/nftables.conf, cli/lib/nftban/cli/cmd_firewall.sh, scripts/ci/data/firewall-projection-drift.allow"
# meta:output="PASS/FAIL per rule; exit 1 on any violation"
# meta:depends="bash,grep,sed,awk,diff,nft"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,awk,diff,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

TPL="${FPA_TPL:-install/nftables/nftables.conf.tpl}"
CONF="${FPA_CONF:-install/nftables/nftables.conf}"
RENDER="${FPA_RENDER:-cli/lib/nftban/cli/cmd_firewall.sh}"
# The Go installer is a SECOND, KNOWN substitution authority. It is declared here
# rather than silently matched. Collapsing the two render paths is FPA lane work.
# pretending there is one. Collapsing them is P12-FPA follow-on work, not a rename.
# A CHECKER MUST NOT BE ITS OWN SUBJECT — and here it structurally cannot be.
# P1 enumerates candidates by EXTENSION (--include='*.tpl' '*.nft' '*.conf'), so a
# .sh file is never a candidate schema. That matters because this guard DOES contain
# the placeholder strings, in P3's render sed below: without the extension filter it
# would flag itself. The filter is the mechanism; there is no path-based
# self-exclusion, and none is needed.

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }
inf() { printf '  [INFO] %s\n' "$1"; }

for f in "$TPL" "$CONF" "$RENDER"; do
    [[ -f "$f" ]] || { bad "MISSING SOURCE: $f"; echo "=== firewall-projection-authority: FAILS=$FAILS ==="; exit 1; }
done

echo "=== check-firewall-projection-authority (current projection invariants: P1 P3 P5) ==="

# GUARD SUBJECT == GUARD INPUT.
# enforce(): drop file comments AND rule-comment strings -> what the kernel enforces.
# rulecmt(): the rule-comment strings alone -> what an operator reads in `nft list ruleset`.
enforce() { grep -vE '^[[:space:]]*#' "$1" | sed -e 's/ comment "[^"]*"//g' -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//' | grep -v '^$'; }
rulecmt() { grep -vE '^[[:space:]]*#' "$1" | grep -oE 'comment "[^"]*"'; }

# ---------------------------------------------------------------------------
# P1 — SCHEMA SINGULARITY. Exactly one file may carry the substitution
# placeholders. A second placeholder-bearing schema IS a second authority.
# ---------------------------------------------------------------------------
mapfile -t P1_HITS < <(grep -rlE '__CT_LIMIT_(SSH|HTTP|MAIL)__' \
    --include='*.tpl' --include='*.nft' --include='*.conf' . 2>/dev/null \
    | sed 's|^\./||' | grep -vE '^\.claude/' | sort -u)
if [[ ${#P1_HITS[@]} -eq 1 && "${P1_HITS[0]}" == "$TPL" ]]; then
    ok "P1 exactly one canonical schema carries the placeholders ($TPL)"
else
    bad "P1 canonical-schema singularity violated — placeholder-bearing files:"
    printf '         %s\n' "${P1_HITS[@]:-<none>}"
    inf "a second placeholder schema is a second firewall authority; extend the canonical schema instead"
fi

# ---------------------------------------------------------------------------
# P3 — ENFORCEMENT EQUIVALENCE.
# The install-time fallbacks are READ FROM the render authority, never hardcoded
# here: if that line changes shape this guard fails loudly instead of silently
# comparing against stale values.
# ---------------------------------------------------------------------------
DEFLINE=$(grep -oE 'local _ct_ssh=[0-9]+ _ct_http=[0-9]+ _ct_mail=[0-9]+' "$RENDER" | head -1)
SSHLINE=$(grep -oE '_ssh_port=[0-9]+' "$RENDER" | tail -1)
if [[ -z "$DEFLINE" || -z "$SSHLINE" ]]; then
    bad "P3 cannot read the install-time fallbacks from $RENDER — guard input shape changed"
    inf "expected 'local _ct_ssh=<n> _ct_http=<n> _ct_mail=<n>' and a '_ssh_port=<n>' fallback"
else
    D_SSH=$(sed 's/.*_ct_ssh=\([0-9]*\).*/\1/'  <<<"$DEFLINE")
    D_HTTP=$(sed 's/.*_ct_http=\([0-9]*\).*/\1/' <<<"$DEFLINE")
    D_MAIL=$(sed 's/.*_ct_mail=\([0-9]*\).*/\1/' <<<"$DEFLINE")
    D_PORT=$(sed 's/.*_ssh_port=\([0-9]*\).*/\1/' <<<"$SSHLINE")
    inf "install-time fallbacks read from the render authority: ssh=$D_PORT ct_ssh=$D_SSH ct_http=$D_HTTP ct_mail=$D_MAIL"
    RENDERED=$(mktemp) || exit 1
    trap 'rm -f "$RENDERED"' EXIT
    sed -e "s/__SSH_PORT__/${D_PORT}/g" -e "s/__CT_LIMIT_SSH__/${D_SSH}/g" \
        -e "s/__CT_LIMIT_HTTP__/${D_HTTP}/g" -e "s/__CT_LIMIT_MAIL__/${D_MAIL}/g" \
        "$TPL" > "$RENDERED"
    if [[ -n "$(grep -oE '__[A-Z0-9_]+__' "$RENDERED")" ]]; then
        bad "P3 unrendered placeholders remain after substitution:"
        grep -oE '__[A-Z0-9_]+__' "$RENDERED" | sort -u | sed 's/^/         /'
    elif diff <(enforce "$CONF") <(enforce "$RENDERED") >/dev/null; then
        ok "P3 boot projection is ENFORCEMENT-IDENTICAL to the rendered canonical schema ($(enforce "$CONF" | wc -l) lines)"
    else
        bad "P3 ENFORCEMENT DRIFT between the boot projection and the canonical schema:"
        diff <(enforce "$CONF") <(enforce "$RENDERED") | head -12 | sed 's/^/         /'
        inf "the boot projection must be generated from the canonical schema, never hand-edited"
    fi

    # -----------------------------------------------------------------------
    # P5 — the rendered projection must actually parse.
    # -----------------------------------------------------------------------
    if command -v nft >/dev/null 2>&1; then
        # nft -c still opens netlink. Unprivileged CI runners get EPERM, so retry
        # inside a user+net namespace before concluding anything. A privilege
        # error is a SKIP, never a PASS: absence of a verdict is not a verdict.
        NFT_MODE="" ; NFT_ERR=""
        if NFT_ERR=$(nft -c -f "$RENDERED" 2>&1); then
            NFT_MODE="host"
        elif grep -qiE 'permission|not permitted|netlink|Operation not' <<<"$NFT_ERR" \
             && command -v unshare >/dev/null 2>&1 \
             && NFT_ERR=$(unshare -rn nft -c -f "$RENDERED" 2>&1); then
            NFT_MODE="netns"
        fi
        case "$NFT_MODE" in
            host)  ok "P5 rendered canonical schema parses under nft -c ($(nft --version 2>/dev/null | head -1))" ;;
            netns) ok "P5 rendered canonical schema parses under nft -c in a user+net namespace ($(nft --version 2>/dev/null | head -1))" ;;
            *)
                if grep -qiE 'permission|not permitted|netlink|Operation not' <<<"$NFT_ERR"; then
                    inf "P5 SKIPPED — nft -c needs privileges and no namespace is available: $(head -1 <<<"$NFT_ERR")"
                else
                    bad "P5 rendered canonical schema FAILS nft -c:"
                    head -3 <<<"$NFT_ERR" | sed 's/^/         /'
                fi ;;
        esac
    else
        inf "P5 SKIPPED — nft not installed in this environment"
    fi
fi

echo "=== firewall-projection-authority: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]] || exit 1
