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
SRCONLY="scripts/ci/data/config-source-only.json"
[[ -r "$SRCONLY" ]] || { fail "source-only manifest unreadable: $SRCONLY"; exit 1; }
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
    # v1.230.0 PR-5a-2: TWO authorities by design. config-registry.json is the RUNTIME
    # config surface; config-source-only.json declares repository artifacts that
    # intentionally never become runtime subjects. A source subject must be covered by
    # EXACTLY ONE of them — never both, never neither.
    _in_runtime=0; _in_srconly=0
    jq -e --arg k "$key" '.files[$k].format // empty' "$REG"     >/dev/null 2>&1 && _in_runtime=1
    jq -e --arg k "$key" '.subjects[$k] // empty'    "$SRCONLY"  >/dev/null 2>&1 && _in_srconly=1
    if [[ $((_in_runtime + _in_srconly)) -eq 0 ]]; then
        fail "subject in NEITHER authority (runtime registry nor source-only manifest): $p"; MISSING=$((MISSING+1))
    elif [[ $((_in_runtime + _in_srconly)) -eq 2 ]]; then
        fail "subject in BOTH authorities — runtime and source-only must be disjoint: $p"; MISSING=$((MISSING+1))
    fi
done < <(git ls-files | grep -E '(^|/)(etc/nftban|install/config)/.*\.conf(\.local)?$')
# ⛔ FLOOR ASSERTION. A dynamically-derived population that enumerates to ZERO must
#    never read as universal compliance. MEASURED: a damaged index made this rule
#    print "all 0 discovered subjects carry a format" and PASS -- the precise defect
#    class this guard exists to prevent, aimed at the guard itself.
if [[ "$TOTAL" -lt 50 ]]; then
    fail "discovered only $TOTAL config subjects (expected >=50) — enumeration is broken, not the tree"
elif [[ "$MISSING" -eq 0 ]]; then
    pass "all $TOTAL discovered subjects carry a format in exactly one authority"
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

echo "=== R-5: every RUNTIME config subject is registry-covered ==="
# v1.230.0 PR-5a-2. R-1 enumerates the SOURCE tree, which is the wrong population in
# BOTH directions: it includes source-only files no host receives, and it cannot see
# install/nftables/, so /etc/nftban/nftables.conf -- present on every host -- was
# invisible to the guard while it reported "all 82 discovered subjects carry a format".
# R-5 enumerates the RUNTIME population from the ACTUAL staging rules, so the guard
# tracks packaging drift instead of repository text.
BUILD="packaging/build_nftban.sh"
[[ -r "$BUILD" ]] || fail "build script unreadable: $BUILD"

# The two glob staging rules the derivation depends on MUST still exist; if either is
# renamed the population silently shrinks, which is the vacuous-pass shape.
grep -q 'cp -r etc/nftban/conf\.d/\* %{buildroot}/etc/nftban/conf\.d/' "$BUILD" \
    || fail "staging rule drift: conf.d glob not found in $BUILD (R-5 population would silently shrink)"
grep -q 'cp etc/nftban/distros/\*\.conf %{buildroot}/etc/nftban/distros/' "$BUILD" \
    || fail "staging rule drift: distros glob not found in $BUILD"

RUNTIME_SUBJECTS=()
# 1. conf.d tree (staged by the cp -r). *.conf.local is deleted from the buildroot.
while IFS= read -r f; do RUNTIME_SUBJECTS+=("${f#etc/nftban/}"); done < <(
    git ls-files 'etc/nftban/conf.d/**/*.conf' 'etc/nftban/conf.d/*.conf' 2>/dev/null | grep -v '\.conf\.local$')
# 2. distros (staged by the cp glob)
while IFS= read -r f; do RUNTIME_SUBJECTS+=("${f#etc/nftban/}"); done < <(git ls-files 'etc/nftban/distros/*.conf')
# 3. explicit install -D targets landing under /etc/nftban
while IFS= read -r t; do RUNTIME_SUBJECTS+=("$t"); done < <(
    grep -oE 'install -D -m [0-7]+ [^ ]+ %\{buildroot\}/etc/nftban/[^ ]+\.conf' "$BUILD" \
    | awk '{print $NF}' | sed 's|.*%{buildroot}/etc/nftban/||')
# 4. operator-state lists: template-staged for RPM, seeded to /etc, shipped as DEB
#    conffiles. Runtime subjects under every packaging family.
#    -> handle PACKAGING-MANUAL-LIST-CONFFILE-AUTHORITY-DIVERGENCE-DEB-VS-RPM
RUNTIME_SUBJECTS+=("whitelist.d/99-manual.conf" "blacklist.d/99-manual.conf")
# 5. GENERATED AT RUNTIME, never packaged: written by
#    core/nftban_health_checks_security.sh:780. A runtime subject nonetheless.
RUNTIME_SUBJECTS+=("ports.d/00-ssh.conf")

# de-duplicate
mapfile -t RUNTIME_SUBJECTS < <(printf '%s\n' "${RUNTIME_SUBJECTS[@]}" | sort -u)
R5_TOTAL="${#RUNTIME_SUBJECTS[@]}"
R5_MISSING=0
for k in "${RUNTIME_SUBJECTS[@]}"; do
    if ! jq -e --arg k "$k" '.files[$k].format // empty' "$REG" >/dev/null 2>&1; then
        fail "runtime subject absent from config-registry.json: $k"; R5_MISSING=$((R5_MISSING+1))
    fi
done
# ⛔ FLOOR. A runtime population that enumerates small or empty is a broken derivation,
#    never a clean tree. Measured population at v1.230.0 PR-5a-2 was 74.
if [[ "$R5_TOTAL" -lt 60 ]]; then
    fail "runtime population enumerated only $R5_TOTAL subjects (expected >=60) — derivation is broken, not the tree"
elif [[ "$R5_MISSING" -eq 0 ]]; then
    pass "all $R5_TOTAL runtime subjects are registry-covered"
fi

echo "=== R-6: the runtime registry must not re-accumulate source-only subjects ==="
# The registry drifted to 83 entries = 74 runtime + 9 source-only before v1.230.0
# PR-5a-2. This asserts the runtime registry stays runtime-only, in the other
# direction from R-5: R-5 catches a runtime subject MISSING, R-6 catches a
# non-runtime subject PRESENT.
mapfile -t REG_KEYS < <(jq -r '.files | keys[]' "$REG")
R6_EXTRA=0
for k in "${REG_KEYS[@]}"; do
    _found=0
    for r in "${RUNTIME_SUBJECTS[@]}"; do [[ "$r" == "$k" ]] && { _found=1; break; }; done
    [[ $_found -eq 0 ]] && { fail "registry entry is not a runtime subject: $k"; R6_EXTRA=$((R6_EXTRA+1)); }
done
if [[ "${#REG_KEYS[@]}" -lt 60 ]]; then
    fail "runtime registry enumerated only ${#REG_KEYS[@]} entries (expected >=60)"
elif [[ "$R6_EXTRA" -eq 0 ]]; then
    pass "runtime registry holds exactly ${#REG_KEYS[@]} runtime subjects, no source-only residue"
fi

echo "=== R-7: derived source-only set == declared source-only set ==="
# SET IDENTITY, not row validity. Derived independently as
#   authoritative source subjects MINUS independently derived runtime population.
mapfile -t SRC_ALL < <(git ls-files | grep -E '(^|/)(etc/nftban|install/config)/.*\.conf(\.local)?$' | while IFS= read -r p; do
    k="${p#etc/nftban/}"
    case "$p" in
        install/config/nftban.conf)           k="nftban.conf" ;;
        install/config/update.conf)           k="update.conf" ;;
        install/config/feeds.conf)            k="conf.d/feeds.conf" ;;
        install/config/service-security.conf) k="service-security.conf" ;;
    esac
    printf '%s\n' "$k"
done | sort -u)
DERIVED_SRCONLY=()
for k in "${SRC_ALL[@]}"; do
    _isrt=0
    for r in "${RUNTIME_SUBJECTS[@]}"; do [[ "$r" == "$k" ]] && { _isrt=1; break; }; done
    [[ $_isrt -eq 0 ]] && DERIVED_SRCONLY+=("$k")
done
mapfile -t DECLARED_SRCONLY < <(jq -r '.subjects | keys[]' "$SRCONLY")
R7_BAD=0
ALLOWED_CLASSES="$(jq -r '.classifications | join("|")' "$SRCONLY")"
for k in "${DERIVED_SRCONLY[@]}"; do
    jq -e --arg k "$k" '.subjects[$k] // empty' "$SRCONLY" >/dev/null 2>&1 \
        || { fail "derived source-only subject is NOT declared: $k"; R7_BAD=$((R7_BAD+1)); }
done
for k in "${DECLARED_SRCONLY[@]}"; do
    _isd=0
    for d in "${DERIVED_SRCONLY[@]}"; do [[ "$d" == "$k" ]] && { _isd=1; break; }; done
    [[ $_isd -eq 0 ]] && { fail "declared source-only subject is NOT derivable as source-only: $k"; R7_BAD=$((R7_BAD+1)); }
done
# every declared row needs a bounded classification, a non-empty owner and evidence
for k in "${DECLARED_SRCONLY[@]}"; do
    cls=$(jq -r --arg k "$k" '.subjects[$k].classification // ""' "$SRCONLY")
    own=$(jq -r --arg k "$k" '.subjects[$k].owner // ""' "$SRCONLY")
    evd=$(jq -r --arg k "$k" '.subjects[$k].disposition_evidence // ""' "$SRCONLY")
    [[ "$cls" =~ ^(${ALLOWED_CLASSES})$ ]] || { fail "source-only subject has unknown/blank classification '$cls': $k"; R7_BAD=$((R7_BAD+1)); }
    [[ -n "$own" ]] || { fail "source-only subject has blank owner: $k"; R7_BAD=$((R7_BAD+1)); }
    [[ -n "$evd" ]] || { fail "source-only subject has blank disposition evidence: $k"; R7_BAD=$((R7_BAD+1)); }
done
if [[ "${#DERIVED_SRCONLY[@]}" -eq 0 ]]; then
    fail "derived source-only population is ZERO — derivation is broken, not the tree"
elif [[ "$R7_BAD" -eq 0 ]]; then
    pass "source-only sets identical (${#DERIVED_SRCONLY[@]} subjects), all rows classified/owned/evidenced"
fi

echo "=== R-8: every governed runtime subject has explicit validator ownership ==="
# The governed population is derived INDEPENDENTLY of validator metadata (it is the
# same RUNTIME_SUBJECTS set R-5 derives from staging rules), so a subject cannot escape
# this rule by having its validator fields removed.
ALLOWED_DISP="$(jq -r '.validator_classification.dispositions | join("|")' "$REG")"
[[ -n "$ALLOWED_DISP" ]] || fail "validator disposition vocabulary missing from $REG"
R8_BAD=0; R8_GOVERNED=0
for k in "${RUNTIME_SUBJECTS[@]}"; do
    jq -e --arg k "$k" '.files[$k] // empty' "$REG" >/dev/null 2>&1 || continue  # R-5 already reports absence
    R8_GOVERNED=$((R8_GOVERNED+1))
    owner=$(jq -r --arg k "$k" '.files[$k].validator_owner // ""' "$REG")
    disp=$(jq -r  --arg k "$k" '.files[$k].validator_disposition // ""' "$REG")
    if [[ -n "$owner" && -n "$disp" ]]; then
        fail "subject declares BOTH validator_owner and validator_disposition: $k"; R8_BAD=$((R8_BAD+1))
    elif [[ -n "$owner" ]]; then
        # an owner must name something that exists in-tree
        [[ -e "$owner" ]] || { fail "validator_owner does not exist in tree: $owner ($k)"; R8_BAD=$((R8_BAD+1)); }
    elif [[ -n "$disp" ]]; then
        # ⛔ a typo must FAIL, never silently invent a new validator policy class
        [[ "$disp" =~ ^(${ALLOWED_DISP})$ ]] \
            || { fail "unknown validator_disposition '$disp' (not in declared vocabulary): $k"; R8_BAD=$((R8_BAD+1)); }
        case "$disp" in
            NONE|N/A|none|n/a|TBD|UNKNOWN) fail "generic validator_disposition '$disp' is not an explicit reason: $k"; R8_BAD=$((R8_BAD+1)) ;;
        esac
    else
        fail "subject has NEITHER validator_owner NOR validator_disposition: $k"; R8_BAD=$((R8_BAD+1))
    fi
done
if [[ "$R8_GOVERNED" -lt 60 ]]; then
    fail "governed runtime population enumerated only $R8_GOVERNED (expected >=60)"
elif [[ "$R8_BAD" -eq 0 ]]; then
    pass "all $R8_GOVERNED governed runtime subjects carry explicit validator ownership"
fi

echo
[[ "$FAIL" -eq 0 ]] && echo "check-config-format-coverage: PASS" || echo "check-config-format-coverage: FAIL"
exit "$FAIL"
