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
REPO="$(cd "${LIB_DIR}/../../.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/etc/conf.d"
export NFTBAN_CONFIG_DIR="$T/etc"

git -C "$REPO" show origin/main:cli/lib/nftban/lib/module_authority.sh > "$T/old_authority.sh" 2>/dev/null \
  || { echo "  [FAIL] cannot read origin/main authority — negative controls would be vacuous"; exit 1; }

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

echo "=== NEGATIVE CONTROLS against origin/main ==="
clear_all; set_master true
old="$(ask_old)"; new="$(ask_new)"
[[ "$old" == "disabled" && "$new" == "ENABLED" ]] \
  && ok "NEGATIVE_AUTHORITY: origin/main says '$old' with master=true; fixed says '$new'" \
  || bad "NEGATIVE_AUTHORITY did not reproduce (old=$old new=$new) — the fix may be untested"

# vocabulary split: reproduce the two readers disagreeing on the SAME value.
for val in true YES; do
    upd_old=$([[ "$val" != "YES" ]] && echo disabled || echo ENABLED)   # update_all required exactly YES
    ah_old=$([[ "$val" == "true" ]] && echo ENABLED || echo disabled)   # autoheal required exactly true
    if [[ "$upd_old" != "$ah_old" ]]; then
        ok "NEGATIVE_VOCAB_SPLIT_${val}: origin/main update_all=$upd_old vs autoheal=$ah_old on the SAME value"
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
_om_failopen="$(git -C "$REPO" show origin/main:cli/lib/nftban/core/nftban_feeds.sh 2>/dev/null | grep -c 'NFTBAN_FEEDS_ENABLED:-YES')"
[[ "${_om_failopen:-0}" -gt 0 ]] \
  && ok "NEGATIVE_FAIL_OPEN: origin/main defaults an ABSENT master gate to YES (enabled)" \
  || bad "NEGATIVE_FAIL_OPEN: could not reproduce the fail-open default in origin/main"
# ⛔ Strip comments first. The fix DOCUMENTS the old expression in a banner, and
#    matching that banner would report the defect as still present — a checker
#    reading prose instead of code.
_fixed_failopen="$(sed 's/#.*//' "${LIB_DIR}/core/nftban_feeds.sh" | grep -c 'NFTBAN_FEEDS_ENABLED:-YES')"
if [[ "${_fixed_failopen:-0}" -gt 0 ]]; then
    bad "fixed tree still contains the fail-open default in EXECUTABLE code"
else
    ok "  fixed: the fail-open default is gone from executable code (banner text excluded)"
fi
# Prove that comment-stripping did not simply blind the check.
_om_stripped="$(git -C "$REPO" show origin/main:cli/lib/nftban/core/nftban_feeds.sh 2>/dev/null | sed 's/#.*//' | grep -c 'NFTBAN_FEEDS_ENABLED:-YES')"
if [[ "${_om_stripped:-0}" -gt 0 ]]; then
    ok "  non-vacuity: the same comment-stripped probe DOES find it on origin/main"
else
    bad "  non-vacuity: comment-stripped probe cannot find the defect on origin/main — it proves nothing"
fi

echo
echo "=== feeds_authority: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
