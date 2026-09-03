#!/usr/bin/env bash
# =============================================================================
# NFTBan - P12-FPA Phase 2 render-only entry point test (v1.229.12)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="fpa_render_boot_v1229_13_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-28"
# meta:description="Locks `nftban firewall render-boot`, the P12-FPA Phase 2 render-only entry point. D positive control: renders the canonical schema and publishes the boot projection. E render authority missing -> refuses. F render failure -> refuses, previous projection preserved. G nft -c failure -> refuses, previous projection preserved. I unresolved placeholder never reaches disk. K the historical /etc/nftban/nftables.conf is byte-identical before and after. Also asserts the entry point NEVER loads a ruleset (no nft -f), which is its entire reason for existing. Hermetic: TMPDIR sandbox with a fake NFTBAN_LIB_DIR; no host, kernel or systemd state touched."
# meta:input="cli/lib/nftban/cli/cmd_firewall.sh, cli/lib/nftban/lib/boot_projection.sh, install/nftables/nftables.conf.tpl"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,nft,mktemp,sha256sum"
# meta:ta.id="fpa_render_boot_v1229_13_test"
# meta:ta.owner="firewall"
# meta:ta.module="boot-projection"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,nft,mktemp,sha256sum"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/lib/lib" "$SB/lib/templates" "$SB/conf"
cp "$ROOT/cli/lib/nftban/lib/boot_projection.sh" "$SB/lib/lib/"
cp "$ROOT/install/nftables/nftables.conf.tpl"    "$SB/lib/templates/"
# The historical conffile, present exactly as a migrated host would have it.
cp "$ROOT/install/nftables/nftables.conf"        "$SB/conf/nftables.conf"
LEGACY_BEFORE=$(sha256sum "$SB/conf/nftables.conf" | cut -d' ' -f1)

export NFTBAN_LIB_DIR="$SB/lib" NFTBAN_CONFIG_DIR="$SB/conf"
# shellcheck source=/dev/null
source "$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

# ⛔ Publication now REQUIRES established validity (v1.229.13 rc=2 tightening), so a
# host that cannot run `nft -c` can publish nothing and every arm below would be
# untestable. Shadow `nft` with a deterministic stub there — not the validator, so
# validate's own logic stays under test. A stub proves the CONTRACT, not nft's
# syntax judgement.
# Probe ONCE whether validity can actually be ESTABLISHED here. `command -v nft`
# is the wrong question: the CI runner HAS nft but cannot open netlink, so every
# check returns UNKNOWN(2) — which, under the tightened contract, forbids
# publication and makes every arm below untestable. Ask the validator itself.
# Probe `nft -c` DIRECTLY, mirroring the validator's own escalation. Going through
# nftban_boot_projection_validate is wrong here: one of these tests loads the library
# inside the command under test, so the function may not exist yet at probe time and
# the probe would silently report 127 instead of "cannot validate".
_probe_f="$(mktemp)"; printf 'table ip nftban_probe {\n}\n' > "$_probe_f"
_can_validate=0
if command -v nft >/dev/null 2>&1; then
    if nft -c -f "$_probe_f" >/dev/null 2>&1; then
        _can_validate=1
    elif command -v unshare >/dev/null 2>&1 && unshare -rn nft -c -f "$_probe_f" >/dev/null 2>&1; then
        _can_validate=1
    fi
fi
rm -f "$_probe_f"
if [[ "$_can_validate" -eq 0 ]]; then
    nft() {
        local a prev="" f=""
        for a in "$@"; do [[ "$prev" == "-f" ]] && f="$a"; prev="$a"; done
        case " $* " in
            *" -c "*) [[ -n "$f" && -f "$f" ]] || return 1
                      grep -qE 'NOT_NFT_SYNTAX|NOT_VALID|__[A-Z0-9_]+__' "$f" && return 1
                      return 0 ;;
        esac
        return 0
    }
fi

echo "== D  positive control =="
if _firewall_render_boot --quiet 2>"$SB/d.err"; then ok "render-boot published the projection"
else no "render-boot failed:"; sed 's/^/        /' "$SB/d.err"; fi

TARGET="$SB/conf/generated/nftban-boot.nft"
[[ -f "$TARGET" ]] && ok "artifact at the frozen path .../generated/nftban-boot.nft" \
                  || no "artifact missing at $TARGET"
grep -q "DO NOT EDIT" "$TARGET" 2>/dev/null && ok "artifact carries the DO-NOT-EDIT header" \
                  || no "artifact missing the header"

echo "== I  no unresolved placeholder reaches disk =="
[[ -z "$(grep -oE '__[A-Z0-9_]+__' "$TARGET" 2>/dev/null)" ]] \
  && ok "no unresolved placeholders in the published artifact" \
  || no "unresolved placeholders present"

echo "== the entry point must NOT load a ruleset =="
# nft is shadowed by a recorder: any invocation other than `-c` is a load.
# `nft -c -f FILE` carries BOTH flags, so presence of -f proves nothing. The real
# test is per-invocation: ANY nft call that does not carry -c is a load. unshare is
# recorded too, because the validator retries through a namespace and a load could
# hide there.
LOADLOG="$SB/nft.calls"; : > "$LOADLOG"
nft()     { echo "nft $*"     >> "$LOADLOG"; command nft "$@"; }
unshare() { echo "unshare $*" >> "$LOADLOG"; command unshare "$@"; }
# Tested position, not bare: cmd_firewall.sh enables errexit in this shell.
_firewall_render_boot --quiet >/dev/null 2>&1 || true
# grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` would append a
# SECOND zero and break the arithmetic below. Take the count, ignore the status.
LOADS=$(grep -cvE '(^| )-c( |$)' "$LOADLOG" 2>/dev/null) || true
LOADS=${LOADS:-0}
if [[ "$LOADS" -eq 0 ]]; then
    ok "render-boot never loaded a ruleset ($(wc -l < "$LOADLOG") nft invocations, all carrying -c)"
else
    no "render-boot made $LOADS nft invocation(s) without -c (a LOAD):"
    grep -vE '(^| )-c( |$)' "$LOADLOG" | sed 's/^/        /'
fi
unset -f nft unshare

GOOD_SUM=$(sha256sum "$TARGET" | cut -d' ' -f1)

echo "== E  render authority missing -> refuse =="
( unset -f _firewall_substitute_placeholders
  _firewall_render_boot --quiet >/dev/null 2>&1 ) \
  && no "published without the render authority" \
  || ok "refuses when the render authority is absent"

echo "== F  render failure -> refuse, previous projection preserved =="
( _firewall_substitute_placeholders() { return 1; }
  _firewall_render_boot --quiet >/dev/null 2>&1 ) \
  && no "published despite a render failure" \
  || ok "refuses when the render fails"
[[ "$(sha256sum "$TARGET" | cut -d' ' -f1)" == "$GOOD_SUM" ]] \
  && ok "previous projection intact after render failure" \
  || no "previous projection was damaged by a failed render"

echo "== G  nft -c failure -> refuse, previous projection preserved =="
cp "$SB/lib/templates/nftables.conf.tpl" "$SB/tpl.bak"
sed -i 's/^table ip nftban {/table ip nftban { NOT_NFT_SYNTAX/' "$SB/lib/templates/nftables.conf.tpl"
_firewall_render_boot --quiet >/dev/null 2>&1 \
  && no "published a projection that fails nft -c" \
  || ok "refuses when nft -c rejects the candidate"
[[ "$(sha256sum "$TARGET" | cut -d' ' -f1)" == "$GOOD_SUM" ]] \
  && ok "previous projection intact after nft -c failure" \
  || no "previous projection was damaged by an invalid candidate"
cp "$SB/tpl.bak" "$SB/lib/templates/nftables.conf.tpl"

echo "== no temp residue on any path =="
RES=$(find "$SB/conf" -name '*.tmp.*' -o -name '.nftables.conf.tmp' 2>/dev/null)
[[ -z "$RES" ]] && ok "no temp-file residue" || { no "temp residue:"; sed 's/^/        /' <<<"$RES"; }

echo "== K  historical conffile untouched =="
LEGACY_AFTER=$(sha256sum "$SB/conf/nftables.conf" | cut -d' ' -f1)
if [[ "$LEGACY_BEFORE" == "$LEGACY_AFTER" ]]; then
    ok "legacy /etc/nftban/nftables.conf byte-identical (${LEGACY_BEFORE:0:16}…)"
else
    no "legacy conffile CHANGED: $LEGACY_BEFORE -> $LEGACY_AFTER"
fi

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
