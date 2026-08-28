#!/usr/bin/env bash
# =============================================================================
# NFTBan - boot projection generator test (v1.229.12 P12-FPA Phase 1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="boot_projection_v1229_12_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-28"
# meta:description="Locks the P12-FPA Phase 1 boot-projection generator. T1 path/header authority. T2 FAIL-CLOSED when the render authority is absent (the generator must never substitute placeholders itself). T3 generation from the REAL canonical schema through the REAL _firewall_substitute_placeholders. T4 DETERMINISM — two generations from identical inputs are byte-identical, which is what makes drift detectable. T5 the generated projection parses under nft -c. T6 a candidate that fails validation must NOT replace an existing good projection, and must leave no temp file. T7 unrendered placeholders never reach disk. T8 atomicity — no .tmp residue. Hermetic: TMPDIR sandbox, NFTBAN_LIB_DIR/NFTBAN_CONFIG_DIR redirected, no host or systemd state touched."
# meta:input="cli/lib/nftban/lib/boot_projection.sh, cli/lib/nftban/cli/cmd_firewall.sh, install/nftables/nftables.conf.tpl"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,nft,mktemp,grep,diff"
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
    if [[ "$RC2" -ne 0 ]] && grep -q "render authority" <<<"$ERR2" && [[ ! -f "$OUT2" ]]; then
        ok "T2 FAILS CLOSED without the render authority, and writes nothing"
    else
        bad "T2 did not fail closed (rc=$RC2, file exists: $([[ -f "$OUT2" ]] && echo yes || echo no))"
    fi
fi

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
nftban_boot_projection_validate "$OUT" "installed projection" 2>/dev/null; VRC=$?
case "$VRC" in
    0) ok "T5 installed projection parses under nft -c" ;;
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

echo "=== boot_projection: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]] || exit 1
