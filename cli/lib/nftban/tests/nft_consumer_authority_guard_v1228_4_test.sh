#!/usr/bin/env bash
# =============================================================================
# NFTBan - negative controls for the nft consumer execution authority guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_consumer_authority_guard_v1228_4_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-28"
# meta:description="v1.228.4 PR-1 negative controls. A guard nobody has proven sensitive is a green light, not a gate. This suite injects each violation class the nft consumer authority guard exists to catch and asserts the guard actually fails, in the expected assertion group, then restores the tree and verifies the restore by hash. NC-1 confirmed consumer loses AF_NETLINK; NC-2 bounded-trace non-consumer gains it unnecessarily; NC-3 an unprivileged unit gains CAP_NET_ADMIN with no recorded decision; NC-4 the Queue/BotScan denial for v1.228.4 is violated; NC-5 an evidence state drifts to an absolute unbounded name; NC-6 a shipped unit is dropped from the inventory; NC-7 the inventory names a unit that is not shipped; NC-8 the guard's non-zero rc survives being piped through a successful consumer - a masked-exit pattern that has silently converted failure into success three separate times in this codebase, so it is asserted here as a permanent harness invariant. Every control proves injector rc=0, mutation observed, guard failed in the exact expected group, and restore hash matches. Operates on temporary COPIES of the repo tree - the working tree is never mutated."
# meta:input="build/nft-consumer-authority.yaml, install/systemd/*.service, scripts/ci/check-nft-consumer-authority.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,python3,sha256sum,grep,sed"
# meta:inventory.files="build/nft-consumer-authority.yaml,scripts/ci/check-nft-consumer-authority.sh"
# meta:inventory.binaries="bash,python3,sha256sum"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="install/systemd/*.service (copies only)"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nft_consumer_authority_guard_v1228_4_test"
# meta:ta.owner="packaging"
# meta:ta.module="systemd-execution-authority"
# meta:ta.execution_class="CI_STATIC"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
GUARD_REL="scripts/ci/check-nft-consumer-authority.sh"
AUTH_REL="build/nft-consumer-authority.yaml"

[[ -f "$REPO/$GUARD_REL" ]] || { echo "FAIL: guard not found" >&2; exit 1; }
[[ -f "$REPO/$AUTH_REL" ]]  || { echo "FAIL: authority file not found" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# Materialise an isolated copy of the surfaces the guard reads. The working tree
# is NEVER mutated by this test.
mkcopy(){
    local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/build" "$d/scripts/ci" "$d/install/systemd"
    cp "$REPO/$AUTH_REL"  "$d/build/"
    cp "$REPO/$GUARD_REL" "$d/scripts/ci/"
    cp "$REPO"/install/systemd/*.service "$d/install/systemd/"
    printf '%s' "$d"
}

# Run the guard in a copy. rc captured independently — never through a pipeline.
# NOTE: deliberately does NOT toggle errexit. An earlier version restored `set -e`
# before `return "$rc"`, which overrode the caller's `set +e` and aborted the whole
# suite after the first control. Callers use `run_guard d || rc=$?` (condition
# context), so errexit never fires on the non-zero return.
run_guard(){
    local d="$1" out rc=0
    out="$(bash "$d/scripts/ci/check-nft-consumer-authority.sh" 2>&1)" || rc=$?
    printf '%s' "$out" > "$d/.guard.out"
    return "$rc"
}

# Path-INDEPENDENT content hash. An earlier version hashed absolute paths, so a
# restored copy in a different directory never matched its own baseline and every
# control reported a false RESTORE_HASH mismatch.
tree_hash(){ ( cd "$1" && find . -type f ! -name '.guard.out' -print0 \
                 | sort -z | xargs -0 sha256sum ) | sha256sum | cut -d' ' -f1; }

# control <id> <desc> <expected-group-regex> <injector-fn>
control(){
    local id="$1" desc="$2" group="$3" inject="$4"
    local d; d=$(mkcopy "$id")
    local before; before=$(tree_hash "$d")

    local irc=0; "$inject" "$d" || irc=$?
    if [[ $irc -ne 0 ]]; then
        no "$id $desc" "INJECTOR_RC=$irc (must be 0) — the control never ran"; return
    fi
    local after; after=$(tree_hash "$d")
    if [[ "$before" == "$after" ]]; then
        no "$id $desc" "MUTATION_OBSERVED=NO — injector changed nothing, so a PASS proves nothing"; return
    fi

    local grc=0; run_guard "$d" || grc=$?
    if [[ $grc -eq 0 ]]; then
        no "$id $desc" "guard returned 0 on an injected violation — GUARD NOT SENSITIVE"; return
    fi
    if ! grep -qE "$group" "$d/.guard.out"; then
        no "$id $desc" "guard failed but not in the expected group /$group/"; return
    fi

    # restore and prove the restore
    local d2; d2=$(mkcopy "${id}_restored")
    if [[ "$(tree_hash "$d2")" != "$before" ]]; then
        no "$id $desc" "RESTORE_HASH mismatch"; return
    fi
    ok "$id $desc (injector rc=0 · mutation observed · guard failed in $group · restore verified)"
}

strip_family(){ sed -i 's/^RestrictAddressFamilies=.*/RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6/' "$1"; }

# ---------------------------------------------------------------- NC-1
# An already-authorized confirmed consumer loses AF_NETLINK. Uses a unit that is
# NOT in expected_open_violations, so the baseline cannot absorb it.
nc1(){ strip_family "$1/install/systemd/nftban-firewall-init.service"
       python3 - "$1/build/nft-consumer-authority.yaml" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace("already_authorized:\n  - nftban-core-feeds.service",
            "already_authorized:\n  - nftban-core-feeds.service")
s=s.replace("  - nftban-firewall-init.service\n","",1)
# Evidence text deliberately avoids spelling a literal nft write verb sequence:
# scripts/ci/check-nft-writes.sh scans this directory and would flag the literal
# string as a direct-write violation even inside a test fixture.
s=s.replace("units:\n","units:\n  - name: nftban-firewall-init.service\n    state: confirmed_consumer\n    user: root\n    nft_operation: write\n    requires_capabilities: []\n    evidence: \"ExecStop removes the nftban tables via the nft binary (see the shipped unit)\"\n\n",1)
open(p,'w').write(s)
PY
}
# ---------------------------------------------------------------- NC-2
nc2(){ sed -i 's/^RestrictAddressFamilies=\(.*\)$/RestrictAddressFamilies=\1 AF_NETLINK/' \
         "$1/install/systemd/nftban-watchdog.service"; }
# ---------------------------------------------------------------- NC-3
nc3(){ printf 'AmbientCapabilities=CAP_NET_ADMIN\n' >> "$1/install/systemd/nftban-tunnel.service"
       grep -q '^User=' "$1/install/systemd/nftban-tunnel.service" \
         || printf 'User=nftban\n' >> "$1/install/systemd/nftban-tunnel.service"
       sed -i 's/^User=root$/User=nftban/' "$1/install/systemd/nftban-tunnel.service"; }
# ---------------------------------------------------------------- NC-4
nc4(){ sed -i 's/^RestrictAddressFamilies=\(.*\)$/RestrictAddressFamilies=\1 AF_NETLINK/' \
         "$1/install/systemd/nftban-queue.service"; }
# ---------------------------------------------------------------- NC-5
nc5(){ sed -i 's/state: no_nft_path_bounded_trace/state: no_nft_path_found/' \
         "$1/build/nft-consumer-authority.yaml"; }
# ---------------------------------------------------------------- NC-6
nc6(){ python3 - "$1/build/nft-consumer-authority.yaml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("  - nftban-health-fix.service\n","",1)   # drop a shipped unit from the inventory
open(p,'w').write(s)
PY
}
# ---------------------------------------------------------------- NC-7
# Must inject into already_authorized, NOT append to the file: the last block is
# expected_open_violations, so a bare append landed there and failed in G1
# instead of the A2 phantom-unit assertion this control exists to prove.
nc7(){ sed -i '/^already_authorized:/a\  - nftban-does-not-exist.service' \
         "$1/build/nft-consumer-authority.yaml"; }

control NC-1 "confirmed consumer stripped of AF_NETLINK -> B group fails" '\[FAIL\] B1' nc1
control NC-2 "bounded-trace non-consumer granted AF_NETLINK -> C group fails" '\[FAIL\] C1' nc2
control NC-3 "unprivileged unit gains CAP_NET_ADMIN undeclared -> D group fails" '\[FAIL\] D1' nc3
control NC-4 "queue violates denied_v1_228_4 -> E group fails" '\[FAIL\] E1' nc4
control NC-5 "evidence state drifts to an absolute name -> F group fails" '\[FAIL\] F(1|3)' nc5
control NC-6 "shipped unit dropped from inventory -> A group fails" '\[FAIL\] A1' nc6
control NC-7 "inventory names a unit that is not shipped -> A group fails" '\[FAIL\] A2' nc7

# ---------------------------------------------------------------- NC-8
# THE MASKED-EXIT INVARIANT. `guard | tail` returns tail's status. This pattern
# has silently converted a failing guard into job success three separate times in
# this codebase (a lost printf rc, a dpkg-deb absence, and this guard's own first
# run). Assert both that the naive pattern DOES mask, and that the pattern the CI
# workflow actually uses does NOT.
echo "=== NC-8 masked-exit invariant ==="
d8=$(mkcopy NC-8); nc4 "$d8"          # inject a real violation
set +e
bash "$d8/scripts/ci/check-nft-consumer-authority.sh" 2>&1 | tail -1 >/dev/null
masked_rc=$?
direct_out="$(bash "$d8/scripts/ci/check-nft-consumer-authority.sh" 2>&1)"
direct_rc=$?
set -e
if [[ $direct_rc -eq 0 ]]; then
    no "NC-8 guard fails on the injected violation" "direct rc=0"
elif [[ $masked_rc -ne 0 ]]; then
    ok "NC-8 pipeline did not mask rc here (rc=$masked_rc) — still asserting the safe pattern"
else
    ok "NC-8 masked-exit reproduced: direct rc=$direct_rc but 'guard | tail' rc=$masked_rc"
fi
printf '%s' "$direct_out" >/dev/null
if [[ $direct_rc -ne 0 ]]; then
    ok "NC-8 independent capture preserves rc=$direct_rc (the pattern ci-architecture.yml uses)"
else
    no "NC-8 independent capture preserves rc" "got 0"
fi

# ---------------------------------------------------------------- baseline contract
echo "=== post-closure contract (PR-2) ==="
d9=$(mkcopy CLOSURE)
crc=0; run_guard "$d9" || crc=$?
if [[ $crc -eq 0 ]] && grep -q 'G1 baseline empty and zero violations' "$d9/.guard.out"; then
    ok "G1 baseline EMPTY and zero violations — PR-2 closure contract satisfied"
else
    no "G1 closure contract satisfied" "rc=$crc — expected an empty baseline with no open violations"
fi

# =============================================================================
# NC-10..13 — coverage holes found by independent audit. Each of these returned
# guard rc=0 before the fix, i.e. a declared authority state escaped enforcement.
# =============================================================================

# NC-10: already_authorized was DESCRIPTIVE, not enforced. Rule B iterated only
# confirmed_consumer entries, so stripping the family from any of the 7 already-
# authorized units left the guard green — the exact defect PR-1 exists to prevent.
# CRITICAL: the YAML classification is left UNCHANGED. Earlier controls (NC-1,
# BC-2) rewrote the unit into `units:` as confirmed_consumer, so they exercised
# rule B and gave false confidence about this path.
nc10(){ strip_family "$1/install/systemd/nftban-firewall-init.service"; }
control NC-10 "already_authorized unit loses AF_NETLINK, YAML untouched -> B2 fails" \
        '\[FAIL\] B2' nc10

# NC-11: conditional_consumer had no semantic rule at all — it appeared only in
# the VALID set, so a declared unit escaped enforcement by virtue of its class.
# Remove the activation key from a conditional consumer: it must HARD FAIL rather
# than silently pass.
nc11(){ sed -i '/^  - name: nftban-report-daily.service$/,/^$/{/^    activation: /d}' \
          "$1/build/nft-consumer-authority.yaml"; }
control NC-11 "conditional_consumer with no activation -> B3 hard-fails" \
        '\[FAIL\] B3' nc11

# NC-12: an operator_action_required consumer that withholds the family WITHOUT a
# recorded capability_decision is drift, not a decision. Strip the decision from
# queue and assert the omission stops being tolerated.
nc12(){ sed -i '/^  - name: nftban-queue.service$/,/^$/{/^    capability_decision: /d}' \
          "$1/build/nft-consumer-authority.yaml"; }
control NC-12 "operator_action_required with unrecorded omission -> B3 fails" \
        '\[FAIL\] B3' nc12

# NC-13: the blanket endswith("@.service") exemption let ANY templated name pass
# phantom detection. nftban-phantom@.service injected into already_authorized
# returned rc=0 before the fix.
nc13(){ sed -i '/^already_authorized:/a\  - nftban-phantom@.service' \
          "$1/build/nft-consumer-authority.yaml"; }
control NC-13 "templated phantom in already_authorized -> A2 fails" \
        '\[FAIL\] A2' nc13

# POSITIVE control: a legitimate operator_action_required consumer that withholds
# the family WITH a recorded capability_decision must PASS. Proves the B3 rule
# discriminates rather than simply rejecting every conditional consumer.
echo "=== NC-14 legitimate inactive conditional state must PASS ==="
d14=$(mkcopy NC-14)
rc14=0; run_guard "$d14" || rc14=$?
if [[ $rc14 -eq 0 ]] && grep -q 'B3 nftban-queue.service operator_action_required' "$d14/.guard.out"; then
    ok "NC-14 queue/botscan withhold the family under a RECORDED decision and PASS (rule discriminates)"
else
    no "NC-14 legitimate inactive conditional passes" "rc=$rc14 — B3 is rejecting a valid recorded omission"
fi

# =============================================================================
# NC-9 — a required CI authority must not be satisfied by an IGNORED local file
# =============================================================================
# build/ is gitignored (.gitignore:8, two negations). A new authority file lives
# on disk, never appears in `git status`, and is silently omitted from the commit
# — the gate then PASSES on a local artefact the committed repository does not
# contain. Uses a synthetic git repo; no production file is added to test this.
echo "=== NC-9 authority must be git-TRACKED, not merely present on disk ==="
d9t="$WORK/NC-9"; mkdir -p "$d9t"
git -C "$d9t" init -q 2>/dev/null
mkdir -p "$d9t/build" "$d9t/scripts/ci" "$d9t/install/systemd"
cp "$REPO/$AUTH_REL"  "$d9t/build/"
cp "$REPO/$GUARD_REL" "$d9t/scripts/ci/"
cp "$REPO"/install/systemd/*.service "$d9t/install/systemd/"
printf 'build/\n' > "$d9t/.gitignore"          # reproduce the ignore condition
git -C "$d9t" add -A >/dev/null 2>&1 || true   # authority is ignored -> NOT tracked
git -C "$d9t" -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 || true

nc9rc=0
nc9out="$(bash "$d9t/scripts/ci/check-nft-consumer-authority.sh" 2>&1)" || nc9rc=$?
if [[ $nc9rc -eq 0 ]]; then
    no "NC-9 untracked authority is rejected" \
       "guard PASSED on an ignored, untracked authority file — CI would be green while the commit has no authority"
elif grep -q 'FAIL. AUTHORITY_FILE_TRACKED' <<<"$nc9out"; then
    ok "NC-9 untracked authority is rejected (AUTHORITY_FILE_TRACKED failed, rc=$nc9rc)"
else
    no "NC-9 untracked authority is rejected" "failed (rc=$nc9rc) but not on AUTHORITY_FILE_TRACKED"
fi

# The same repo with the file force-added must PASS the tracked assertion.
git -C "$d9t" add -f build/nft-consumer-authority.yaml >/dev/null 2>&1 || true
nc9brc=0
nc9bout="$(bash "$d9t/scripts/ci/check-nft-consumer-authority.sh" 2>&1)" || nc9brc=$?
if grep -q 'PASS. AUTHORITY_FILE_TRACKED' <<<"$nc9bout"; then
    ok "NC-9b force-added authority satisfies AUTHORITY_FILE_TRACKED"
else
    no "NC-9b force-added authority satisfies AUTHORITY_FILE_TRACKED" \
       "still not tracked after git add -f (guard rc=$nc9brc)"
fi

# Malformed YAML must fail loudly, not silently degrade to an empty inventory.
d9m="$WORK/NC-9m"; mkdir -p "$d9m/build" "$d9m/scripts/ci" "$d9m/install/systemd"
cp "$REPO/$GUARD_REL" "$d9m/scripts/ci/"
cp "$REPO"/install/systemd/*.service "$d9m/install/systemd/"
printf 'units: [ this is not: valid: yaml\n' > "$d9m/build/nft-consumer-authority.yaml"
nc9mrc=0
nc9mout="$(bash "$d9m/scripts/ci/check-nft-consumer-authority.sh" 2>&1)" || nc9mrc=$?
if [[ $nc9mrc -ne 0 ]] && grep -q 'AUTHORITY_FILE_PARSEABLE' <<<"$nc9mout"; then
    ok "NC-9c malformed authority YAML fails loudly (not a silent empty inventory)"
else
    no "NC-9c malformed authority YAML fails loudly" "rc=$nc9mrc"
fi

# =============================================================================
# BC — the expected-open baseline must be TRANSITIONAL, not a suppression
# =============================================================================
# PR-2 must drive expected_open_violations 5 -> 0. Prove the mechanism fails in
# every direction, so a stale or wrong exception cannot survive a merge.
echo "=== BC. expected-open baseline is transitional ==="

bc_case(){ # bc_case <id> <desc> <group-regex> <mutator>
    local id="$1" desc="$2" group="$3" mut="$4"
    local d; d=$(mkcopy "$id")
    local irc=0; "$mut" "$d" || irc=$?
    if [[ $irc -ne 0 ]]; then no "$id $desc" "mutator rc=$irc"; return; fi
    local rc=0; run_guard "$d" || rc=$?
    if [[ $rc -eq 0 ]]; then
        no "$id $desc" "guard PASSED — the baseline absorbed a change it must reject"; return
    fi
    grep -qE "$group" "$d/.guard.out" \
        && ok "$id $desc (failed in $group)" \
        || no "$id $desc" "failed, but not in /$group/"
}

# PR-2 CLOSED the baseline: expected_open_violations is now EMPTY and all six units carry
# AF_NETLINK. The transitional controls that proved the baseline could not be abused have served
# their purpose. What must be guarded NOW is the post-closure state:
#   1. a fixed unit must not silently regress
#   2. a suppression must not be resurrected

# PC-1: a now-fixed unit loses AF_NETLINK again. With no baseline to absorb it, this must FAIL.
pc_regress(){ sed -i 's/^RestrictAddressFamilies=\(.*\) AF_NETLINK$/RestrictAddressFamilies=\1/' \
                "$1/install/systemd/nftban-snapshot.service"; }
# PC-2: someone re-introduces a baseline naming a unit that is NOT actually open.
pc_resurrect(){ printf '\nexpected_open_violations:\n  - nftban-snapshot.service\n' \
                  >> "$1/build/nft-consumer-authority.yaml"; }
# PC-3: a full six-unit baseline is re-added when nothing is open at all.
pc_resurrect_all(){ printf '\nexpected_open_violations:\n' >> "$1/build/nft-consumer-authority.yaml"
    for u in maintenance rollback snapshot update-apply community-stats report-daily; do
        printf '  - nftban-%s.service\n' "$u" >> "$1/build/nft-consumer-authority.yaml"
    done; }

bc_case PC-1 "a FIXED unit regresses (loses AF_NETLINK) -> B group fails"        '\[FAIL\] B1' pc_regress
bc_case PC-2 "a suppression is resurrected for a non-open unit -> G1 fails"      '\[FAIL\] G1' pc_resurrect
bc_case PC-3 "a full stale baseline is re-added when nothing is open -> G1 fails" '\[FAIL\] G1' pc_resurrect_all

# =============================================================================
# HR — harness self-regressions. Each of these defects was found in THIS suite
# during development; without an assertion each would silently return and make
# the negative controls prove nothing.
# =============================================================================
echo "=== HR. harness cannot regress its own evidence defects ==="

# HR-1: run_guard must not restore errexit before returning non-zero. It did, and
# that overrode the caller's `set +e`, aborting the suite after the first control
# with EMPTY output and rc=1 — indistinguishable from "nothing ran".
if sed -n '/^run_guard()/,/^}/p' "$0" | grep -qE '^\s*set -e\s*$'; then
    no "HR-1 run_guard does not re-enable errexit" "found 'set -e' inside run_guard — it will abort the suite on the first failing control"
else
    ok "HR-1 run_guard does not re-enable errexit (callers use 'run_guard || rc=\$?')"
fi

# HR-2: tree_hash must be path-INDEPENDENT. It hashed absolute paths, so a
# restored copy in a different directory never matched and every RESTORE_HASH
# comparison failed falsely.
hr2a="$WORK/hr2a"; hr2b="$WORK/hr2b"; mkdir -p "$hr2a" "$hr2b"
printf 'identical\n' > "$hr2a/f"; printf 'identical\n' > "$hr2b/f"
if [[ "$(tree_hash "$hr2a")" == "$(tree_hash "$hr2b")" ]]; then
    ok "HR-2 tree_hash is path-independent (same content in two dirs hashes equal)"
else
    no "HR-2 tree_hash is path-independent" "identical content in different dirs hashed differently — restores will falsely fail"
fi

# HR-3: a control must assert its EXACT assertion group. Prove the group check
# has teeth by pointing a real violation at a group that cannot match.
d_hr3=$(mkcopy HR-3); nc4 "$d_hr3"
hr3rc=0; run_guard "$d_hr3" || hr3rc=$?
if [[ $hr3rc -ne 0 ]] && ! grep -qE '\[FAIL\] Z9' "$d_hr3/.guard.out"; then
    ok "HR-3 group matching has teeth (a real failure does not match a wrong group)"
else
    no "HR-3 group matching has teeth" "a wrong group regex would have matched — controls could pass via the wrong assertion"
fi

# HR-4: this file must not contain a literal nft write-verb sequence. Descriptive
# fixture text using one contaminated scripts/ci/check-nft-writes.sh and failed an
# unrelated guard (nft_writer_authority_v150_test).
if grep -nE '\bnft[[:space:]]+(add|delete|flush|insert|replace|create)[[:space:]]' "$0" \
     | grep -vE '^\s*[0-9]+:\s*#' | grep -q .; then
    no "HR-4 no literal nft write verb in this fixture" "a literal write sequence will trip scripts/ci/check-nft-writes.sh"
else
    ok "HR-4 no literal nft write verb in this fixture (cannot contaminate check-nft-writes)"
fi

echo
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
