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
# meta:description="BLOCKING guard for P12-FPA. THE INVARIANT: there must be no hand-maintained second NFTBan firewall schema capable of reaching the kernel. NFTBan ships TWO executable nft artifacts — the canonical schema (placeholder template, rendered at rebuild into the runtime projection) and a pre-rendered boot projection included by nftables.service. Both reach the kernel. Rules: P1 exactly ONE placeholder-bearing canonical schema. P2 exactly ONE substitution authority (_firewall_substitute_placeholders); no file may reimplement placeholder substitution. P3 the shipped boot projection must be ENFORCEMENT-IDENTICAL to the canonical schema rendered with the install-time fallbacks read FROM the substitution authority itself. P4 rule-comment text must also match; known unfixable divergences must be REGISTERED with a reason, and the registry may only shrink. P5 the rendered projection must parse under nft -c. Existing coverage: check-nft-bounded-limiters R4 compares only 'update @|flags dynamic' lines — this guard covers the WHOLE ruleset, including the ct-count rules R4 cannot see."
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
ALLOW="${FPA_ALLOW:-scripts/ci/data/firewall-projection-drift.allow}"
PATHAUTH="${FPA_PATHAUTH:-cli/lib/nftban/lib/boot_projection.sh}"
FC="${FPA_FC:-install/selinux/nftban.fc}"
# A CHECKER MUST NOT BE ITS OWN SUBJECT. This guard renders the schema in order to
# compare it, and its inversion harness builds fixtures that deliberately contain the
# violating shapes. Both are guard machinery, not the product render path, so both are
# excluded from P2 — and ONLY those two, by exact path, never a blanket scripts/ci/
# exemption that would let a real reimplementation hide there.
SELF="scripts/ci/$(basename "${BASH_SOURCE[0]}")"
SELF_INV="${SELF%.sh}-falsifiability.sh"

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }
inf() { printf '  [INFO] %s\n' "$1"; }

for f in "$TPL" "$CONF" "$RENDER"; do
    [[ -f "$f" ]] || { bad "MISSING SOURCE: $f"; echo "=== firewall-projection-authority: FAILS=$FAILS ==="; exit 1; }
done
[[ -f "$ALLOW" ]] || : >"$ALLOW"

echo "=== check-firewall-projection-authority (P12-FPA Phase 1) ==="

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
# P2 — SUBSTITUTION AUTHORITY SINGULARITY. Only _firewall_substitute_placeholders
# may turn placeholders into values. Any other sed/replace of the placeholder
# tokens reimplements the render and can drift from it.
# ---------------------------------------------------------------------------
mapfile -t P2_HITS < <(grep -rnE "s/__(CT_LIMIT_(SSH|HTTP|MAIL)|SSH_PORT)__/" \
    --include='*.sh' --include='*.go' . 2>/dev/null \
    | sed 's|^\./||' | grep -vE '^\.claude/' | grep -vE "^$RENDER:" | grep -vE "^$SELF:" | grep -vE "^$SELF_INV:" | grep -vE '^cli/lib/nftban/tests/')
if [[ ${#P2_HITS[@]} -eq 0 ]]; then
    ok "P2 substitution happens only in the render authority ($RENDER)"
else
    bad "P2 placeholder substitution reimplemented outside the render authority:"
    printf '         %s\n' "${P2_HITS[@]}"
    inf "call _firewall_substitute_placeholders; do not re-derive the substitution"
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
    # P4 — RULE-COMMENT EQUIVALENCE. Rule comments are loaded into the kernel
    # and are what an operator reads back from `nft list ruleset`, so a wrong
    # one misinforms exactly like a wrong rule. Known divergences that cannot
    # be corrected yet (the boot copy is a DEB conffile / RPM %config(noreplace),
    # so editing it turns every upgrade into an interactive prompt) live in the
    # registry WITH their reason. THE REGISTRY MAY ONLY SHRINK.
    # -----------------------------------------------------------------------
    REGISTERED=$(grep -cvE '^[[:space:]]*(#|$)' "$ALLOW" 2>/dev/null || echo 0)
    mapfile -t P4_DIFF < <(diff <(rulecmt "$CONF") <(rulecmt "$RENDERED") | grep -E '^[<>]' || true)
    UNREG=0
    for line in "${P4_DIFF[@]}"; do
        txt=${line#? }
        grep -qxF -- "$txt" <(grep -vE '^[[:space:]]*(#|$)' "$ALLOW") || { 
            bad "P4 UNREGISTERED rule-comment drift: $txt"; UNREG=1; }
    done
    if [[ ${#P4_DIFF[@]} -eq 0 ]]; then
        ok "P4 rule comments identical between boot projection and canonical schema"
        [[ "$REGISTERED" -gt 0 ]] && bad "P4 registry lists $REGISTERED entries but NO drift remains — delete the stale rows (the registry may only shrink)"
    elif [[ "$UNREG" -eq 0 ]]; then
        ok "P4 ${#P4_DIFF[@]} rule-comment divergence(s), ALL registered with a reason in $ALLOW"
        inf "these are P12-FPA migration debt: they disappear when the boot projection becomes generated"
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

# ---------------------------------------------------------------------------
# P6 — SELINUX LABEL BINDING. The boot projection is read by the distro
# nftables.service, which runs nft in iptables_t. That domain may read ONLY
# nftban_nftables_conf_t under /etc/nftban; everything else there is
# nftban_conf_t and is deliberately unreadable to it. A boot projection without
# an explicit file-context entry inherits nftban_conf_t from the
# /etc/nftban(/.*)? catch-all and fails at boot with a misleading
# "File not found" (FAILED_NO_FIREWALL, proven on Rocky 9.7, v1.228.5).
#
# The path is taken FROM the path authority, not restated here, so renaming the
# artifact without updating the policy fails this guard instead of shipping a
# host that cannot load its firewall at boot.
# ---------------------------------------------------------------------------
if [[ -f "$PATHAUTH" && -f "$FC" ]]; then
    BP=$(grep -oE "printf '%s/[A-Za-z0-9._-]+' \"\\\$\(nftban_boot_projection_dir\)\"" "$PATHAUTH" \
         | grep -oE "/[A-Za-z0-9._-]+\.nft" | head -1)
    if [[ -z "$BP" ]]; then
        bad "P6 cannot read the boot-projection filename from $PATHAUTH — path authority shape changed"
    else
        FCPAT="/etc/nftban/generated${BP//./\\.}"
        if grep -qF "$FCPAT" "$FC" && grep -F "$FCPAT" "$FC" | grep -q 'nftban_nftables_conf_t'; then
            ok "P6 boot projection ${BP#/} has an explicit nftban_nftables_conf_t entry in $FC"
        else
            bad "P6 boot projection ${BP#/} has NO nftban_nftables_conf_t entry in $FC"
            inf "it would inherit nftban_conf_t and nftables.service (iptables_t) could not read it at boot"
        fi
    fi
else
    inf "P6 SKIPPED — $PATHAUTH or $FC absent"
fi

echo "=== firewall-projection-authority: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]] || exit 1
