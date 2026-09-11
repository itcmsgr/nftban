#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-config-format-coverage"
# meta:type="ci-guard"
# meta:description="v1.230.0 PR-5a-1. Every shipped configuration subject must carry an explicit format in config-registry.json, and the generic assignment parser must never report an observation failure as an empty-valid configuration. SCOPE IS FORMAT ONLY -- role/owner/load-mechanism truth is PR-5a-2 and this guard deliberately does not assert it. Static analysis; reads files, invokes nothing, contacts no host."
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1
FAIL=0
fail(){ printf '  [FAIL] %s\n' "$1"; FAIL=1; }
pass(){ printf '  [PASS] %s\n' "$1"; }

REG="cli/lib/nftban/data/config-registry.json"
[[ -r "$REG" ]] || { fail "registry unreadable: $REG"; exit 1; }

echo "=== R-1: every discovered config subject has a registered format ==="
MISSING=0; TOTAL=0
while IFS= read -r p; do
    TOTAL=$((TOTAL+1))
    # The registry keys on the INSTALLED path. install/config/* subjects ship to
    # /etc/nftban/... (build_nftban.sh:569,594,2468,2484), so map source -> installed
    # before lookup. Keying on the source path instead produced three duplicate
    # registry entries during this PR.
    key="${p#etc/nftban/}"
    case "$p" in
        install/config/nftban.conf)          key="nftban.conf" ;;
        install/config/update.conf)          key="update.conf" ;;
        install/config/feeds.conf)           key="conf.d/feeds.conf" ;;
        install/config/service-security.conf) key="service-security.conf" ;;
    esac
    if ! jq -e --arg k "$key" '.files[$k].format // empty' "$REG" >/dev/null 2>&1; then
        fail "no registered format: $p"; MISSING=$((MISSING+1))
    fi
done < <(git ls-files | grep -E '(^|/)(etc/nftban|install/config)/.*\.conf(\.local)?$')
# ⛔ FLOOR ASSERTION. A dynamically-derived population that enumerates to ZERO must
#    never read as universal compliance. MEASURED: a damaged index made this rule
#    print "all 0 discovered subjects carry a format" and PASS -- the precise defect
#    class this guard exists to prevent, aimed at the guard itself.
if [[ "$TOTAL" -lt 50 ]]; then
    fail "discovered only $TOTAL config subjects (expected >=50) — enumeration is broken, not the tree"
elif [[ "$MISSING" -eq 0 ]]; then
    pass "all $TOTAL discovered subjects carry a format"
fi

echo "=== R-2: the duplicate key-alias authority stays deleted ==="
for f in deprecated_keys renamed_keys; do
    if jq -e --arg f "$f" 'has($f)' "$REG" >/dev/null 2>&1; then
        fail "config-registry.json re-introduced .$f — config-schema.json is the single key-semantics authority"
    fi
done
jq -e 'has("deprecated_keys") or has("renamed_keys")' "$REG" >/dev/null 2>&1 || pass "single key rename/deprecation authority (config-schema.json)"

echo "=== R-3: parser must not report an observation failure as empty-valid ==="
# BEHAVIOURAL, not textual. Two earlier attempts to grep for the fail-open failed:
# the first matched the fix's own explanatory comment, the second matched the
# legitimate `|| { printf {}; return IO_ERROR; }` paths. Emitting {} is not the
# defect -- emitting it WITH SUCCESS is. Only execution can tell those apart.
_r3_tmp="$(mktemp -d)"
# MEASURED: the format gate refuses this BEFORE the jq stage, so this case proves
# UNSUPPORTED_FORMAT, not UNPARSEABLE. The jq fail-open branch is now defence in
# depth -- no constructed input (backslashes, tabs, invalid UTF-8) was found that
# reaches it. Naming the case honestly matters: a control aimed at an unreachable
# branch cannot fail, and a control that cannot fail is not a control.
cat > "$_r3_tmp/shellconstruct.conf" <<'R3EOF'
GOOD_KEY="value"
: "${SOME_VAR:=/default/path}"
R3EOF
printf 'K=1
' > "$_r3_tmp/good.conf"
: > "$_r3_tmp/emptyvalid.conf"
_r3=0
(
  # shellcheck source=/dev/null
  source "$ROOT/cli/lib/nftban/core/nftban_config_schema.sh" >/dev/null 2>&1 || exit 90
  set +e
  nftban_config_parse_to_json "$_r3_tmp/good.conf"        >/dev/null 2>&1; [ $? -eq 0 ] || exit 11
  nftban_config_parse_to_json "$_r3_tmp/emptyvalid.conf"  >/dev/null 2>&1; [ $? -eq 0 ] || exit 12
  nftban_config_parse_to_json "$_r3_tmp/shellconstruct.conf" >/dev/null 2>&1; [ $? -ne 0 ] || exit 13
  nftban_config_parse_to_json "$_r3_tmp/does-not-exist"   >/dev/null 2>&1; [ $? -ne 0 ] || exit 14
) || _r3=$?
case "$_r3" in
  0)  pass "parse outcomes distinguish PARSED / EMPTY_VALID / failure by exit status" ;;
  11) fail "a valid simple-assignment subject did not parse successfully" ;;
  12) fail "a genuinely empty subject was not reported EMPTY_VALID" ;;
  13) fail "a shell-construct subject returned SUCCESS — the FORMAT GATE is not refusing it, so an unreadable subject would be reported as empty-valid" ;;
  14) fail "an absent subject returned SUCCESS — IO_ERROR is being reported as empty-valid" ;;
  *)  fail "R-3 harness could not load the parser (rc=$_r3)" ;;
esac
for tok in NFTBAN_CONFIG_PARSE_UNPARSEABLE NFTBAN_CONFIG_PARSE_UNSUPPORTED_FORMAT NFTBAN_CONFIG_PARSE_IO_ERROR; do
    grep -q "$tok" "cli/lib/nftban/core/nftban_config_schema.sh" || fail "result vocabulary missing: $tok"
done
rm -rf "$_r3_tmp"

echo "=== R-4: no-reader claims must survive constructed-path loading ==="
# Permanently falsifies `grep <basename> == 0  ->  no runtime reader`. These
# subjects are loaded ONLY through paths built at runtime, so a filename search
# finds nothing while the reader is real.
R4=0
for probe in "distros" "conf.d"; do
    if ! grep -rqE '\$\{[A-Za-z_]+\}/'"$probe"'|'"$probe"'/\$\{' cli/lib/nftban/ 2>/dev/null; then
        fail "constructed-path loader for '$probe' not detected — reachability census would report a false zero"; R4=1
    fi
done
[[ "$R4" -eq 0 ]] && pass "constructed-path loaders detected (distros, conf.d)"

echo
[[ "$FAIL" -eq 0 ]] && echo "check-config-format-coverage: PASS" || echo "check-config-format-coverage: FAIL"
exit "$FAIL"
