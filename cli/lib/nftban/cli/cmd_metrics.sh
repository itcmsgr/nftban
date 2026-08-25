#!/usr/bin/env bash
# =============================================================================
# NFTBan - Metrics Management (Prometheus)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Enable/disable Prometheus metrics collection
#
# meta:name="cmd_metrics"
# meta:type="cli"
# meta:header="Metrics Management"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Manage Prometheus metrics collection"
# meta:inventory.files=""
# meta:inventory.binaries="prometheus,node_exporter"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="prometheus.service,node_exporter.service"
# meta:inventory.network="127.0.0.1:9090,127.0.0.1:9100"
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-28"
# meta:updated_date="2026-01-25"
# =============================================================================

set -Eeuo pipefail

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_DATA_DIR:=/var/lib/nftban}"

# Load main config (sets readonly paths)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
fi

# Metrics endpoint defaults (use config or fallback)
: "${NFTBAN_METRICS_PROMETHEUS_ADDR:=localhost:9090}"
: "${NFTBAN_METRICS_NODE_EXPORTER_ADDR:=localhost:9100}"

# Load helper functions
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro.sh" || return 1
fi

# Load shared metrics library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics.sh" || return 1
fi

# Load pipeline validation library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" || return 1
fi

# Load Pro library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" || return 1
fi

# Load metrics helpers (config helpers, validation)
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_metrics_helpers.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_metrics_helpers.sh" || return 1
fi

# ==============================================================================
# Command: nftban metrics enable [options]
# ==============================================================================
# Options:
#   --pro                                 Enable NFTBan Pro submission
#   --remote                              Enable remote submission to user's backend
#   --url URL                             Remote write URL (for --remote)
#   --token FILE                          Token file path (optional)
#   --labels KEY=VAL,KEY=VAL              External labels (optional)
#   --force|-f                            Force enable even if already running
# ==============================================================================
# ==============================================================================
# Remote-submission wrappers (v1.229.10)
# ==============================================================================
# `nftban metrics enable --pro` and `--remote` dispatched to
# _metrics_enable_pro / _metrics_enable_remote_user, which were CALLED but never
# DEFINED anywhere in the tree — both advertised flags exited 127
# ("command not found"). The shipping implementation itself was never missing:
# setup/install_vmagent.sh already provides install / config-pro / config-user /
# start / validate. Only the wrapper was absent.
#
#   AN ADVERTISED FLAG THAT DISPATCHES TO NOTHING IS A BROKEN CONTRACT,
#   NOT AN UNIMPLEMENTED FEATURE.
#
# These wrappers GATE BEFORE THEY MUTATE. A shipper pointed at a target that
# serves nothing would report success and deliver no metrics — the fail-open
# shape this project rejects. Every precondition is proven, never assumed.
# ==============================================================================

# The address the vmagent config will actually scrape. Kept as one constant so
# the precondition subject IS the configured input (GUARD SUBJECT == GUARD INPUT).
# setup/install_vmagent.sh writes `targets: ['localhost:9100']` — the
# node_exporter textfile surface, which is this CLI's canonical local export
# (see nftban_metrics_status: "OpenMetrics format (node_exporter textfile)").
: "${NFTBAN_METRICS_SCRAPE_TARGET:=localhost:9100}"

_metrics_vmagent_script() {
    # Resolve the shipper installer. ENOENT != absence of the capability, so we
    # report the exact path we looked for instead of guessing an alternative.
    local script="${NFTBAN_LIB_DIR}/setup/install_vmagent.sh"
    if [[ ! -f "$script" ]]; then
        echo "ERROR: metrics shipper installer not found" >&2
        echo "  expected: $script" >&2
        echo "  This is an installation defect — reinstall the nftban-core package." >&2
        return 1
    fi
    printf '%s\n' "$script"
}

_metrics_scrape_target_serves() {
    # CAPABILITY, NOT PRESENCE: a running unit is not proof that the endpoint
    # serves metrics. We require an actual exposition response.
    local target="$1" body=""

    if ! command -v curl >/dev/null 2>&1; then
        # TOOL ABSENCE != EMPTY PASS. We cannot establish the fact, so we must
        # not claim it either way.
        echo "ERROR: curl is required to verify the scrape target and is not installed" >&2
        return 2
    fi

    body=$(curl -fsS --max-time 5 "http://${target}/metrics" 2>/dev/null) || return 1
    [[ -n "$body" ]] || return 1
    grep -qE '^[#a-zA-Z_]' <<<"$body" || return 1
    return 0
}

_metrics_require_scrape_target() {
    local target="$1" rc=0
    _metrics_scrape_target_serves "$target" || rc=$?
    case "$rc" in
        0) return 0 ;;
        2) return 1 ;;   # message already printed; do not restate a cause we did not establish
    esac

    echo "ERROR: the metrics scrape target is not serving metrics" >&2
    echo "  target: http://${target}/metrics" >&2
    echo "" >&2
    echo "  vmagent would be configured to scrape this address and would ship" >&2
    echo "  nothing. Refusing to configure a shipper over a dead target." >&2
    echo "" >&2
    echo "  Enable the local export surface first:" >&2
    echo "    nftban metrics enable" >&2
    echo "  Then re-run this command." >&2
    return 1
}

_metrics_run_vmagent() {
    # Single execution point for the installer, so every stage failure is
    # attributed to the stage that produced it.
    local script="$1" stage="$2"; shift 2
    if ! bash "$script" "$stage" "$@"; then
        echo "ERROR: metrics shipper stage failed: $stage" >&2
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# nftban metrics enable --pro
# ------------------------------------------------------------------------------
_metrics_enable_pro() {
    local script server_id="" token_file="${NFTBAN_PRO_TOKEN_FILE:-/etc/nftban/pro.token}"

    script=$(_metrics_vmagent_script) || return 1

    # ---- PRECONDITION: enrolment. Asserted BEFORE any capability work. --------
    if ! declare -F nftban_pro_get_server_id >/dev/null 2>&1; then
        echo "ERROR: the Pro library is not loaded (nftban_pro_get_server_id undefined)" >&2
        echo "  expected: ${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" >&2
        return 1
    fi

    # READ-ONLY accessor by design: enabling metrics must not mint an identity.
    server_id=$(nftban_pro_get_server_id)
    if [[ -z "$server_id" ]]; then
        echo "ERROR: this host is not enrolled with NFTBan Pro" >&2
        echo "  no server_id at ${NFTBAN_PRO_SERVER_ID_FILE:-/etc/nftban/server_id}" >&2
        echo "" >&2
        echo "  Enrol first:  nftban pro enroll" >&2
        return 1
    fi

    if [[ ! -s "$token_file" ]]; then
        echo "ERROR: no NFTBan Pro token present" >&2
        echo "  expected a non-empty file at: $token_file" >&2
        echo "" >&2
        echo "  Enrol first:  nftban pro enroll" >&2
        return 1
    fi

    _metrics_require_scrape_target "$NFTBAN_METRICS_SCRAPE_TARGET" || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enabling NFTBan Pro metrics submission"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Server ID:     $server_id"
    echo "  Scrape target: http://${NFTBAN_METRICS_SCRAPE_TARGET}/metrics"
    echo "  Destination:   ${NFTBAN_PRO_REMOTE_WRITE_URL:-https://pro.nftban.com/api/v1/write}"
    echo ""

    echo "Step 1/4: Installing the metrics shipper..."
    _metrics_run_vmagent "$script" install || return 1

    echo "Step 2/4: Writing the Pro submission config..."
    _metrics_run_vmagent "$script" config-pro "$server_id" || return 1

    echo "Step 3/4: Starting the shipper..."
    _metrics_run_vmagent "$script" start || return 1

    echo "Step 4/4: Validating..."
    if ! _metrics_run_vmagent "$script" validate; then
        echo "" >&2
        echo "  The shipper was configured but did not validate." >&2
        echo "  Metrics submission is NOT confirmed. Inspect: nftban metrics status" >&2
        return 1
    fi

    echo ""
    echo "NFTBan Pro metrics submission enabled."
    echo "  Verify: nftban metrics status"
    echo ""
    return 0
}

# ------------------------------------------------------------------------------
# nftban metrics enable --remote --url URL [--token FILE] [--labels K=V,...]
# ------------------------------------------------------------------------------
_metrics_enable_remote_user() {
    local remote_url="$1" token_file="$2" external_labels="$3"
    local script

    script=$(_metrics_vmagent_script) || return 1

    if [[ -z "$remote_url" ]]; then
        echo "ERROR: --remote requires a remote-write URL" >&2
        echo "  usage: nftban metrics enable --remote --url <URL> [--token FILE] [--labels K=V,...]" >&2
        return 1
    fi

    case "$remote_url" in
        http://*|https://*) : ;;
        *)
            echo "ERROR: --url must be an http:// or https:// remote-write endpoint" >&2
            echo "  got: $remote_url" >&2
            return 1
            ;;
    esac

    # A token was NAMED, so it must exist. A named-but-absent token is an error,
    # never a silent downgrade to unauthenticated submission.
    if [[ -n "$token_file" && ! -s "$token_file" ]]; then
        echo "ERROR: token file named but not readable or empty: $token_file" >&2
        return 1
    fi

    _metrics_require_scrape_target "$NFTBAN_METRICS_SCRAPE_TARGET" || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enabling remote metrics submission"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Scrape target: http://${NFTBAN_METRICS_SCRAPE_TARGET}/metrics"
    echo "  Destination:   $remote_url"
    echo "  Token:         ${token_file:-(none)}"
    echo "  Labels:        ${external_labels:-(none)}"
    echo ""

    echo "Step 1/4: Installing the metrics shipper..."
    _metrics_run_vmagent "$script" install || return 1

    echo "Step 2/4: Writing the remote submission config..."
    _metrics_run_vmagent "$script" config-user "$remote_url" "$token_file" "$external_labels" || return 1

    echo "Step 3/4: Starting the shipper..."
    _metrics_run_vmagent "$script" start || return 1

    echo "Step 4/4: Validating..."
    if ! _metrics_run_vmagent "$script" validate; then
        echo "" >&2
        echo "  The shipper was configured but did not validate." >&2
        echo "  Metrics submission is NOT confirmed. Inspect: nftban metrics status" >&2
        return 1
    fi

    echo ""
    echo "Remote metrics submission enabled."
    echo "  Verify: nftban metrics status"
    echo ""
    return 0
}

nftban_metrics_enable() {
    local force=false
    local remote_mode=""        # "user" or "pro" or ""
    local remote_url=""
    local token_file=""
    local external_labels=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --remote)
                remote_mode="user"
                shift
                ;;
            --pro)
                remote_mode="pro"
                shift
                ;;
            --url)
                remote_url="$2"
                shift 2
                ;;
            --token)
                token_file="$2"
                shift 2
                ;;
            --token=*)
                token_file="${1#*=}"
                shift
                ;;
            --labels)
                external_labels="$2"
                shift 2
                ;;
            --labels=*)
                external_labels="${1#*=}"
                shift
                ;;
            --force|-f)
                force=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # ============================================================================
    # Remote: User's own backend (--remote)
    # ============================================================================
    if [[ "$remote_mode" == "user" ]]; then
        _metrics_enable_remote_user "$remote_url" "$token_file" "$external_labels"
        return $?
    fi

    # ============================================================================
    # Remote: NFTBan Pro (--pro)
    # ============================================================================
    if [[ "$remote_mode" == "pro" ]]; then
        _metrics_enable_pro
        return $?
    fi

    # ============================================================================
    # LOCAL MODE: Prometheus metrics
    # ============================================================================

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Enabling NFTBan Metrics Collection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already enabled
    if [[ "$force" != "true" ]] && \
       systemctl is-active prometheus &>/dev/null && \
       systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
        echo "Prometheus metrics already enabled"
        echo ""
        echo "Prometheus:  http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
        echo "Metrics:     http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
        echo ""
        return 0
    fi

    # Step 1: Check and install dependencies
    echo "Step 1/3: Checking Prometheus dependencies..."

    if ! nftban_metrics_check_deps; then
        echo "  Missing: ${NFTBAN_METRICS_MISSING[*]}"
        if ! nftban_metrics_install_deps; then
            return 1
        fi
    else
        echo "  All dependencies present"
    fi

    # Step 2: Start metrics stack
    echo ""
    echo "Step 2/3: Starting Prometheus stack..."

    if ! nftban_metrics_start_stack; then
        echo "  Failed to start Prometheus stack"
        return 1
    fi

    # v1.143 PR-A (FS3-MUTATION): capture _set_metrics_backend rc instead
    # of discarding it. Pre-v1.143 a failed config update (file permission,
    # disk full, atomic-write race) silently fell through to the
    # 'Prometheus Metrics Enabled Successfully!' marker AND function rc=0.
    # Same FS3 family. The Prometheus stack is already running (Step 2
    # succeeded); the failure here is config-side only, but it must not
    # be hidden from the caller. (V1_143_0_PLAN.md §4 PR-A.)
    if ! _set_metrics_backend "prometheus"; then
        echo "  ⚠ Prometheus stack started but config write to nftban.conf.local failed" >&2
        echo "  Restore-on-restart behavior may revert NFTBAN_METRICS_ENABLED." >&2
        return 1
    fi

    # Final output
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Prometheus Metrics Enabled Successfully!"
    echo ""
    echo "Prometheus UI:   http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
    echo "Node Exporter:   http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    echo "NFTBan Metrics:  /var/lib/node_exporter/textfile_collector/nftban.prom"
    echo "Collection:      Every 60 seconds"
    echo ""
    echo "Test: nftban metrics status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# ==============================================================================
# Command: nftban metrics disable
# ==============================================================================
nftban_metrics_disable() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Disabling NFTBan Metrics Collection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if already disabled
    if ! systemctl is-active prometheus &>/dev/null; then
        echo "Metrics already disabled"
        return 0
    fi

    # Stop metrics stack
    echo "Stopping metrics services..."
    nftban_metrics_stop_stack true

    # Update config - disable metrics via ENABLED flag in nftban.conf.local
    # User overrides go to .conf.local — package defaults (.conf) are never modified
    local local_conf="${NFTBAN_CONFIG_DIR}/nftban.conf.local"

    # Source atomic file ops if not already loaded
    if ! declare -F nftban_atomic_write >/dev/null 2>&1; then
        # shellcheck source=../core/nftban_file_ops.sh
        source "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" 2>/dev/null || true
    fi

    local content
    if [[ -f "$local_conf" ]] && grep -q "^NFTBAN_METRICS_ENABLED=" "$local_conf"; then
        content=$(sed 's/^NFTBAN_METRICS_ENABLED=.*/NFTBAN_METRICS_ENABLED="false"/' "$local_conf")
    elif [[ -f "$local_conf" ]]; then
        content=$(cat "$local_conf")
        content="${content}"$'\n''NFTBAN_METRICS_ENABLED="false"'
    else
        content='NFTBAN_METRICS_ENABLED="false"'
    fi

    if declare -F nftban_atomic_write >/dev/null 2>&1; then
        echo "$content" | nftban_atomic_write "$local_conf"
    else
        echo "$content" > "$local_conf"
        chmod 640 "$local_conf" 2>/dev/null || true
        chown root:nftban "$local_conf" 2>/dev/null || true
    fi

    echo ""
    echo "Metrics collection disabled"
    echo ""
}

# ==============================================================================
# Command: nftban metrics status
# ==============================================================================
nftban_metrics_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Metrics Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show export configuration
    local local_export="OpenMetrics format (node_exporter textfile)"
    local remote_export="None"

    if [[ "${NFTBAN_ZABBIX_ENABLED:-false}" == "true" ]]; then
        remote_export="Zabbix trapper (${NFTBAN_ZABBIX_SERVER:-not configured})"
    fi

    echo "Local:  $local_export"
    echo "Remote: $remote_export"
    echo ""

    # ============================================================================
    # STATUS DISPLAY
    # ============================================================================
    local all_running=true

    echo "Service Status:"

    # Check Prometheus
    local prometheus_service
    prometheus_service=$(nftban_distro_get_service prometheus 2>/dev/null || echo "prometheus")
    if systemctl is-active "$prometheus_service" &>/dev/null; then
        echo "  Prometheus:        Running"
        echo "   URL:               http://${NFTBAN_METRICS_PROMETHEUS_ADDR}/"
    else
        echo "  Prometheus:        Stopped"
        all_running=false
    fi

    echo ""

    # Check Node Exporter
    # Service name varies: node_exporter, node-exporter, prometheus-node-exporter
    local node_exporter_running=false
    if systemctl is-active node_exporter &>/dev/null || \
       systemctl is-active node-exporter &>/dev/null || \
       systemctl is-active prometheus-node-exporter &>/dev/null; then
        node_exporter_running=true
    fi

    if [[ "$node_exporter_running" == "true" ]]; then
        echo "  Node Exporter:     Running"
        echo "   URL:               http://${NFTBAN_METRICS_NODE_EXPORTER_ADDR}/metrics"
    else
        echo "  Node Exporter:     Stopped"
        all_running=false
    fi

    echo ""

    # Check NFTBan metrics exporter
    if systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
        echo "  NFTBan Exporter:   Running"
        local last_run
        last_run=$(systemctl show nftban-unified-exporter.timer -p LastTriggerUSec --value 2>/dev/null || echo "n/a")
        if [[ -n "$last_run" ]] && [[ "$last_run" != "n/a" ]]; then
            echo "   Last run:          $(date -d "$last_run" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_run")"
        fi
        echo "   Interval:          60 seconds"
        echo "   Output:            /var/lib/node_exporter/textfile_collector/nftban.prom"
    else
        echo "  NFTBan Exporter:   Stopped"
        all_running=false
    fi

    echo ""

    if [[ "$all_running" == true ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "All metrics services running"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Some services stopped"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "To enable metrics collection:"
        echo ""
        echo "  nftban metrics enable"
        echo ""
    fi

    echo ""
}

# ==============================================================================
# Main Command Handler
# ==============================================================================

nftban_cmd_metrics() {
    local subcommand="${1:-status}"
    shift || true

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    case "$subcommand" in
        evidence)
            # v1.87: Kernel evidence snapshot (human-readable)
            "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core" metrics evidence
            ;;
        evidence-json)
            # v1.87: Kernel evidence snapshot (canonical JSON)
            "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core" metrics evidence-json
            ;;
        enable)
            nftban_metrics_enable "$@"
            ;;
        disable)
            nftban_metrics_disable
            ;;
        status)
            nftban_metrics_status
            ;;
        pipeline)
            # Show pipeline validation report
            local json_flag=""
            [[ "${1:-}" == "--json" ]] && json_flag="--json"
            nftban_print_pipeline_report $json_flag
            ;;
        help|--help|-h)
            echo "Usage: nftban metrics {evidence|evidence-json|enable|disable|status|pipeline} [options]"
            echo ""
            echo "Commands:"
            echo "  evidence        Show kernel evidence snapshot (operator-first)"
            echo "  evidence-json   Show kernel evidence snapshot (canonical JSON)"
            echo "  enable          Enable Prometheus metrics collection"
            echo "  disable         Disable metrics collection"
            echo "  status          Show metrics services status"
            echo "  pipeline        Show pipeline validation report"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ENABLE OPTIONS"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  --pro                     Enable NFTBan Pro metrics submission"
            echo "  --remote                  Enable remote submission to your backend"
            echo "  --url URL                 Remote write URL (for --remote)"
            echo "  --token FILE              Token file path (optional)"
            echo "  --labels KEY=VAL,...      External labels (optional)"
            echo "  --force                   Force enable even if already running"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  EXAMPLES"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "  # Enable local Prometheus metrics"
            echo "  nftban metrics enable"
            echo ""
            echo "  # Enable NFTBan Pro subscription"
            echo "  nftban metrics enable --pro"
            echo ""
            echo "  # Send to remote backend (Grafana Cloud, Mimir, etc.)"
            echo "  nftban metrics enable --remote --url https://your-backend/api/v1/write"
            echo ""
            echo "  # Check status"
            echo "  nftban metrics status"
            echo ""
            echo "  # Show pipeline validation"
            echo "  nftban metrics pipeline --json"
            echo ""
            ;;
        *)
            echo "Unknown command: $subcommand"
            echo "Usage: nftban metrics {evidence|evidence-json|enable|disable|status|pipeline|help}"
            return 1
            ;;
    esac
}

# Export functions
export -f nftban_cmd_metrics
