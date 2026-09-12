#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config-overlay-cli-family"
# meta:type="test"
# meta:description="v1.230.0 PR-5c-B1 (CLI family). Locks the shell config precedence contract BASE < MODULE_LOCAL < CENTRAL_OPERATOR_OVERRIDE for the SOURCE_ENV config-load transactions in cmd_report.sh, cmd_update.sh, cmd_status.sh and cmd_zabbix.sh. Precedence is observed as a POST-LOAD EFFECTIVE VALUE: the real consumer file is sourced and the real transaction function is invoked in a subshell whose NFTBAN_CONFIG_DIR points at a mktemp fixture, and the resulting variable (or the value the consumer actually emits) is read back. Source text is never asserted on for the behavioural claims. A negative control resolves the same fixtures against the pre-fix subject (git show of the branch base, with a declared inversion as fallback for a shallow checkout) and REQUIRES the old code to resolve the lower-precedence layer — without it a passing suite would not distinguish the repair from an unreachable one. The bootstrap invariant is asserted structurally: the repair must not add an env.sh source site, because env.sh participates in configuration initialisation and a fresh source solely to reach the helper would itself change load order — the defect class this increment removes."
# meta:ta.id="config_overlay_cli_family_test"
# meta:ta.owner="core"
# meta:ta.module="config-precedence"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/env.sh,cli/lib/nftban/cli/cmd_report.sh,cli/lib/nftban/cli/cmd_update.sh,cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/cli/cmd_zabbix.sh"
# meta:inventory.binaries="bash,grep,git"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_LOG_DIR,NFTBAN_DATA_DIR,NFTBAN_CACHE_DIR"
# meta:inventory.config_files="conf.d/stats.conf,conf.d/mail.conf,conf.d/update.conf,conf.d/zabbix.conf,conf.d/services.conf,conf.d/rbl/main.conf,conf.d/tunnel/main.conf,nftban.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BASE_SHA="9ab3bade"   # branch base of fix/v1230-0-p5c-b1-cli == the pre-fix subject
P=0; F=0
ok(){  printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }

SB="$(mktemp -d)"
# shellcheck disable=SC2064  # SB must expand now, not at trap time
trap "rm -rf '$SB'" EXIT INT TERM

CUR_REPORT="$ROOT/cli/lib/nftban/cli/cmd_report.sh"
CUR_UPDATE="$ROOT/cli/lib/nftban/cli/cmd_update.sh"
CUR_STATUS="$ROOT/cli/lib/nftban/cli/cmd_status.sh"
CUR_ZABBIX="$ROOT/cli/lib/nftban/cli/cmd_zabbix.sh"

# ---------------------------------------------------------------------------
# Fixture. Values are deliberately NON-EMPTY and distinct per layer: `: "${K:=d}"`
# and "${K:-d}" both treat empty as unset, so an empty layer would prove nothing.
# ⛔ "${SB:?}" not "$SB": an empty SB would make this `rm -rf /etc` (SC2115).
# ---------------------------------------------------------------------------
_mk(){
    rm -rf "${SB:?}/etc" "${SB:?}/log" "${SB:?}/data" "${SB:?}/cache"
    mkdir -p "$SB/etc/conf.d/rbl" "$SB/etc/conf.d/tunnel" "$SB/log" "$SB/data" "$SB/cache"
    printf '# hermetic base\n' > "$SB/etc/nftban.conf"
}

# _eff <consumer file> <transaction invocation> <key>
# Sources the REAL consumer, runs the REAL transaction function, prints the resulting
# effective value. env.sh is sourced first because that is how the nftban entrypoint
# bootstraps every consumer; the strict-mode traps are relaxed only AFTER loading so a
# reporting section that needs systemd/nft cannot abort the observation.
_eff(){
    env NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" \
        NFTBAN_LOG_DIR="$SB/log" NFTBAN_DATA_DIR="$SB/data" NFTBAN_CACHE_DIR="$SB/cache" \
        timeout 180 bash -c "
        cd '$ROOT'
        source cli/lib/nftban/lib/env.sh 2>/dev/null || true
        source '$1' 2>/dev/null || true
        source cli/lib/nftban/core/nftban_output.sh 2>/dev/null || true
        set +e +u +o pipefail; trap - ERR
        $2 >/dev/null 2>&1
        printf '%s' \"\${$3:-<unset>}\"" 2>/dev/null
}

# _eff_emitted <consumer file> — output_json exits the shell on the way out, so its
# transaction is observed through the value the consumer ACTUALLY EMITS.
_eff_emitted(){
    env NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" \
        NFTBAN_LOG_DIR="$SB/log" NFTBAN_DATA_DIR="$SB/data" NFTBAN_CACHE_DIR="$SB/cache" \
        timeout 180 bash -c "
        cd '$ROOT'
        source cli/lib/nftban/lib/env.sh 2>/dev/null || true
        source '$1' 2>/dev/null || true
        source cli/lib/nftban/core/nftban_output.sh 2>/dev/null || true
        set +e +u +o pipefail; trap - ERR
        output_json 2>/dev/null | grep -m1 'master_enabled'" 2>/dev/null \
      | sed 's/.*: *//; s/,$//'
}

# Pre-fix subject. PRIMARY: the immutable base SHA. FALLBACK (shallow checkout, where
# `git show <sha>` is unavailable): a DECLARED INVERSION of the current subject — the
# overlay authority is removed from the file, so the definedness guard the repair relies
# on fails closed and the consumer behaves exactly as it did before the repair.
# _prefix runs inside a command substitution, so it CANNOT report its mode through a
# variable — it records the mode in a file and _prefix_mode reads it back. A label that
# silently said "unset" would misreport which subject the control actually ran against.
_prefix_mode(){ cat "$SB/.prefix_mode" 2>/dev/null || printf 'unrecorded'; }
_prefix(){ # $1=repo-relative path  ->  echoes a local path to the pre-fix subject
    local rel="$1"
    local out
    out="$SB/prefix_$(basename "$rel")"
    if git -C "$ROOT" show "${BASE_SHA}:${rel}" > "$out" 2>/dev/null && [[ -s "$out" ]]; then
        printf 'git_show_%s' "$BASE_SHA" > "$SB/.prefix_mode"
    else
        printf 'declared_inversion' > "$SB/.prefix_mode"
        sed -e 's/^\([[:space:]]*\)declare -F nftban_config_apply_final_operator_overlay .*$/\1: # inverted/' \
            -e 's/^\([[:space:]]*\)&& nftban_config_apply_final_operator_overlay[[:space:]]*$/\1: # inverted/' \
            "$ROOT/$rel" > "$out"
    fi
    printf '%s' "$out"
}

echo "=== 1. cmd_report.sh nftban_report_cmd_status — stats.conf transaction ==="
_mk
printf 'STATS_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/stats.conf"
printf 'NFTBAN_MAIL_ENABLED="NO"\n' > "$SB/etc/conf.d/mail.conf"
printf 'STATS_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/stats.conf.local"
printf 'STATS_ENABLED="USERVAL"\n'  > "$SB/etc/nftban.conf.local"
r=$(_eff "$CUR_REPORT" nftban_report_cmd_status STATS_ENABLED)
[[ "$r" == "USERVAL" ]] && ok "report status: central operator override WINS" || bad "report status: central override lost (got '$r')"

_mk
printf 'STATS_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/stats.conf"
printf 'NFTBAN_MAIL_ENABLED="NO"\n' > "$SB/etc/conf.d/mail.conf"
printf 'STATS_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/stats.conf.local"
r=$(_eff "$CUR_REPORT" nftban_report_cmd_status STATS_ENABLED)
[[ "$r" == "LOCALVAL" ]] && ok "report status: module-local wins when central absent (overlay does not clobber)" || bad "report status: module-local lost (got '$r')"

_mk
printf 'STATS_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/stats.conf"
printf 'NFTBAN_MAIL_ENABLED="NO"\n' > "$SB/etc/conf.d/mail.conf"
r=$(_eff "$CUR_REPORT" nftban_report_cmd_status STATS_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "report status: base survives with no override present" || bad "report status: base value lost (got '$r')"

echo "=== 2. cmd_zabbix.sh _cmd_zabbix_reload — zabbix.conf RELOAD transaction ==="
_mk
printf 'NFTBAN_ZABBIX_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/zabbix.conf"
printf 'NFTBAN_ZABBIX_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/zabbix.conf.local"
printf 'NFTBAN_ZABBIX_ENABLED="USERVAL"\n'  > "$SB/etc/nftban.conf.local"
r=$(_eff "$CUR_ZABBIX" _cmd_zabbix_reload NFTBAN_ZABBIX_ENABLED)
[[ "$r" == "USERVAL" ]] && ok "zabbix reload: central operator override WINS after the re-source" || bad "zabbix reload: central override lost (got '$r')"

_mk
printf 'NFTBAN_ZABBIX_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/zabbix.conf"
printf 'NFTBAN_ZABBIX_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/zabbix.conf.local"
r=$(_eff "$CUR_ZABBIX" _cmd_zabbix_reload NFTBAN_ZABBIX_ENABLED)
[[ "$r" == "LOCALVAL" ]] && ok "zabbix reload: module-local wins when central absent" || bad "zabbix reload: module-local lost (got '$r')"

_mk
printf 'NFTBAN_ZABBIX_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/zabbix.conf"
r=$(_eff "$CUR_ZABBIX" _cmd_zabbix_reload NFTBAN_ZABBIX_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "zabbix reload: base survives with no override present" || bad "zabbix reload: base value lost (got '$r')"

echo "=== 3. cmd_update.sh _cmd_update_auto_run — update.conf + mail.conf transaction ==="
_mk
printf 'NFTBAN_UPDATE_AUTO_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/update.conf"
printf 'NFTBAN_MAIL_RECIPIENT=""\n'              > "$SB/etc/conf.d/mail.conf"
printf 'NFTBAN_UPDATE_AUTO_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/update.conf.local"
printf 'NFTBAN_UPDATE_AUTO_ENABLED="USERVAL"\n'  > "$SB/etc/nftban.conf.local"
r=$(_eff "$CUR_UPDATE" _cmd_update_auto_run NFTBAN_UPDATE_AUTO_ENABLED)
[[ "$r" == "USERVAL" ]] && ok "update auto-run: central operator override WINS" || bad "update auto-run: central override lost (got '$r')"

_mk
printf 'NFTBAN_UPDATE_AUTO_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/update.conf"
printf 'NFTBAN_MAIL_RECIPIENT=""\n'              > "$SB/etc/conf.d/mail.conf"
printf 'NFTBAN_UPDATE_AUTO_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/update.conf.local"
r=$(_eff "$CUR_UPDATE" _cmd_update_auto_run NFTBAN_UPDATE_AUTO_ENABLED)
[[ "$r" == "LOCALVAL" ]] && ok "update auto-run: module-local wins when central absent" || bad "update auto-run: module-local lost (got '$r')"

_mk
printf 'NFTBAN_UPDATE_AUTO_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/update.conf"
printf 'NFTBAN_MAIL_RECIPIENT=""\n'             > "$SB/etc/conf.d/mail.conf"
r=$(_eff "$CUR_UPDATE" _cmd_update_auto_run NFTBAN_UPDATE_AUTO_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "update auto-run: base survives with no override present" || bad "update auto-run: base value lost (got '$r')"

echo "=== 4. cmd_update.sh _update_auto_status — the shipped mail.conf base is NOT inert ==="
# /etc/nftban/conf.d/mail.conf ships NFTBAN_MAIL_RECIPIENT="" as a PLAIN assignment, so
# sourcing it erases a central operator value. The recipient must still resolve centrally.
_mk
printf 'NFTBAN_UPDATE_AUTO_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/update.conf"
printf 'NFTBAN_MAIL_RECIPIENT=""\n'             > "$SB/etc/conf.d/mail.conf"
printf 'NFTBAN_MAIL_RECIPIENT="ops@example.test"\n' > "$SB/etc/nftban.conf.local"
r=$(_eff "$CUR_UPDATE" _update_auto_status NFTBAN_MAIL_RECIPIENT)
[[ "$r" == "ops@example.test" ]] && ok "update auto-status: central recipient survives the empty shipped base" || bad "update auto-status: shipped empty base erased the central recipient (got '$r')"

echo "=== 5. cmd_status.sh _status_section_protection — six subjects, six sub-transactions ==="
_mk
printf 'NFTBAN_RBL_ENABLED="BASEVAL"\n'    > "$SB/etc/conf.d/rbl/main.conf"
printf 'NFTBAN_TUNNEL_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/tunnel/main.conf"
printf 'NFTBAN_ZABBIX_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/zabbix.conf"
printf 'NFTBAN_RBL_ENABLED="USERVAL"\nNFTBAN_TUNNEL_ENABLED="USERVAL"\nNFTBAN_ZABBIX_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
r=$(_eff "$CUR_STATUS" _status_section_protection NFTBAN_RBL_ENABLED)
[[ "$r" == "USERVAL" ]] && ok "protection: RBL sub-transaction takes the central override" || bad "protection: RBL kept the base value (got '$r')"
r=$(_eff "$CUR_STATUS" _status_section_protection NFTBAN_TUNNEL_ENABLED)
[[ "$r" == "USERVAL" ]] && ok "protection: tunnel sub-transaction takes the central override" || bad "protection: tunnel kept the base value (got '$r')"
r=$(_eff "$CUR_STATUS" _status_section_protection NFTBAN_ZABBIX_ENABLED)
[[ "$r" == "USERVAL" ]] && ok "protection: zabbix sub-transaction takes the central override" || bad "protection: zabbix kept the base value (got '$r')"

_mk
printf 'NFTBAN_RBL_ENABLED="BASEVAL"\n'    > "$SB/etc/conf.d/rbl/main.conf"
printf 'NFTBAN_RBL_ENABLED="LOCALVAL"\n'   > "$SB/etc/conf.d/rbl/main.conf.local"
r=$(_eff "$CUR_STATUS" _status_section_protection NFTBAN_RBL_ENABLED)
[[ "$r" == "LOCALVAL" ]] && ok "protection: module-local wins when central absent" || bad "protection: module-local lost (got '$r')"
_mk
printf 'NFTBAN_RBL_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/rbl/main.conf"
r=$(_eff "$CUR_STATUS" _status_section_protection NFTBAN_RBL_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "protection: base survives with no override present" || bad "protection: base value lost (got '$r')"

echo "=== 6. cmd_status.sh output_json — observed through the EMITTED value ==="
_mk
printf 'NFTBAN_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/services.conf.local"
printf 'NFTBAN_ENABLED="USERVAL"\n'  > "$SB/etc/nftban.conf.local"
r=$(_eff_emitted "$CUR_STATUS")
[[ "$r" == "USERVAL" ]] && ok "output_json: central operator override beats the module-local services override" || bad "output_json: module-local still wins (got '$r')"

echo "=== 7. NEGATIVE CONTROL — the pre-fix subject must resolve the LOWER layer ==="
_mk
printf 'STATS_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/stats.conf"
printf 'NFTBAN_MAIL_ENABLED="NO"\n' > "$SB/etc/conf.d/mail.conf"
printf 'STATS_ENABLED="USERVAL"\n'  > "$SB/etc/nftban.conf.local"
r=$(_eff "$(_prefix cli/lib/nftban/cli/cmd_report.sh)" nftban_report_cmd_status STATS_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "pre-fix report status resolves the BASE value [$(_prefix_mode)]" || bad "pre-fix report status did not resolve BASE — the control does not hit the motivating defect (got '$r', mode $(_prefix_mode))"

_mk
printf 'NFTBAN_ZABBIX_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/zabbix.conf"
printf 'NFTBAN_ZABBIX_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
r=$(_eff "$(_prefix cli/lib/nftban/cli/cmd_zabbix.sh)" _cmd_zabbix_reload NFTBAN_ZABBIX_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "pre-fix zabbix reload resolves the BASE value [$(_prefix_mode)]" || bad "pre-fix zabbix reload did not resolve BASE (got '$r', mode $(_prefix_mode))"

_mk
printf 'NFTBAN_UPDATE_AUTO_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/update.conf"
printf 'NFTBAN_MAIL_RECIPIENT=""\n'             > "$SB/etc/conf.d/mail.conf"
printf 'NFTBAN_UPDATE_AUTO_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
r=$(_eff "$(_prefix cli/lib/nftban/cli/cmd_update.sh)" _cmd_update_auto_run NFTBAN_UPDATE_AUTO_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "pre-fix update auto-run resolves the BASE value [$(_prefix_mode)]" || bad "pre-fix update auto-run did not resolve BASE (got '$r', mode $(_prefix_mode))"

_mk
printf 'NFTBAN_RBL_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/rbl/main.conf"
printf 'NFTBAN_RBL_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
r=$(_eff "$(_prefix cli/lib/nftban/cli/cmd_status.sh)" _status_section_protection NFTBAN_RBL_ENABLED)
[[ "$r" == "BASEVAL" ]] && ok "pre-fix status protection resolves the BASE value [$(_prefix_mode)]" || bad "pre-fix status protection did not resolve BASE (got '$r', mode $(_prefix_mode))"

echo "=== 8. BOOTSTRAP INVARIANT — the repair must add no env.sh source site ==="
for rel in cli/lib/nftban/cli/cmd_report.sh cli/lib/nftban/cli/cmd_update.sh \
           cli/lib/nftban/cli/cmd_status.sh cli/lib/nftban/cli/cmd_zabbix.sh; do
    now=$(grep -cE 'source .*lib/env\.sh' "$ROOT/$rel" 2>/dev/null || true)
    before=$(git -C "$ROOT" show "${BASE_SHA}:${rel}" 2>/dev/null | grep -cE 'source .*lib/env\.sh' || true)
    if [[ -z "$before" ]] || ! git -C "$ROOT" cat-file -e "${BASE_SHA}:${rel}" 2>/dev/null; then
        # Shallow checkout: the base blob is unreachable, so compare against the
        # invariant itself (<=1) rather than silently reporting a pass with no subject.
        [[ "$now" -le 1 ]] && ok "$(basename "$rel"): env.sh source sites = $now (<=1; base blob unavailable)" \
                           || bad "$(basename "$rel"): env.sh source sites = $now — new bootstrap path"
    else
        [[ "$now" -eq "$before" ]] && ok "$(basename "$rel"): env.sh source sites unchanged ($before -> $now)" \
                                   || bad "$(basename "$rel"): env.sh source sites $before -> $now — new bootstrap path introduced"
    fi
done

echo "=== 9. every wired consumer reaches the single overlay authority ==="
for rel in cli/lib/nftban/cli/cmd_report.sh cli/lib/nftban/cli/cmd_update.sh \
           cli/lib/nftban/cli/cmd_status.sh cli/lib/nftban/cli/cmd_zabbix.sh; do
    grep -q 'nftban_config_apply_final_operator_overlay' "$ROOT/$rel" \
        && ok "$(basename "$rel") invokes the final overlay authority" \
        || bad "$(basename "$rel") has no final overlay"
done
grep -q '^nftban_config_apply_final_operator_overlay()' "$ROOT/cli/lib/nftban/lib/env.sh" \
    && ok "single overlay authority is defined in env.sh" || bad "overlay authority missing from env.sh"

echo
printf 'config-overlay-cli-family: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
