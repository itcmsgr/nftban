#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# FIXTURE: MUST NOT TRIP check-success-claim-proof.sh
# =============================================================================
# The three shapes already correct in cli/lib/nftban/cli/cmd_connector.sh, kept
# structurally identical so a guard that over-matches is caught here rather
# than in review:
#
#   elasticsearch  transport is the CONDITION of an `if`
#   webhook        same, with the emitter separated from the condition by other
#                  statements inside the then-branch
#   syslog-fixed   the shape this release introduces: rc captured on the next
#                  statement, then branched on
#   retry          transport status consumed by `||`
#
# It deliberately contains the same transport verbs as the negative fixture, so
# a PASS here cannot be explained by the verbs being absent.
# This fixture is NEVER sourced or executed. It is inert text read by the guard.
# =============================================================================

_connector_print_success() { echo "OK $1"; }
_connector_print_error()   { echo "ERR $1" >&2; }

_fixture_push() {
    case "$CONNECTOR_TYPE" in
        elasticsearch)
            if curl -sf -X POST "$url" -d "$event_json" -o /dev/null; then
                _connector_print_success "Event pushed to Elasticsearch"
            else
                _connector_print_error "Failed to push event"
                return 1
            fi
            ;;

        webhook)
            if curl -sf -X POST -d "$event_json" -o /dev/null "$url"; then
                local _note="delivered"
                echo "$_note" >/dev/null
                _connector_print_success "Event pushed to webhook"
            else
                _connector_print_error "Failed to push event"
                return 1
            fi
            ;;

        syslog)
            local _rc=0
            echo "$msg" | nc -u -w1 "$host" "$port"
            _rc=$?
            if [[ $_rc -ne 0 ]]; then
                _connector_print_error "Failed to push event to syslog"
                return 1
            fi
            _connector_print_success "Event pushed to syslog"
            ;;

        retry)
            wget -q -O /dev/null "$url" || { _connector_print_error "Failed"; return 1; }
            _connector_print_success "Event pushed by retry transport"
            ;;
    esac
}
