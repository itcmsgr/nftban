#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.201.2 — recovery legacy reconcile (schema truth + nftban-apply wiring)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="recovery_legacy_reconcile_v12012_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-24"
# meta:description="RECOVERY_LEGACY_RECONCILE: the 11 dead recovery keys are deprecated in BOTH config-schema.json copies; the 3 live commit-confirm knobs stay accurate (config_file=conf.d/recovery.conf, not deprecated); shipped recovery.conf carries only the 3; nftban-apply sources recovery.conf + routes .local through _source_local + captures env for highest precedence; the rebuild_recovery.json marker is untouched."
# meta:input="config-schema.json (x2), etc/nftban/conf.d/recovery.conf, cli/sbin/nftban-apply"
# meta:output="PASS/FAIL per assertion; nonzero on any FAIL"
# meta:depends="bash,jq,grep"
# meta:inventory.files="etc/nftban/conf.d/recovery.conf,cli/sbin/nftban-apply"
# meta:inventory.binaries="jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files="conf.d/recovery.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SCHEMA_A="$REPO_ROOT/cli/lib/nftban/data/config-schema.json"
SCHEMA_B="$REPO_ROOT/install/config/schema/config-schema.json"
RECOV="$REPO_ROOT/etc/nftban/conf.d/recovery.conf"
APPLY="$REPO_ROOT/cli/sbin/nftban-apply"
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS: $1"; }
no(){ F=$((F+1)); echo "  FAIL: $1"; }

DEAD="NFTBAN_BACKUP_GENERATIONS NFTBAN_BACKUP_RULES NFTBAN_BASELINE_RULES NFTBAN_EMERGENCY_RESET_ENABLED NFTBAN_REBOOT_AUTO_APPLY NFTBAN_RECOVERY_ENABLED NFTBAN_RESET_ON_BOOT NFTBAN_ROLLBACK_ALERT NFTBAN_ROLLBACK_ALERT_EMAIL NFTBAN_ROLLBACK_CHECK_INTERVAL NFTBAN_ROLLBACK_FLAG"
LIVE="NFTBAN_REBOOT_GRACE_PERIOD NFTBAN_SSH_TEST_BEFORE_APPLY NFTBAN_SSH_TEST_PORT"

echo "== 11 dead keys deprecated in BOTH schema copies =="
for f in "$SCHEMA_A" "$SCHEMA_B"; do
    miss=""
    for k in $DEAD; do
        dep=$(jq -r --arg k "$k" '.properties[$k].deprecated // false' "$f" 2>/dev/null)
        inmap=$(jq -r --arg k "$k" '.deprecated | has($k)' "$f" 2>/dev/null)
        { [ "$dep" = "true" ] && [ "$inmap" = "true" ]; } || miss="$miss $k"
    done
    [ -z "$miss" ] && ok "all 11 dead keys deprecated (prop + map) in $(basename "$(dirname "$f")")/$(basename "$f")" || no "not deprecated in $f:$miss"
done

echo "== 3 live keys accurate (NOT deprecated, config_file=conf.d/recovery.conf) =="
for k in $LIVE; do
    dep=$(jq -r --arg k "$k" '.properties[$k].deprecated // false' "$SCHEMA_A")
    cf=$(jq -r --arg k "$k" '.properties[$k].config_file // ""' "$SCHEMA_A")
    { [ "$dep" != "true" ] && [ "$cf" = "conf.d/recovery.conf" ]; } && ok "$k live + config_file=conf.d/recovery.conf" || no "$k wrong (dep=$dep cf=$cf)"
done

echo "== shipped recovery.conf: exactly the 3 live keys, no dead keys =="
[ -f "$RECOV" ] && ok "etc/nftban/conf.d/recovery.conf present (shipped)" || no "recovery.conf not shipped"
nkeys=$(grep -cE '^NFTBAN_[A-Z_]+=' "$RECOV" 2>/dev/null || echo 0)
[ "$nkeys" -eq 3 ] && ok "recovery.conf has exactly 3 keys" || no "recovery.conf has $nkeys keys (want 3)"
for k in $LIVE; do grep -qE "^${k}=" "$RECOV" && ok "recovery.conf ships $k" || no "recovery.conf missing $k"; done
for k in $DEAD; do grep -qE "^${k}=" "$RECOV" && no "recovery.conf still ships dead key $k" || true; done
ok "no dead keys live-assigned in shipped recovery.conf"

echo "== nftban-apply wiring + precedence =="
grep -q 'source "$RECOVERY_CONF"' "$APPLY" && ok "nftban-apply sources shipped recovery.conf" || no "nftban-apply does not source recovery.conf"
grep -q '_source_local "$RECOVERY_CONF_LOCAL"' "$APPLY" && ok "nftban-apply routes recovery.conf.local through _source_local" || no ".local not via _source_local"
grep -q '_env_grace=' "$APPLY" && grep -q '_env_ssh_port=' "$APPLY" && ok "nftban-apply captures env for highest precedence" || no "env-capture precedence missing"
grep -qE 'GRACE="\$\{_env_grace:-' "$APPLY" && ok "effective value prefers env (explicit precedence)" || no "env precedence not applied to GRACE"
# legacy /etc/default/nftban compat retained
grep -q 'CONFIG="/etc/default/nftban"' "$APPLY" && ok "legacy /etc/default/nftban compat retained" || no "legacy compat dropped"

echo "== rebuild_recovery.json marker untouched (separate mechanism) =="
grep -q 'REBUILD_RECOVERY_MARKER' "$REPO_ROOT/cli/lib/nftban/core/nftban_rebuild_classify.sh" && ok "rebuild_recovery marker contract present + untouched" || no "rebuild_recovery marker missing"

echo "-----------------------------------------------"
echo "recovery legacy reconcile tests: $P passed, $F failed"
[ "$F" -eq 0 ]
