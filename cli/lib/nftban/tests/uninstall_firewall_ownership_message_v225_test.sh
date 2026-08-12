#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.225.0 PR-C: uninstall firewall-ownership operator message
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="uninstall_firewall_ownership_message_v225_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-22"
# meta:description="Regression guard for v1.225.0 PR-C (OPEN_UNINSTALL_HELP_MESSAGE_OPERATOR_OWNS_FIREWALL). Message-only. Inspects the ACTUAL package scripts (packaging/deb/postrm + the RPM %postun emitted by packaging/build_nftban.sh) — NOT fixture-only text — to prove: the operator firewall-ownership message is in the DEB `remove)` branch (once), NOT in the `purge)` branch (no duplicate), and in the RPM `[ \$1 -eq 0 ]` FINAL-ERASE branch (not upgrade). v1.229 UNINSTALL-PR2 D5: parity is now asserted on the TRUTH CONTRACT, not on a literal string — both families must state that NFTBan no longer protects the host, must direct the operator to review the resulting firewall state, and must disclose that nftables tooling may have been removed by package-manager dependency cleanup; NEITHER may claim that other firewall rules remain active, because nothing in either scriptlet observes that. Forbidden claims absent; cleanup precedes the message; uninstall cleanup behavior intact. Hermetic static package-script inspection; no host."
# meta:inventory.files="packaging/deb/postrm,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="uninstall_firewall_ownership_message_v225_test"
# meta:ta.owner="packaging"
# meta:ta.module="packaging"
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
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
POSTRM="$REPO_ROOT/packaging/deb/postrm"
BUILD="$REPO_ROOT/packaging/build_nftban.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "v1.225.0 PR-C uninstall firewall-ownership message:"

# Extract a DEB postrm case branch: from `<label>)` to the next `;;`.
deb_case(){ awk -v lbl="$1" '
  $0 ~ "^[[:space:]]*"lbl"\\)[[:space:]]*$" {inb=1; next}
  inb && /^[[:space:]]*;;[[:space:]]*$/ {exit}
  inb {print}
' "$POSTRM"; }

REMOVE="$(deb_case remove)"
PURGE="$(deb_case purge)"

# ---- v1.229 UNINSTALL-PR2 (D5): TRUTH CONTRACT, not literal-string parity ----
# The old NOTMOD phrase asserted that other firewall rules "were NOT modified and
# may still be active". Nothing in either scriptlet observes other firewall
# authorities, and on the proven EL9 host the package manager's own dependency
# cleanup removed the nftables tooling in the same transaction — so the claim was
# false exactly when it read as reassurance. It is now FORBIDDEN, not required.
#
#   DO NOT ASSERT a firewall state that was not observed.
#
# Parity is enforced on meaning. The wording may differ between families
# ("[NFTBan] " vs "nftban: " prefixes already do); the guarantees may not.
CORE='NFTBan-owned nftables tables and enforcement rules were deleted'
UNPROT='no longer protects this host'
REVIEW='Review the resulting firewall state'
CASCADE='nftables tooling may have been removed by package-manager dependency cleanup'
INSPECT='sudo nft list ruleset'
RESTORE='To restore NFTBan protection, reinstall/start NFTBan'
# Retired claim — must NOT appear in either family.
NOTMOD='were NOT modified and may still be active'

# ---- DEB remove branch ----
grep -qF "$CORE"    <<<"$REMOVE" && ok "DEB remove: states NFTBan-owned rules deleted"                    || no "DEB remove: missing owned-rules statement"
grep -qF "$UNPROT"  <<<"$REMOVE" && ok "DEB remove: states NFTBan no longer protects this host"             || no "DEB remove: missing unprotected statement"
grep -qF "$REVIEW"  <<<"$REMOVE" && ok "DEB remove: directs operator to review resulting firewall state"    || no "DEB remove: missing review directive"
grep -qF "$CASCADE" <<<"$REMOVE" && ok "DEB remove: discloses possible nftables tooling removal"            || no "DEB remove: missing dependency-cleanup disclosure"
grep -qF "$NOTMOD"  <<<"$REMOVE" && no "DEB remove: asserts an UNOBSERVED 'other firewall still active' state (D5)" || ok "DEB remove: makes no unobserved other-firewall claim"
grep -qF "$INSPECT" <<<"$REMOVE" && ok "DEB remove: includes 'sudo nft list ruleset'"                          || no "DEB remove: missing inspect command"
grep -qF "$RESTORE" <<<"$REMOVE" && ok "DEB remove: includes restore guidance"                                || no "DEB remove: missing restore guidance"

# ---- DEB purge branch must NOT duplicate the message ----
grep -qF "$CORE" <<<"$PURGE" && no "DEB purge duplicates the ownership message" "should appear only in remove" || ok "DEB purge does NOT duplicate the message (no double-print)"

# ---- DEB: cleanup precedes the message (delete table before the echo) ----
if awk '/delete table ip nftban/{d=NR} /'"$CORE"'/{m=NR} END{exit !(d>0 && m>0 && d<m)}' <<<"$REMOVE"; then
    ok "DEB remove: NFTBan table deletion precedes the message"
else
    no "DEB remove: message not printed after table-deletion cleanup"
fi

# ---- RPM %postun: message in the FINAL-ERASE branch only ----
grep -qF "$CORE" "$BUILD" && ok "RPM %postun: ownership message present in build_nftban.sh" || no "RPM %postun: message missing"
# the message must sit within the `[ $1 -eq 0 ]` FINAL-ERASE guard (not an upgrade branch).
# Track the most recent $1-comparison guard; at the message line it must be an erase guard.
# ([^0-9]1 matches both `$1 ` and the heredoc-escaped `\$1 `; \] = literal ].)
if awk '
    /[^0-9]1 -eq 0 \]/                                  { guard="erase" }
    /[^0-9]1 -ge 1 \]|[^0-9]1 -gt 0 \]|[^0-9]1 -ne 0 \]/ { guard="upgrade" }
    # v1.229 D5: anchor updated to the live phrase. The old anchor
    # ("no longer protecting this system") no longer exists, and awk exits 0 at
    # END when nothing matches — so a stale anchor made this arm report PASS
    # while testing nothing. `seen` makes a missing anchor FAIL CLOSED.
    /no longer protects this host/                      { seen=1; exit (guard=="erase")?0:1 }
    END                                                 { if (!seen) exit 1 }
' "$BUILD"; then
    ok "RPM %postun: message governed by the [ \$1 -eq 0 ] final-erase guard (not upgrade)"
else
    no "RPM %postun: message not governed by the final-erase guard"
fi
grep -qF "$INSPECT" "$BUILD" && ok "RPM %postun: includes 'sudo nft list ruleset'" || no "RPM %postun: missing inspect command"
grep -qF "$RESTORE" "$BUILD" && ok "RPM %postun: includes restore guidance"        || no "RPM %postun: missing restore guidance"
grep -qF "$UNPROT"  "$BUILD" && ok "RPM %postun: states NFTBan no longer protects this host"          || no "RPM %postun: missing unprotected statement"
grep -qF "$REVIEW"  "$BUILD" && ok "RPM %postun: directs operator to review resulting firewall state" || no "RPM %postun: missing review directive"
grep -qF "$CASCADE" "$BUILD" && ok "RPM %postun: discloses possible nftables tooling removal"         || no "RPM %postun: missing dependency-cleanup disclosure"

# ---- Forbidden claims absent (both scripts) ----
forbid=0
for f in "$POSTRM" "$BUILD"; do
    while IFS= read -r bad; do
        if grep -qiE "$bad" "$f"; then no "forbidden claim present in $(basename "$f")" "$bad"; forbid=$((forbid+1)); fi
    done <<'BAD'
host has no firewall
all nftables rules were deleted
all firewall software
network access is safe
automatically restore
BAD
done
[[ $forbid -eq 0 ]] && ok "no forbidden over-claims in either package script"

# ---- No uninstall behavior change: cleanup logic intact ----
grep -qF 'delete table ip nftban'  "$POSTRM" && grep -qF 'delete table ip6 nftban' "$POSTRM" \
  && ok "DEB uninstall behavior intact (table deletion still present)" || no "DEB table-deletion cleanup missing"

# ---- v1.229 D5: the retired claim must be absent from BOTH families ----
retired=0
for f in "$POSTRM" "$BUILD"; do
    if grep -qF "$NOTMOD" "$f"; then
        no "retired unobserved claim still present in $(basename "$f")" "$NOTMOD"; retired=1
    fi
done
[[ $retired -eq 0 ]] && ok "neither family asserts other firewall rules remain active"

# ---- Parity on the TRUTH CONTRACT (meaning), not on a literal string ----
# A family that drops any guarantee fails even if its own wording is internally
# consistent. Wording may differ; the guarantees may not.
parity=0
for p in "$CORE" "$UNPROT" "$REVIEW" "$CASCADE" "$INSPECT" "$RESTORE"; do
    grep -qF "$p" "$POSTRM" && grep -qF "$p" "$BUILD" || { parity=1; no "DEB↔RPM truth-contract parity gap" "$p"; }
done
[[ $parity -eq 0 ]] && ok "DEB↔RPM parity on all 6 truth-contract guarantees"

# ---- FALSIFIABILITY: the retired-claim detector must be able to see it ----
# Without this, the absence assertions above could pass on a blind grep.
if grep -qF "$NOTMOD" <<<"nftban: rules ${NOTMOD} today"; then
    ok "retired-claim detector IS sighted (absence assertions are load-bearing)"
else
    no "retired-claim detector blind" "every D5 absence arm would be vacuous"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
