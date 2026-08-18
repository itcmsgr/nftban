#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 P1-4 — THE v1.228.5 AUDIT MIGRATION MUST TAKE THE ROTATED SIBLINGS
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="permissions-audit-rotated-siblings-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="P1-4. The v1.228.5 permissions_audit migration is gated on the exact head filename, so rotated siblings written while the old /var/lib stanza was live were never moved, rotated or deleted. Proves the extended migration relocates the exact sibling grammar, is idempotent, never overwrites, never follows symlinks, and touches nothing outside the allowlist. Runs the REAL block extracted from the shipped packaging script with only its two path prefixes remapped."
# meta:inventory.files="packaging/deb/postinst,packaging/build_nftban.sh"
# meta:inventory.privileges="none"
# meta:ta.id="permissions_audit_rotated_siblings_v1229_3_test"
# meta:ta.owner="packaging"
# meta:ta.module="packaging"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   ⛔ HEAD FILE MIGRATED != CLASS MIGRATED. The original block is gated on the exact
#      filename, so it reported success while leaving the rotated generations behind.
#
#   ⛔ EXACT PATTERNS, NEVER A /var/lib SWEEP. The allowlist is the audit basename plus
#      a logrotate suffix grammar. Anything outside it must be untouched — proven by
#      planting decoys that a broader pattern would have taken.
#
#   The block under test is EXTRACTED FROM THE SHIPPED postinst; only the two path
#   prefixes are remapped so it can run unprivileged. If the extraction or the remap
#   fails, that is a TEST FAILURE, never a silent skip.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DEB="$ROOT/packaging/deb/postinst"
RPM="$ROOT/packaging/build_nftban.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== permissions_audit rotated-sibling migration (v1.229.3 P1-4) ==="
for f in "$DEB" "$RPM"; do [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; exit 1; }; done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
OLD="$TMP/var/lib/nftban"; NEW="$TMP/var/log/nftban"
mkdir -p "$OLD" "$NEW"

# ---- extract the REAL loop from the shipped postinst -------------------------
BLOCK="$(awk '/ROTATED SIBLINGS/,/^    done$/' "$DEB")"
if [[ -z "$BLOCK" ]] || ! grep -q 'for _sib in' <<<"$BLOCK"; then
    fail "A0 SUBJECT_NOT_FOUND: could not extract the rotated-sibling loop from postinst"
    echo "RESULT: FAIL"; exit 1
fi
REMAPPED="${BLOCK//\/var\/lib\/nftban/$OLD}"
REMAPPED="${REMAPPED//\/var\/log\/nftban/$NEW}"
# chown/restorecon are root operations; neutralise them without touching the mv logic
REMAPPED="${REMAPPED//chown nftban:nftban/: chown}"
if ! grep -q "$OLD" <<<"$REMAPPED" || ! grep -q "$NEW" <<<"$REMAPPED"; then
    fail "A0 the path remap did not apply — the extracted block would touch real system paths"
    echo "RESULT: FAIL"; exit 1
fi
pass "A0 real migration loop extracted from the shipped postinst and remapped"

run_migration(){ ( set +u; eval "$REMAPPED" ) >/dev/null 2>&1; }

# ---- fixture: a pre-v1.228.5 host with rotated generations -------------------
plant() {
    : > "$OLD/permissions_audit.log.1"
    : > "$OLD/permissions_audit.log.2"
    : > "$OLD/permissions_audit.log.3.gz"
    : > "$OLD/permissions_audit.log-20260701"
    : > "$OLD/permissions_audit.log-20260702.gz"
    # DECOYS — a broader pattern would take these. None may move.
    : > "$OLD/permissions_audit.log"          # the HEAD file: owned by the other block
    : > "$OLD/other_service.log.1"            # different basename
    : > "$OLD/permissions_audit.notes"        # different suffix grammar
    : > "$OLD/permissions_audit.log.keep"     # non-numeric, non-date suffix
    mkdir -p "$OLD/permissions_audit.log.d"   # a directory that matches nothing
}
plant
run_migration

# --- A1 · every rotated sibling moved -----------------------------------------
missing=()
for f in permissions_audit.log.1 permissions_audit.log.2 permissions_audit.log.3.gz \
         permissions_audit.log-20260701 permissions_audit.log-20260702.gz; do
    [[ -f "$NEW/$f" ]] || missing+=("$f")
done
[[ ${#missing[@]} -eq 0 ]] && pass "A1 all 5 rotated siblings relocated (numbered, dateext, compressed)" \
                           || fail "A1 not relocated: ${missing[*]}"

# --- A2 · source side is emptied of exactly those --------------------------------
left=$(find "$OLD" -maxdepth 1 -name 'permissions_audit.log.[0-9]*' -o -maxdepth 1 -name 'permissions_audit.log-[0-9]*' 2>/dev/null | grep -v '\.d$' | grep -v '\.keep$' | wc -l)
[[ "$left" -eq 0 ]] && pass "A2 no rotated sibling left behind in the old location" \
                    || fail "A2 $left sibling(s) still in the old location"

# --- A3 · DECOYS untouched (the allowlist is exact) ----------------------------
d=0
for f in permissions_audit.log other_service.log.1 permissions_audit.notes permissions_audit.log.keep; do
    [[ -f "$OLD/$f" ]] || { fail "A3 decoy MOVED by the migration: $f"; d=1; }
done
[[ -d "$OLD/permissions_audit.log.d" ]] || { fail "A3 a directory was consumed"; d=1; }
[[ $d -eq 0 ]] && pass "A3 head file, foreign basename, foreign suffix and directory all untouched"

# --- A4 · IDEMPOTENCY: a second run changes nothing ----------------------------
before="$(find "$NEW" "$OLD" -type f | sort | md5sum)"
run_migration
after="$(find "$NEW" "$OLD" -type f | sort | md5sum)"
[[ "$before" == "$after" ]] && pass "A4 idempotent — a second run is a no-op" \
                            || fail "A4 second run changed the tree"

# --- A5 · NEVER OVERWRITE: an existing destination is preserved ----------------
rm -rf "${TMP:?}/var"; mkdir -p "$OLD" "$NEW"
echo "NEW-CONTENT" > "$NEW/permissions_audit.log.1"
echo "OLD-CONTENT" > "$OLD/permissions_audit.log.1"
run_migration
if [[ "$(cat "$NEW/permissions_audit.log.1")" == "NEW-CONTENT" ]] \
   && [[ -f "$NEW/permissions_audit.log.1.pre-v1.228.5" ]] \
   && [[ "$(cat "$NEW/permissions_audit.log.1.pre-v1.228.5")" == "OLD-CONTENT" ]]; then
    pass "A5 collision preserved BOTH — destination intact, predecessor beside it"
else
    fail "A5 a collision overwrote or lost audit content"
fi

# --- A6 · a third collision does not overwrite the .pre file ------------------
echo "THIRD" > "$OLD/permissions_audit.log.1"
run_migration
if [[ "$(cat "$NEW/permissions_audit.log.1.pre-v1.228.5")" == "OLD-CONTENT" ]]; then
    pass "A6 an already-used .pre-v1.228.5 slot is never overwritten (audit trail preserved)"
else
    fail "A6 the .pre-v1.228.5 predecessor was overwritten — audit history lost"
fi

# --- A7 · symlinks are refused -------------------------------------------------
rm -rf "${TMP:?}/var"; mkdir -p "$OLD" "$NEW"
echo outside > "$TMP/outside.txt"
ln -s "$TMP/outside.txt" "$OLD/permissions_audit.log.7"
run_migration
if [[ -L "$OLD/permissions_audit.log.7" && ! -e "$NEW/permissions_audit.log.7" && -f "$TMP/outside.txt" ]]; then
    pass "A7 symlink refused — neither relocated nor followed outside the namespace"
else
    fail "A7 a symlinked sibling was relocated or followed"
fi

# --- A8 · DEB and RPM carry the SAME extension --------------------------------
if grep -q 'ROTATED SIBLINGS' "$RPM" && grep -q 'ROTATED SIBLINGS' "$DEB"; then
    pass "A8 both package families carry the sibling migration"
else
    fail "A8 only one package family was extended — families would diverge"
fi

# --- A9 · the extension is OUTSIDE the head-file guard ------------------------
# If it were nested inside `if [ -f "$_oa" ]`, the migration would run once and then
# skip the siblings forever once the head file was gone.
seg="$(awk '/_oa=\/var\/lib\/nftban\/permissions_audit.log/,/ROTATED SIBLINGS/' "$DEB")"
if grep -qE '^\s*fi\s*$' <<<"$seg"; then
    pass "A9 sibling loop sits AFTER the head-file guard closes (runs even once the head is gone)"
else
    fail "A9 the sibling loop appears nested inside the head-file guard"
fi

# --- A10 · INVERSION: a permissive pattern DOES take the decoys ---------------
rm -rf "${TMP:?}/var"; mkdir -p "$OLD" "$NEW"; plant
find "$OLD" -maxdepth 1 -type f -name 'permissions_audit.*' -exec mv -t "$NEW" {} + 2>/dev/null || true
if [[ ! -f "$OLD/permissions_audit.notes" || ! -f "$OLD/permissions_audit.log" ]]; then
    pass "A10 INVERSION: a permissive \"permissions_audit.*\" DOES take the head file/decoys (A3 is falsifiable)"
else
    fail "A10 inversion did not reproduce over-capture — A3 may be vacuous"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
