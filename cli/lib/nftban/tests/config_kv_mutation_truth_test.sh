#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config-kv-mutation-truth"
# meta:type="test"
# meta:description="v1.230.0 PR-5c-A. Locks CONFIG-MUTATION-SILENT-DROP-WHEN-KEY-ABSENT. `sed -i \"s|^KEY=.*|KEY=v|\"` substitutes ONLY when the key already exists; against an absent key it changes nothing and still exits 0, so the caller reports success for a request that was never written. Asserts both branches of nftban_config_kv_set (replace-exactly-once / append-exactly-once), the exactly-one cardinality invariant that stops a naive append converting silent-drop into duplicate-key ambiguity, fail-closed refusal on ambiguous or malformed input, and post-write verification. Negative control reproduces the OLD sed idiom and proves it silently drops — so a regression to that idiom fails here. SCOPE of the PR-5c-A sections: REQUESTED == PERSISTED. They do NOT assert REQUESTED == EFFECTIVE; that is PR-5c-B (CONFIG-SHELL-CENTRAL-OVERRIDE-OVERWRITTEN-BY-LATE-BASE). The B3 section locks the OTHER disposition available to a mutation entry point: FAIL_CLOSED_SPLIT_AUTHORITY. watchdog and login are each served by TWO runtime planes (shell and Go) whose config chains disagree, so no write can be proven to reach every owner; the mutation must be refused BEFORE any state change, leave the target byte-identical (asserted on sha256, never on rc alone), name both conflicting authorities, and exit non-zero. Negative controls re-run the SAME command functions with the guard call removed by declared inversion and prove the pre-B3 behaviour: rc=0 plus a real mutation. It does NOT choose a plane, synchronise owners or redirect writes — CONFIG-WATCHDOG-DUAL-RUNTIME-AUTHORITY-SPLIT stays BLOCKED_BY = OWNER_DECISION."
# meta:ta.id="config_kv_mutation_truth_test"
# meta:ta.owner="core"
# meta:ta.module="config-mutation-safety"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/nftban_config_kv.sh,cli/lib/nftban/lib/nftban_config_split_authority.sh,cli/lib/nftban/cli/cmd_connector.sh,cli/lib/nftban/cli/cmd_report.sh,cli/lib/nftban/cli/cmd_watchdog.sh,cli/lib/nftban/cli/cmd_login.sh"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HELPER="$ROOT/cli/lib/nftban/lib/nftban_config_kv.sh"
P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
[[ -r "$HELPER" ]] || { echo "FAIL: helper not reachable: $HELPER" >&2; exit 1; }
# shellcheck source=/dev/null
source "$HELPER" || { echo "FAIL: helper did not load" >&2; exit 1; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT INT TERM
_card(){ grep -cE "^[[:space:]]*$2=" "$1" 2>/dev/null || true; }
_val(){ sed -n "s/^[[:space:]]*$2=\"\([^\"]*\)\".*$/\1/p" "$1" | head -1; }

echo "=== 1. key EXISTS -> replaced exactly once, neighbours intact ==="
printf 'A=1\nCONNECTOR_ENABLED="false"\nB=2\n' > "$SB/x.conf"
if nftban_config_kv_set "$SB/x.conf" CONNECTOR_ENABLED "true"; then ok "mutation returned success"; else bad "mutation failed on an existing key"; fi
[[ "$(_val "$SB/x.conf" CONNECTOR_ENABLED)" == "true" ]] && ok "REQUESTED == PERSISTED (true)" || bad "persisted value is not the request"
[[ "$(_card "$SB/x.conf" CONNECTOR_ENABLED)" -eq 1 ]] && ok "cardinality == 1" || bad "cardinality != 1"
{ grep -q '^A=1$' "$SB/x.conf" && grep -q '^B=2$' "$SB/x.conf"; } && ok "neighbouring keys preserved" || bad "neighbouring keys damaged"

echo "=== 2. key ABSENT -> appended exactly once (THE DEFECT) ==="
printf 'CONNECTOR_NAME="demo"\n' > "$SB/y.conf"
if nftban_config_kv_set "$SB/y.conf" CONNECTOR_ENABLED "true"; then ok "mutation returned success"; else bad "mutation failed on an absent key"; fi
[[ "$(_val "$SB/y.conf" CONNECTOR_ENABLED)" == "true" ]] && ok "REQUESTED == PERSISTED (absent-key branch)" || bad "absent key was not written"
[[ "$(_card "$SB/y.conf" CONNECTOR_ENABLED)" -eq 1 ]] && ok "cardinality == 1 (no duplicate-key ambiguity)" || bad "append produced cardinality != 1"

echo "=== 3. NEGATIVE CONTROL — the OLD sed idiom must be shown to drop silently ==="
printf 'CONNECTOR_NAME="demo"\n' > "$SB/z.conf"
sed -i 's/^CONNECTOR_ENABLED=.*/CONNECTOR_ENABLED="true"/' "$SB/z.conf"; sed_rc=$?
if [[ "$sed_rc" -eq 0 && "$(_card "$SB/z.conf" CONNECTOR_ENABLED)" -eq 0 ]]; then
  ok "old idiom exits 0 while writing NOTHING — regression to it is detectable here"
else bad "negative control did not reproduce the silent drop (rc=$sed_rc card=$(_card "$SB/z.conf" CONNECTOR_ENABLED))"; fi

echo "=== 4. FAIL-CLOSED on ambiguity / malformed input ==="
printf 'K="x"\nK="y"\n' > "$SB/dup.conf"; before=$(cat "$SB/dup.conf")
nftban_config_kv_set "$SB/dup.conf" K "z" >/dev/null 2>&1; rc=$?
[[ "$rc" -eq "${NFTBAN_KV_AMBIGUOUS}" ]] && ok "duplicate key REFUSED (rc=$rc)" || bad "duplicate key not refused (rc=$rc)"
[[ "$before" == "$(cat "$SB/dup.conf")" ]] && ok "refused mutation left the target untouched" || bad "target mutated despite refusal"
nftban_config_kv_set "$SB/x.conf" "BAD KEY" v >/dev/null 2>&1; [[ $? -eq "${NFTBAN_KV_BAD_KEY}" ]] && ok "malformed key refused" || bad "malformed key accepted"
nftban_config_kv_set "$SB/missing.conf" K v >/dev/null 2>&1; [[ $? -eq "${NFTBAN_KV_NO_TARGET}" ]] && ok "absent target refused" || bad "absent target accepted"

echo "=== 5. values hostile to the old delimiter-based sed ==="
printf 'MAIL="old"\n' > "$SB/m.conf"
nftban_config_kv_set "$SB/m.conf" MAIL 'a|b/c d' >/dev/null 2>&1
[[ "$(_val "$SB/m.conf" MAIL)" == 'a|b/c d' ]] && ok "value containing | and / persisted intact" || bad "delimiter-hostile value corrupted"

echo "=== 6. the four converted call sites no longer use the bare idiom ==="
n=$(grep -cE "sed -i .*\^(CONNECTOR_ENABLED|NFTBAN_MAIL_SYSTEM)=" \
      "$ROOT/cli/lib/nftban/cli/cmd_connector.sh" "$ROOT/cli/lib/nftban/cli/cmd_report.sh" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
[[ "$n" -eq 0 ]] && ok "no bare absent-key-unsafe sed remains at the converted sites" || bad "$n bare sed site(s) remain"
for f in cmd_connector.sh cmd_report.sh; do
  grep -q 'nftban_config_kv.sh' "$ROOT/cli/lib/nftban/cli/$f" && ok "$f sources the mutation authority" || bad "$f does not source the helper"
done

echo
echo "=== B2 (v1.230.0): the two mutation paths repaired for PR-5c-B2 ==="
# Both were REGISTERED defects, not hypotheses:
#   CONFIG-UPDATE-AUTO-DISABLE-EXACT-MATCH-SILENT-DROP   cmd_update.sh
#   CONFIG-MAIL-SETUP-MUTATES-PACKAGE-OWNED-BASE         cmd_report.sh
# The contract is WRITE_SUCCESS != MUTATION_SUCCESS: rc=0 proves nothing on its own,
# MUTATION_SUCCESS requires REQUESTED == PERSISTED == EFFECTIVE.

# --- structural: no executable exact-literal sed survives in the disable path ---
_b2_seds=$(awk '/^[[:space:]]*#/ {next} /sed -i .*NFTBAN_UPDATE_AUTO_ENABLED/ {c++} END {print c+0}' \
           "$ROOT/cli/lib/nftban/cli/cmd_update.sh")
[[ "$_b2_seds" -eq 0 ]] \
    && ok "B2-05 no executable exact-match sed remains for NFTBAN_UPDATE_AUTO_ENABLED" \
    || bad "B2-05 $_b2_seds executable exact-match sed(s) remain — the value-form drop can return"

# --- structural: the mail wizard must not write the dpkg-tracked base ---
# conf.d/mail.conf is enrolled as a conffile by packaging/build_nftban.sh (every *.conf
# under /etc/nftban; *.local explicitly excluded). A runtime writer against it makes the
# shipped file diverge from its packaged checksum.
_b2_base=$(awk '/^[[:space:]]*#/ {next} /(sed -i|>>|\} >)[^#]*"\$mail_conf"/ {c++} END {print c+0}' \
           "$ROOT/cli/lib/nftban/cli/cmd_report.sh")
[[ "$_b2_base" -eq 0 ]] \
    && ok "B2-03 no writer targets the package-owned conf.d/mail.conf" \
    || bad "B2-03 $_b2_base writer(s) still mutate the packaged base conffile"

# --- structural: the full-regeneration branch is gone, not retargeted ---
grep -q 'Old format or empty file - write new configuration' "$ROOT/cli/lib/nftban/cli/cmd_report.sh" \
    && bad "B2-03 the wizard still regenerates the whole mail config (discards operator edits)" \
    || ok "B2-03 full-regeneration branch removed, not retargeted"

# --- behavioural: every value form the exact-literal sed used to drop ---
# These are the measured pre-fix drops. Each must now persist as an EFFECTIVE "false".
for _b2_seed in 'NFTBAN_UPDATE_AUTO_ENABLED="true"' 'NFTBAN_UPDATE_AUTO_ENABLED=true' \
                "NFTBAN_UPDATE_AUTO_ENABLED='true'" 'NFTBAN_UPDATE_AUTO_ENABLED = "true"'; do
    _b2_d="$(mktemp -d)"; printf '%s\n' "$_b2_seed" > "$_b2_d/update.conf.local"
    if nftban_config_kv_set "$_b2_d/update.conf.local" NFTBAN_UPDATE_AUTO_ENABLED "false" >/dev/null 2>&1; then
        _b2_n=$(grep -cE '^[[:space:]]*NFTBAN_UPDATE_AUTO_ENABLED=' "$_b2_d/update.conf.local")
        _b2_v=$(grep -E '^[[:space:]]*NFTBAN_UPDATE_AUTO_ENABLED=' "$_b2_d/update.conf.local" | tail -1 | sed 's/^[^=]*=//; s/^"//; s/"$//')
        [[ "$_b2_v" == "false" ]] \
            && ok "B2-05 seed [$_b2_seed] -> persisted false (cardinality $_b2_n)" \
            || bad "B2-05 seed [$_b2_seed] -> persisted [$_b2_v], request dropped"
    else
        bad "B2-05 seed [$_b2_seed] -> authority refused the write"
    fi
    rm -rf "$_b2_d"
done

# --- behavioural: absent target file must still persist (the second drop) ---
# Pre-fix the sed sat inside `[[ -f "$config_local" ]]`, so with no .local NOTHING was
# written while the timers were disabled anyway: TIMERS OFF / CONFIG SAYS ENABLED.
_b2_d="$(mktemp -d)"; : > "$_b2_d/update.conf.local"
nftban_config_kv_set "$_b2_d/update.conf.local" NFTBAN_UPDATE_AUTO_ENABLED "false" >/dev/null 2>&1
_b2_v=$(grep -E '^[[:space:]]*NFTBAN_UPDATE_AUTO_ENABLED=' "$_b2_d/update.conf.local" 2>/dev/null | tail -1 | sed 's/^[^=]*=//; s/"//g')
[[ "$_b2_v" == "false" ]] \
    && ok "B2-05 empty target file: key appended, value persisted" \
    || bad "B2-05 empty target file: nothing persisted (got [$_b2_v])"
rm -rf "$_b2_d"


echo
echo "=== B3 (v1.230.0): SPLIT RUNTIME AUTHORITY must fail closed BEFORE mutation ==="
# CONFIG-WATCHDOG-DUAL-RUNTIME-AUTHORITY-SPLIT (BLOCKED_BY = OWNER_DECISION).
# Two subjects are served by TWO runtime planes whose config chains disagree:
#   watchdog  conf.d/watchdog.conf / NFTBAN_WATCHDOG_ENABLED
#             shell owner  core/nftban_watchdog.sh:81,:590 consumes the key but loads only
#                          conf.d/watchdog/main.conf[.local]  (:71-77) — never the subject
#             go owner     internal/watchdog/config_loader.go:36-62 reads the subject but
#                          consumes NFTBAN_DYNAMIC_WATCHDOG_ENABLED (:106) — never the key
#             => 0 of 2 owners observe the write: STRUCTURAL split
#   login     conf.d/login/main.conf.local / LOGIN_ENABLED
#             shell owner  core/nftban_login.sh:113-121,:433,:504 — nftban.conf.local is
#                          applied BEFORE the module base (:68) and never re-applied
#             go owner     internal/loginmon/module.go:699-720,:754 — nftban.conf.local is
#                          applied LAST (:722-727)
#             => the planes invert central precedence: STATE-DEPENDENT split, present
#                exactly when nftban.conf.local also declares LOGIN_ENABLED
# SCOPE: refusal only. B3 does not choose a plane, synchronise owners or redirect writes.
GUARD="$ROOT/cli/lib/nftban/lib/nftban_config_split_authority.sh"
[[ -r "$GUARD" ]] && ok "B3-00 split-authority guard is present" || bad "B3-00 guard missing: $GUARD"

# --- unit: verdicts and fail-closed vocabulary -------------------------------
if [[ -r "$GUARD" ]]; then
  _b3_rc(){ ( set +e
              NFTBAN_CONFIG_DIR="$1" bash -c '
                 source "$1" || exit 90
                 nftban_config_split_guard "$2" >/dev/null 2>&1
                 echo $?' _ "$GUARD" "$2" ); }
  _b3_msg(){ ( set +e
               NFTBAN_CONFIG_DIR="$1" bash -c '
                 source "$1" || exit 90
                 nftban_config_split_guard "$2" 2>&1 >/dev/null' _ "$GUARD" "$2" ); }

  _b3_empty="$(mktemp -d)"
  [[ "$(_b3_rc "$_b3_empty" watchdog)" -eq 9 ]] \
      && ok "B3-01 watchdog: structural split REFUSED (rc=9)" \
      || bad "B3-01 watchdog split not refused (rc=$(_b3_rc "$_b3_empty" watchdog))"
  [[ "$(_b3_rc "$_b3_empty" nosuchsubject)" -eq 8 ]] \
      && ok "B3-02 unregistered subject fails closed (rc=8), never silently permitted" \
      || bad "B3-02 unregistered subject did not fail closed"

  _b3_d="$(_b3_msg "$_b3_empty" watchdog)"
  { grep -q 'SPLIT RUNTIME AUTHORITY' <<<"$_b3_d" \
    && grep -q 'core/nftban_watchdog.sh' <<<"$_b3_d" \
    && grep -q 'internal/watchdog/config_loader.go' <<<"$_b3_d" \
    && grep -q 'NFTBAN_DYNAMIC_WATCHDOG_ENABLED' <<<"$_b3_d"; } \
      && ok "B3-03 watchdog diagnostic NAMES both conflicting runtime authorities" \
      || bad "B3-03 watchdog diagnostic does not name both authorities"

  # login is STATE-dependent: no central declaration -> no split -> the guard must NOT refuse.
  # (A guard that refuses unconditionally would pass a refusal test while breaking the command.)
  printf 'NFTBAN_UNRELATED="x"\n' > "$_b3_empty/nftban.conf.local"
  [[ "$(_b3_rc "$_b3_empty" login)" -eq 0 ]] \
      && ok "B3-04 login: no central LOGIN_ENABLED -> both owners agree -> guard permits" \
      || bad "B3-04 login guard refused a state with no proven split (blanket refusal)"
  printf 'LOGIN_ENABLED="false"\n' >> "$_b3_empty/nftban.conf.local"
  [[ "$(_b3_rc "$_b3_empty" login)" -eq 9 ]] \
      && ok "B3-05 login: central LOGIN_ENABLED present -> chains invert -> REFUSED (rc=9)" \
      || bad "B3-05 login split not refused (rc=$(_b3_rc "$_b3_empty" login))"
  _b3_d="$(_b3_msg "$_b3_empty" login)"
  { grep -q 'core/nftban_login.sh' <<<"$_b3_d" \
    && grep -q 'internal/loginmon/module.go' <<<"$_b3_d"; } \
      && ok "B3-06 login diagnostic NAMES both conflicting runtime authorities" \
      || bad "B3-06 login diagnostic does not name both authorities"
  rm -rf "$_b3_empty"
fi

# --- structural: the guard is MANDATORY and runs FIRST ------------------------
# Located by CONTENT, never by line number: the first executable statement of each
# mutation entry point must be the guard, so nothing (not even a mkdir/touch of a
# .local file, not even systemctl) can run ahead of the refusal.
_b3_first_stmt(){ # <file> <function>
    awk -v fn="$2" '
        $0 ~ "^"fn"\\(\\) \\{" {inf=1; next}
        inf && /^\}/ {exit}
        inf {
            line=$0
            sub(/^[[:space:]]+/,"",line)
            if (line=="" || line ~ /^#/) next
            print line; exit
        }' "$1"
}
for _b3_pair in "cmd_watchdog.sh:nftban_watchdog_cmd_enable:watchdog" \
                "cmd_watchdog.sh:nftban_watchdog_cmd_disable:watchdog" \
                "cmd_login.sh:nftban_login_cmd_enable:login" \
                "cmd_login.sh:nftban_login_cmd_disable:login"; do
    _b3_f="${_b3_pair%%:*}"; _b3_rest="${_b3_pair#*:}"
    _b3_fn="${_b3_rest%%:*}"; _b3_subj="${_b3_rest##*:}"
    _b3_got="$(_b3_first_stmt "$ROOT/cli/lib/nftban/cli/$_b3_f" "$_b3_fn")"
    [[ "$_b3_got" == "nftban_config_split_guard ${_b3_subj} || return \$?" ]] \
        && ok "B3-07 $_b3_fn: guard is the FIRST executable statement" \
        || bad "B3-07 $_b3_fn: first statement is [$_b3_got], not the split guard"
done
for _b3_f in cmd_watchdog.sh cmd_login.sh; do
    # MANDATORY source: an `if [[ -f ... ]]` wrapper would silently fail OPEN when the
    # guard is absent. The module must refuse to load instead.
    grep -qE '^source "\$\{NFTBAN_LIB_DIR\}/lib/nftban_config_split_authority\.sh" \|\| return 1$' \
        "$ROOT/cli/lib/nftban/cli/$_b3_f" \
        && ok "B3-08 $_b3_f sources the guard unconditionally (fail closed if absent)" \
        || bad "B3-08 $_b3_f does not source the guard unconditionally"
done

# --- behavioural: REFUSAL LEAVES THE TARGET BYTE-IDENTICAL --------------------
# rc!=0 does not prove "no file change", so both arms assert on sha256, not on rc alone.
# Both arms run the REAL command function from the REAL module, over an identical
# sandbox, with the SAME accommodations (systemctl stubbed, the root gate neutralised).
# The ONLY difference in the negative-control arm is the DECLARED INVERSION: the guard
# call is removed, reproducing the pre-B3 code exactly.
_b3_sb="$(mktemp -d)"
mkdir -p "$_b3_sb/bin" "$_b3_sb/lib/cli"
printf '#!/bin/sh\nexit 0\n' > "$_b3_sb/bin/systemctl"; chmod +x "$_b3_sb/bin/systemctl"
for _b3_d in lib core helpers exporters data setup health cron; do
    [[ -d "$ROOT/cli/lib/nftban/$_b3_d" ]] && ln -s "$ROOT/cli/lib/nftban/$_b3_d" "$_b3_sb/lib/$_b3_d"
done
_b3_tree(){ ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) | sha256sum | cut -d' ' -f1; }
_b3_run(){ # <cmdfile> <configdir> <call...>  -> prints rc
    ( set +e
      PATH="$_b3_sb/bin:$PATH" NFTBAN_LIB_DIR="$_b3_sb/lib" NFTBAN_CONFIG_DIR="$2" \
      bash -c 'source "$1" >/dev/null 2>&1 || exit 90
               shift
               _rc=0; "$@" >/dev/null 2>&1 || _rc=$?
               echo "$_rc"' _ "$1" "${@:3}" )
}

# ---- watchdog: disable() flips "true"->"false" pre-fix, so a byte change is visible
_b3_wd="$_b3_sb/wd"; mkdir -p "$_b3_wd/conf.d"
cp "$ROOT/etc/nftban/conf.d/watchdog.conf" "$_b3_wd/conf.d/watchdog.conf"
cp "$ROOT/cli/lib/nftban/cli/cmd_watchdog.sh" "$_b3_sb/lib/cli/cmd_watchdog.sh"
_b3_h0="$(sha256sum "$_b3_wd/conf.d/watchdog.conf" | cut -d' ' -f1)"
_b3_r="$(_b3_run "$_b3_sb/lib/cli/cmd_watchdog.sh" "$_b3_wd" nftban_watchdog_cmd_disable)"
_b3_h1="$(sha256sum "$_b3_wd/conf.d/watchdog.conf" | cut -d' ' -f1)"
[[ "$_b3_r" -ne 0 ]] && ok "B3-09 watchdog disable REFUSED (rc=$_b3_r)" \
                     || bad "B3-09 watchdog disable returned success despite the split"
[[ "$_b3_h0" == "$_b3_h1" ]] \
    && ok "B3-10 refused watchdog mutation left conf.d/watchdog.conf BYTE-IDENTICAL" \
    || bad "B3-10 refused watchdog mutation changed the packaged conffile"

# NEGATIVE CONTROL — declared inversion of the guard call only.
grep -v 'nftban_config_split_guard watchdog || return \$?' \
     "$ROOT/cli/lib/nftban/cli/cmd_watchdog.sh" > "$_b3_sb/lib/cli/cmd_watchdog.sh"
grep -q 'nftban_config_split_guard' "$_b3_sb/lib/cli/cmd_watchdog.sh" \
    && bad "B3-11 inversion failed: the guard call is still present" \
    || ok "B3-11 negative control built (guard call removed, nothing else changed)"
cp "$ROOT/etc/nftban/conf.d/watchdog.conf" "$_b3_wd/conf.d/watchdog.conf"
_b3_h0="$(sha256sum "$_b3_wd/conf.d/watchdog.conf" | cut -d' ' -f1)"
_b3_r="$(_b3_run "$_b3_sb/lib/cli/cmd_watchdog.sh" "$_b3_wd" nftban_watchdog_cmd_disable)"
_b3_h1="$(sha256sum "$_b3_wd/conf.d/watchdog.conf" | cut -d' ' -f1)"
{ [[ "$_b3_r" -eq 0 ]] && [[ "$_b3_h0" != "$_b3_h1" ]]; } \
    && ok "B3-12 pre-B3 behaviour reproduced: rc=0 AND the conffile was mutated" \
    || bad "B3-12 negative control did not hit the defect (rc=$_b3_r, changed=$([[ "$_b3_h0" == "$_b3_h1" ]] && echo no || echo yes))"

# ---- login: split state = central override ALSO declares LOGIN_ENABLED
_b3_lg="$_b3_sb/lg"; mkdir -p "$_b3_lg/conf.d/login"
cp "$ROOT/etc/nftban/conf.d/login/main.conf" "$_b3_lg/conf.d/login/main.conf"
cp "$ROOT/etc/nftban/conf.d/login_alert.conf" "$_b3_lg/conf.d/login_alert.conf" 2>/dev/null || true
printf 'LOGIN_ENABLED="false"\n' > "$_b3_lg/nftban.conf.local"
# Environment accommodation applied to BOTH arms: the root gate cannot be satisfied in
# CI, and neutralising it identically in both arms cannot manufacture the difference.
sed 's/\[\[ \$EUID -ne 0 \]\]/[[ 0 -ne 0 ]]/' \
    "$ROOT/cli/lib/nftban/cli/cmd_login.sh" > "$_b3_sb/lib/cli/cmd_login.sh"
_b3_h0="$(_b3_tree "$_b3_lg")"
_b3_r="$(_b3_run "$_b3_sb/lib/cli/cmd_login.sh" "$_b3_lg" nftban_login_cmd_enable service)"
_b3_h1="$(_b3_tree "$_b3_lg")"
[[ "$_b3_r" -ne 0 ]] && ok "B3-13 login enable REFUSED under the split (rc=$_b3_r)" \
                     || bad "B3-13 login enable returned success despite the split"
[[ "$_b3_h0" == "$_b3_h1" ]] \
    && ok "B3-14 refused login mutation left the whole config tree BYTE-IDENTICAL" \
    || bad "B3-14 refused login mutation changed the config tree"
[[ ! -e "$_b3_lg/conf.d/login/main.conf.local" ]] \
    && ok "B3-15 refusal created no override file (no state change, not just no write)" \
    || bad "B3-15 refusal still created conf.d/login/main.conf.local"

# NEGATIVE CONTROL — same accommodation, guard call additionally removed.
sed 's/\[\[ \$EUID -ne 0 \]\]/[[ 0 -ne 0 ]]/' "$ROOT/cli/lib/nftban/cli/cmd_login.sh" \
  | grep -v 'nftban_config_split_guard login || return \$?' > "$_b3_sb/lib/cli/cmd_login.sh"
_b3_h0="$(_b3_tree "$_b3_lg")"
_b3_r="$(_b3_run "$_b3_sb/lib/cli/cmd_login.sh" "$_b3_lg" nftban_login_cmd_enable service)"
_b3_h1="$(_b3_tree "$_b3_lg")"
{ [[ "$_b3_r" -eq 0 ]] && [[ "$_b3_h0" != "$_b3_h1" ]] \
  && [[ -f "$_b3_lg/conf.d/login/main.conf.local" ]]; } \
    && ok "B3-16 pre-B3 behaviour reproduced: rc=0, tree mutated, override file created" \
    || bad "B3-16 login negative control did not hit the defect (rc=$_b3_r)"
rm -rf "$_b3_sb"

printf 'config-kv-mutation-truth: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
