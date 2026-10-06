#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# NFTBan v1.235 - G20 smoke gate verdict (skip is not pass)
# =============================================================================
# meta:name="check-smoke-g20"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="GATE-CLI-SMOKE-G20-PASSES-VACUOUSLY-ALL-SKIPPED (v1.235 batch C, option b). The CI Smoke Test reported PASS with '0 pass, 10 skip, 0 fail': every check skipped on a missing prerequisite and the gate counted only failures. Verdict over `nftban-core smoke --json`: FAIL on invalid JSON, on any FAIL, on pass == 0, and when a REQUIRED test (one whose prerequisites the job provisions; default T1 T2 C1) is not PASS. Other skips are printed as NOT_IN_SCOPE with their reason, never counted as passes."
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="G20_REQUIRED"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="none"
# meta:inventory.privileges="none"
# =============================================================================
# Usage: check-smoke-g20.sh <smoke.json>
set -Eeuo pipefail
IFS=$'\n\t'
J="${1:?usage: check-smoke-g20.sh <smoke.json>}"
IFS=' ' read -r -a REQUIRED <<< "${G20_REQUIRED:-T1 T2 C1}"

if ! jq -e '(.summary | type == "object") and (.tests | type == "array")' "$J" > /dev/null 2>&1; then
    echo "::error::G20: smoke --json output is not a valid smoke report"
    exit 1
fi
pass="$(jq -r '.summary.pass // 0' "$J")"
fail="$(jq -r '.summary.fail // 0' "$J")"
skip="$(jq -r '.summary.skip // 0' "$J")"
rc=0

if [[ "$fail" != "0" ]]; then
    echo "::error::G20: $fail test(s) FAILED"
    jq -c '.tests[] | select(.status == "FAIL")' "$J"
    rc=1
fi
if [[ "$pass" == "0" ]]; then
    echo "::error::G20: 0 tests passed ($skip skipped) — a gate that ran nothing measured nothing"
    rc=1
fi
for id in "${REQUIRED[@]}"; do
    st="$(jq -r --arg id "$id" '[.tests[] | select(.id == $id) | .status][0] // "ABSENT"' "$J")"
    if [[ "$st" == "PASS" ]]; then
        echo "[PASS] required $id"
    else
        det="$(jq -r --arg id "$id" '[.tests[] | select(.id == $id) | .detail // ""][0] // ""' "$J")"
        echo "::error::G20: required test $id is $st (the job provisions its prerequisites) ${det}"
        rc=1
    fi
done
while IFS=$'\t' read -r id det; do
    [[ -n "$id" ]] || continue
    req=0
    for r in "${REQUIRED[@]}"; do
        if [[ "$r" == "$id" ]]; then req=1; fi
    done
    if (( req == 0 )); then echo "[NOT_IN_SCOPE] $id skipped: ${det:-no reason given} (not provisioned in this job; not a pass)"; fi
done < <(jq -r '.tests[] | select(.status == "SKIP") | [.id, (.detail // "")] | @tsv' "$J")

if (( rc == 0 )); then
    echo "G20 Smoke Gate: PASS ($pass pass, $skip skip, 0 fail; required $(printf "%s " "${REQUIRED[@]}")all PASS)"
else
    echo "G20 Smoke Gate: FAIL ($pass pass, $skip skip, $fail fail)"
fi
exit "$rc"
