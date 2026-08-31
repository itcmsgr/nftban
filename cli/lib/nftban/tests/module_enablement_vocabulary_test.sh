#!/usr/bin/env bash
# =============================================================================
# NFTBan - generic module enablement must honour operator boolean intent
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="module-enablement-vocabulary-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="GENERIC_BOOLEAN_NORMALIZATION = CONFIRMED_DEFECT_CORRECTION. The generic module authority tested [[ \$val == \"true\" ]], so an operator who wrote DDOS_ENABLED=yes — an explicit request to enable — silently got a DISABLED module and lost the protection they configured. This is the same authority-fragmentation class as the feeds master gate: operator intent exists but readers disagree on its meaning. IMPACT: previously ignored valid truthy spellings can now activate the protection the operator configured; no previously-recognised true value becomes false, and malformed values remain non-affirmative. Drives real shipped modules END TO END (config file -> nftban_module_effective_enabled -> observed result), not the parser in isolation, and reproduces the defect against origin/main so no row passes vacuously."
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "${LIB_DIR}/../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export NFTBAN_CONFIG_DIR="$T/etc"
git -C "$REPO" show origin/main:cli/lib/nftban/lib/module_authority.sh > "$T/old.sh" 2>/dev/null || {
    echo "  [FAIL] cannot read origin/main authority — negative control would be vacuous"; exit 1; }

# END-TO-END: write the real config file, ask the real authority.
probe() { # $1=module $2=KEY $3=value $4=impl(new|old)
    local m="$1" k="$2" v="$3" impl="$4"
    mkdir -p "$T/etc/conf.d/$m"
    if [[ "$v" == "__MISSING__" ]]; then rm -f "$T/etc/conf.d/$m/main.conf"
    else printf '%s="%s"\n' "$k" "$v" > "$T/etc/conf.d/$m/main.conf"; fi
    local lib="${LIB_DIR}/lib/module_authority.sh"; [[ "$impl" == "old" ]] && lib="$T/old.sh"
    ( set +u; source "$lib" >/dev/null 2>&1
      nftban_module_effective_enabled "$m" >/dev/null 2>&1 && echo ENABLED || echo disabled )
}

for pair in "ddos:DDOS_ENABLED" "portscan:PORTSCAN_ENABLED"; do
    m="${pair%%:*}"; k="${pair##*:}"
    echo "=== $m ($k) — config file -> authority -> result ==="
    t_bad=""
    for v in true TRUE yes YES 1 on enabled; do
        r="$(probe "$m" "$k" "$v" new)"; [[ "$r" == "ENABLED" ]] || t_bad="$t_bad $v($r)"
    done
    [[ -z "$t_bad" ]] && ok "$m truthy spellings all ENABLE:$( echo ' true TRUE yes YES 1 on enabled')" \
                      || bad "$m truthy spellings failed:$t_bad"
    f_bad=""
    for v in false FALSE no NO 0 off disabled; do
        r="$(probe "$m" "$k" "$v" new)"; [[ "$r" == "disabled" ]] || f_bad="$f_bad $v($r)"
    done
    [[ -z "$f_bad" ]] && ok "$m falsy spellings all DISABLE" || bad "$m falsy spellings leaked ENABLED:$f_bad"
    m_bad=""
    for v in "" " " maybe truthy YE 2 -1 "yes please"; do
        r="$(probe "$m" "$k" "$v" new)"; [[ "$r" == "disabled" ]] || m_bad="$m_bad '$v'($r)"
    done
    [[ -z "$m_bad" ]] && ok "$m malformed values never ENABLE (no fail-open)" || bad "$m malformed failed open:$m_bad"
    r="$(probe "$m" "$k" "__MISSING__" new)"
    [[ "$r" == "disabled" ]] && ok "$m missing config -> disabled (absence is not enablement)" || bad "$m missing -> $r"

    # NEGATIVE CONTROL: the motivating defect, on the real shipped module.
    old_yes="$(probe "$m" "$k" yes old)"; new_yes="$(probe "$m" "$k" yes new)"
    [[ "$old_yes" == "disabled" && "$new_yes" == "ENABLED" ]] \
        && ok "$m NEGATIVE CONTROL: origin/main reads ${k}=yes as '$old_yes'; fixed reads '$new_yes'" \
        || bad "$m negative control did not reproduce (old=$old_yes new=$new_yes)"
    # Direction guard: nothing that was TRUE may become FALSE.
    old_true="$(probe "$m" "$k" true old)"; new_true="$(probe "$m" "$k" true new)"
    [[ "$old_true" == "ENABLED" && "$new_true" == "ENABLED" ]] \
        && ok "$m ${k}=true still ENABLED (no previously-true value became false)" \
        || bad "$m regression on ${k}=true (old=$old_true new=$new_true)"
    # Direction guard: nothing that was explicitly FALSE may become TRUE.
    old_false="$(probe "$m" "$k" false old)"; new_false="$(probe "$m" "$k" false new)"
    [[ "$old_false" == "disabled" && "$new_false" == "disabled" ]] \
        && ok "$m ${k}=false still disabled (no explicit false became true)" \
        || bad "$m regression on ${k}=false (old=$old_false new=$new_false)"
done

echo
echo "=== module_enablement_vocabulary: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
