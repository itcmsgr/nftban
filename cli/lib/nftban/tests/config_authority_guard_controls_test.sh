#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config-authority-guard-controls"
# meta:type="test"
# meta:description="v1.230.0 PR-5a-2 behavioural negative controls for scripts/ci/check-config-format-coverage.sh R-5 (runtime-population registry coverage). Every control proves THREE things, not merely a non-zero rc: (1) the population is non-empty, (2) the intended subject is actually IN the population, (3) the injected mutation changes the guard verdict FOR THE EXPECTED REASON. The middle assertion exists because a mutation that removes a subject from BOTH sides yields another vacuous pass. A generic non-zero rc is never accepted as proof — see BUG-VALIDATE-DISTRO-CONFIGS-FAILURE-ABORTS-BEFORE-VERDICT, where rc=1 meant 'set -e killed the validator', not 'the validator rejected the subject'."
# meta:inventory.files="scripts/ci/check-config-format-coverage.sh,cli/lib/nftban/data/config-registry.json"
# meta:inventory.binaries="jq,git"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GUARD="$ROOT/scripts/ci/check-config-format-coverage.sh"
REG="$ROOT/cli/lib/nftban/data/config-registry.json"
PASS=0; FAILED=0
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; FAILED=$((FAILED+1)); }

[[ -x "$GUARD" || -r "$GUARD" ]] || { echo "FAIL: guard subject not reachable: $GUARD" >&2; exit 1; }
[[ -r "$REG" ]] || { echo "FAIL: registry not reachable: $REG" >&2; exit 1; }

# Independent derivation of the runtime population, so assertion (2) does not simply
# re-read whatever the guard computed.
_runtime_has() {
    local want="$1"
    { git -C "$ROOT" ls-files 'etc/nftban/conf.d/**/*.conf' 'etc/nftban/conf.d/*.conf' 'etc/nftban/distros/*.conf' 2>/dev/null \
        | grep -v '\.conf\.local$' | sed 's|^etc/nftban/||'
      grep -oE 'install -D -m [0-7]+ [^ ]+ %\{buildroot\}/etc/nftban/[^ ]+\.conf' "$ROOT/packaging/build_nftban.sh" \
        | awk '{print $NF}' | sed 's|.*%{buildroot}/etc/nftban/||'
      printf '%s\n' "whitelist.d/99-manual.conf" "blacklist.d/99-manual.conf" "ports.d/00-ssh.conf"
    } | sort -u | grep -qx "$want"
}

echo "=== CONTROL 0: baseline must PASS with a non-vacuous population ==="
base_out="$(bash "$GUARD" 2>&1)"; base_rc=$?
base_n="$(printf '%s' "$base_out" | sed -n 's/.*all \([0-9]\+\) runtime subjects are registry-covered.*/\1/p')"
[[ "$base_rc" -eq 0 ]] && ok "baseline guard rc=0" || bad "baseline guard rc=$base_rc (expected 0)"
if [[ -n "$base_n" && "$base_n" -ge 60 ]]; then ok "baseline runtime population non-vacuous: $base_n"
else bad "baseline runtime population missing or below floor: '${base_n:-none}'"; fi

echo "=== CONTROL 1: removing ONE runtime subject's registry coverage must FAIL ==="
SUBJECT="nftables.conf"
if _runtime_has "$SUBJECT"; then ok "(2) intended subject is in the runtime population: $SUBJECT"
else bad "(2) intended subject NOT in the runtime population — control would be vacuous"; fi

BACKUP="$(mktemp)"; cp -p "$REG" "$BACKUP"
_restore(){ cp -p "$BACKUP" "$REG"; rm -f "$BACKUP"; }
trap _restore EXIT INT TERM
jq --arg k "$SUBJECT" 'del(.files[$k])' "$BACKUP" > "$REG"
mut_out="$(bash "$GUARD" 2>&1)"; mut_rc=$?
# the subject must STILL be discoverable — the mutation removed coverage, not membership
if _runtime_has "$SUBJECT"; then ok "(2b) subject still discoverable after mutation (not removed from both sides)"
else bad "(2b) mutation removed the subject from the population too — vacuous control"; fi
if [[ "$mut_rc" -ne 0 ]]; then ok "(3) guard FAILS under mutation (rc=$mut_rc)"
else bad "(3) guard still passed under mutation — R-5 is not load-bearing"; fi
# ⛔ reason, not just rc
if printf '%s' "$mut_out" | grep -q "runtime subject absent from config-registry.json: $SUBJECT"; then
    ok "(3b) guard failed for the EXPECTED REASON, naming $SUBJECT"
else bad "(3b) guard failed for an unexpected reason — non-zero rc is not proof"; fi
_restore; trap - EXIT INT TERM
post_rc=0; bash "$GUARD" >/dev/null 2>&1 || post_rc=$?
[[ "$post_rc" -eq 0 ]] && ok "registry restored, guard green again" || bad "registry not restored (rc=$post_rc)"

echo "=== CONTROL 3/4/5: source-only manifest (R-7) must be load-bearing ==="
SRCONLY="$ROOT/scripts/ci/data/config-source-only.json"
[[ -r "$SRCONLY" ]] || bad "source-only manifest not reachable: $SRCONLY"
SUBJ2="modules/inline_exceptions.conf"
SB="$(mktemp)"; cp -p "$SRCONLY" "$SB"
_restore2(){ cp -p "$SB" "$SRCONLY"; rm -f "$SB"; }
trap _restore2 EXIT INT TERM

# (2) the subject must genuinely be a DERIVED source-only subject, else vacuous
if jq -e --arg k "$SUBJ2" '.subjects[$k]' "$SB" >/dev/null 2>&1; then ok "(2) $SUBJ2 is a declared source-only subject"
else bad "(2) $SUBJ2 not declared — controls 3/4 would be vacuous"; fi

# CONTROL 3: blank ONE disposition. Subject stays in the derived population.
jq --arg k "$SUBJ2" '.subjects[$k].disposition_evidence = ""' "$SB" > "$SRCONLY"
o3="$(bash "$GUARD" 2>&1)"; r3=$?
[[ "$r3" -ne 0 ]] && ok "(3) blanked disposition FAILS the guard" || bad "(3) blanked disposition still passed"
printf '%s' "$o3" | grep -q "blank disposition evidence: $SUBJ2"     && ok "(3b) failed for the EXPECTED REASON, naming $SUBJ2" || bad "(3b) unexpected failure reason"
cp -p "$SB" "$SRCONLY"

# CONTROL 4: OMIT one declaration. Derived subject still exists -> must FAIL.
jq --arg k "$SUBJ2" 'del(.subjects[$k])' "$SB" > "$SRCONLY"
o4="$(bash "$GUARD" 2>&1)"; r4=$?
[[ "$r4" -ne 0 ]] && ok "(4) omitted declaration FAILS the guard" || bad "(4) omitted declaration still passed"
printf '%s' "$o4" | grep -qE "derived source-only subject is NOT declared: $SUBJ2|NEITHER authority"     && ok "(4b) failed for the EXPECTED REASON (derived but undeclared)" || bad "(4b) unexpected failure reason"
cp -p "$SB" "$SRCONLY"

# CONTROL 5: EXTRA declaration — declare a genuine RUNTIME subject as source-only.
jq '.subjects["conf.d/feeds.conf"] = {source_path:"x",classification:"RETIRED_SURFACE",owner:"x",disposition_evidence:"x"}' "$SB" > "$SRCONLY"
o5="$(bash "$GUARD" 2>&1)"; r5=$?
[[ "$r5" -ne 0 ]] && ok "(5) extra/bogus declaration FAILS the guard" || bad "(5) extra declaration still passed"
printf '%s' "$o5" | grep -qE "NOT derivable as source-only: conf.d/feeds.conf|in BOTH authorities"     && ok "(5b) failed for the EXPECTED REASON (declared but not derivable / both authorities)" || bad "(5b) unexpected failure reason"
_restore2; trap - EXIT INT TERM
pr=0; bash "$GUARD" >/dev/null 2>&1 || pr=$?
[[ "$pr" -eq 0 ]] && ok "manifest restored, guard green again" || bad "manifest not restored (rc=$pr)"

echo "=== CONTROL 6/7: validator ownership (R-8) must be load-bearing ==="
SUBJ3="conf.d/watchdog.conf"
RB2="$(mktemp)"; cp -p "$REG" "$RB2"
_restore3(){ cp -p "$RB2" "$REG"; rm -f "$RB2"; }
trap _restore3 EXIT INT TERM
# (2) the subject must be a genuinely GOVERNED runtime subject, else vacuous
if _runtime_has "$SUBJ3" && jq -e --arg k "$SUBJ3" '.files[$k]' "$RB2" >/dev/null 2>&1; then
    ok "(2) $SUBJ3 is a governed runtime subject"
else bad "(2) $SUBJ3 not governed — controls 6/7 would be vacuous"; fi

# CONTROL 6: strip validator ownership from one governed subject
jq --arg k "$SUBJ3" 'del(.files[$k].validator_owner) | del(.files[$k].validator_disposition)' "$RB2" > "$REG"
o6="$(bash "$GUARD" 2>&1)"; r6=$?
if _runtime_has "$SUBJ3"; then ok "(2b) subject still in runtime population after mutation"
else bad "(2b) mutation removed the subject from the population — vacuous"; fi
[[ "$r6" -ne 0 ]] && ok "(6) stripped validator ownership FAILS the guard" || bad "(6) stripped ownership still passed"
printf '%s' "$o6" | grep -q "NEITHER validator_owner NOR validator_disposition: $SUBJ3"     && ok "(6b) failed for the EXPECTED REASON, naming $SUBJ3" || bad "(6b) unexpected failure reason"
cp -p "$RB2" "$REG"

# CONTROL 7: a TYPO must not invent a new validator policy class
jq --arg k "$SUBJ3" '.files[$k].validator_disposition = "KEY_SCHEMA_ONLYY"' "$RB2" > "$REG"
o7="$(bash "$GUARD" 2>&1)"; r7=$?
[[ "$r7" -ne 0 ]] && ok "(7) unknown disposition value FAILS the guard" || bad "(7) typo accepted as a new validator class"
printf '%s' "$o7" | grep -q "unknown validator_disposition 'KEY_SCHEMA_ONLYY'"     && ok "(7b) failed for the EXPECTED REASON (vocabulary rejection)" || bad "(7b) unexpected failure reason"
_restore3; trap - EXIT INT TERM
pr3=0; bash "$GUARD" >/dev/null 2>&1 || pr3=$?
[[ "$pr3" -eq 0 ]] && ok "registry restored, guard green again" || bad "registry not restored (rc=$pr3)"

echo "=== CONTROL 2: empty population must FAIL on the FLOOR, never universal-PASS ==="
TMP="$(mktemp -d)"
( set -e
  cd "$TMP"; git init -q .; mkdir -p scripts/ci/data cli/lib/nftban/data packaging
  cp "$GUARD" scripts/ci/
  printf '{"files":{},"format_classification":{"families":[]}}\n' > cli/lib/nftban/data/config-registry.json
  # the guard requires BOTH authorities to exist; supply an empty source-only manifest so
  # the run reaches the POPULATION FLOOR rather than exiting on a missing precondition.
  printf '{"classifications":["RETIRED_SURFACE"],"subjects":{}}\n' > scripts/ci/data/config-source-only.json
  printf 'cp -r etc/nftban/conf.d/* %%{buildroot}/etc/nftban/conf.d/\ncp etc/nftban/distros/*.conf %%{buildroot}/etc/nftban/distros/\n' > packaging/build_nftban.sh
  git add -A >/dev/null 2>&1; git -c user.email=t@t -c user.name=t commit -qm x >/dev/null 2>&1 || true
) >/dev/null 2>&1
empty_out="$(bash "$TMP/scripts/ci/check-config-format-coverage.sh" 2>&1)"; empty_rc=$?
if [[ "$empty_rc" -ne 0 ]]; then ok "empty population FAILS (rc=$empty_rc)"; else bad "empty population PASSED — vacuous guard"; fi
if printf '%s' "$empty_out" | grep -qE 'runtime population enumerated only [0-9]+ subjects'; then
    ok "failed specifically on the POPULATION FLOOR, not an incidental error"
else bad "did not fail on the population floor — reason unverified"; fi
rm -rf "$TMP"

echo
printf 'config-authority-guard-controls: %s (passed=%d failed=%d)\n' "$([[ $FAILED -eq 0 ]] && echo PASS || echo FAIL)" "$PASS" "$FAILED"
exit $(( FAILED > 0 ? 1 : 0 ))
