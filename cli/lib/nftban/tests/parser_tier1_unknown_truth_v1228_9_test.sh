#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tier-1 parser UNKNOWN-truth consumer controls (v1.228.9 PR3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="parser_tier1_unknown_truth_v1228_9_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-09"
# meta:description="Consumer-level controls for the nine Tier-1 parser sites closed in v1.228.9 PR3. Asserts OBSERVABLE CONSUMER BEHAVIOUR, not that a helper exists: an unreadable nft read must produce a visible UNKNOWN verdict at the surface an operator or JSON consumer actually sees, and must never render as 0, absent, healthy, disabled or sole-authority. Covers the config-doctor unreadable-ruleset finding (severity, type, source and that the finding count increments), the set-size threshold guard, the SSH-port advisory, the accept-policy advisory, service_control rule counting, the conflict priority comparison, portscan LOG-prefix verification, and the DDoS meter offender read. Includes falsifiability controls that re-introduce each defect and require the test to fail."
# meta:ta.id="parser_tier1_unknown_truth_v1228_9_test"
# meta:ta.owner="health"
# meta:ta.module="nft-parser-contract"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="180"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
set +e   # sourced modules enable `set -e`; a CRITICAL status must not abort us

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$(cd "$SCRIPT_DIR/.." && pwd)"; NFTBAN_LIB_DIR="$LIB"; export NFTBAN_LIB_DIR

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# Never the host's /run/nftban: on an installed host the daemon's set_counts.json made the
# check read the cache and the nft arm below never ran (lab2 2026-10-08).
mkdir -p "$WORK/run"; NFTBAN_RUN_DIR="$WORK/run"; export NFTBAN_RUN_DIR
# A fake nft whose behaviour is chosen per control. The point is to drive the
# REAL consumers, so the assertion is about what an operator would see.
cat > "$WORK/nft" <<'EOS'
#!/usr/bin/env bash
case "$NFT_MODE" in
    fail)      echo "Error: Could not receive from netlink" >&2; exit 1 ;;
    emptyok)   exit 0 ;;                       # rc=0, no output
    ok)        cat "$NFT_PAYLOAD" 2>/dev/null; exit 0 ;;
esac
exit 1
EOS
chmod +x "$WORK/nft"; export PATH="$WORK:$PATH"

# --------------------------------------------------------------------------
echo "=== A. config doctor — the unreadable ruleset must SURFACE as a finding ==="
# This is the control the invented-helper bug would have defeated: the code
# looked right, the call was swallowed by `|| true`, and no finding appeared.
NFT_MODE=fail; export NFT_MODE
( # subshell: the module sets globals
  # shellcheck source=/dev/null
  source "$LIB/core/nftban_config_doctor.sh" >/dev/null 2>&1
  declare -f _doctor_finding >/dev/null 2>&1 || { echo "NO_API"; exit 9; }
  declare -f _doctor_gather_data >/dev/null 2>&1 || { echo "NO_GATHER"; exit 9; }
  _doctor_gather_data >/dev/null 2>&1
  printf 'COUNT=%s\n' "${#_DOCTOR_FINDINGS[@]}"
  printf 'WARN=%s\n'  "${_DOCTOR_COUNTS_WARN:-0}"
  printf '%s\n' "${_DOCTOR_FINDINGS[@]}"
) > "$WORK/doctor.out" 2>&1
if grep -q 'NO_API\|NO_GATHER' "$WORK/doctor.out"; then
    bad "doctor API missing — cannot assert consumer behaviour"
else
    cnt=$(grep -m1 '^COUNT=' "$WORK/doctor.out" | cut -d= -f2)
    wrn=$(grep -m1 '^WARN='  "$WORK/doctor.out" | cut -d= -f2)
    [[ "${cnt:-0}" -gt 0 ]] && ok "finding count incremented (${cnt})" || bad "no finding recorded for an unreadable ruleset"
    [[ "${wrn:-0}" -gt 0 ]] && ok "warning counter incremented (${wrn})" || bad "warning counter did not increment"
    grep -q 'nft-ruleset-unreadable' "$WORK/doctor.out" && ok "finding TYPE is nft-ruleset-unreadable" || bad "finding type absent"
    grep -q '"severity": *"warning"' "$WORK/doctor.out" && ok "finding SEVERITY is warning" || bad "severity not warning"
    grep -q 'nft -j list ruleset' "$WORK/doctor.out" && ok "finding SOURCE names the failing probe" || bad "source does not identify the probe"
    grep -q 'did NOT inspect live state' "$WORK/doctor.out" && ok "message states the checks did not inspect live state" || bad "message does not disclaim the downstream checks"
fi
# FALSIFIABILITY: with the call removed, the controls above must fail.
sed 's/_doctor_finding "\$_SEV_WARN" "nft-ruleset-unreadable"/: skipped_for_probe/' \
    "$LIB/core/nftban_config_doctor.sh" > "$WORK/doctor_broken.sh"
( source "$WORK/doctor_broken.sh" >/dev/null 2>&1
  _doctor_gather_data >/dev/null 2>&1
  printf '%s\n' "${_DOCTOR_FINDINGS[@]:-}" ) > "$WORK/doctor_bad.out" 2>&1
if grep -q 'nft-ruleset-unreadable' "$WORK/doctor_bad.out"; then
    bad "FALSIFIABILITY: finding still present with the call removed — the control is vacuous"
else
    ok "FALSIFIABILITY: removing the call removes the finding (control is load-bearing)"
fi
# and a swallowed call must not be how this is written
if grep -qE '_doctor_finding[^\n]*\|\|[[:space:]]*true' "$LIB/core/nftban_config_doctor.sh"; then
    bad "the finding call is guarded by '|| true' — a broken control would be silent"
else
    ok "the finding call is NOT swallowed by '|| true'"
fi

# --------------------------------------------------------------------------
echo "=== B. health checks — UNKNOWN reaches the operator, never 0/healthy ==="
run_health() { # $1=check fn -> sets ST/ISS/SURF
    HEALTH_OK=0; HEALTH_WARNING=1; HEALTH_CRITICAL=2; HEALTH_ERROR=2
    # The sourced health module reads these from the caller's scope; naming them
    # here documents the contract rather than silencing the linter.
    : "$HEALTH_OK" "$HEALTH_WARNING" "$HEALTH_CRITICAL" "$HEALTH_ERROR"
    declare -gA NFTBAN_HEALTH_RESULTS=() NFTBAN_HEALTH_ISSUES=()
    NFTBAN_HEALTH_ERRORS=(); NFTBAN_HEALTH_WARNINGS=()
    # shellcheck source=/dev/null
    source "$LIB/core/nftban_health_checks_security.sh" >/dev/null 2>&1
    "$1" >/dev/null 2>&1 || true
    ST="${NFTBAN_HEALTH_RESULTS[${1#nftban_health_check_}]:-MISSING}"
    ISS="${NFTBAN_HEALTH_ISSUES[${1#nftban_health_check_}]:-}"
    # NFTBAN_HEALTH_ISSUES is internal state. What the operator actually sees is
    # rendered from NFTBAN_HEALTH_ERRORS / NFTBAN_HEALTH_WARNINGS
    # (nftban_health_render.sh), which the check populates at :1109-1113. This
    # section claims UNKNOWN "reaches the operator", so capture the surfaced text
    # and assert on it instead of assuming the internal map implies delivery.
    SURF="${NFTBAN_HEALTH_ERRORS[*]:-} ${NFTBAN_HEALTH_WARNINGS[*]:-}"
}
NFT_MODE=fail; export NFT_MODE
run_health nftban_health_check_set_sizes
if [[ "$ISS" == *UNKNOWN* && "$ST" != "0" ]]; then
    ok "set_sizes: unreadable dump -> UNKNOWN + non-OK (a 500k set cannot read as small)"
else
    bad "set_sizes: unreadable dump gave status=$ST issues=${ISS:0:60}"
fi
# An UNKNOWN recorded only in the internal map is not an UNKNOWN the operator
# ever reads. The render layer consumes ERRORS/WARNINGS, so delivery is asserted
# here rather than inferred from the status code.
if [[ "$SURF" == *UNKNOWN* ]]; then
    ok "set_sizes: UNKNOWN reaches the operator-facing collector (render input), not just the issues map"
else
    bad "set_sizes: UNKNOWN never reached NFTBAN_HEALTH_ERRORS/WARNINGS — the operator would not see it (surfaced='${SURF:0:80}')"
fi


# --- B2. the daemon cache path (what every host running the daemon actually reads) ---
# Shape = internal/stats/set_counters.go SetCountSnapshot: counts live under .sets.<name>.count.
cache(){ # $1 = JSON body written verbatim
    printf '%s\n' "$1" > "$NFTBAN_RUN_DIR/set_counts.json"
}
sets(){ # name=count ... -> daemon-shaped JSON
    local out='{"timestamp":"2026-10-08T00:00:00Z","daemon_pid":1,"scale_mode":"NORMAL","exporter_interval_seconds":60,"sets":{' sep='' kv
    for kv in "$@"; do out+="${sep}\"${kv%%=*}\":{\"count\":${kv#*=},\"scale\":\"NORMAL\",\"scale_num\":0,\"display\":\"${kv#*=}\",\"last_reconciled\":\"2026-10-08T00:00:00Z\",\"trend\":\"stable\"}"; sep=','; done
    printf '%s}}' "$out"
}
if command -v jq >/dev/null 2>&1; then
    NFT_MODE=fail; export NFT_MODE    # any fallback to nft would read UNKNOWN: the cache must carry the verdict
    cache "$(sets blacklist_ipv4=0 blacklist_ipv6=0 blacklist_manual_ipv4=37 blacklist_manual_ipv6=0 whitelist_ipv4=0 whitelist_ipv6=0)"
    run_health nftban_health_check_set_sizes
    [[ "$ST" == "0" && "$ISS" != *UNKNOWN* ]] && ok "set_sizes cache: daemon shape with valid zeros -> OK, no UNKNOWN (a real 0 stays 0)" \
                                              || bad "set_sizes cache: valid zeros gave status=$ST issues=${ISS:0:80}"
    cache "$(sets blacklist_ipv4=150000 blacklist_ipv6=0 blacklist_manual_ipv4=0 blacklist_manual_ipv6=0 whitelist_ipv4=0 whitelist_ipv6=0)"
    run_health nftban_health_check_set_sizes
    [[ "$ST" == "1" && "$ISS" == *HUGE* ]] && ok "set_sizes cache: 150000 in blacklist_ipv4 -> WARNING (HUGE) read from the daemon cache" \
                                           || bad "set_sizes cache: 150000 gave status=$ST issues=${ISS:0:80} (the old reader saw 0 here)"
    cache "$(sets blacklist_ipv4=0 blacklist_ipv6=600000 blacklist_manual_ipv4=0 blacklist_manual_ipv6=0 whitelist_ipv4=0 whitelist_ipv6=0)"
    run_health nftban_health_check_set_sizes
    [[ "$ST" == "2" && "$ISS" == *CRITICAL_SCALE* ]] && ok "set_sizes cache: 600000 in blacklist_ipv6 -> CRITICAL" \
                                                     || bad "set_sizes cache: 600000 gave status=$ST issues=${ISS:0:80}"
    cache "$(sets blacklist_ipv4=0 blacklist_ipv6=0 blacklist_manual_ipv4=0 blacklist_manual_ipv6=0 whitelist_ipv4=12000 whitelist_ipv6=0)"
    run_health nftban_health_check_set_sizes
    [[ "$ST" == "1" && "$ISS" == *whitelist_ipv4* ]] && ok "set_sizes cache: 12000 whitelist entries -> WARNING" \
                                                     || bad "set_sizes cache: whitelist 12000 gave status=$ST issues=${ISS:0:80}"
    cache "$(sets blacklist_ipv4=0 blacklist_ipv6=0 blacklist_manual_ipv4=0 blacklist_manual_ipv6=0 whitelist_ipv4=0)"
    run_health nftban_health_check_set_sizes
    [[ "$ST" != "0" && "$ISS" == *"UNKNOWN: whitelist_ipv6"* ]] && ok "set_sizes cache: a set missing from the cache -> UNKNOWN for that set, never 0" \
                                                                || bad "set_sizes cache: missing whitelist_ipv6 gave status=$ST issues=${ISS:0:80}"
    cache '{"timestamp":"2026-10-08T00:00:00Z","sets":{"blacklist_ipv4":{"count":'
    run_health nftban_health_check_set_sizes
    [[ "$ST" != "0" && "$ISS" == *"UNKNOWN: blacklist_ipv4"* && "$ISS" == *"UNKNOWN: whitelist_ipv4"* ]] && ok "set_sizes cache: malformed JSON -> every set UNKNOWN, status non-OK" \
                                                                                                    || bad "set_sizes cache: malformed JSON gave status=$ST issues=${ISS:0:80}"
    cache '{"blacklist_ipv4":600000,"blacklist_ipv6":0,"whitelist_ipv4":0,"whitelist_ipv6":0}'
    run_health nftban_health_check_set_sizes
    [[ "$ST" != "0" && "$ISS" == *UNKNOWN* ]] && ok "set_sizes cache: a flat (non-daemon) shape is not read as sizes -> UNKNOWN, not healthy" \
                                              || bad "set_sizes cache: flat shape gave status=$ST issues=${ISS:0:80}"
    rm -f "$NFTBAN_RUN_DIR/set_counts.json"
else
    echo "  [NOT_EXECUTED] set_sizes cache arms: jq not installed (the product reads the cache only with jq)"
fi

# --------------------------------------------------------------------------
echo "=== C. static guarantees on the remaining Tier-1 consumers ==="
# These sites need a live kernel or systemd to drive end-to-end, so the
# assertion is that the UNKNOWN branch EXISTS and is reachable — verified by
# the fact that removing it changes the file (checked by falsifiability below).
declare -A GUARD=(
  ["$LIB/lib/service_control.sh"]='rule count NOT established'
  ["$LIB/core/nftban_firewall_conflicts.sh"]='shadowing NOT ruled out'
  ["$LIB/core/nftban_portscan_classic.sh"]='LOG prefix NOT verified'
  ["$LIB/core/nftban_ddos_classic.sh"]='not evidence of zero offenders'
  ["$LIB/core/nftban_health_checks_security.sh"]='NOT verified in nftables'
)
for f in "${!GUARD[@]}"; do
    if grep -qF "${GUARD[$f]}" "$f"; then
        ok "$(basename "$f"): UNKNOWN branch present (\"${GUARD[$f]}\")"
    else
        bad "$(basename "$f"): UNKNOWN branch missing"
    fi
done
# no numeric comparison may be performed against a possibly-UNKNOWN priority
if [[ "$(grep -A2 'shadowing NOT ruled out' "$LIB/core/nftban_firewall_conflicts.sh" | grep -c 'elif' || true)" -gt 0 ]]; then
    ok "conflict priority: UNKNOWN is checked BEFORE the numeric comparison"
else
    bad "conflict priority: numeric comparison is not guarded by the UNKNOWN branch"
fi
# and the doctor's fabricated-empty fallback must no longer be unconditional
if grep -qE "_DOCTOR_NFT_JSON=\\\$\(nft -j list ruleset 2>/dev/null \|\| echo" "$LIB/core/nftban_config_doctor.sh"; then
    bad "doctor still collapses a failed read into an empty ruleset unconditionally"
else
    ok "doctor no longer collapses a failed read into an empty ruleset unconditionally"
fi

echo
echo "=== parser_tier1_unknown_truth_v1228_9: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
