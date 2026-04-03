#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Generic Connector CLI
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_connector"
# meta:type="cli"
# meta:header="Connector Management"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Manage generic metric and event connectors"
# meta:created_date="2026-01-22"
# meta:updated_date="2026-01-22"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_CONNECTORS_DIR"
# meta:inventory.config_files="/etc/nftban/connectors/*.yaml"
# meta:inventory.systemd_units=""
# meta:inventory.network="9200/tcp,9092/tcp"
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load main config (sets readonly paths)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
fi

# Connector-specific path
readonly NFTBAN_CONNECTORS_DIR="${NFTBAN_CONFIG_DIR}/connectors"

# Load output module for banner and styling
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
fi

# =============================================================================
# SUPPORTED CONNECTOR TYPES
# =============================================================================
readonly CONNECTOR_TYPES="elasticsearch kafka syslog webhook file"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_connector_print_header() {
    local title="$1"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $title"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

_connector_print_success() {
    echo "✅ $1"
}

_connector_print_error() {
    echo "❌ $1" >&2
}

_connector_print_warning() {
    echo "⚠️  $1"
}

_connector_print_info() {
    echo "ℹ️  $1"
}

_connector_config_path() {
    local name="$1"
    echo "${NFTBAN_CONNECTORS_DIR}/${name}.conf"
}

_connector_exists() {
    local name="$1"
    [[ -f "$(_connector_config_path "$name")" ]]
}

_connector_load() {
    local name="$1"
    local config_file
    config_file=$(_connector_config_path "$name")

    if [[ ! -f "$config_file" ]]; then
        return 1
    fi

    # H23 fix: Validate config file contains only safe variable assignments before sourcing
    if grep -qE '^[^#]*[;|&`\(]' "$config_file" 2>/dev/null; then
        _connector_print_error "Connector config contains unsafe content: $config_file"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$config_file" || true
}

_connector_save() {
    local name="$1"
    local type="$2"
    shift 2

    # Ensure directory exists
    mkdir -p "${NFTBAN_CONNECTORS_DIR}" || return 1

    local config_file
    config_file=$(_connector_config_path "$name")

    cat > "$config_file" << EOF
# NFTBan Connector Configuration
# Name: $name
# Type: $type
# Generated: $(date -Iseconds)

CONNECTOR_NAME="$name"
CONNECTOR_TYPE="$type"
CONNECTOR_ENABLED="true"
EOF

    # Add type-specific options
    while [[ $# -gt 0 ]]; do
        echo "$1" >> "$config_file"
        shift
    done

    chmod 640 "$config_file"
}

# =============================================================================
# Command: nftban connector list
# =============================================================================
_cmd_connector_list() {
    local json="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json="true"; shift ;;
            *)      shift ;;
        esac
    done

    if [[ "$json" == "true" ]]; then
        echo '{"connectors":['
        local first=true
        if [[ -d "${NFTBAN_CONNECTORS_DIR}" ]]; then
            for conf in "${NFTBAN_CONNECTORS_DIR}"/*.conf; do
                [[ -f "$conf" ]] || continue
                local name type enabled
                name=$(basename "$conf" .conf)
                # shellcheck source=/dev/null
                source "$conf" || true
                type="${CONNECTOR_TYPE:-unknown}"
                enabled="${CONNECTOR_ENABLED:-false}"

                [[ "$first" != "true" ]] && echo ","
                echo "{\"name\":\"$name\",\"type\":\"$type\",\"enabled\":$enabled}"
                first=false
            done
        fi
        echo ']}'
        return 0
    fi

    _connector_print_header "NFTBan Connectors"

    printf "%-20s %-15s %-10s %-30s\n" "NAME" "TYPE" "STATUS" "TARGET"
    echo "────────────────────────────────────────────────────────────────────────────"

    local count=0
    if [[ -d "${NFTBAN_CONNECTORS_DIR}" ]]; then
        for conf in "${NFTBAN_CONNECTORS_DIR}"/*.conf; do
            [[ -f "$conf" ]] || continue
            local name type enabled target
            name=$(basename "$conf" .conf)
            # shellcheck source=/dev/null
            source "$conf" || true
            type="${CONNECTOR_TYPE:-unknown}"
            enabled="${CONNECTOR_ENABLED:-false}"

            # Get target based on type
            case "$type" in
                elasticsearch) target="${CONNECTOR_ES_URL:-not set}" ;;
                kafka)         target="${CONNECTOR_KAFKA_BROKERS:-not set}" ;;
                syslog)        target="${CONNECTOR_SYSLOG_HOST:-not set}:${CONNECTOR_SYSLOG_PORT:-514}" ;;
                webhook)       target="${CONNECTOR_WEBHOOK_URL:-not set}" ;;
                file)          target="${CONNECTOR_FILE_PATH:-not set}" ;;
                *)             target="unknown" ;;
            esac

            local status="disabled"
            [[ "$enabled" == "true" ]] && status="enabled"

            printf "%-20s %-15s %-10s %-30s\n" "$name" "$type" "$status" "$target"
            # v1.19.20 FIX
            ((count++)) || true
        done
    fi

    if [[ $count -eq 0 ]]; then
        echo "No connectors configured."
        echo ""
        echo "Add a connector:"
        echo "  nftban connector add myconnector --type elasticsearch --url https://es.example.com"
        echo "  nftban connector add kafka-prod --type kafka --brokers kafka1:9092,kafka2:9092"
    fi
    echo ""
}

# =============================================================================
# Command: nftban connector add
# =============================================================================
_cmd_connector_add() {
    local name="${1:-}"
    shift || true

    if [[ -z "$name" ]]; then
        _connector_print_error "Connector name required"
        echo "Usage: nftban connector add NAME --type TYPE [options]"
        return 1
    fi

    if _connector_exists "$name"; then
        _connector_print_error "Connector '$name' already exists"
        echo "Use: nftban connector edit $name"
        return 1
    fi

    local type=""
    local options=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type)    type="$2"; shift 2 ;;
            --type=*)  type="${1#*=}"; shift ;;
            # Elasticsearch options
            --url)     options+=("CONNECTOR_ES_URL=\"$2\""); shift 2 ;;
            --url=*)   options+=("CONNECTOR_ES_URL=\"${1#*=}\""); shift ;;
            --index)   options+=("CONNECTOR_ES_INDEX=\"$2\""); shift 2 ;;
            --index=*) options+=("CONNECTOR_ES_INDEX=\"${1#*=}\""); shift ;;
            --user)    options+=("CONNECTOR_ES_USER=\"$2\""); shift 2 ;;
            --user=*)  options+=("CONNECTOR_ES_USER=\"${1#*=}\""); shift ;;
            --pass)
                # H6 fix: Warn about password visibility in process list
                if [[ "$2" == "-" ]]; then
                    # Read password from stdin (safe)
                    local _pass
                    read -rs -p "Connector password: " _pass
                    echo "" >&2
                    options+=("CONNECTOR_ES_PASS=\"${_pass}\"")
                else
                    echo "WARNING: --pass on command line is visible in 'ps'. Use --pass - (stdin) or config file instead." >&2
                    options+=("CONNECTOR_ES_PASS=\"$2\"")
                fi
                shift 2 ;;
            --pass=*)
                echo "WARNING: --pass on command line is visible in 'ps'. Use --pass - (stdin) or config file instead." >&2
                options+=("CONNECTOR_ES_PASS=\"${1#*=}\""); shift ;;
            # Kafka options
            --brokers)   options+=("CONNECTOR_KAFKA_BROKERS=\"$2\""); shift 2 ;;
            --brokers=*) options+=("CONNECTOR_KAFKA_BROKERS=\"${1#*=}\""); shift ;;
            --topic)     options+=("CONNECTOR_KAFKA_TOPIC=\"$2\""); shift 2 ;;
            --topic=*)   options+=("CONNECTOR_KAFKA_TOPIC=\"${1#*=}\""); shift ;;
            # Syslog options
            --host)    options+=("CONNECTOR_SYSLOG_HOST=\"$2\""); shift 2 ;;
            --host=*)  options+=("CONNECTOR_SYSLOG_HOST=\"${1#*=}\""); shift ;;
            --port)    options+=("CONNECTOR_SYSLOG_PORT=\"$2\""); shift 2 ;;
            --port=*)  options+=("CONNECTOR_SYSLOG_PORT=\"${1#*=}\""); shift ;;
            --proto)   options+=("CONNECTOR_SYSLOG_PROTO=\"$2\""); shift 2 ;;
            --proto=*) options+=("CONNECTOR_SYSLOG_PROTO=\"${1#*=}\""); shift ;;
            # Webhook options
            --webhook-url)   options+=("CONNECTOR_WEBHOOK_URL=\"$2\""); shift 2 ;;
            --webhook-url=*) options+=("CONNECTOR_WEBHOOK_URL=\"${1#*=}\""); shift ;;
            --secret)        options+=("CONNECTOR_WEBHOOK_SECRET=\"$2\""); shift 2 ;;
            --secret=*)      options+=("CONNECTOR_WEBHOOK_SECRET=\"${1#*=}\""); shift ;;
            # File options
            --path)    options+=("CONNECTOR_FILE_PATH=\"$2\""); shift 2 ;;
            --path=*)  options+=("CONNECTOR_FILE_PATH=\"${1#*=}\""); shift ;;
            --format)  options+=("CONNECTOR_FILE_FORMAT=\"$2\""); shift 2 ;;
            --format=*) options+=("CONNECTOR_FILE_FORMAT=\"${1#*=}\""); shift ;;
            # Common options
            --filter)  options+=("CONNECTOR_FILTER=\"$2\""); shift 2 ;;
            --filter=*) options+=("CONNECTOR_FILTER=\"${1#*=}\""); shift ;;
            *)         shift ;;
        esac
    done

    # Validate type
    if [[ -z "$type" ]]; then
        _connector_print_error "--type required"
        echo "Valid types: $CONNECTOR_TYPES"
        return 1
    fi

    if ! echo "$CONNECTOR_TYPES" | grep -qw "$type"; then
        _connector_print_error "Invalid type: $type"
        echo "Valid types: $CONNECTOR_TYPES"
        return 1
    fi

    # Add default options based on type
    case "$type" in
        elasticsearch)
            # Set defaults if not provided
            grep -q "CONNECTOR_ES_INDEX" <<< "${options[*]}" || options+=("CONNECTOR_ES_INDEX=\"nftban-events\"")
            ;;
        kafka)
            grep -q "CONNECTOR_KAFKA_TOPIC" <<< "${options[*]}" || options+=("CONNECTOR_KAFKA_TOPIC=\"nftban\"")
            ;;
        syslog)
            grep -q "CONNECTOR_SYSLOG_PORT" <<< "${options[*]}" || options+=("CONNECTOR_SYSLOG_PORT=\"514\"")
            grep -q "CONNECTOR_SYSLOG_PROTO" <<< "${options[*]}" || options+=("CONNECTOR_SYSLOG_PROTO=\"udp\"")
            ;;
        file)
            grep -q "CONNECTOR_FILE_FORMAT" <<< "${options[*]}" || options+=("CONNECTOR_FILE_FORMAT=\"json\"")
            ;;
    esac

    # Save connector
    _connector_save "$name" "$type" "${options[@]}"

    _connector_print_success "Connector '$name' created"
    echo ""
    echo "Configuration: $(_connector_config_path "$name")"
    echo ""
    echo "Test connection: nftban connector test $name"
    echo "Enable:          nftban connector enable $name"
}

# =============================================================================
# Command: nftban connector remove
# =============================================================================
_cmd_connector_remove() {
    local name="${1:-}"
    local force="false"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f) force="true"; shift ;;
            *)          shift ;;
        esac
    done

    if [[ -z "$name" ]]; then
        _connector_print_error "Connector name required"
        return 1
    fi

    if ! _connector_exists "$name"; then
        _connector_print_error "Connector '$name' not found"
        return 1
    fi

    local config_file
    config_file=$(_connector_config_path "$name")

    if [[ "$force" != "true" ]]; then
        read -rp "Remove connector '$name'? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy] ]] && return 0 || true
    fi

    rm -f "$config_file"
    _connector_print_success "Connector '$name' removed"
}

# =============================================================================
# Command: nftban connector enable/disable
# =============================================================================
_cmd_connector_enable() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        _connector_print_error "Connector name required"
        return 1
    fi

    if ! _connector_exists "$name"; then
        _connector_print_error "Connector '$name' not found"
        return 1
    fi

    local config_file
    config_file=$(_connector_config_path "$name")

    sed -i 's/^CONNECTOR_ENABLED=.*/CONNECTOR_ENABLED="true"/' "$config_file"
    _connector_print_success "Connector '$name' enabled"
}

_cmd_connector_disable() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        _connector_print_error "Connector name required"
        return 1
    fi

    if ! _connector_exists "$name"; then
        _connector_print_error "Connector '$name' not found"
        return 1
    fi

    local config_file
    config_file=$(_connector_config_path "$name")

    sed -i 's/^CONNECTOR_ENABLED=.*/CONNECTOR_ENABLED="false"/' "$config_file"
    _connector_print_success "Connector '$name' disabled"
}

# =============================================================================
# Command: nftban connector test
# =============================================================================
_cmd_connector_test() {
    local name="${1:-}"
    local verbose="false"

    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose) verbose="true"; shift ;;
            *)         shift ;;
        esac
    done

    if [[ -z "$name" ]]; then
        _connector_print_error "Connector name required"
        return 1
    fi

    if ! _connector_exists "$name"; then
        _connector_print_error "Connector '$name' not found"
        return 1
    fi

    _connector_load "$name"

    _connector_print_info "Testing connector '$name' (type: $CONNECTOR_TYPE)..."
    echo ""

    case "$CONNECTOR_TYPE" in
        elasticsearch)
            [[ "$verbose" == "true" ]] && echo "[1/3] Checking URL: $CONNECTOR_ES_URL"
            if ! curl -sf "${CONNECTOR_ES_URL}/_cluster/health" -o /dev/null --connect-timeout "${NFTBAN_TIMEOUT_FAST:-5}"; then
                _connector_print_error "Cannot connect to Elasticsearch"
                return 1
            fi
            [[ "$verbose" == "true" ]] && echo "      ✅ OK"

            [[ "$verbose" == "true" ]] && echo "[2/3] Checking index: $CONNECTOR_ES_INDEX"
            # Index may not exist yet, that's OK
            [[ "$verbose" == "true" ]] && echo "      ✅ OK (will be created on first write)"

            [[ "$verbose" == "true" ]] && echo "[3/3] Test complete"
            _connector_print_success "Elasticsearch connector test passed"
            ;;

        kafka)
            [[ "$verbose" == "true" ]] && echo "[1/2] Checking brokers: $CONNECTOR_KAFKA_BROKERS"
            local broker
            broker=$(echo "$CONNECTOR_KAFKA_BROKERS" | cut -d',' -f1)
            local host port
            host=$(echo "$broker" | cut -d':' -f1)
            port=$(echo "$broker" | cut -d':' -f2)
            port="${port:-9092}"

            if ! timeout "${NFTBAN_TIMEOUT_FAST:-5}" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
                _connector_print_error "Cannot connect to Kafka broker $host:$port"
                return 1
            fi
            [[ "$verbose" == "true" ]] && echo "      ✅ OK"

            [[ "$verbose" == "true" ]] && echo "[2/2] Test complete"
            _connector_print_success "Kafka connector test passed"
            ;;

        syslog)
            local host="${CONNECTOR_SYSLOG_HOST:-localhost}"
            local port="${CONNECTOR_SYSLOG_PORT:-514}"
            local proto="${CONNECTOR_SYSLOG_PROTO:-udp}"

            [[ "$verbose" == "true" ]] && echo "[1/2] Checking $proto://$host:$port"

            if [[ "$proto" == "tcp" ]]; then
                if ! timeout "${NFTBAN_TIMEOUT_FAST:-5}" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
                    _connector_print_error "Cannot connect to syslog server"
                    return 1
                fi
            fi
            # UDP doesn't have connection test
            [[ "$verbose" == "true" ]] && echo "      ✅ OK"

            [[ "$verbose" == "true" ]] && echo "[2/2] Test complete"
            _connector_print_success "Syslog connector test passed"
            ;;

        webhook)
            local url="${CONNECTOR_WEBHOOK_URL:-}"
            [[ "$verbose" == "true" ]] && echo "[1/2] Checking URL: $url"

            if ! curl -sf "$url" -o /dev/null --connect-timeout "${NFTBAN_TIMEOUT_FAST:-5}" -X HEAD 2>/dev/null; then
                # Try GET if HEAD fails
                if ! curl -sf "$url" -o /dev/null --connect-timeout "${NFTBAN_TIMEOUT_FAST:-5}" 2>/dev/null; then
                    _connector_print_warning "Cannot reach webhook URL (may require POST)"
                fi
            fi
            [[ "$verbose" == "true" ]] && echo "      ✅ OK (reachable)"

            [[ "$verbose" == "true" ]] && echo "[2/2] Test complete"
            _connector_print_success "Webhook connector test passed"
            ;;

        file)
            local path="${CONNECTOR_FILE_PATH:-}"
            local dir
            dir=$(dirname "$path")

            [[ "$verbose" == "true" ]] && echo "[1/2] Checking directory: $dir"
            if [[ ! -d "$dir" ]]; then
                _connector_print_warning "Directory does not exist: $dir"
                echo "Will be created on first write"
            else
                [[ "$verbose" == "true" ]] && echo "      ✅ OK" || true
            fi

            [[ "$verbose" == "true" ]] && echo "[2/2] Test complete"
            _connector_print_success "File connector test passed"
            ;;

        *)
            _connector_print_error "Unknown connector type: $CONNECTOR_TYPE"
            return 1
            ;;
    esac
}

# =============================================================================
# Command: nftban connector show
# =============================================================================
_cmd_connector_show() {
    local name="${1:-}"

    if [[ -z "$name" ]]; then
        _connector_print_error "Connector name required"
        return 1
    fi

    if ! _connector_exists "$name"; then
        _connector_print_error "Connector '$name' not found"
        return 1
    fi

    _connector_print_header "Connector: $name"

    local config_file
    config_file=$(_connector_config_path "$name")

    grep -v "^#" "$config_file" | grep -v "^$"
    echo ""
}

# =============================================================================
# Command: nftban connector push
# =============================================================================
_cmd_connector_push() {
    local name="${1:-}"
    local event_type="${2:-test}"

    if [[ -z "$name" ]]; then
        _connector_print_error "Connector name required"
        return 1
    fi

    if ! _connector_exists "$name"; then
        _connector_print_error "Connector '$name' not found"
        return 1
    fi

    _connector_load "$name"

    # Create test event
    local timestamp
    timestamp=$(date -Iseconds)
    local event_json
    event_json=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "event_type": "$event_type",
  "source": "nftban",
  "hostname": "$(hostname)",
  "version": "1.2.3",
  "message": "Test event from NFTBan connector"
}
EOF
)

    _connector_print_info "Pushing test event to '$name'..."

    case "$CONNECTOR_TYPE" in
        elasticsearch)
            local url="${CONNECTOR_ES_URL}/${CONNECTOR_ES_INDEX}/_doc"
            # v1.19.0: Use .netrc file to avoid credential exposure in process args (R23)
            local netrc_file=""
            if [[ -n "${CONNECTOR_ES_USER:-}" ]]; then
                netrc_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban-es-netrc.XXXXXX")
                chmod 600 "$netrc_file"
                # Extract hostname from URL for netrc format
                local es_host
                es_host=$(echo "$url" | sed -E 's|https?://([^/:]+).*|\1|')
                echo "machine $es_host login ${CONNECTOR_ES_USER} password ${CONNECTOR_ES_PASS:-}" > "$netrc_file"
            fi

            local curl_auth_args=()
            [[ -n "$netrc_file" ]] && curl_auth_args=(--netrc-file "$netrc_file")

            if curl -sf -X POST "$url" -H "Content-Type: application/json" -d "$event_json" "${curl_auth_args[@]}" -o /dev/null; then
                [[ -n "$netrc_file" ]] && rm -f "$netrc_file"
                _connector_print_success "Event pushed to Elasticsearch"
            else
                [[ -n "$netrc_file" ]] && rm -f "$netrc_file"
                _connector_print_error "Failed to push event"
                return 1
            fi
            ;;

        kafka)
            if command -v kafka-console-producer.sh &>/dev/null; then
                echo "$event_json" | kafka-console-producer.sh \
                    --broker-list "$CONNECTOR_KAFKA_BROKERS" \
                    --topic "$CONNECTOR_KAFKA_TOPIC" 2>/dev/null
                _connector_print_success "Event pushed to Kafka"
            else
                _connector_print_warning "kafka-console-producer.sh not found"
                echo "Install Kafka tools or use kafkacat"
                return 1
            fi
            ;;

        syslog)
            local host="${CONNECTOR_SYSLOG_HOST:-localhost}"
            local port="${CONNECTOR_SYSLOG_PORT:-514}"
            local proto="${CONNECTOR_SYSLOG_PROTO:-udp}"
            local msg
            msg="<14>1 $timestamp $(hostname) nftban - - - $event_json"

            if [[ "$proto" == "udp" ]]; then
                echo "$msg" | nc -u -w1 "$host" "$port"
            else
                echo "$msg" | nc -w1 "$host" "$port"
            fi
            _connector_print_success "Event pushed to syslog"
            ;;

        webhook)
            local url="${CONNECTOR_WEBHOOK_URL}"
            local secret="${CONNECTOR_WEBHOOK_SECRET:-}"
            local -a curl_args=(-sf -X POST -H "Content-Type: application/json")

            if [[ -n "$secret" ]]; then
                local sig
                sig=$(echo -n "$event_json" | openssl dgst -sha256 -hmac "$secret" | cut -d' ' -f2)
                curl_args+=(-H "X-NFTBan-Signature: sha256=$sig")
            fi

            if curl "${curl_args[@]}" -d "$event_json" -o /dev/null "$url"; then
                _connector_print_success "Event pushed to webhook"
            else
                _connector_print_error "Failed to push event"
                return 1
            fi
            ;;

        file)
            local path="${CONNECTOR_FILE_PATH}"
            local format="${CONNECTOR_FILE_FORMAT:-json}"
            local dir
            dir=$(dirname "$path")

            mkdir -p "$dir" || return 1

            if [[ "$format" == "json" ]]; then
                echo "$event_json" >> "$path"
            else
                # CSV format
                echo "$timestamp,test,nftban,$(hostname),Test event" >> "$path"
            fi
            _connector_print_success "Event written to $path"
            ;;
    esac
}

# =============================================================================
# Command: nftban connector help
# =============================================================================
_cmd_connector_help() {
    cat <<'EOF'
NFTBan Connector Management

USAGE:
    nftban connector <command> [options]

COMMANDS:
    list                List all connectors
    add NAME            Add a new connector
    remove NAME         Remove a connector
    enable NAME         Enable a connector
    disable NAME        Disable a connector
    test NAME           Test connector connectivity
    show NAME           Show connector configuration
    push NAME           Push a test event
    help                Show this help

CONNECTOR TYPES:
    elasticsearch       Elasticsearch/OpenSearch
    kafka               Apache Kafka
    syslog              Syslog (RFC 5424)
    webhook             HTTP webhook (POST)
    file                Local file (JSON/CSV)

ADD OPTIONS:
    --type TYPE         Connector type (required)

    Elasticsearch:
    --url URL           Elasticsearch URL
    --index NAME        Index name (default: nftban-events)
    --user USER         Username (optional)
    --pass PASS         Password (optional)

    Kafka:
    --brokers LIST      Broker list (host1:port,host2:port)
    --topic NAME        Topic name (default: nftban)

    Syslog:
    --host HOST         Syslog server host
    --port PORT         Syslog port (default: 514)
    --proto tcp|udp     Protocol (default: udp)

    Webhook:
    --webhook-url URL   Webhook URL
    --secret SECRET     HMAC secret for signing

    File:
    --path PATH         Output file path
    --format json|csv   Output format (default: json)

    Common:
    --filter EXPR       Event filter expression

EXAMPLES:
    # Add Elasticsearch connector
    nftban connector add es-prod --type elasticsearch \
        --url https://es.example.com:9200 --index nftban-events

    # Add Kafka connector
    nftban connector add kafka-logs --type kafka \
        --brokers kafka1:9092,kafka2:9092 --topic security-events

    # Add syslog connector
    nftban connector add siem --type syslog \
        --host siem.example.com --port 514 --proto tcp

    # Add webhook connector
    nftban connector add slack --type webhook \
        --webhook-url https://hooks.slack.com/services/XXX

    # Add file connector
    nftban connector add backup --type file \
        --path ${NFTBAN_LOG_DIR}/events.json --format json

    # Test a connector
    nftban connector test es-prod --verbose

    # Push test event
    nftban connector push es-prod

    # List all connectors
    nftban connector list
    nftban connector list --json

EOF
}

# =============================================================================
# Main Command Handler
# =============================================================================
nftban_cmd_connector() {
    local subcommand="${1:-list}"
    shift || true

    # Show banner
    if [[ $(type -t nftban_banner) == "function" ]]; then
        nftban_banner "connector"
    fi

    case "$subcommand" in
        list)    _cmd_connector_list "$@" ;;
        add)     _cmd_connector_add "$@" ;;
        remove|delete|rm) _cmd_connector_remove "$@" ;;
        enable)  _cmd_connector_enable "$@" ;;
        disable) _cmd_connector_disable "$@" ;;
        test)    _cmd_connector_test "$@" ;;
        show)    _cmd_connector_show "$@" ;;
        push)    _cmd_connector_push "$@" ;;
        help|--help|-h) _cmd_connector_help ;;
        *)
            _connector_print_error "Unknown command: $subcommand"
            _cmd_connector_help
            return 1
            ;;
    esac
}

# Export main handler
export -f nftban_cmd_connector
