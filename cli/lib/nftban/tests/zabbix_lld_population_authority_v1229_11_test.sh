#!/usr/bin/env bash
# =============================================================================
# NFTBan - Zabbix LLD reads the canonical enable authority (v1.229.11)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="zabbix_lld_population_authority_v1229_11_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="metrics"
# meta:ta.id="zabbix_lld_population_authority_v1229_11_test"
# meta:ta.owner="metrics"
# meta:ta.module="zabbix-lld-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.229.11 lane 3. nftban zabbix discover modules inferred enablement from \${NFTBAN_CONFIG_DIR}/modules/<m>.conf — a path that does not exist, since real config lives under conf.d/. Every module was therefore reported ENABLED=0 on every host: measured on lab2 where ddos, portscan, login and geoban were all enabled yet the LLD reported 0 for each. A PATH THAT NEVER EXISTS IS A CONSTANT, NOT A CHECK. The literal module list was also a second, non-canonical population authority. Locks: enablement is derived from nftban_module_effective_enabled (the same authority the CLI and health surfaces use); the dead modules/<m>.conf probe cannot return; the function's RETURN-STATUS contract is honoured rather than its stdout (it does not echo — capturing stdout and comparing to \"true\" is always false, which is the original bug and must not be reintroduced by the fix); and an unresolvable module reports UNKNOWN rather than 0, because UNRESOLVED != DISABLED."
# meta:inventory.files="cli/lib/nftban/cli/cmd_zabbix.sh,cli/lib/nftban/lib/module_authority.sh"
# meta:inventory.binaries="bash,grep"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$SD/../cli/cmd_zabbix.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# MENTION != CODE — a rule about behaviour must never be satisfied by a comment.
body="$(grep -vE '^[[:space:]]*#' "$F" || true)"
blk="$(awk '/^        modules\)/,/^        interfaces\)/' "$F" | grep -vE '^[[:space:]]*#' || true)"

echo "=== Zabbix LLD reads the canonical enable authority (v1.229.11) ==="
echo ""

# --- P1 the dead probe is gone ------------------------------------------------
if grep -q 'modules/\${module}\.conf' <<<"$body"; then
    no "P1 the non-existent modules/<m>.conf probe still decides enablement"
else
    ok "P1 the dead modules/<m>.conf probe is gone"
fi

# --- P2 the canonical authority is consulted ----------------------------------
grep -q 'nftban_module_effective_enabled' <<<"$blk" \
  && ok "P2 LLD consults nftban_module_effective_enabled" \
  || no "P2 LLD does not consult the canonical authority"

# --- P3 RETURN-STATUS contract, not stdout ------------------------------------
# The function's last statement is [[ "$val" == "true" ]]; it returns a status and
# does NOT echo. Capturing stdout yields "" and comparing to "true" is always
# false — the original defect. The fix must not reintroduce it.
if grep -qE '_eff="\$\(nftban_module_effective_enabled|\$\(nftban_module_effective_enabled[^)]*\)"[[:space:]]*==' <<<"$blk"; then
    no "P3 the authority's STDOUT is being compared — it returns a STATUS and does not echo"
else
    ok "P3 the authority is consumed by RETURN STATUS, not stdout"
fi
grep -qE 'nftban_module_effective_enabled[^|]*\|\| _rc=' <<<"$blk" \
  && ok "P3b the return status is captured explicitly" \
  || no "P3b return status not captured"

# --- P4 UNRESOLVED != DISABLED -------------------------------------------------
grep -qE '\*\)[[:space:]]*enabled=""' <<<"$blk" \
  && ok "P4 an unresolvable module reports UNKNOWN, not 0" \
  || no "P4 unresolvable module collapses to 0 — a false claim of 'disabled'"

# --- P5 the discovery population is preserved ---------------------------------
# The literal list stays as the DECLARED discovery population — a monitoring feed
# must not silently gain or lose subjects. It just no longer decides TRUTH.
for m in login portscan ddos feeds geoban suricata; do
    grep -q "$m" <<<"$blk" || no "P5 discovery population lost '$m'"
done
grep -qE 'for module in login portscan ddos feeds geoban suricata' <<<"$blk" \
  && ok "P5 all six discovery subjects retained (feed declares subjects, not their truth)" \
  || no "P5 discovery population changed"

# --- P6 modules outside the authority's table get an explicit key -------------
grep -qE 'login\)[[:space:]]*_mkey="LOGIN_ENABLED"' <<<"$blk" \
  && ok "P6 login passes its key explicitly (not in _nftban_module_enable_var)" \
  || no "P6 login has no key — would resolve UNKNOWN"
grep -qE 'suricata\)[[:space:]]*_mkey="SURICATA_ENABLED"' <<<"$blk" \
  && ok "P6b suricata passes its key explicitly" || no "P6b suricata has no key"

# --- N1 NEGATIVE CONTROL -------------------------------------------------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' 'if [[ -f "${NFTBAN_CONFIG_DIR}/modules/${module}.conf" ]]; then' > "$TMP/pre.sh"
if grep -q 'modules/\${module}\.conf' "$TMP/pre.sh"; then
    ok "N1 negative control: the guard detects the pre-fix probe (P1 is meaningful)"
else
    no "N1 negative control failed — the guard cannot see the defect"
fi

# --- N2 a comment must not satisfy P1 -----------------------------------------
printf '%s\n' '# it used to read modules/${module}.conf which never exists' > "$TMP/c.sh"
cb="$(grep -vE '^[[:space:]]*#' "$TMP/c.sh" || true)"
if grep -q 'modules/\${module}\.conf' <<<"$cb"; then
    no "N2 a COMMENT satisfied the check — MENTION != CODE not enforced"
else
    ok "N2 a commented mention does not trip the guard (MENTION != CODE)"
fi

# --- N3 no second resolver was invented ---------------------------------------
if grep -qE '_ENABLED=|grep .*_ENABLED' <<<"$blk"; then
    no "N3 the LLD reads config keys directly — a SECOND authority was introduced"
else
    ok "N3 no direct config parsing in the LLD (one authority for state)"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "zabbix LLD population authority PASSED"
