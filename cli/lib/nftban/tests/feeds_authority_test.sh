#!/usr/bin/env bash
# =============================================================================
# NFTBan - one Feed enablement authority, one boolean interpretation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="feeds-authority-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="FEED_ENABLEMENT_AUTHORITY_FRAGMENTED. Measured 2026-08-31: the same question had three incompatible answers. nftban_module_effective_enabled read FEEDS_ENABLED from conf.d/feeds/main.conf — a key and a file that exist on no host — so feeds resolved DISABLED unconditionally and the DSR recovery path treated the producer as intentionally off (lab4: feeds disabled rc=1 while geoban ENABLED, proving the mechanism itself worked). nftban_feeds_update_all required exactly \"YES\" and defaulted an ABSENT gate to enabled (fail-open) despite the shipped default being false. autoheal required exactly \"true\". No configured value satisfied all three readers. Asserts one canonical truth parser across truthy/falsy/malformed vocabularies, feeds resolution from the authority that actually ships (conf.d/feeds.conf overridden by nftban.conf.local), removal of the fail-open default, and reproduces each defect against origin/main so no assertion passes vacuously."
# meta:ta.id="feeds_authority_test"
# meta:ta.owner="feeds"
# meta:ta.module="feed-enablement-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/core/nftban_feeds.sh,cli/lib/nftban/helpers/autoheal.sh"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc/conf.d"
export NFTBAN_CONFIG_DIR="$T/etc"

# ⛔ THE PRE-FIX BASELINE IS SYNTHESISED FROM THE LIVE LIBRARY, NOT READ FROM A REF.
#    This previously did `git show origin/main:module_authority.sh`. origin/main is a
#    MOVING ref: the hour this lane merged, the "pre-fix" baseline BECAME the fixed
#    code and every negative control below inverted, failing deterministically on main
#    and on every branch cut from it. Third occurrence of that defect in this release.
#    A tag is not the fix either — the ci-bash checkout is shallow, so no historical
#    ref is guaranteed present.
#    Instead: restore exactly what the fix changed. Immutable by construction.
_synth_prefix_authority() { # $1=destination
    local live="${LIB_DIR}/lib/module_authority.sh" n_bool n_key n_disp
    n_bool=$(grep -c 'nftban_bool_is_true "\$val"' "$live") || n_bool=0
    n_key=$(grep -c 'feeds).*"NFTBAN_FEEDS_ENABLED"' "$live") || n_key=0
    n_disp=$(grep -c 'if \[\[ "\$module" == "feeds" \]\]; then' "$live") || n_disp=0
    if [[ "$n_bool" -eq 0 || "$n_key" -eq 0 || "$n_disp" -eq 0 ]]; then
        echo "  [FAIL] live authority no longer has the shape this inversion reverts" \
             "(bool=$n_bool key=$n_key dispatch=$n_disp) — the negative control cannot" \
             "reproduce the defect; re-derive it."
        return 1
    fi
    awk '
      /if \[\[ "\$module" == "feeds" \]\]; then/ { skip=1; next }
      skip && /^[[:space:]]*fi[[:space:]]*$/          { skip=0; next }
      skip { next }
      { print }
    ' "$live" \
    | sed -e 's/nftban_bool_is_true "\$val"/[[ "$val" == "true" ]]/' \
          -e 's/feeds)    echo "NFTBAN_FEEDS_ENABLED" ;;/feeds)    echo "FEEDS_ENABLED" ;;/' \
      > "$1" || return 1
    if cmp -s "$live" "$1"; then
        echo "  [FAIL] synthesised baseline is identical to the live library — vacuous"; return 1
    fi
    bash -n "$1" 2>/dev/null || { echo "  [FAIL] synthesised baseline is not valid shell"; return 1; }
}
_synth_prefix_authority "$T/old_authority.sh" || exit 1

# Each probe runs in a SUBSHELL: module_authority.sh guards against double-sourcing,
# so old and new cannot both be live in one shell.
ask_new() { ( set +u; source "${LIB_DIR}/lib/module_authority.sh" >/dev/null 2>&1
              nftban_module_effective_enabled feeds >/dev/null 2>&1 && echo ENABLED || echo disabled ); }
ask_old() { ( set +u; source "$T/old_authority.sh" >/dev/null 2>&1
              nftban_module_effective_enabled feeds >/dev/null 2>&1 && echo ENABLED || echo disabled ); }
set_master()   { printf 'NFTBAN_FEEDS_ENABLED="%s"\n' "$1" > "$T/etc/conf.d/feeds.conf"; }
set_override() { printf 'NFTBAN_FEEDS_ENABLED="%s"\n' "$1" > "$T/etc/nftban.conf.local"; }
clear_all()    { rm -f "$T/etc/conf.d/feeds.conf" "$T/etc/nftban.conf.local"; }

echo "=== canonical truth parser ==="
# shellcheck source=/dev/null
( source "${LIB_DIR}/lib/module_authority.sh" >/dev/null 2>&1
  t_ok=1; for v in true TRUE True yes YES 1 on ON enabled; do
      nftban_bool_is_true "$v" || { echo "      truthy '$v' not recognised"; t_ok=0; }
  done; exit $((1-t_ok)) ) && ok "TRUE_MATRIX: true/TRUE/yes/YES/1/on/enabled all resolve TRUE" \
                          || bad "TRUE_MATRIX: a truthy spelling was not recognised"
( source "${LIB_DIR}/lib/module_authority.sh" >/dev/null 2>&1
  f_ok=1; for v in false FALSE no NO 0 off disabled; do
      nftban_bool_is_true "$v" && { echo "      falsy '$v' resolved TRUE"; f_ok=0; }
  done; exit $((1-f_ok)) ) && ok "FALSE_MATRIX: false/no/0/off/disabled all resolve FALSE" \
                          || bad "FALSE_MATRIX: a falsy spelling resolved TRUE"
( source "${LIB_DIR}/lib/module_authority.sh" >/dev/null 2>&1
  m_ok=1; for v in "" " " maybe truthy YE "true " 2 -1 "yes;rm"; do
      nftban_bool_is_true "$v" && { echo "      malformed '$v' resolved TRUE"; m_ok=0; }
  done; exit $((1-m_ok)) ) && ok "MALFORMED_MATRIX: empty/garbage never fails open into enabled" \
                          || bad "MALFORMED_MATRIX: a malformed value failed OPEN"

echo "=== feeds resolves from the authority that actually ships ==="
clear_all; set_master true
[[ "$(ask_new)" == "ENABLED" ]] && ok "master true in conf.d/feeds.conf -> ENABLED" || bad "master true -> $(ask_new)"
set_master false
[[ "$(ask_new)" == "disabled" ]] && ok "MASTER_DISABLED: master false -> disabled" || bad "master false -> $(ask_new)"
set_master YES
[[ "$(ask_new)" == "ENABLED" ]] && ok "master YES resolves identically to true" || bad "master YES -> $(ask_new)"
set_master 1
[[ "$(ask_new)" == "ENABLED" ]] && ok "master 1 resolves identically to true" || bad "master 1 -> $(ask_new)"

echo "=== local override precedence (same model as the per-feed reader) ==="
set_master true;  set_override false
[[ "$(ask_new)" == "disabled" ]] && ok "LOCAL_OVERRIDE: local false over shipped true -> disabled" || bad "override false -> $(ask_new)"
set_master false; set_override true
[[ "$(ask_new)" == "ENABLED" ]]  && ok "LOCAL_OVERRIDE: local true over shipped false -> ENABLED" || bad "override true -> $(ask_new)"

echo "=== missing authority must not become enablement ==="
clear_all
[[ "$(ask_new)" == "disabled" ]] && ok "no configuration at all -> disabled (absence is not enablement)" || bad "absent config -> $(ask_new)"

echo "=== NEGATIVE CONTROLS against the synthesised pre-fix authority ==="
clear_all; set_master true
old="$(ask_old)"; new="$(ask_new)"
[[ "$old" == "disabled" && "$new" == "ENABLED" ]] \
  && ok "NEGATIVE_AUTHORITY: pre-fix authority says '$old' with master=true; fixed says '$new'" \
  || bad "NEGATIVE_AUTHORITY did not reproduce (old=$old new=$new) — the fix may be untested"

# vocabulary split: reproduce the two readers disagreeing on the SAME value.
for val in true YES; do
    upd_old=$([[ "$val" != "YES" ]] && echo disabled || echo ENABLED)   # update_all required exactly YES
    ah_old=$([[ "$val" == "true" ]] && echo ENABLED || echo disabled)   # autoheal required exactly true
    if [[ "$upd_old" != "$ah_old" ]]; then
        ok "NEGATIVE_VOCAB_SPLIT_${val}: pre-fix update_all=$upd_old vs autoheal=$ah_old on the SAME value"
    else
        bad "NEGATIVE_VOCAB_SPLIT_${val}: expected the two readers to disagree"
    fi
    ( source "${LIB_DIR}/lib/module_authority.sh" >/dev/null 2>&1; nftban_bool_is_true "$val" ) \
        && ok "  fixed: '$val' resolves TRUE for every reader" \
        || bad "  fixed: '$val' did not resolve TRUE"
done

# fail-open: absent master gate
# ⛔ NEVER `grep -q` inside a pipeline under `set -o pipefail`: grep exits on the
#    first match and closes the pipe, the producer takes SIGPIPE, and the pipeline
#    reports non-zero — a match read as "not found". Count, then compare.
# ⛔ FIXTURE, NOT A GIT REF. This previously read the fail-open default out of
#    `git show origin/main:nftban_feeds.sh`. Once the fix merged, origin/main no
#    longer contained it and the control inverted. The live code does not merely
#    change that expression, it removes the gate entirely, so there is no one-line
#    inversion to apply — and none is needed: what this control must prove is that
#    the PROBE can see the defect shape, which a fixture proves without history.
_FIXTURE_CODE='    if [[ "${NFTBAN_FEEDS_ENABLED:-YES}" != "YES" ]]; then'
_FIXTURE_COMMENT='    # historical banner mentioning ${NFTBAN_FEEDS_ENABLED:-YES} in prose'

_fx_code="$(printf '%s\n' "$_FIXTURE_CODE" | grep -c 'NFTBAN_FEEDS_ENABLED:-YES')" || _fx_code=0
[[ "${_fx_code:-0}" -gt 0 ]] \
  && ok "NEGATIVE_FAIL_OPEN: the probe DOES detect an absent-gate default of YES" \
  || bad "NEGATIVE_FAIL_OPEN: probe cannot see the fail-open shape — every arm below is vacuous"

# ⛔ Strip comments first. The fix DOCUMENTS the old expression in a banner, and
#    matching that banner would report the defect as still present — a checker
#    reading prose instead of code.
_fixed_failopen="$(sed 's/#.*//' "${LIB_DIR}/core/nftban_feeds.sh" | grep -c 'NFTBAN_FEEDS_ENABLED:-YES')" || _fixed_failopen=0
if [[ "${_fixed_failopen:-0}" -gt 0 ]]; then
    bad "fixed tree still contains the fail-open default in EXECUTABLE code"
else
    ok "  fixed: the fail-open default is gone from executable code (banner text excluded)"
fi

# Prove comment-stripping did not blind the probe: it must still find the shape in
# CODE, and must NOT find it in a comment carrying the same words.
_fx_code_stripped="$(printf '%s\n' "$_FIXTURE_CODE" | sed 's/#.*//' | grep -c 'NFTBAN_FEEDS_ENABLED:-YES')" || _fx_code_stripped=0
_fx_cmt_stripped="$(printf '%s\n' "$_FIXTURE_COMMENT" | sed 's/#.*//' | grep -c 'NFTBAN_FEEDS_ENABLED:-YES')" || _fx_cmt_stripped=0
[[ "${_fx_code_stripped:-0}" -gt 0 ]] \
  && ok "  non-vacuity: the comment-stripped probe still finds the shape in CODE" \
  || bad "  non-vacuity: comment-stripping blinded the probe entirely — it proves nothing"
[[ "${_fx_cmt_stripped:-0}" -eq 0 ]] \
  && ok "  and correctly does NOT match the same words inside a comment" \
  || bad "  comment-stripping failed: prose still satisfies the probe"

echo
echo "=== feeds_authority: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
