#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="witness-identity-gate" meta:type="tool" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Abort a runtime witness unless the intended candidate binary and config are provably the ones executing"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="EXPECTED_SHA,EXPECTED_VERSION,EXPECTED_BINARY,EXPECTED_UNIT,EXPECTED_OVERLAY"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# ⛔ WHY THIS EXISTS. Two runtime witnesses in v1.229.12 produced FICTION:
#
#   1. `cp` onto a running binary failed with "Text file busy". The patched
#      daemon was never installed. Every observation ran against the old build
#      and returned zeros that read like "no events occurred".
#   2. A witness sourced the INSTALLED module instead of the instrumented one,
#      so its counters were blank — which reads like "the producer never ran".
#
# Both were caught only by luck. Recording a rule does not enforce it; only a
# check does. This gate runs BEFORE any behavioural evidence is collected and
# ABORTS on mismatch, so a witness can never silently measure the wrong subject.
#
# USAGE (all optional; each supplied expectation is enforced):
#   EXPECTED_BINARY=/usr/lib/nftban/bin/nftband \
#   EXPECTED_SHA=<sha256> EXPECTED_VERSION=1.229.12 \
#   EXPECTED_UNIT=nftband EXPECTED_OVERLAY=/etc/nftban/conf.d/x.local \
#     ./witness-identity-gate.sh   # rc=0 proceed, rc=1 ABORT
set -uo pipefail
fail=0
say(){ printf '  %-34s %s\n' "$1" "$2"; }
bad(){ printf '  %-34s %s  <-- MISMATCH\n' "$1" "$2"; fail=1; }

echo "WITNESS IDENTITY GATE"

if [[ -n "${EXPECTED_BINARY:-}" ]]; then
    if [[ -x "$EXPECTED_BINARY" ]]; then say "binary path" "$EXPECTED_BINARY"
    else bad "binary path" "$EXPECTED_BINARY (missing or not executable)"; fi

    if [[ -n "${EXPECTED_SHA:-}" ]]; then
        actual=$(sha256sum "$EXPECTED_BINARY" 2>/dev/null | cut -d' ' -f1)
        if [[ "$actual" == "${EXPECTED_SHA}"* || "${EXPECTED_SHA}" == "${actual}"* ]]; then
            say "binary sha256" "${actual:0:16} (matches)"
        else
            bad "binary sha256" "expected ${EXPECTED_SHA:0:16} got ${actual:0:16}"
            echo "         the candidate was NOT installed — a failed copy is silent"
        fi
    fi
fi

# The running process must map to the bytes we just verified: an installed-but-
# not-restarted daemon is still executing the OLD image.
if [[ -n "${EXPECTED_UNIT:-}" ]]; then
    pid=$(systemctl show "$EXPECTED_UNIT" -p MainPID --value 2>/dev/null)
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        say "unit $EXPECTED_UNIT MainPID" "$pid"
        running=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
        if [[ -n "${EXPECTED_BINARY:-}" && -n "$running" ]]; then
            if [[ "$running" == "$EXPECTED_BINARY"* ]]; then
                say "running image path" "$running"
            else
                bad "running image path" "$running != $EXPECTED_BINARY"
            fi
            # A replaced-then-not-restarted binary shows as "(deleted)".
            if [[ "$running" == *"(deleted)"* ]]; then
                bad "running image" "process holds a DELETED image — restart required"
            fi
            rsha=$(sha256sum "/proc/$pid/exe" 2>/dev/null | cut -d' ' -f1)
            dsha=$(sha256sum "$EXPECTED_BINARY" 2>/dev/null | cut -d' ' -f1)
            if [[ -n "$rsha" && "$rsha" == "$dsha" ]]; then
                say "running bytes == on-disk" "${rsha:0:16}"
            else
                bad "running bytes" "process image ${rsha:0:16} != on-disk ${dsha:0:16} (stale process)"
            fi
        fi
    else
        bad "unit $EXPECTED_UNIT" "not running (MainPID=${pid:-none})"
    fi
fi

if [[ -n "${EXPECTED_VERSION:-}" ]]; then
    v=$(cat /usr/lib/nftban/VERSION 2>/dev/null)
    [[ "$v" == "$EXPECTED_VERSION" ]] && say "VERSION" "$v" || bad "VERSION" "expected $EXPECTED_VERSION got ${v:-unreadable}"
fi

if [[ -n "${EXPECTED_OVERLAY:-}" ]]; then
    [[ -f "$EXPECTED_OVERLAY" ]] && say "config overlay" "$EXPECTED_OVERLAY present" \
                                 || bad "config overlay" "$EXPECTED_OVERLAY ABSENT"
fi

echo
if [[ $fail -ne 0 ]]; then
    echo "ABORT: witness identity NOT established. Collect no behavioural evidence."
    echo "       Observations from the wrong subject are indistinguishable from a negative result."
    exit 1
fi
echo "IDENTITY ESTABLISHED — witness may proceed."
exit 0
