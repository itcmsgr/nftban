#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.222.0 — log-retention generator wiring + RPM/DEB parity guard (R2/R3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logretention_wiring_gateb_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Static guard proving the v1.222.0 log-retention generator is wired symmetrically into the package lifecycle and that RPM no longer freezes the generated policy. Asserts: RPM %post and DEB postinst both invoke `nftban-core logretention generate install`; the maintenance service regenerates periodically (`generate timer`); /etc/logrotate.d/nftban is DERIVED STATE — %ghost on RPM (not %config(noreplace), not a plain tracked file) and not shipped in the DEB payload, so neither rpm -V nor dpkg --verify report it; both scriptlets fail-safe by copying the shipped template baseline; and the maintenance service can write /etc/logrotate.d. Deterministic render (proven by the Go TestDeterministicByteEquivalence) makes the DEB and RPM effective policy equivalent for identical inputs."
# meta:input="packaging/build_nftban.sh, packaging/deb/postinst, cron/maintenance.sh, systemd/nftban-maintenance.service"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="packaging/build_nftban.sh,packaging/deb/postinst,cli/lib/nftban/cron/maintenance.sh,install/systemd/nftban-maintenance.service"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-maintenance.service"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1${2:+ — $2}"; }

BUILD="$REPO_ROOT/packaging/build_nftban.sh"
DEBPI="$REPO_ROOT/packaging/deb/postinst"
MAINT="$REPO_ROOT/cli/lib/nftban/cron/maintenance.sh"
SVC="$REPO_ROOT/install/systemd/nftban-maintenance.service"

echo "== R2: generator wired symmetrically into the package lifecycle =="
grep -q "logretention generate install" "$BUILD" && ok "RPM %post invokes 'logretention generate install'" || no "RPM %post missing generate"
grep -q "logretention generate install" "$DEBPI" && ok "DEB postinst invokes 'logretention generate install'" || no "DEB postinst missing generate"
grep -q "logretention generate timer" "$MAINT" && ok "maintenance regenerates periodically ('generate timer')" || no "maintenance missing regeneration"

echo "== R3: RPM no longer freezes the generated policy; DEB/RPM parity of ownership =="
if grep -Eq '%config\(noreplace\)[[:space:]]+/etc/logrotate\.d/nftban($|[[:space:]])' "$BUILD"; then
    no "RPM STILL freezes /etc/logrotate.d/nftban with %config(noreplace)"
else
    ok "RPM does NOT freeze the generated logrotate policy (no %config(noreplace))"
fi
# Z2: the generated policy is now DERIVED STATE — declared %ghost (RPM owns the
# path for cleanup, records no digest, `rpm -V` never flags it), not a tracked
# payload file. A plain (tracked) %files entry would re-introduce verify noise.
grep -Eq '^%ghost[[:space:]].*/etc/logrotate\.d/nftban[[:space:]]*$' "$BUILD" && ok "RPM declares /etc/logrotate.d/nftban as %ghost (derived state, no rpm -V noise)" || no "RPM %ghost entry for the generated policy missing"
grep -Eq '^/etc/logrotate\.d/nftban[[:space:]]*$' "$BUILD" && no "RPM %files still has a PLAIN tracked /etc/logrotate.d/nftban entry (verify noise)" || ok "RPM %files has no plain tracked entry for the generated policy"

echo "== maintenance service can write the generated policy =="
grep -E "^ReadWritePaths=" "$SVC" | grep -q "/etc/logrotate.d" && ok "nftban-maintenance.service ReadWritePaths includes /etc/logrotate.d" || no "maintenance service cannot write /etc/logrotate.d"

echo "== generation is fail-safe + non-fatal, and runs BEFORE installer validate (DELTA-L1) =="
# DELTA-L1: both scriptlets define _nftban_generate_logretention (generate +
# template fallback + structured error) and CALL it before the nftban-installer
# invocation, so the logretention_policy_ready assertion gates the verdict.
for _f in "$BUILD" "$DEBPI"; do
    _n=$(basename "$_f")
    grep -q '_nftban_generate_logretention' "$_f" && grep -q 'logretention generate install' "$_f" \
        && ok "$_n defines the generation function + calls generate install" \
        || no "$_n missing _nftban_generate_logretention / generate install"
    grep -q 'LOG_RETENTION_POLICY_UNAVAILABLE' "$_f" \
        && ok "$_n emits a structured durable error when generation AND fallback fail" \
        || no "$_n missing structured LOG_RETENTION_POLICY_UNAVAILABLE error"
done
# generation must PRECEDE the installer invocation so the readiness assertion sees it.
_gen_line=$(grep -n '_nftban_generate_logretention || true' "$DEBPI" | head -1 | cut -d: -f1)
_inst_line=$(grep -n 'if \[ -x "\$NFTBAN_INSTALLER" \]' "$DEBPI" | head -1 | cut -d: -f1)
if [ -n "$_gen_line" ] && [ -n "$_inst_line" ] && [ "$_gen_line" -lt "$_inst_line" ]; then
    ok "DEB: generation runs BEFORE the installer invocation (readiness gate sees the policy)"
else
    no "DEB: generation must precede the installer (gen=$_gen_line inst=$_inst_line)"
fi

echo
echo "======================================================================"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
