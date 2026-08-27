#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="producer-absence-claim" meta:type="tool" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Closure gate for any claim that a producer/mutation authority is absent: requires evidence across every authority class"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# ⛔ WHY THIS EXISTS. In v1.229.12 the DDoS penalty ladder was declared to have
# NO PRODUCER, on 9/9 production hosts, from a search that could only ever see
# one authority class. The producer existed: it was userspace shell, invoked
# from a timer, writing through daemon IPC, targeting VARIABLE set names. A
# rule-edge census is structurally incapable of seeing that.
#
#   NO PRODUCER IN ONE REPRESENTATION LAYER != NO PRODUCER.
#
# This is NOT a static detector — absence cannot be proven by grep, and a
# brittle regex pretending otherwise would be worse than nothing. It is a
# CLOSURE CHECKLIST: a lane claiming PRODUCER_ABSENT is not closure-valid until
# every authority class below is resolved with recorded evidence.
#
# USAGE:  ./producer-absence-claim.sh <claim-file>
#         ./producer-absence-claim.sh --template > claim.md
set -uo pipefail

CLASSES=(
  "nft_rule:an nft rule that adds/updates the state (add @set / update @set)"
  "shell_userspace:shell or other userspace code that mutates it directly"
  "go_daemon:Go/daemon code paths"
  "ipc_mutation:mutation routed through daemon IPC rather than written directly"
  "timer_cron:invocation from a timer, cron, or scheduler unit"
  "indirect_dispatch:dispatchers, hooks, or callback registries that reach it"
  "variable_target:targets named by VARIABLE rather than literal (the A08 blind spot)"
  "runtime_reachability:runtime evidence that the path is actually reached"
)

if [[ "${1:-}" == "--template" ]]; then
    echo "# PRODUCER ABSENCE CLAIM"
    echo "# A claim of \"no producer\" is not closure-valid until every line is resolved."
    echo "# Mark each: SEARCHED <evidence>  |  NOT_APPLICABLE <why>"
    echo
    echo "subject: <the state/set/queue claimed to have no producer>"
    echo "lane: <register lane id>"
    echo
    for c in "${CLASSES[@]}"; do
        printf '%-22s UNRESOLVED   # %s\n' "${c%%:*}:" "${c#*:}"
    done
    exit 0
fi

f="${1:-}"
[[ -z "$f" || ! -r "$f" ]] && { echo "usage: $0 <claim-file> | --template"; exit 2; }

echo "PRODUCER ABSENCE CLAIM — $f"
missing=0
for c in "${CLASSES[@]}"; do
    key="${c%%:*}"; desc="${c#*:}"
    line=$(grep -m1 "^${key}:" "$f" 2>/dev/null)
    # Strip any trailing `# comment` before judging the VALUE. An earlier form
    # anchored UNRESOLVED to end-of-line and therefore passed every template
    # line, because the template carries an explanatory comment — the guard
    # silently accepted the exact claim it exists to reject.
    value="${line#*:}"; value="${value%%#*}"; value="$(printf '%s' "$value" | tr -d '[:space:]')"
    if [[ -z "$line" ]]; then
        printf '  %-22s ABSENT FROM CLAIM   # %s\n' "$key" "$desc"; missing=1
    elif [[ -z "$value" || "$value" == "UNRESOLVED" || "$value" == "TODO" || "$value" == "?" ]]; then
        printf '  %-22s UNRESOLVED          # %s\n' "$key" "$desc"; missing=1
    else
        printf '  %-22s resolved\n' "$key"
    fi
done

echo
if [[ $missing -ne 0 ]]; then
    echo "CLAIM NOT CLOSURE-VALID: at least one authority class is unresolved."
    echo "  A producer found in none of the searched layers may still exist in an unsearched one."
    exit 1
fi
echo "CLAIM COMPLETE: every authority class resolved. (Completeness of the CHECKLIST,"
echo "  not proof of absence — a resolved checklist still records judgement, not certainty.)"
exit 0
