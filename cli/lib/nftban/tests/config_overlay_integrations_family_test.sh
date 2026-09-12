#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config-overlay-integrations-family"
# meta:type="test"
# meta:description="v1.230.0 PR-5c-B1. Locks the shell config precedence contract BASE < MODULE_LOCAL < CENTRAL_OPERATOR_OVERRIDE for the metrics/zabbix/connectors integration family (health integration checks, the unified exporter, the pipeline validation library), by observing POST-LOAD EFFECTIVE VALUES produced by the real subjects — never by inspecting source text. Two of the five transactions load at FILE SCOPE; the unified exporter loads FOUR subjects with no consumption between them, so it is ONE transaction taking ONE overlay, and that topology is asserted behaviourally (a key from each subject resolves to the central override) as well as by call count. Also locks the bootstrap invariant: the repair must not increase the number of env.sh source sites, because env.sh participates in configuration initialisation and a fresh source solely to reach the helper would itself change load order — the exact defect class this increment removes."
# meta:ta.id="config_overlay_integrations_family_test"
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
# meta:inventory.files="cli/lib/nftban/lib/env.sh,cli/lib/nftban/core/nftban_health_checks_integrations.sh,cli/lib/nftban/exporters/nftban_unified_exporter.sh,cli/lib/nftban/lib/nftban_pipeline_validation.sh"
# meta:inventory.binaries="bash,grep,git"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR,NFTBAN_CACHE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
# ⛔ "${SB:?}" not "$SB" on every destructive path: an empty SB would make this `rm -rf /etc`.
#    A destructive path must fail to expand rather than widen (SC2115).
SB="$(mktemp -d)"; trap 'rm -rf "${SB:?}"' EXIT INT TERM

INTEG="$ROOT/cli/lib/nftban/core/nftban_health_checks_integrations.sh"
EXPORTER="$ROOT/cli/lib/nftban/exporters/nftban_unified_exporter.sh"
PIPELINE="$ROOT/cli/lib/nftban/lib/nftban_pipeline_validation.sh"

# Values are deliberately NON-EMPTY: `: "${K:=default}"` treats empty as unset, and
# empty-value semantics are separate debt (CONFIG-LOCAL-EMPTY-VALUE-SEMANTICS).
_mk(){ rm -rf "${SB:?}/etc"; mkdir -p "$SB/etc/conf.d"; printf '# base\n' > "$SB/etc/nftban.conf"; }

# ---- observation harness 1: FILE-SCOPE subject that is a plain library --------------
_eff_file(){ # $1=subject file  $2=key
  NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" bash -c "
    cd '$ROOT'
    source cli/lib/nftban/lib/env.sh >/dev/null 2>&1 || true
    source '$1' >/dev/null 2>&1 || true
    printf '%s' \"\${$2:-<unset>}\"" 2>/dev/null
}

# ---- observation harness 2: transaction that lives inside a health-check function ----
# The health module is normally loaded by nftban_health.sh, which owns the HEALTH_* codes
# and the result arrays; stub exactly those so the real function body runs unmodified.
_eff_fn(){ # $1=subject file  $2=function  $3=key
  NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" bash -c "
    cd '$ROOT'
    HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_ERROR=2; HEALTH_CRITICAL=3
    HEALTH_NOT_INSTALLED=4; HEALTH_DISABLED=5
    declare -gA NFTBAN_HEALTH_RESULTS=() NFTBAN_HEALTH_ISSUES=()
    source cli/lib/nftban/lib/env.sh >/dev/null 2>&1 || true
    source '$1' >/dev/null 2>&1 || true
    $2 >/dev/null 2>&1 || true
    printf '%s' \"\${$3:-<unset>}\"" 2>/dev/null
}

# ---- observation harness 3: the unified exporter ------------------------------------
# The exporter ends in `main "$@"`, so it cannot simply be sourced and inspected. A DEBUG
# trap (functrace) stops the process at the exact instant BEFORE main is entered — i.e.
# immediately after the whole file-scope config load transaction — and records the EFFECTIVE
# value then. This observes the real file executing; it never reads its source text.
cat > "$SB/probe.sh" <<'PROBE'
cd "$NFTBAN_PROBE_ROOT" || exit 1
set -T
trap 'if [[ "$BASH_COMMAND" == main* ]]; then printf "%s\n" "${!NFTBAN_PROBE_KEY:-<unset>}" > "$NFTBAN_PROBE_OUT"; exit 0; fi' DEBUG
# shellcheck source=/dev/null
source "$NFTBAN_PROBE_SUBJECT"
PROBE
_eff_exporter(){ # $1=subject file  $2=key
  rm -f "${SB:?}/probe.out"
  NFTBAN_PROBE_ROOT="$ROOT" NFTBAN_PROBE_SUBJECT="$1" NFTBAN_PROBE_KEY="$2" \
  NFTBAN_PROBE_OUT="$SB/probe.out" \
  NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban" \
  NFTBAN_CACHE_DIR="$SB/cache" NFTBAN_RUN_DIR="$SB/run" NFTBAN_LOG_DIR="$SB/log" \
    bash "$SB/probe.sh" >/dev/null 2>&1
  cat "$SB/probe.out" 2>/dev/null || printf '<no-observation>'
}

echo "=== 1. pipeline_validation FILE-SCOPE txn (subject: conf.d/metrics.conf) ==="
_mk; printf 'NFTBAN_METRICS_PROM_FILE="/base.prom"\n'    > "$SB/etc/conf.d/metrics.conf"
     printf 'NFTBAN_METRICS_PROM_FILE="/local.prom"\n'   > "$SB/etc/conf.d/metrics.conf.local"
     printf 'NFTBAN_METRICS_PROM_FILE="/central.prom"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_eff_file "$PIPELINE" NFTBAN_METRICS_PROM_FILE)" == "/central.prom" ]] \
  && ok "pipeline: central operator override WINS" || bad "pipeline: central override did not win"
_mk; printf 'NFTBAN_METRICS_PROM_FILE="/base.prom"\n'  > "$SB/etc/conf.d/metrics.conf"
     printf 'NFTBAN_METRICS_PROM_FILE="/local.prom"\n' > "$SB/etc/conf.d/metrics.conf.local"
[[ "$(_eff_file "$PIPELINE" NFTBAN_METRICS_PROM_FILE)" == "/local.prom" ]] \
  && ok "pipeline: module-local wins when central absent (overlay does not clobber)" || bad "pipeline: module-local lost"
_mk; printf 'NFTBAN_METRICS_PROM_FILE="/base.prom"\n' > "$SB/etc/conf.d/metrics.conf"
[[ "$(_eff_file "$PIPELINE" NFTBAN_METRICS_PROM_FILE)" == "/base.prom" ]] \
  && ok "pipeline: base survives with no overrides" || bad "pipeline: base value lost"

echo "=== 2. health_check_zabbix txn (subject: conf.d/zabbix.conf) ==="
_mk; printf 'NFTBAN_ZABBIX_SERVER="base.example.net"\n'    > "$SB/etc/conf.d/zabbix.conf"
     printf 'NFTBAN_ZABBIX_SERVER="local.example.net"\n'   > "$SB/etc/conf.d/zabbix.conf.local"
     printf 'NFTBAN_ZABBIX_SERVER="central.example.net"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_eff_fn "$INTEG" nftban_health_check_zabbix NFTBAN_ZABBIX_SERVER)" == "central.example.net" ]] \
  && ok "zabbix: central operator override WINS" || bad "zabbix: central override did not win"
_mk; printf 'NFTBAN_ZABBIX_SERVER="base.example.net"\n'  > "$SB/etc/conf.d/zabbix.conf"
     printf 'NFTBAN_ZABBIX_SERVER="local.example.net"\n' > "$SB/etc/conf.d/zabbix.conf.local"
[[ "$(_eff_fn "$INTEG" nftban_health_check_zabbix NFTBAN_ZABBIX_SERVER)" == "local.example.net" ]] \
  && ok "zabbix: module-local wins when central absent" || bad "zabbix: module-local lost"
_mk; printf 'NFTBAN_ZABBIX_SERVER="base.example.net"\n' > "$SB/etc/conf.d/zabbix.conf"
[[ "$(_eff_fn "$INTEG" nftban_health_check_zabbix NFTBAN_ZABBIX_SERVER)" == "base.example.net" ]] \
  && ok "zabbix: base survives with no overrides" || bad "zabbix: base value lost"

echo "=== 3. health_check_connectors txn (subject: conf.d/connectors.conf) ==="
_mk; printf 'NFTBAN_CONNECTORS_INTERVAL="60"\n'  > "$SB/etc/conf.d/connectors.conf"
     printf 'NFTBAN_CONNECTORS_INTERVAL="900"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_eff_fn "$INTEG" nftban_health_check_connectors NFTBAN_CONNECTORS_INTERVAL)" == "900" ]] \
  && ok "connectors: central operator override WINS" || bad "connectors: central override did not win"

echo "=== 4. health_check_metrics txn (subject: conf.d/metrics.conf) ==="
_mk; printf 'NFTBAN_METRICS_ENABLED="true"\nNFTBAN_EXPORT_PROMETHEUS="false"\n' > "$SB/etc/conf.d/metrics.conf"
     printf 'NFTBAN_EXPORT_PROMETHEUS="true"\n' > "$SB/etc/nftban.conf.local"
[[ "$(_eff_fn "$INTEG" nftban_health_check_metrics NFTBAN_EXPORT_PROMETHEUS)" == "true" ]] \
  && ok "metrics: central operator override WINS" || bad "metrics: central override did not win"

echo "=== 5. unified exporter: FOUR subjects, ONE transaction, ONE overlay ==="
_mk; printf 'NFTBAN_COLLECT_INTERVAL="60"\n'   > "$SB/etc/conf.d/metrics.conf"
     printf 'NFTBAN_ZABBIX_PORT="10051"\n'     > "$SB/etc/conf.d/zabbix.conf"
     printf 'NFTBAN_EXPORT_CONNECTORS="false"\n' > "$SB/etc/conf.d/connectors.conf"
     printf 'NFTBAN_COLLECT_INTERVAL="300"\nNFTBAN_ZABBIX_PORT="20051"\nNFTBAN_EXPORT_CONNECTORS="true"\n' \
       > "$SB/etc/nftban.conf.local"
[[ "$(_eff_exporter "$EXPORTER" NFTBAN_COLLECT_INTERVAL)" == "300" ]] \
  && ok "exporter: central wins for a metrics.conf key" || bad "exporter: metrics.conf key lost to base"
[[ "$(_eff_exporter "$EXPORTER" NFTBAN_ZABBIX_PORT)" == "20051" ]] \
  && ok "exporter: central wins for a zabbix.conf key" || bad "exporter: zabbix.conf key lost to base"
[[ "$(_eff_exporter "$EXPORTER" NFTBAN_EXPORT_CONNECTORS)" == "true" ]] \
  && ok "exporter: central wins for a connectors.conf key" || bad "exporter: connectors.conf key lost to base"
n=$(grep -c '&& nftban_config_apply_final_operator_overlay' "$EXPORTER")
[[ "$n" -eq 1 ]] && ok "exporter: ONE overlay for the whole multi-subject transaction (found $n)" \
                 || bad "exporter: expected 1 overlay, found $n — the transaction was split"

echo "=== 6. FALSIFICATION — the pre-fix subject resolves BASE ==="
# The negative control must be an IMMUTABLE subject. Preferred: the branch base commit.
# Fallback (shallow CI checkout, where that object is absent): synthesise the pre-fix subject
# by DECLARED INVERSION — strip exactly the overlay invocation this increment added.
BASE_REF="9ab3bade"
_prefix(){ # $1=repo-relative path  $2=output path
  if git -C "$ROOT" cat-file -e "${BASE_REF}:$1" 2>/dev/null; then
    git -C "$ROOT" show "${BASE_REF}:$1" > "$2"; printf 'base-commit'
  else
    grep -v 'nftban_config_apply_final_operator_overlay' "$ROOT/$1" > "$2"; printf 'declared-inversion'
  fi
}
_mk; printf 'NFTBAN_METRICS_PROM_FILE="/base.prom"\n'    > "$SB/etc/conf.d/metrics.conf"
     printf 'NFTBAN_METRICS_PROM_FILE="/central.prom"\n' > "$SB/etc/nftban.conf.local"
mode=$(_prefix cli/lib/nftban/lib/nftban_pipeline_validation.sh "$SB/prefix_pipeline.sh")
[[ "$(_eff_file "$SB/prefix_pipeline.sh" NFTBAN_METRICS_PROM_FILE)" == "/base.prom" ]] \
  && ok "pipeline pre-fix ($mode) resolves BASE — the defect reproduces" \
  || bad "pipeline pre-fix ($mode) did not reproduce the defect — the control proves nothing"
[[ "$(_eff_file "$PIPELINE" NFTBAN_METRICS_PROM_FILE)" == "/central.prom" ]] \
  && ok "pipeline repaired resolves CENTRAL on the identical fixture" || bad "pipeline repaired did not resolve CENTRAL"

# The exporter resolves its sibling modules relative to its own path, so the pre-fix subject
# is placed in a COPY of the exporters directory (copy, never move).
_mk; printf 'NFTBAN_EXPORT_CONNECTORS="false"\n' > "$SB/etc/conf.d/connectors.conf"
     printf 'NFTBAN_EXPORT_CONNECTORS="true"\n'  > "$SB/etc/nftban.conf.local"
rm -rf "${SB:?}/pre"; mkdir -p "$SB/pre"
cp -a "$ROOT/cli/lib/nftban/exporters" "$SB/pre/exporters"
mode=$(_prefix cli/lib/nftban/exporters/nftban_unified_exporter.sh "$SB/pre/exporters/nftban_unified_exporter.sh")
[[ "$(_eff_exporter "$SB/pre/exporters/nftban_unified_exporter.sh" NFTBAN_EXPORT_CONNECTORS)" == "false" ]] \
  && ok "exporter pre-fix ($mode) resolves BASE — the defect reproduces" \
  || bad "exporter pre-fix ($mode) did not reproduce the defect — the control proves nothing"
[[ "$(_eff_exporter "$EXPORTER" NFTBAN_EXPORT_CONNECTORS)" == "true" ]] \
  && ok "exporter repaired resolves CENTRAL on the identical fixture" || bad "exporter repaired did not resolve CENTRAL"

echo "=== 7. BOOTSTRAP INVARIANT — the repair must add no env.sh source site ==="
# A fresh `source env.sh` to reach the helper would change initialisation order while still
# passing every precedence check above. Assert the structure, not only the behaviour.
for f in core/nftban_health_checks_integrations.sh exporters/nftban_unified_exporter.sh lib/nftban_pipeline_validation.sh; do
  n=$(grep -cE 'source .*lib/env\.sh' "$ROOT/cli/lib/nftban/$f" 2>/dev/null || true)
  [[ "$n" -le 1 ]] && ok "$(basename "$f"): env.sh source sites = $n (<=1, no new bootstrap)" \
                   || bad "$(basename "$f"): env.sh source sites = $n — a new bootstrap path was introduced"
done

echo "=== 8. transaction count per consumer ==="
n=$(grep -c '&& nftban_config_apply_final_operator_overlay' "$INTEG")
[[ "$n" -eq 3 ]] && ok "integrations: one overlay per health-check transaction (metrics, zabbix, connectors) = $n" \
               || bad "integrations: expected 3 overlays, found $n"
n=$(grep -c '&& nftban_config_apply_final_operator_overlay' "$PIPELINE")
[[ "$n" -eq 1 ]] && ok "pipeline_validation: single file-scope transaction takes one overlay" \
               || bad "pipeline_validation: expected 1 overlay, found $n"
grep -q '^nftban_config_apply_final_operator_overlay()' "$ROOT/cli/lib/nftban/lib/env.sh" \
  && ok "single overlay authority is defined in env.sh" || bad "overlay authority missing"

echo
printf 'config-overlay-integrations-family: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
