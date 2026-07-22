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
# meta:description="Regression guard for v1.225.0 PR-C (OPEN_UNINSTALL_HELP_MESSAGE_OPERATOR_OWNS_FIREWALL). Message-only. Inspects the ACTUAL package scripts (packaging/deb/postrm + the RPM %postun emitted by packaging/build_nftban.sh) — NOT fixture-only text — to prove: the operator firewall-ownership message is in the DEB `remove)` branch (once), NOT in the `purge)` branch (no duplicate), and in the RPM `[ \$1 -eq 0 ]` FINAL-ERASE branch (not upgrade); required semantics present (NFTBan-owned rules deleted / no longer protecting / other firewall authorities NOT modified / operator owns state / `sudo nft list ruleset` / restore guidance); forbidden claims absent (host has no firewall / all nftables deleted / network safe / auto-restore); cleanup precedes the message; and the message change did not remove uninstall cleanup behavior. Hermetic static package-script inspection; no host."
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

CORE='NFTBan-owned nftables tables and enforcement rules were deleted'
NOTMOD='were NOT modified and may still be active'
INSPECT='sudo nft list ruleset'
RESTORE='To restore NFTBan protection, reinstall/start NFTBan'

# ---- DEB remove branch ----
grep -qF "$CORE"    <<<"$REMOVE" && ok "DEB remove: states NFTBan-owned rules deleted / no longer protecting" || no "DEB remove: missing owned-rules statement"
grep -qF "$NOTMOD"  <<<"$REMOVE" && ok "DEB remove: states other firewall authorities NOT modified"           || no "DEB remove: missing not-modified statement"
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
    /no longer protecting this system/                  { exit (guard=="erase")?0:1 }
' "$BUILD"; then
    ok "RPM %postun: message governed by the [ \$1 -eq 0 ] final-erase guard (not upgrade)"
else
    no "RPM %postun: message not governed by the final-erase guard"
fi
grep -qF "$INSPECT" "$BUILD" && ok "RPM %postun: includes 'sudo nft list ruleset'" || no "RPM %postun: missing inspect command"
grep -qF "$RESTORE" "$BUILD" && ok "RPM %postun: includes restore guidance"        || no "RPM %postun: missing restore guidance"

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

# ---- Parity: both families carry the 4 core semantic phrases ----
parity=0
for p in "$CORE" "$NOTMOD" "$INSPECT" "$RESTORE"; do
    grep -qF "$p" "$POSTRM" && grep -qF "$p" "$BUILD" || { parity=1; no "DEB↔RPM parity gap" "$p"; }
done
[[ $parity -eq 0 ]] && ok "DEB↔RPM message parity (4 core phrases in both)"

echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
