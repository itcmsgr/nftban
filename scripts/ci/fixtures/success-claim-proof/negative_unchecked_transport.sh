#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# FIXTURE: MUST TRIP check-success-claim-proof.sh
# =============================================================================
# A faithful reduction of the two v1.231.0 motivating defects in
# cli/lib/nftban/cli/cmd_connector.sh, kept structurally identical to the code
# that was proven on lab4 to print an affirmative success line while the
# transport had not run (nc absent) or had failed (producer exit 1):
#
#   syslog  the transport sits inside an if/else whose CONDITION tests a
#           CONFIG STRING, not the transport -- so nothing checks the transport
#   kafka   the transport's stderr is redirected away and its rc is discarded
#
# This fixture is NEVER sourced or executed. It is inert text read by the guard.
# =============================================================================

_connector_print_success() { echo "OK $1"; }
_connector_print_error()   { echo "ERR $1" >&2; }

_fixture_push() {
    case "$CONNECTOR_TYPE" in
        kafka)
            if command -v kafka-console-producer.sh &>/dev/null; then
                echo "$event_json" | kafka-console-producer.sh \
                    --broker-list "$CONNECTOR_KAFKA_BROKERS" \
                    --topic "$CONNECTOR_KAFKA_TOPIC" 2>/dev/null
                _connector_print_success "Event pushed to Kafka"
            else
                _connector_print_error "kafka-console-producer.sh not found"
                return 1
            fi
            ;;

        syslog)
            if [[ "$proto" == "udp" ]]; then
                echo "$msg" | nc -u -w1 "$host" "$port"
            else
                echo "$msg" | nc -w1 "$host" "$port"
            fi
            _connector_print_success "Event pushed to syslog"
            ;;
    esac
}
