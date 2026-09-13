#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config-overlay-maintenance-family"
# meta:type="test"
# meta:description="v1.230.0 PR-5c-B1. Locks BASE < MODULE_LOCAL < CENTRAL_OPERATOR_OVERRIDE for the two MANY-SUBJECT config-load transactions of the maintenance family: helpers/suricata_effective_config.sh::_suricata_generate_module_overlap_disables (5 subject loads, proven DYNAMICALLY from the file the generator emits, plus a synthesised pre-fix negative control that must still lose to the shipped base) and cron/maintenance.sh::main (proven STRUCTURALLY by load/overlay/use ordering, because main() is a lock-taking, IPC-driving orchestrator that the declared hermetic class — no root, no nftables, no systemd — cannot execute; faking a dynamic run there would be worse evidence than an honest structural one). Both files also carry the bootstrap invariant: the repair must not add an env.sh source site, since env.sh participates in configuration initialisation and a fresh source solely to reach the helper would itself change load order — the defect class this increment removes."
# meta:ta.id="config_overlay_maintenance_family_test"
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
# meta:inventory.files="cli/lib/nftban/lib/env.sh,cli/lib/nftban/helpers/suricata_effective_config.sh,cli/lib/nftban/cron/maintenance.sh"
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,SURICATA_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT INT TERM

SURI="$ROOT/cli/lib/nftban/helpers/suricata_effective_config.sh"
MAINT="$ROOT/cli/lib/nftban/cron/maintenance.sh"
OUT_REL="disable.conf.d/nftban-modules.conf"

# ⛔ "${SB:?}" not "$SB": an empty SB would make this `rm -rf /etc`. A destructive path
#    must fail to expand rather than widen (SC2115).
_mk(){
  rm -rf "${SB:?}/etc" "${SB:?}/suricata"
  mkdir -p "$SB/etc/conf.d/portscan" "$SB/etc/conf.d/login" "$SB/etc/conf.d/ddos" "$SB/suricata"
  printf '# base\n' > "$SB/etc/nftban.conf"
}

# Run the REAL generator against the sandbox and read back the module state it emitted.
# Values are observed POST-LOAD, from the artefact the function writes — never from source
# text. Values are deliberately NON-EMPTY: `: "${K:=default}"` and `${K:-default}` treat
# empty as unset, and empty-value semantics are separate debt.
_eff(){ # $1 = helper file to load  $2 = sed extractor for the trailer field
  NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" SURICATA_CONFIG_DIR="$SB/suricata" \
  bash -c "
    cd '$ROOT'
    source cli/lib/nftban/lib/env.sh >/dev/null 2>&1 || true
    source '$1' >/dev/null 2>&1 || true
    _suricata_generate_module_overlap_disables >/dev/null 2>&1 || true" >/dev/null 2>&1
  sed -n "$2" "$SB/suricata/$OUT_REL" 2>/dev/null
}
_portscan(){ _eff "$1" 's/^# Portscan: enabled=\([^ ]*\).*/\1/p'; }
_login(){    _eff "$1" 's/^# Module states: login=\([^ ]*\).*/\1/p'; }

echo "=== 1. suricata overlap generator — DYNAMIC, 5-subject single transaction ==="
_mk; printf 'PORTSCAN_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/portscan/main.conf"
     printf 'PORTSCAN_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/portscan/main.conf.local"
     printf 'PORTSCAN_ENABLED="USERVAL"\n'  > "$SB/etc/nftban.conf.local"
[[ "$(_portscan "$SURI")" == "USERVAL" ]] \
  && ok "central operator override WINS over the LAST-loaded subject base (portscan)" \
  || bad "central override lost on portscan"

_mk; printf 'PORTSCAN_ENABLED="BASEVAL"\n'  > "$SB/etc/conf.d/portscan/main.conf"
     printf 'PORTSCAN_ENABLED="LOCALVAL"\n' > "$SB/etc/conf.d/portscan/main.conf.local"
[[ "$(_portscan "$SURI")" == "LOCALVAL" ]] \
  && ok "module-local wins when central absent (overlay does not clobber)" \
  || bad "module-local lost"

_mk; printf 'PORTSCAN_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/portscan/main.conf"
[[ "$(_portscan "$SURI")" == "BASEVAL" ]] \
  && ok "base survives with no overrides" \
  || bad "base value lost"

# The overlay is applied ONCE, after the LAST of five loads — so it must also protect the
# FIRST-loaded subject (login), not merely the one nearest the call site.
_mk; printf 'NFTBAN_LOGIN_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/login/main.conf"
     printf 'NFTBAN_LOGIN_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_login "$SURI")" == "USERVAL" ]] \
  && ok "one overlay covers the FIRST-loaded subject too (login), proving one transaction" \
  || bad "first-loaded subject (login) not protected by the single overlay"

echo "=== 2. NEGATIVE CONTROL — synthesised pre-fix copy must still lose to the base ==="
# The subject is synthesised by declared inversion (the overlay call removed) rather than
# taken from a moving ref: origin/main inverts the moment the fix merges. If this arm
# passes, the assertions above are not measuring the repair.
PRE="$SB/prefix_suricata_effective_config.sh"
grep -v 'nftban_config_apply_final_operator_overlay' "$SURI" > "$PRE"
grep -q 'nftban_config_apply_final_operator_overlay' "$PRE" \
  && bad "inversion did not remove the overlay call" \
  || ok "inversion subject built: overlay call removed, loads untouched"
_mk; printf 'PORTSCAN_ENABLED="BASEVAL"\n' > "$SB/etc/conf.d/portscan/main.conf"
     printf 'PORTSCAN_ENABLED="USERVAL"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_portscan "$PRE")" == "BASEVAL" ]] \
  && ok "pre-fix copy reproduces the defect (shipped base beats the operator override)" \
  || bad "negative control did not reproduce the motivating defect — the arms above prove nothing"

echo "=== 3. maintenance.sh main() — STRUCTURAL (load < overlay < first use) ==="
# PROOF_MODE=STRUCTURAL, declared, not defaulted to. main() acquires ${NFTBAN_RUN_DIR}
# locks, drives nft through the daemon IPC client (a hard `exit 1` when nft_ipc.sh is
# absent) and writes ${NFTBAN_LOG_DIR}; the file runs `main "$@"` at source time. None of
# that is reachable under requires_root/nftables/systemd = false, so the transaction
# boundary is asserted by ordering. Line numbers are DERIVED, never hard-coded.
_ln(){ grep -nE "$2" "$1" | head -1 | cut -d: -f1; }
_ln_last(){ grep -nE "$2" "$1" | tail -1 | cut -d: -f1; }
_order(){ # $1 label  $2 load  $3 overlay  $4 use
  if [[ -n "$2" && -n "$3" && -n "$4" ]] && (( $2 < $3 && $3 < $4 )); then
    ok "$1: load($2) < overlay($3) < first use($4)"
  else
    bad "$1: ordering not proven (load='$2' overlay='$3' use='$4')"
  fi
}

# main() transaction: portscan base + portscan module-local, then ONE overlay, then the
# first read of PORTSCAN_ENABLED.
M_LOAD="$(_ln "$MAINT" '_source_local .*conf\.d/portscan/main\.conf\.local')"
M_OVL="$(_ln "$MAINT" '&& nftban_config_apply_final_operator_overlay')"
M_USE="$(_ln "$MAINT" '_ps_enabled="\$\{PORTSCAN_ENABLED')"
_order "maintenance.sh main() portscan transaction" "$M_LOAD" "$M_OVL" "$M_USE"

# Script-scope transaction of the same file: nftban.conf base, then the central override,
# then the first read (`: "${NFTBAN_TABLE_IPV4:=...}"` IS a read). Already central-last —
# locked here so a later edit cannot silently reorder it.
S_BASE="$(_ln "$MAINT" 'source "\$\{NFTBAN_CONFIG_DIR:-/etc/nftban\}/nftban\.conf"')"
S_CEN="$(_ln "$MAINT" '_source_local "\$\{NFTBAN_CONFIG_DIR:-/etc/nftban\}/nftban\.conf\.local"')"
S_USE="$(_ln "$MAINT" ': "\$\{NFTBAN_TABLE_IPV4')"
_order "maintenance.sh script-scope transaction" "$S_BASE" "$S_CEN" "$S_USE"

# Same ordering assertion for the suricata transaction, so a reorder is caught structurally
# as well as behaviourally: LAST of the five loads (ddos local) < overlay < first use.
U_LOAD="$(_ln_last "$SURI" '_source_local "\$\{NFTBAN_CONFIG_DIR\}/conf\.d/(login|portscan|ddos)/main\.conf\.local"')"
U_OVL="$(_ln "$SURI" '&& nftban_config_apply_final_operator_overlay')"
U_USE="$(_ln "$SURI" 'login_enabled="\$\{NFTBAN_LOGIN_ENABLED')"
_order "suricata overlap transaction" "$U_LOAD" "$U_OVL" "$U_USE"

echo "=== 4. BOOTSTRAP INVARIANT — the repair must add no env.sh source site ==="
for f in helpers/suricata_effective_config.sh cron/maintenance.sh; do
  n=$(grep -cE 'source .*lib/env\.sh' "$ROOT/cli/lib/nftban/$f" 2>/dev/null || true)
  [[ "$n" -le 1 ]] && ok "$(basename "$f"): env.sh source sites = $n (<=1, no new bootstrap)" \
                   || bad "$(basename "$f"): env.sh source sites = $n — a new bootstrap path was introduced"
done

echo "=== 5. overlay authority is the single one in env.sh ==="
for f in helpers/suricata_effective_config.sh cron/maintenance.sh; do
  grep -q 'nftban_config_apply_final_operator_overlay' "$ROOT/cli/lib/nftban/$f" \
    && ok "$(basename "$f") invokes the final overlay authority" \
    || bad "$(basename "$f") has no final overlay"
  grep -q 'source .*nftban\.conf\.local' "$ROOT/cli/lib/nftban/$f" \
    && bad "$(basename "$f") sources nftban.conf.local directly — scattered authority" \
    || ok "$(basename "$f") does not scatter a direct nftban.conf.local source"
done
grep -q '^nftban_config_apply_final_operator_overlay()' "$ROOT/cli/lib/nftban/lib/env.sh" \
  && ok "single overlay authority is defined in env.sh" || bad "overlay authority missing"

echo
printf 'config-overlay-maintenance-family: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
