#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="distro-subject-reachability-contract"
# meta:type="test"
# meta:description="v1.230.0 PR-5a-2. Freezes the distro parser reachability contract (PARSER_REACHABLE / FIXTURE_POPULATION / EXECUTED / FAILED / SKIPPED) and independently falsifies each of the three historical breakages that made test_distro_integration.sh green-looking while exercising nothing: a stale parser path, the wrong configuration-directory variable, and a missing required call argument. Every negative asserts the EXPECTED DIAGNOSTIC, never merely rc != 0 — see BUG-VALIDATE-DISTRO-CONFIGS-FAILURE-ABORTS-BEFORE-VERDICT."
# meta:inventory.files="cli/lib/nftban/tests/test_distro_integration.sh,cli/lib/nftban/lib/nftban_distro_config.sh,etc/nftban/distros"
# meta:inventory.binaries="bash,find"
# meta:inventory.env_vars="NFTBAN_DISTRO_CONF_DIR"
# meta:inventory.config_files="etc/nftban/distros/*.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
INTEG="$ROOT/cli/lib/nftban/tests/test_distro_integration.sh"
PARSER="$ROOT/cli/lib/nftban/lib/nftban_distro_config.sh"
FIXTURES="$ROOT/etc/nftban/distros"
EXPECTED_POPULATION=21
P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }

echo "=== FROZEN CONTRACT ==="
[[ -f "$PARSER" ]] && ok "PARSER_REACHABLE = yes ($PARSER)" || bad "PARSER_REACHABLE = no"
pop=$(find "$FIXTURES" -maxdepth 1 -name '*.conf' -type f 2>/dev/null | wc -l)
[[ "$pop" -eq "$EXPECTED_POPULATION" ]] && ok "FIXTURE_POPULATION = $pop" \
    || bad "FIXTURE_POPULATION = $pop (expected $EXPECTED_POPULATION) — population drift must be a deliberate change"
out="$(bash "$INTEG" 2>&1)"; rc=$?
[[ "$rc" -eq 0 ]] && ok "integration suite rc=0" || bad "integration suite rc=$rc"
failed=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*Failed: *\([0-9]\+\).*/\1/p' | head -1)
skipped=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*Skipped: *\([0-9]\+\).*/\1/p' | head -1)
[[ "${failed:-x}" == "0" ]] && ok "FAILED = 0"  || bad "FAILED = ${failed:-unparsed}"
[[ "${skipped:-x}" == "0" ]] && ok "SKIPPED = 0" || bad "SKIPPED = ${skipped:-unparsed}"
# EXECUTED: every fixture must actually be parsed by the suite, not merely discovered
parsed=$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -c 'parses successfully')
[[ "$parsed" -eq "$EXPECTED_POPULATION" ]] && ok "EXECUTED = $parsed (every fixture exercised)" \
    || bad "EXECUTED = $parsed (expected $EXPECTED_POPULATION) — suite ran without exercising the whole population"

echo "=== NEGATIVE 1: stale parser path -> reachability/precondition failure ==="
n1="$(bash "$INTEG" "/nonexistent/track1/nftban_distro_config.sh" 2>&1)"; r1=$?
[[ "$r1" -ne 0 ]] && ok "stale parser path fails (rc=$r1)" || bad "stale parser path still passed"
printf '%s' "$n1" | grep -q 'parser subject not reachable' \
    && ok "expected diagnostic: 'parser subject not reachable'" || bad "wrong diagnostic — rc alone is not evidence"

echo "=== NEGATIVE 2: wrong config-directory authority -> not applied ==="
# Falsifies the old NFTBAN_DISTRO_CONFIG_DIR export: the parser's authority is
# NFTBAN_DISTRO_CONF_DIR, so the wrong name must NOT steer it.
TMPD="$(mktemp -d)"; mkdir -p "$TMPD/distros"
cp "$FIXTURES/debian-13.conf" "$TMPD/distros/zzz-sentinel.conf" 2>/dev/null || true
wrongvar_out="$(
  NFTBAN_DISTRO_CONFIG_DIR="$TMPD/distros" bash -c '
    source "'"$PARSER"'" >/dev/null 2>&1
    printf "%s" "${NFTBAN_DISTRO_CONF_DIR}"' 2>/dev/null)"
if [[ "$wrongvar_out" != "$TMPD/distros" ]]; then
    ok "wrong variable name does NOT set the parser authority (resolved: ${wrongvar_out:-<empty>})"
else bad "wrong variable name steered the parser — authority is not NFTBAN_DISTRO_CONF_DIR"; fi
rightvar_out="$(
  NFTBAN_DISTRO_CONF_DIR="$TMPD/distros" bash -c '
    source "'"$PARSER"'" >/dev/null 2>&1
    printf "%s" "${NFTBAN_DISTRO_CONF_DIR}"' 2>/dev/null)"
[[ "$rightvar_out" == "$TMPD/distros" ]] && ok "correct variable DOES set the authority (positive half)" \
    || bad "correct variable did not apply — control is not discriminating"
# empty fixture population must be a precondition FAILURE, never a quiet skip
EMPTYD="$(mktemp -d)"; mkdir -p "$EMPTYD/distros"
n2="$(bash "$INTEG" "$PARSER" "$EMPTYD/distros" 2>&1)"; r2=$?
[[ "$r2" -ne 0 ]] && ok "empty fixture population fails (rc=$r2)" || bad "empty fixture population passed"
printf '%s' "$n2" | grep -q 'distro fixture population is empty or absent' \
    && ok "expected diagnostic: empty fixture population" || bad "wrong diagnostic for empty population"
rm -rf "$TMPD" "$EMPTYD"

echo "=== NEGATIVE 3: missing required call argument -> invocation-contract failure ==="
n3="$(bash -c '
  set -u
  source "'"$PARSER"'" >/dev/null 2>&1
  nftban_distro_find_config' 2>&1)"; r3=$?
[[ "$r3" -ne 0 ]] && ok "bare call fails (rc=$r3)" || bad "bare call succeeded — invocation contract not enforced"
printf '%s' "$n3" | grep -qE 'unbound variable|\$1' \
    && ok "expected diagnostic: unbound required argument" || bad "wrong diagnostic for invocation contract"
# positive half must be environment-controlled: point the authority at the repo
# fixtures, otherwise it resolves /etc/nftban/distros which need not exist here.
NFTBAN_DISTRO_CONF_DIR="$FIXTURES" bash -c '
  set -u
  source "'"$PARSER"'" >/dev/null 2>&1
  nftban_distro_find_config "centos:9"' >/dev/null 2>&1; r3b=$?
[[ "$r3b" -eq 0 ]] && ok "documented invocation succeeds (positive half)" || bad "documented invocation failed (rc=$r3b)"

echo
printf 'distro-subject-reachability-contract: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
