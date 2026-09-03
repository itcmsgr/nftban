#!/usr/bin/env bash
# =============================================================================
# NFTBan - boot projection generator test (v1.229.12 P12-FPA Phase 1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="boot_projection_v1229_13_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-28"
# meta:description="Locks the P12-FPA Phase 1 boot-projection generator. T1 path/header authority. T2 FAIL-CLOSED when the render authority is absent (the generator must never substitute placeholders itself). T3 generation from the REAL canonical schema through the REAL _firewall_substitute_placeholders. T4 DETERMINISM — two generations from identical inputs are byte-identical, which is what makes drift detectable. T5 the generated projection parses under nft -c. T6 a candidate that fails validation must NOT replace an existing good projection, and must leave no temp file. T7 unrendered placeholders never reach disk. T8 atomicity — no .tmp residue. Hermetic: TMPDIR sandbox, NFTBAN_LIB_DIR/NFTBAN_CONFIG_DIR redirected, no host or systemd state touched."
# meta:input="cli/lib/nftban/lib/boot_projection.sh, cli/lib/nftban/cli/cmd_firewall.sh, install/nftables/nftables.conf.tpl"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,nft,mktemp,grep,diff"
# meta:ta.id="boot_projection_v1229_13_test"
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
# meta:inventory.binaries="bash,nft,mktemp,grep,diff"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$ROOT/cli/lib/nftban/lib/boot_projection.sh"
CMD="$ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
TPL="$ROOT/install/nftables/nftables.conf.tpl"

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }
inf() { printf '  [INFO] %s\n' "$1"; }

for f in "$LIB" "$CMD" "$TPL"; do
    [[ -f "$f" ]] || { bad "MISSING: $f"; echo "=== boot_projection: FAILS=$FAILS ==="; exit 1; }
done

SB=$(mktemp -d) || exit 1
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/empty-lib" "$SB/conf"
export NFTBAN_LIB_DIR="$SB/empty-lib"
export NFTBAN_CONFIG_DIR="$SB/conf"

echo "=== boot_projection (P12-FPA Phase 1) ==="

# shellcheck source=/dev/null
source "$LIB"

# ⛔ PUBLICATION-CONTRACT ARMS NEED A DECIDABLE VALIDATOR.
# After the v1.229.13 rc=2 tightening, publication REQUIRES established validity:
# UNKNOWN may only PRESERVE an identical artifact, never create or change one. On a
# host where validity CANNOT BE ESTABLISHED there is nothing publishable and every
# publication arm becomes untestable. Substitute a DETERMINISTIC nft stub there.
# The stub shadows `nft`, NOT the validator, so nftban_boot_projection_validate's own
# logic stays under test. ⛔ A STUB PROVES THE PUBLICATION CONTRACT, NOT nft's SYNTAX
# JUDGEMENT — real `nft -c` coverage belongs to the package/boot validation lane.
NFT_IS_STUB=0
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
    NFT_IS_STUB=1
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

# --- T1 path + header authority --------------------------------------------
P="$(nftban_boot_projection_path)"
if [[ "$P" == "$SB/conf/generated/nftban-boot.nft" ]]; then
    ok "T1 path authority honours NFTBAN_CONFIG_DIR: .../generated/nftban-boot.nft"
else
    bad "T1 unexpected path: $P"
fi
H="$(nftban_boot_projection_header)"
if grep -q "DO NOT EDIT" <<<"$H" && grep -q "GENERATED BOOT PROJECTION" <<<"$H" \
   && ! grep -qiE '[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{2}:[0-9]{2}:[0-9]{2}' <<<"$H"; then
    ok "T1 header carries DO-NOT-EDIT and is timestamp-free (byte-reproducible)"
else
    bad "T1 header wrong or carries a timestamp (would defeat drift detection)"
    sed 's/^/         /' <<<"$H"
fi

# --- T2 FAIL-CLOSED without the render authority ----------------------------
# The generator must refuse rather than fall back to its own substitution.
if declare -F _firewall_substitute_placeholders >/dev/null 2>&1; then
    bad "T2 precondition broken — render authority already defined before the negative case"
else
    OUT2="$SB/conf/generated/t2.nft"
    ERR2=$(nftban_boot_projection_generate "$TPL" "$OUT2" 2>&1); RC2=$?
    if [[ "$RC2" -ne 0 ]] && grep -q "_firewall_substitute_placeholders" <<<"$ERR2" && [[ ! -f "$OUT2" ]]; then
        ok "T2 FAILS CLOSED without the render authority, names it, and writes nothing"
    else
        bad "T2 did not fail closed (rc=$RC2, file exists: $([[ -f "$OUT2" ]] && echo yes || echo no))"
    fi
fi

# --- T2b FAIL-CLOSED without the PUBLICATION authority ----------------------
# A bare `mv` would preserve the temp file's SELinux type, so the projection would
# carry nftban_conf_t and the distro nftables.service (nft in iptables_t) could not
# read it — a boot-time FAILED_NO_FIREWALL with a misleading "File not found".
# The generator must refuse rather than publish it itself.
( _firewall_substitute_placeholders() { cp "$1" "$2"; }
  OUT2B="$SB/conf/generated/t2b.nft"
  ERR2B=$(nftban_boot_projection_generate "$TPL" "$OUT2B" 2>&1); RC2B=$?
  [[ "$RC2B" -ne 0 ]] && grep -q "_firewall_publish_conf" <<<"$ERR2B" && [[ ! -f "$OUT2B" ]]
) && ok "T2b FAILS CLOSED without the SELinux-aware publication authority" \
   || bad "T2b published without _firewall_publish_conf (would carry the wrong SELinux type)"

# --- load the REAL render authority ----------------------------------------
# cmd_firewall.sh only defines functions at top level (its guarded sources are
# no-ops against the empty sandbox), so sourcing dispatches nothing.
# shellcheck source=/dev/null
source "$CMD"
declare -F _firewall_substitute_placeholders >/dev/null 2>&1 \
    || { bad "render authority not defined after sourcing $CMD"; echo "=== boot_projection: FAILS=$FAILS ==="; exit 1; }

# --- T3 generation from the real canonical schema ---------------------------
OUT="$(nftban_boot_projection_path)"
if nftban_boot_projection_generate "$TPL" "$OUT" 2>"$SB/gen.err"; then
    ok "T3 generated from the real canonical schema through the real render authority"
else
    bad "T3 generation failed:"; sed 's/^/         /' "$SB/gen.err" | head -5
fi

if [[ -f "$OUT" ]]; then
    if head -1 "$OUT" | grep -q '^#!' && grep -q "DO NOT EDIT" "$OUT"; then
        ok "T3 output keeps the #! first and carries the DO-NOT-EDIT header"
    else
        bad "T3 output preamble wrong: $(head -2 "$OUT" | tr '\n' '|')"
    fi
    # --- T7 no unrendered placeholders --------------------------------------
    if [[ -z "$(grep -oE '__[A-Z0-9_]+__' "$OUT")" ]]; then
        ok "T7 no unrendered placeholders reached disk"
    else
        bad "T7 unrendered placeholders in the installed projection:"
        grep -oE '__[A-Z0-9_]+__' "$OUT" | sort -u | sed 's/^/         /'
    fi
fi

# --- T4 DETERMINISM ---------------------------------------------------------
cp "$OUT" "$SB/first.nft"
if nftban_boot_projection_generate "$TPL" "$OUT" 2>/dev/null && diff -q "$SB/first.nft" "$OUT" >/dev/null; then
    ok "T4 DETERMINISTIC — two generations from identical inputs are byte-identical"
else
    bad "T4 generation is NOT deterministic — drift becomes undetectable:"
    diff "$SB/first.nft" "$OUT" | head -6 | sed 's/^/         /'
fi

# --- T5 the installed projection parses -------------------------------------
# ⛔ SOURCING cmd_firewall.sh ABOVE ENABLES errexit IN THIS SHELL
# (cli/lib/nftban/cli/cmd_firewall.sh:29 is `set -Eeuo pipefail` at top level).
# A BARE call to a function that returns non-zero therefore KILLS this test
# rather than failing an assertion. That is invisible while nft is installed —
# validate returns 0 — and aborts the whole test on a runner without nft, which
# is exactly what happened in CI. Keep every such call in a TESTED position.
VRC=0
nftban_boot_projection_validate "$OUT" "installed projection" 2>/dev/null || VRC=$?
case "$VRC" in
    0) if [[ "$NFT_IS_STUB" -eq 1 ]]; then
           inf "T5 INCONCLUSIVE — validated against the deterministic stub, not real nft -c"
       else
           ok "T5 installed projection parses under nft -c"
       fi ;;
    2) inf "T5 INCONCLUSIVE — nft -c could not run here (a skip is not a pass)" ;;
    *) bad "T5 installed projection FAILS nft -c" ;;
esac

# --- T6 a rejected candidate must not replace a good projection -------------
GOOD_SUM=$(sha256sum < "$OUT")
BROKEN="$SB/broken.tpl"
sed 's/^table ip nftban {/table ip nftban { NOT_NFT_SYNTAX/' "$TPL" > "$BROKEN"
if nftban_boot_projection_generate "$BROKEN" "$OUT" 2>/dev/null; then
    if [[ "$VRC" -eq 2 ]]; then
        inf "T6 INCONCLUSIVE — validation is unavailable here, so a bad candidate cannot be rejected"
    else
        bad "T6 a candidate that fails nft -c was INSTALLED over a good projection"
    fi
else
    if [[ "$(sha256sum < "$OUT")" == "$GOOD_SUM" ]]; then
        ok "T6 rejected candidate did NOT replace the existing good projection"
    else
        bad "T6 the existing projection was damaged by a failed generation"
    fi
fi

# --- T8 atomicity: no temp residue ------------------------------------------
RESIDUE=$(find "$SB/conf/generated" -name '*.tmp.*' 2>/dev/null)
if [[ -z "$RESIDUE" ]]; then
    ok "T8 no temp-file residue after success and failure paths"
else
    bad "T8 temp files left behind:"; sed 's/^/         /' <<<"$RESIDUE"
fi

# --- T9 PUBLICATION CONTRACT — UNKNOWN must not authorize new boot authority ----
# rc=0 valid            -> PERMITTED
# rc=1 invalid          -> FORBIDDEN
# rc=2 cannot establish -> identical: no-op OK · different: FORBIDDEN · absent: FORBIDDEN
#
# The rc=2/absent arm matters most: "there is no previous projection" is LESS evidence
# about the candidate, not more. After the distro include is repointed at this artifact
# an unverified first publication becomes boot-critical.
C="$SB/contract"; mkdir -p "$C"; CO="$C/nftban-boot.nft"
_stub_rc=0
nftban_boot_projection_validate() { return "$_stub_rc"; }

_stub_rc=2; rm -f "$CO"
_rc=0; nftban_boot_projection_generate "$TPL" "$CO" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" -ne 0 && ! -e "$CO" ]]; then
    ok "T9a UNKNOWN + no existing projection -> REFUSED, nothing published"
else
    bad "T9a UNKNOWN published a first projection (rc=$_rc)"
fi

_stub_rc=0
_rc=0; nftban_boot_projection_generate "$TPL" "$CO" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" -eq 0 && -s "$CO" ]]; then ok "T9b VALID -> published"; else bad "T9b a valid candidate was not published (rc=$_rc)"; fi
C_SUM=$(sha256sum < "$CO")

_stub_rc=2
_rc=0; nftban_boot_projection_generate "$TPL" "$CO" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" -eq 0 && "$(sha256sum < "$CO")" == "$C_SUM" ]]; then
    ok "T9c UNKNOWN + byte-identical candidate -> no-op, artifact preserved"
else bad "T9c identical-candidate no-op broke (rc=$_rc)"; fi

sed 's/^table ip nftban {/table ip nftban { CHANGED/' "$TPL" > "$C/diff.tpl"
_rc=0; nftban_boot_projection_generate "$C/diff.tpl" "$CO" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" -ne 0 && "$(sha256sum < "$CO")" == "$C_SUM" ]]; then
    ok "T9d UNKNOWN + DIFFERENT candidate -> REFUSED, existing preserved"
else bad "T9d an unverified CHANGE was published (rc=$_rc)"; fi

_stub_rc=1
_rc=0; nftban_boot_projection_generate "$C/diff.tpl" "$CO" >/dev/null 2>&1 || _rc=$?
if [[ "$_rc" -ne 0 && "$(sha256sum < "$CO")" == "$C_SUM" ]]; then
    ok "T9e INVALID -> REFUSED, existing preserved"
else bad "T9e an invalid candidate was published (rc=$_rc)"; fi

if [[ -z "$(find "$C" -name '*.tmp.*' 2>/dev/null)" ]]; then
    ok "T9f no temp residue from any refused publication"
else bad "T9f temp residue left by a refused publication"; fi
unset -f nftban_boot_projection_validate

echo "=== boot_projection: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]] || exit 1
