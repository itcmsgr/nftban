#!/usr/bin/env bash
# =============================================================================
# NFTBan — v1.229.7 cross-mode teardown falsification (P1-P4 + N1-N4)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v1229_7_teardown_falsification"
# meta:type="lab"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-24"
# meta:description="Proves the cross-mode teardown contract on the EXACT operator path `nftban ddos reload`, and proves the proof itself is falsifiable by mutating the shipped implementation four ways and requiring each mutation to be DETECTED."
# =============================================================================
#
# ⛔ A REBUILD PASS DOES NOT PROVE A TRANSITION-SPECIFIC TEARDOWN PATH.
# `firewall rebuild` recreates the table and therefore never creates the
# opposite mode's objects; it cannot exercise cross-mode teardown at all. Every
# arm here uses `nftban ddos reload`, the operator path where the defect lived.
#
# ⛔ FINAL STATE ALONE IS NOT ENOUGH -- ASSERT THE SUBJECT POPULATION.
# The shipped fix once processed ZERO subjects and still returned success
# (inherited IFS=$'\n\t' made `read -r kind name` leave $name empty). A test that
# only checks the end state would call an empty loop a pass on a host that
# happened to start clean. So every arm asserts:
#       EXPECTED_POPULATION  > 0
#       DISCOVERED           == EXPECTED_POPULATION
#       PURGED               == DISCOVERED
#   NO SUBJECTS PROCESSED != NOTHING TO DO
set -uo pipefail

SRC=/usr/lib/nftban/core/nftban_ddos.sh
PRISTINE="/var/tmp/nftban-ddos.pristine.$$"
F=0
ok(){   echo "  ok    $*"; }
bad(){  F=$((F+1)); echo "  FAIL  $*"; }

[[ -r "$SRC" ]] || { echo "FATAL: $SRC not readable"; exit 2; }
# COPY never MOVE: the pristine copy is the restore source and is never the
# file under test.
cp -p "$SRC" "$PRISTINE" || { echo "FATAL: cannot snapshot $SRC"; exit 2; }
restore(){ cp -p "$PRISTINE" "$SRC"; rm -f "$PRISTINE"; }
# Restore on ANY exit path -- a mutated product left installed would be far
# worse than a failed test.
trap 'restore' EXIT INT TERM

setmode(){ printf 'DDOS_ENABLED="true"\nDDOS_MODE="%s"\n' "$1" > /etc/nftban/conf.d/ddos/main.conf.local; }
# Classic-owned objects only: ddos_blocked is the SHARED ban set and is never
# part of the classic projection census.
classic_objs(){
  local f n=0
  for f in ip ip6; do
    n=$((n + $(nft list table "$f" nftban 2>/dev/null \
        | grep -oE 'chain ddos_[a-z_]+|set ddos_[a-z_0-9]+' \
        | grep -v 'ddos_blocked' | grep -c . || true)))
  done
  echo "$n"
}
jumps(){ local f n=0; for f in ip ip6; do n=$((n + $(nft list chain "$f" nftban input 2>/dev/null | grep -coE 'jump ddos_[a-z_]+' || true))); done; echo "$n"; }
valchain(){ /usr/lib/nftban/bin/nftban-validate 2>&1 | grep -c 'VAL-CHAIN-004' || true; }

# transition_converges -- classic -> suricata via the OPERATOR path.
# Returns 0 only if the population was non-vacuous AND fully purged AND the
# runtime matches the plan exactly. Prints its own evidence line.
transition_converges(){
  local expected discovered after purged jl vc rc
  setmode classic; nftban firewall rebuild --quiet >/dev/null 2>&1; sleep 6
  expected="$(classic_objs)"
  if [[ "$expected" -eq 0 ]]; then
    echo "      VACUOUS: no classic objects existed to purge (EXPECTED_POPULATION=0)"
    return 1
  fi
  discovered="$expected"
  setmode suricata; nftban ddos reload >/dev/null 2>&1; rc=$?; sleep 5
  after="$(classic_objs)"; purged=$(( discovered - after )); jl="$(jumps)"; vc="$(valchain)"
  echo "      expected=$discovered purged=$purged residue=$after jumps=$jl VAL-CHAIN-004=$vc rc=$rc"
  [[ "$purged" -eq "$discovered" && "$after" -eq 0 && "$jl" -eq 0 && "$vc" -eq 0 && "$rc" -eq 0 ]]
}

echo "=== v1.229.7 cross-mode teardown falsification ==="
echo ""
echo "P — POSITIVE (shipped implementation)"
if transition_converges; then ok "P1 classic->suricata converges, population non-vacuous and fully purged"
else bad "P1 classic->suricata did NOT converge on the shipped implementation"; fi

setmode classic; nftban ddos reload >/dev/null 2>&1; sleep 5
if [[ "$(classic_objs)" -gt 0 && "$(valchain)" -eq 0 ]]; then
  ok "P2 suricata->classic restores the classic projection ($(classic_objs) objects), VAL-CHAIN-004=0"
else bad "P2 suricata->classic left objects=$(classic_objs) VAL-CHAIN-004=$(valchain)"; fi

nftban ddos reload >/dev/null 2>&1; sleep 5
[[ "$(classic_objs)" -gt 0 && "$(valchain)" -eq 0 ]] \
  && ok "P3 classic->classic idempotent" || bad "P3 classic->classic not idempotent"

setmode suricata; nftban ddos reload >/dev/null 2>&1; sleep 4
nftban ddos reload >/dev/null 2>&1; sleep 5
[[ "$(classic_objs)" -eq 0 && "$(valchain)" -eq 0 ]] \
  && ok "P4 suricata->suricata idempotent" || bad "P4 suricata->suricata not idempotent"

# --- negative controls -------------------------------------------------------
# Each mutation is applied to the INSTALLED implementation, the SAME positive
# arm is re-run, and the arm MUST fail. A mutation the arm still passes means
# the arm was never testing that property.
#   A NEGATIVE CONTROL THAT PASSES IS A TEST THAT PROVES NOTHING.
negative(){ # <label> <python-mutation> <why>
    local label="$1" prog="$2" why="$3" mrc
    cp -p "$PRISTINE" "$SRC"
    # Apply the mutation. A mutation that does not actually change the file makes
    # the control VACUOUS, so that is reported as a failure -- it must never be
    # allowed to look like "detected".
    #   MUTATION NOT APPLIED != DEFECT NOT PRESENT
    python3 - "$SRC" "$prog" <<'MUTEOF'
import sys
path, prog = sys.argv[1], sys.argv[2]
s = open(path).read()
ns = {'s': s}
exec(compile(prog, '<mutation>', 'exec'), {}, ns)
if ns['s'] == s:
    sys.stderr.write("      MUTATION DID NOT APPLY\n"); sys.exit(3)
open(path, 'w').write(ns['s'])
MUTEOF
    mrc=$?
    if [[ $mrc -ne 0 ]]; then
        bad "$label mutation could not be applied — CONTROL INVALID (not a pass)"
        cp -p "$PRISTINE" "$SRC"; return
    fi
    echo "    [$label] $why"
    if transition_converges; then
        bad "$label MUTATION NOT DETECTED — the positive arm passed with the defect reintroduced"
    else
        ok "$label detected (arm failed with the defect reintroduced)"
    fi
    cp -p "$PRISTINE" "$SRC"
}

echo ""
echo "N — NEGATIVE CONTROLS (mutate the shipped implementation, require detection)"

negative "N1 no jump removal" \
  's = s.replace("                    nft_fragment_remove_jump \"$name\" || true", "                    : # N1: jump removal disabled")' \
  "remove the jump-edge cleanup: referenced chains cannot be deleted, so residue must remain"

negative "N2 IPv4 only" \
  's = s.replace("    for fam in ip ip6; do\n        # Base Layer-0 lives", "    for fam in ip; do\n        # Base Layer-0 lives")' \
  "clean only IPv4: IPv6 residue must be detected"

negative "N3 flush not delete" \
  's = s.replace("nft delete chain \"$fam\" nftban \"$name\"", "nft flush chain \"$fam\" nftban \"$name\"").replace("nft delete set \"$fam\" nftban \"$name\"", "nft flush set \"$fam\" nftban \"$name\"")' \
  "flush instead of delete: chains survive empty, VAL-CHAIN-004 must fire"

negative "N4 empty subject population" \
  's = s.replace("        /^[[:space:]]*chain[[:space:]]+ddos_/ { print \"chain \" $2 }", "        /^ZZZ_NEVER_MATCHES/ { print \"chain \" $2 }").replace("        /^[[:space:]]*set[[:space:]]+ddos_/   { print \"set \"   $2 }", "        /^ZZZ_NEVER_MATCHES/ { print \"set \" $2 }")' \
  "make subject parsing yield zero objects (the IFS failure class): must fail as vacuous, never as success"

echo ""
if [[ $F -gt 0 ]]; then echo "TEARDOWN FALSIFICATION FAILED ($F)"; exit 1; fi
echo "TEARDOWN FALSIFICATION PASSED (P1-P4 positive, N1-N4 all detected)"
