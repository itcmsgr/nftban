#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - DDoS status: a chain with its jump but 0 rules is not ENABLED
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="ddos_status_empty_chain_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="BUG-DDOS-STATUS-REPORTS-CHAIN-ACTIVE-WITH-ZERO-RULES (v1.235). lab3 witness 2026-09-24: after `systemctl stop nftband` ddos_protection and ddos_prefix were flushed EMPTY with their input jumps kept, and `nftban ddos status` printed 'ENABLED (chain + jump active)'. Drives the REAL nftban_ddos_classic_status (core/nftban_ddos_classic.sh) under the dispatcher's plane for `ddos status` (set -Eeuo pipefail, default IFS, `main || exit`) against a stub nft whose `nft -j list chain` returns a chosen rule count per chain. Arms: T1 every chain has rules -> 8 ENABLED lines with the count; T2 the witness shape (protection + prefix 0 rules, v4 and v6) -> those 4 lines EMPTY / NOT protecting, sanity and synproxy stay ENABLED; T3 `nft -j` fails for ddos_protection -> UNKNOWN, never ENABLED; T4 unreadable JSON -> UNKNOWN; every arm: no ERR-trap banner. Regression test only: the packaged-candidate confirmation is the RC smoke DDoS-stop row. Set DDOS_EC_SUBJECT_ROOT to an older tree (e.g. e79a1173): T2/T3/T4 FAIL there."
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos_classic.sh"
# meta:inventory.binaries="bash,grep,jq,mktemp"
# meta:inventory.env_vars="DDOS_EC_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="ddos_status_empty_chain_v1235_test"
# meta:ta.owner="ddos"
# meta:ta.module="ddos-status-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${DDOS_EC_SUBJECT_ROOT:-$REPO}"
LIB="$ROOT/cli/lib/nftban"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: DDoS status vs a chain with its jump and 0 rules ==="
[[ -f "$LIB/core/nftban_ddos_classic.sh" ]] \
    || { echo "  NOT_EXECUTED: subject files missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "  NOT_EXECUTED: jq missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/etc/conf.d/ddos" "$SB/log"
printf 'DDOS_SYNPROXY_ENABLED="true"\nDDOS_PREFIX_ENABLED="true"\n' > "$SB/etc/conf.d/ddos/classic.conf"

# Stub nft. Every DDoS chain exists and the input chains jump to all of them.
# R_<chain> = rule count for `nft -j list chain`, ERR = command fails, BAD = not JSON.
cat > "$SB/bin/nft" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-j" ]]; then
    shift
    [[ "$1 $2" == "list chain" ]] || exit 1
    c="$5"; v="R_${c}"; n="${!v:-3}"
    case "$n" in
        ERR) echo "Error: stub failure" >&2; exit 1 ;;
        BAD) echo "not json"; exit 0 ;;
    esac
    printf '{"nftables":[{"metainfo":{"json_schema_version":1}},{"chain":{"family":"%s","table":"%s","name":"%s"}}' "$3" "$4" "$c"
    for ((i = 0; i < n; i++)); do printf ',{"rule":{"family":"%s","table":"%s","chain":"%s","handle":%d}}' "$3" "$4" "$c" "$((i + 10))"; done
    printf ']}\n'
    exit 0
fi
case "$1 $2" in
    "list chain")
        if [[ "$5" == input ]]; then
            printf 'table %s %s {\n chain input {\n  jump ddos_sanity\n  jump ddos_synproxy\n  jump ddos_prefix\n  jump ddos_protection\n }\n}\n' "$3" "$4"
        fi
        exit 0 ;;
    "list table") exit 0 ;;
    "list set") exit 1 ;;
esac
exit 0
EOF
chmod 0755 "$SB/bin/nft"

# The dispatcher's plane for `nftban ddos status`: cli/sbin/nftban:30 and cmd_ddos.sh:33
# run `set -Eeuo pipefail` with the DEFAULT IFS (neither sources lib/strict.sh, whose
# IFS=$'\n\t' would keep the module's unquoted "$table" = "ip nftban" from splitting),
# and the dispatcher calls `main "$@" || exit $?` (cli/sbin/nftban:1688).
run_status(){ # <out name> [R_<chain>=value ...]
    local o="$1"; shift
    env -i PATH="$SB/bin:/usr/local/bin:/usr/bin:/bin" HOME="$SB" NFTBAN_LIB_DIR="$LIB" \
        NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LOG_DIR="$SB/log" NFTBAN_ENABLE_ERROR_LOGGING=0 "$@" \
        bash -c '
set -Eeuo pipefail
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_ddos_classic.sh"
main(){ nftban_ddos_classic_status; }
main "$@" || exit $?
' > "$SB/$o.out" 2> "$SB/$o.err" || echo "rc=$?" >> "$SB/$o.err"
}
# line <out> <section header> <family>: the first <family> line within 3 lines of the header.
line(){ awk -v h="$2" -v f="$3" 'index($0, h) {w = 4} w > 0 && index($0, f) {print; exit} w > 0 {w--}' "$SB/$1.out"; }
banner(){ # <out name> <arm>
    if grep -q 'ERROR: Script failed' "$SB/$1.out" "$SB/$1.err"; then no "$2 ERR-trap banner" "$(grep -m1 'Command:' "$SB/$1.err" || true)"
    else ok "$2 no ERR-trap banner"; fi
}

# T1 — every chain carries rules.
run_status t1
n_en="$(grep -c 'ENABLED (chain + jump active, 3 rules)' "$SB/t1.out" || true)"
if [[ "$n_en" == 8 ]] && ! grep -qE 'EMPTY|UNKNOWN' "$SB/t1.out"; then ok "T1 all chains with rules -> 8 ENABLED lines carrying the rule count"
else no "T1 rules present" "ENABLED lines=$n_en; $(tr '\n' '|' < "$SB/t1.out" | cut -c1-300)"; fi
banner t1 T1

# T2 — the lab3 witness shape: protection + prefix flushed, jumps kept.
run_status t2 R_ddos_protection=0 R_ddos_prefix=0
p4="$(line t2 'Stage 2 - Rate Limiting' 'IPv4')"; p6="$(line t2 'Stage 2 - Rate Limiting' 'IPv6')"
x4="$(line t2 'Stage 1.5 - Prefix Aggregation' 'IPv4')"; x6="$(line t2 'Stage 1.5 - Prefix Aggregation' 'IPv6')"
s4="$(line t2 'Stage 3 - Sanity Checks' 'IPv4')"
all="$p4|$p6|$x4|$x6"
n_empty=0
for x in "$p4" "$p6" "$x4" "$x6"; do [[ "$x" == *"EMPTY (chain + jump present, 0 rules: NOT protecting"* ]] && n_empty=$((n_empty + 1)); done
if [[ "$all" != *ENABLED* && "$n_empty" == 4 ]]; then
    ok "T2 witness shape -> rate-limit and prefix (v4+v6) EMPTY / NOT protecting, never ENABLED"
else no "T2 empty chains rendered as protecting" "$all"; fi
[[ "$s4" == *"ENABLED (chain + jump active, 3 rules)"* ]] && ok "T2 sanity (rules present) stays ENABLED" || no "T2 sanity line" "$s4"
banner t2 T2

# T3 — the count cannot be read: UNKNOWN, never a default ENABLED.
run_status t3 R_ddos_protection=ERR
p4="$(line t3 'Stage 2 - Rate Limiting' 'IPv4')"
[[ "$p4" == *"UNKNOWN (chain + jump present; rule count unreadable)"* ]] \
    && ok "T3 nft -j failure -> UNKNOWN, not ENABLED" || no "T3 unreadable count" "$p4"
banner t3 T3

# T4 — output that is not JSON.
run_status t4 R_ddos_prefix=BAD
x4="$(line t4 'Stage 1.5 - Prefix Aggregation' 'IPv4')"
[[ "$x4" == *"UNKNOWN"* && "$x4" != *ENABLED* ]] && ok "T4 unreadable JSON -> UNKNOWN" || no "T4 bad JSON" "$x4"
banner t4 T4

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
