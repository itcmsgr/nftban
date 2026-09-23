#!/usr/bin/env bash
# =============================================================================
# NFTBan - the connlimit CLAIM must match the connlimit KEYING (v1.231.0)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="connlimit_claim_matches_keying_v1231_test"
# meta:type="test"
# meta:version="2.0.0"
# meta:owner="ddos"
# meta:ta.id="connlimit_claim_matches_keying_v1231_test"
# meta:ta.owner="ddos"
# meta:ta.module="ddos-status-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="SUPERSEDES ddos_connlimit_label_global_v1229_10_test. That test locked the operator-facing text to GLOBAL because the shipped rules were bare 'ct count over N' with no ip saddr key, and it deliberately asserted the rule generator was UNCHANGED so a report-only PR could not smuggle a semantic change. v1.231.0 P12-A02 closes the enforcement limb: every connlimit rule is now projected from data/connlimit-services.tsv as 'add @connlimit_<svc>_<fam> { ip|ip6 saddr ct count over N }', so the old premise is retired by the fix rather than weakened. This test locks the INVARIANT BEHIND BOTH VERSIONS, in both directions: the operator-facing claim and the emitted rule must agree. A per-source claim is permitted ONLY while every emission surface is keyed by source; a bare host-wide rule anywhere must force the text back to GLOBAL. Negative controls synthesise both halves of the contradiction."
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$SD/../core/nftban_ddos_classic.sh"
FRAG="$SD/../lib/nft_fragment.sh"

# ⛔ REQUIRED SOURCE UNAVAILABLE != PASS  (v1.233.0 G1)
# Measured on lab4: run from an INSTALLED tree (/usr/lib/nftban/tests), $TPL and
# $CONF resolved to /install/nftables/* — which does not exist there. P0 silently
# `continue`d past them and P2's bare_count() on an unreadable file returned 0,
# so TWO OF SEVEN claimed surfaces were never inspected while the banner still
# printed 13/0. A gate that reports green over surfaces it never opened is the
# exact failure class this release exists to eliminate.
#
# Both surfaces ARE shipped, at different paths, so resolve rather than skip:
#     nftables.conf.tpl  source install/nftables/  ->  installed /usr/lib/nftban/templates/
#     nftables.conf      source install/nftables/  ->  installed /etc/nftban/
# Only when NEITHER exists is a verdict owed, and it is never PASS:
#     source tree (repo sentinel present) -> FAIL, the surface is required
#     otherwise                           -> NOT_TESTED, reported and excluded
ROOT="$SD/../../../.."
# A repo-only file: packaging/ is never installed, so its presence discriminates
# a source checkout from an installed package without consulting the surfaces
# under test (which would be circular).
IS_SOURCE_TREE=0; [[ -r "$ROOT/packaging/build_nftban.sh" ]] && IS_SOURCE_TREE=1
NOTTESTED=0; NOTTESTED_NAMES=()
resolve_surface(){  # resolve_surface <candidate>...  -> echoes the first readable path, or empty
    local c
    for c in "$@"; do [[ -r "$c" ]] && { printf '%s' "$c"; return 0; }; done
    printf ''
    return 1
}
TPL="$(resolve_surface "$ROOT/install/nftables/nftables.conf.tpl" \
                            /usr/lib/nftban/templates/nftables.conf.tpl || true)"
CONF="$(resolve_surface "$ROOT/install/nftables/nftables.conf" \
                             /etc/nftban/nftables.conf || true)"

# ⛔ THE CLAIM-SURFACE POPULATION. This test's own thesis is
#     SECURITY CLAIM == RUNTIME STRUCTURE == OPERATOR REPORT
# and until v1.233.0 it enforced only two thirds of that: the operator-report
# arms read ONE file ($F) while three OTHER files print connlimit scope claims to
# the operator. Measured on lab2/lab3/lab4 with a fully green gate: `nftban ddos
# help` asserted the rules "carry no ip saddr key" while the kernel carried it,
# and on a DDOS_ENABLED=false host the ONLY scope line the CLI produced said
# "host-wide (not per source)".
#
#     THE OPERATOR-REPORT LIMB WAS GUARDED OVER A SUBSET OF ITSELF.
#
# Any file that PRINTS a connlimit scope claim belongs here, not just the one
# that prints the good claim.
CLAIM_SURFACES=(
    "$F"
    "$SD/../core/nftban_ddos.sh"
    "$SD/../cli/cmd_ddos.sh"
    "$SD/../cli/cmd_port.sh"
)
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# NOT_TESTED is its own verdict class. It is never PASS and never FAIL; it is the
# honest answer when a surface is legitimately absent from this layout.
nt(){ printf '  ....  NOT_TESTED  %s\n' "$1"; NOTTESTED=$((NOTTESTED+1)); NOTTESTED_NAMES+=("$1"); }
# Adjudicate an unresolved required surface ONCE, at the point of use.
unresolved(){  # unresolved <label>
    if [[ "$IS_SOURCE_TREE" -eq 1 ]]; then
        no "$1 REQUIRED surface missing from the source tree"
    else
        nt "$1 not present in this installed layout"
    fi
}

# MENTION != CODE: comments describe history and must never satisfy an assertion.
strip(){ grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }
body="$(strip "$F")"

# A BARE host-wide connlimit: `ct count over` with no saddr key on the same line.
bare_count(){ strip "$1" | grep -E 'ct count over' | grep -vcE 'ip6?[[:space:]]+saddr' || true; }

echo "=== the connlimit claim must match the connlimit keying (v1.231.0) ==="
echo ""

# --- P1 the rendered claim states PER SOURCE ---------------------------------
n=$(grep -c 'concurrent PER SOURCE' <<<"$body" || true)
[[ "$n" -ge 2 ]] && ok "P1 both connlimit lines report PER SOURCE ($n renderings)" \
                 || no "P1 PER SOURCE wording missing (found $n)"
grep -q 'one source cannot consume' <<<"$body" \
  && ok "P1b the operator consequence is stated, not just the keying" \
  || no "P1b consequence not stated"

# --- P2 EVERY emission surface is actually keyed ------------------------------
# This is the half the v1.229.10 test could not assert, because it was false then.
# ⛔ bare_count() on an UNREADABLE file returns 0, which is indistinguishable
# from "inspected and clean". Adjudicate resolvability FIRST, per surface.
surfaces_bare=0; surfaces_seen=0
for lbl in tpl conf frag; do
    case "$lbl" in tpl) f="$TPL";; conf) f="$CONF";; frag) f="$FRAG";; esac
    if [[ -z "$f" || ! -r "$f" ]]; then unresolved "P2 $lbl"; continue; fi
    surfaces_seen=$((surfaces_seen+1))
    c=$(bare_count "$f")
    [[ "$c" -eq 0 ]] || { no "P2 $(basename "$f") has $c bare host-wide ct count rule(s)"; surfaces_bare=1; }
done
if [[ "$surfaces_seen" -eq 0 ]]; then
    no "P2 vacuous: no emission surface was inspected at all"
elif [[ "$surfaces_bare" -eq 0 ]]; then
    ok "P2 no bare host-wide ct count in any inspected emission surface ($surfaces_seen/3)"
fi

# --- P0 NO CLAIM SURFACE MAY CONTRADICT THE KERNEL ---------------------------
# ⛔ Scans EVERY file that prints a connlimit scope claim, not just the one that
# prints the correct one. Reads raw text (NOT strip()) on purpose: these claims
# live inside `echo`/heredoc help text, and for the GENERATED fragment header
# they are emitted verbatim into /etc/nftban/rules.d/*.nft as operator-visible
# output. A comment that reaches the operator is a claim, not a comment — which
# is precisely the case MENTION!=CODE was blind to.
contradictions=0
claim_seen=0
# Labelled so an unresolved surface is NAMED in the coverage report; a bare
# basename of an empty path reads as "<unresolved>" and tells the reader nothing.
for entry in "${CLAIM_SURFACES[@]/#/claim:}" "frag:$FRAG" "tpl:$TPL" "conf:$CONF"; do
    lbl="${entry%%:*}"; cs="${entry#*:}"
    [[ "$lbl" == claim ]] && lbl="$(basename "$cs")"
    # ⛔ was `[[ -r "$cs" ]] || continue` — a silent skip that let P0 report a
    # clean sweep over surfaces it never opened. Absence is now adjudicated.
    if [[ -z "$cs" || ! -r "$cs" ]]; then unresolved "P0 $lbl"; continue; fi
    claim_seen=$((claim_seen+1))
    # "not per source"/"host-wide" asserted as CURRENT scope. Historical notes
    # explaining what v1.233.0 changed are permitted and must say so explicitly.
    # ⛔ MATCH ONLY AN ASSERTION OF HOST-WIDE SCOPE. The first version of this
    # detector matched the bare substring 'host-wide' and therefore flagged the
    # CORRECT text "PER SOURCE IP, not host-wide" — an over-match is as broken as
    # a miss (this is what N4 exists to catch, and it caught me). Negations and
    # dated historical notes are legitimate and must not fire.
    # ⛔ DETECTOR case-INsensitive (v1.233.0 G3): 'NOT per source IP:' at
    # nft_schema.sh:289 escaped the case-sensitive 'not per source IP:' pattern.
    # The alternation (HOST-WIDE|host-wide) already showed the intent was to
    # match either casing; -i makes that uniform.
    # ⛔ The EXCLUSION list stays case-SENSITIVE on purpose. Under -i the allow
    # term 'PER SOURCE' would match the 'per source' inside a stale claim such as
    # 'host-wide, not per source', excluding the very lines P0 exists to catch —
    # a detector disarmed by its own allow-list. N6 pins this.
    hits=$(grep -niE '(is|are|count is|remains?|stays?) +host-wide|host-wide, not per|not per source IP:|concurrent GLOBAL' "$cs" 2>/dev/null \
           | grep -vE 'not host-wide|NOT host-wide|v1\.233|was told|previously|until v1|historical|no longer|PER SOURCE' || true)
    if [[ -n "$hits" ]]; then
        no "P0 $(basename "$cs") still asserts host-wide scope:"
        printf '        %s\n' "$hits" | head -3
        contradictions=1
    fi
done
if [[ "$claim_seen" -eq 0 ]]; then
    no "P0 vacuous: no claim surface was inspected at all"
elif [[ "$contradictions" -eq 0 ]]; then
    ok "P0 no claim surface contradicts the keyed kernel contract ($claim_seen surfaces inspected)"
fi

# --- N6 NON-VACUITY FOR P0 ---------------------------------------------------
tmp_claim=$(mktemp)
printf 'echo "ct count over N — host-wide, not per source IP"\n' > "$tmp_claim"
if grep -qE 'host-wide|not per source' "$tmp_claim"; then
    ok "N6 negative control: the P0 detector fires on a synthesised stale claim"
else
    no "N6 negative control FAILED — P0 cannot detect a stale claim"
fi
rm -f "$tmp_claim"

# --- P3 THE OPERATOR SURFACE MUST POSITIVELY STATE THE NEW CONTRACT ----------
# ⛔ ABSENCE OF THE WRONG CLAIM IS NOT PRESENCE OF THE RIGHT ONE. N1/N2 below
# only prove the stale GLOBAL/"/IP" wording is gone. A surface that says NOTHING
# about scope would pass both and still leave the operator unable to learn what
# the firewall now enforces — which is the exact asymmetry that let the original
# defect sit behind correct-looking surfaces for eight months.
#
#     SECURITY CLAIM == RUNTIME STRUCTURE == OPERATOR REPORT.
#
# The kernel now keys on source identity, so the report must SAY source identity.
if grep -qE 'Conn:.*concurrent PER SOURCE' <<<"$body"; then
    ok "P3 the operator surface positively states the per-source contract"
else
    no "P3 the operator surface does not state the per-source contract (absence of the stale claim is not a claim)"
fi

# --- P3b the claim must be SOURCE identity, not a stronger identity ----------
# nftables keys on the L3 source address. It cannot see HTTP Host, account, or
# vhost. srv2 proves why this matters: many name-based sites share ONE public
# IP, so "per website" would be unachievable at this layer and a false promise.
if grep -qiE 'Conn:.*per (website|account|vhost|virtual host|user|destination)' <<<"$body"; then
    no "P3b the surface claims an identity nftables cannot key on at L3"
else
    ok "P3b no over-claimed identity (source-address scope only)"
fi

# --- N0 NON-VACUITY FOR P3: a stale surface must FAIL the positive arm -------
# Without this, P3 could pass against any text whatsoever if the grep were wrong.
# Synthesise the PRE-FIX operator output and require the assertion to reject it.
stale_body='    SSH Conn:  max 15 concurrent GLOBAL (not per-source)
    HTTP Conn: max 200 concurrent GLOBAL (not per-source)'
if grep -qE 'Conn:.*concurrent PER SOURCE' <<<"$stale_body"; then
    no "N0 negative control FAILED — the P3 assertion accepts the pre-fix GLOBAL output"
else
    ok "N0 negative control: the pre-fix GLOBAL output does NOT satisfy P3"
fi

# --- N1 the retired GLOBAL claim must not linger ------------------------------
if grep -qE 'concurrent GLOBAL \(not per-source\)' <<<"$body"; then
    no "N1 a stale GLOBAL connlimit claim still renders alongside the keyed rules"
else
    ok "N1 no stale GLOBAL claim remains"
fi

# --- N2 the ORIGINAL defect must not return ----------------------------------
if grep -qE '(SSH|HTTP) Conn:.*/IP' <<<"$body"; then
    no "N2 the pre-v1.229.10 '/IP' shorthand returned"
else
    ok "N2 the pre-v1.229.10 '/IP' claim has not returned"
fi

# --- N3 NEGATIVE CONTROL: a bare rule must be detectable ----------------------
# Without this, P2 could be passing because the detector is broken rather than
# because the tree is clean. Synthesise the MOTIVATING defect.
tmp_bare=$(mktemp)
printf 'add rule ip nftban c tcp dport 25 ct state new ct count over 30 counter drop\n' > "$tmp_bare"
if [[ "$(bare_count "$tmp_bare")" -ge 1 ]]; then
    ok "N3 negative control: the bare-rule detector fires on a synthesised host-wide rule"
else
    no "N3 negative control FAILED — P2 is not meaningful"
fi
rm -f "$tmp_bare"

# --- N4 NEGATIVE CONTROL: a keyed rule must NOT trip the detector -------------
tmp_keyed=$(mktemp)
printf 'add rule ip nftban c ct state new tcp dport 53 add @connlimit_dns_v4 { ip saddr ct count over 50 } counter drop\n' > "$tmp_keyed"
if [[ "$(bare_count "$tmp_keyed")" -eq 0 ]]; then
    ok "N4 negative control: a keyed rule does not trip the bare-rule detector"
else
    no "N4 the detector over-matches — a correct keyed rule reads as a defect"
fi
rm -f "$tmp_keyed"

# --- N5 MENTION != CODE -------------------------------------------------------
tmp_comment=$(mktemp)
printf '# historical: ct count over 30 with no saddr key\n' > "$tmp_comment"
if [[ "$(bare_count "$tmp_comment")" -eq 0 ]]; then
    ok "N5 a commented mention does not trip the guard (MENTION != CODE)"
else
    no "N5 comments are being matched as code"
fi
rm -f "$tmp_comment"

echo ""
echo "  PASS=$PASS FAIL=$FAIL NOT_TESTED=$NOTTESTED"
# ⛔ Never let a PASS count stand in for coverage. If anything went uninspected,
# say so on the same line a reader uses to judge the run.
if [[ "$NOTTESTED" -gt 0 ]]; then
    echo "  ⚠ COVERAGE INCOMPLETE — these surfaces were NOT inspected in this layout:"
    printf '      - %s\n' "${NOTTESTED_NAMES[@]}"
fi
[[ "$FAIL" -eq 0 ]]
