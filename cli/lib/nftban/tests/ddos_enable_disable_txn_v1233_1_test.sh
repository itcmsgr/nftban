#!/usr/bin/env bash
# =============================================================================
# NFTBan - DDoS enable/disable TRANSACTION, stateful model (v1.233.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="ddos_enable_disable_txn_v1233_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-25"
# meta:description="T1 hermetic STATEFUL model of `nftban ddos enable|disable` (V1_234_0 claim-truth contract, owner rulings L1-L3; handle BUG-DDOS-ENABLE-DISABLE-STALE-INTENT-AND-SWALLOWED-TEARDOWN). Same harness shape as portscan_enable_disable_txn_v1233_1_test: a fake kernel (per-family chains, rules incl. DROP rules, sets with elements, the raw prerouting table) is read and written by a fake nft binary and by a fake daemon behind the REAL IPC client (fake socat); the intent file, the plan/generation authority, the reconcile root, the classic and suricata DDoS modules, the shared transaction engine and the CLI router arm are REAL product code, run under the product's strict mode with errexit suspended exactly as the router suspends it. Covers transitions (disabled->enable, idempotent enable, enabled->disable, idempotent disable with NO kernel write, never-projected disable, lab3-shaped partial enable), the IPC-down disable of live DROP rules (the lab3 ARM2 witness: rc!=0, DROP rules reported, never a success mark), suricata-mode enable/disable, restart-never-ready, lock busy and an interrupted record, plus a DERIVED fault matrix: pass 1 records every mutation primitive the command reaches (IPC apply/flush_set, nft -f/add/insert/delete/flush, intent writer, plan commit, transaction-record writes, systemctl restart, the daemon's start-up reconcile); pass k+1 fails primitive k before and after its effect. UNMEASURED arms fail every kernel query from query j onward (error, timeout, malformed) and must end DEGRADED. Witness arms reproduce the lab3 v1.233.0 signatures (teardown on enable; ENABLED (INACTIVE); success mark with 9 DROP rules per family retained) so the test FAILS against pre-fix sources. Stateless always-succeed stubs are not used for any transactional property."
# meta:ta.id="ddos_enable_disable_txn_v1233_1_test"
# meta:ta.owner="firewall"
# meta:ta.module="daemon-runtime-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="2400"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/cli/cmd_ddos.sh,cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_ddos_classic.sh,cli/lib/nftban/core/nftban_ddos_suricata.sh,cli/lib/nftban/lib/nft_fragment.sh,cli/lib/nftban/lib/module_authority.sh,cli/lib/nftban/lib/module_txn.sh"
# meta:inventory.binaries="bash,jq,python3,flock,grep,sed,awk"
# meta:inventory.env_vars="NFTBAN_ROOT,DDOS_TXN_TEST_FULL"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (fake nft/socat/systemctl on PATH; no real kernel, daemon or unit is touched)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
LIB="$ROOT/cli/lib/nftban"
FAILURES=0; CHECKS=0; RUNS=0; FMATRIX=(); UMATRIX=()
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { CHECKS=$((CHECKS + 1)); [[ -n "${VERBOSE:-}" ]] && echo "  ok    $1"; return 0; }
say()  { echo "$@"; }

echo "=== ddos enable/disable transaction — stateful model (v1.233.1) ==="
echo "subject root: $ROOT"

for f in "$LIB/cli/cmd_ddos.sh" "$LIB/core/nftban_ddos.sh" "$LIB/core/nftban_ddos_classic.sh" \
         "$LIB/core/nftban_ddos_suricata.sh" "$LIB/lib/nft_fragment.sh" \
         "$LIB/lib/module_authority.sh" "$ROOT/etc/nftban/conf.d/ddos/main.conf"; do
    [[ -f "$f" ]] || { echo "::error::SUBJECT_NOT_FOUND: $f"; exit 1; }
done
for b in jq python3 flock; do
    command -v "$b" >/dev/null 2>&1 || { echo "::error::NOT_EXECUTED: required tool '$b' missing (precondition, not a verdict)"; exit 2; }
done

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
export FAKE_T="$TMPD/t"
BIN="$TMPD/bin"; mkdir -p "$BIN" "$FAKE_T"
export FAKE_KERNEL_BIN="$BIN/nft"

# =============================================================================
# FAKE KERNEL + FAKE PRIMITIVE ACCOUNTING
# =============================================================================
# prim <name>: every MUTATION primitive the command reaches passes through here.
#   rc 0 proceed · rc 10 injected failure BEFORE the effect · rc 11 AFTER it
cat > "$FAKE_T/prim.sh" <<'PRIM'
prim() {
    local n
    n=$(( $(cat "$FAKE_T/pcount" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_T/pcount"
    echo "$n $1" >> "$FAKE_T/ptrace"
    if [[ "${FAIL_AT:-0}" == "$n" ]]; then
        echo "$n $1 ${FAULT_KIND:-before}" >> "$FAKE_T/pfired"
        if [[ "${FAULT_KIND:-before}" == "after" ]]; then return 11; fi
        return 10
    fi
    return 0
}
PRIM

# ---- fake nft ---------------------------------------------------------------
# State under $FAKE_K:
#   tables                          "<fam> <table>" lines
#   c/<fam>/<table>/<chain>         one "<handle>\t<rule text>" line per rule
#   ct/<fam>/<table>/<chain>        base-chain type line (optional)
#   s/<fam>/<table>/<set>           one element per line (file exists = set exists)
#   next_handle
# nft joins argv with spaces, so a fused "ip nftban" argument works as on a host.
cat > "$BIN/nft" <<'NFT'
#!/usr/bin/env bash
set -uo pipefail
IFS=$' \t\n'
K="$FAKE_K"
# shellcheck source=/dev/null
. "$FAKE_T/prim.sh"
annot=0; check=0; file=""
args=("$@")
while (( ${#args[@]} )); do
    case "${args[0]}" in
        -a) annot=1; args=("${args[@]:1}") ;;
        -c) check=1; args=("${args[@]:1}") ;;
        -f) file="${args[1]:-}"; args=("${args[@]:2}") ;;
        -j|-t|-n|-s) echo "UNSUPPORTED flag ${args[0]} in: $*" >> "$FAKE_T/unsupported"
                     echo "fake nft: unsupported flag ${args[0]}" >&2; exit 99 ;;
        *) break ;;
    esac
done
cmd="${args[*]:-}"
read -ra A <<<"$cmd"

enoent() { printf 'Error: Could not process rule: No such file or directory\n%s\n' "$1" >&2; return 1; }
ebusy()  { printf 'Error: Could not process rule: Device or resource busy\n%s\n' "$1" >&2; return 1; }
cdir() { printf '%s/c/%s/%s' "$1" "$2" "$3"; }
sdir() { printf '%s/s/%s/%s' "$1" "$2" "$3"; }
tdir() { printf '%s/ct/%s/%s' "$1" "$2" "$3"; }
have_table() { grep -qxF "$2 $3" "$1/tables" 2>/dev/null; }
next_handle() { local h; h=$(cat "$1/next_handle" 2>/dev/null || echo 100); echo $((h + 1)) > "$1/next_handle"; echo "$h"; }

apply_line() {  # <state-dir> <line> -> 0 ok, 1 error
    local S="$1" line="$2" f t c rest h tmp
    local -a w
    read -ra w <<<"$line"
    case "${w[0]:-} ${w[1]:-}" in
        "add table") have_table "$S" "${w[2]}" "${w[3]}" || echo "${w[2]} ${w[3]}" >> "$S/tables"
                     mkdir -p "$(cdir "$S" "${w[2]}" "${w[3]}")" "$(sdir "$S" "${w[2]}" "${w[3]}")" "$(tdir "$S" "${w[2]}" "${w[3]}")"; return 0 ;;
        "add chain") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     have_table "$S" "$f" "$t" || { enoent "$line"; return 1; }
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || : > "$(cdir "$S" "$f" "$t")/$c"
                     if [[ "$line" == *"{ type "* ]]; then
                         rest="${line#*\{ }"; rest="${rest% \}}"; mkdir -p "$(tdir "$S" "$f" "$t")"
                         printf '%s\n' "$rest" > "$(tdir "$S" "$f" "$t")/$c"
                     fi
                     return 0 ;;
        "flush chain") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     : > "$(cdir "$S" "$f" "$t")/$c"; return 0 ;;
        "add rule")  f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     rest="${line#*" $c "}"
                     local ref
                     for ref in $(grep -oE '@[A-Za-z0-9_]+' <<<"$rest" | tr -d '@'); do
                         [[ -e "$(sdir "$S" "$f" "$t")/$ref" ]] || { enoent "$line (set $ref)"; return 1; }
                     done
                     h=$(next_handle "$S")
                     printf '%s\t%s\n' "$h" "$rest" >> "$(cdir "$S" "$f" "$t")/$c"; return 0 ;;
        "insert rule") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     if [[ "${w[5]:-}" == "position" ]]; then
                         rest="${line#*position "${w[6]}" }"
                         grep -q "^${w[6]}	" "$(cdir "$S" "$f" "$t")/$c" || { enoent "$line"; return 1; }
                         h=$(next_handle "$S"); tmp="$(cdir "$S" "$f" "$t")/$c.tmp"
                         awk -v p="${w[6]}" -v h="$h" -v r="$rest" -F'\t' \
                             '$1==p{print h"\t"r} {print}' "$(cdir "$S" "$f" "$t")/$c" > "$tmp"
                         mv "$tmp" "$(cdir "$S" "$f" "$t")/$c"
                     else
                         rest="${line#*" $c "}"; h=$(next_handle "$S"); tmp="$(cdir "$S" "$f" "$t")/$c.tmp"
                         { printf '%s\t%s\n' "$h" "$rest"; cat "$(cdir "$S" "$f" "$t")/$c"; } > "$tmp"
                         mv "$tmp" "$(cdir "$S" "$f" "$t")/$c"
                     fi
                     return 0 ;;
        "delete rule") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     grep -q "^${w[6]:-x}	" "$(cdir "$S" "$f" "$t")/$c" || { enoent "$line"; return 1; }
                     tmp="$(cdir "$S" "$f" "$t")/$c.tmp"
                     awk -v p="${w[6]}" -F'\t' '$1!=p' "$(cdir "$S" "$f" "$t")/$c" > "$tmp"
                     mv "$tmp" "$(cdir "$S" "$f" "$t")/$c"; return 0 ;;
        "delete chain") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     if grep -qE "(^|[[:space:]])jump ${c}([[:space:]]|$)" "$(cdir "$S" "$f" "$t")"/* 2>/dev/null; then
                         ebusy "$line"; return 1
                     fi
                     rm -f "$(cdir "$S" "$f" "$t")/$c" "$(tdir "$S" "$f" "$t")/$c"; return 0 ;;
        "add set")   f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     have_table "$S" "$f" "$t" || { enoent "$line"; return 1; }
                     mkdir -p "$(sdir "$S" "$f" "$t")"
                     [[ -e "$(sdir "$S" "$f" "$t")/$c" ]] || : > "$(sdir "$S" "$f" "$t")/$c"; return 0 ;;
        "delete set") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(sdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     if grep -qE "@${c}([^A-Za-z0-9_]|$)" "$(cdir "$S" "$f" "$t")"/* 2>/dev/null; then
                         ebusy "$line"; return 1
                     fi
                     rm -f "$(sdir "$S" "$f" "$t")/$c"; return 0 ;;
        "flush set") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(sdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     : > "$(sdir "$S" "$f" "$t")/$c"; return 0 ;;
    esac
    echo "UNSUPPORTED statement: $line" >> "$FAKE_T/unsupported"
    printf 'Error: syntax error (fake nft does not model: %s)\n' "$line" >&2
    return 1
}

print_chain() {  # <fam> <table> <chain> <annot>
    local d; d="$(cdir "$K" "$1" "$2")"
    printf '\tchain %s {\n' "$3"
    if [[ -r "$(tdir "$K" "$1" "$2")/$3" ]]; then printf '\t\t%s\n' "$(cat "$(tdir "$K" "$1" "$2")/$3")"
    elif [[ "$3" == "input" ]]; then printf '\t\ttype filter hook input priority filter; policy accept;\n'; fi
    while IFS=$'\t' read -r h r; do
        [[ -n "$h" ]] || continue
        if (( $4 )); then printf '\t\t%s # handle %s\n' "$r" "$h"; else printf '\t\t%s\n' "$r"; fi
    done < "$d/$3"
    printf '\t}\n'
}
print_set() {  # <fam> <table> <set>
    local sf; sf="$(sdir "$K" "$1" "$2")/$3"
    printf '\tset %s {\n\t\ttype %s\n\t\tflags timeout\n' "$3" "$([[ "$1" == ip6 ]] && echo ipv6_addr || echo ipv4_addr)"
    if [[ -s "$sf" ]]; then printf '\t\telements = { %s }\n' "$(paste -sd, "$sf" | sed 's/,/, /g')"; fi
    printf '\t}\n'
}

query_gate() {
    local n
    n=$(( $(cat "$FAKE_T/qcount" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_T/qcount"
    echo "$n $cmd" >> "$FAKE_T/qtrace"
    if [[ -n "${QUERY_FAULT_FROM:-}" ]] && (( n >= QUERY_FAULT_FROM )); then
        echo "$n ${QUERY_FAULT_KIND:-fail}" >> "$FAKE_T/qfired"
        case "${QUERY_FAULT_KIND:-fail}" in
            fail)      echo "Error: cache initialization failed: Operation not permitted" >&2; exit 1 ;;
            timeout)   exit 124 ;;
            malformed) echo "<<garbled netlink dump>>"; exit 0 ;;
        esac
    fi
}

# ---------------- -f / -c -f -----------------------------------------------
if [[ -n "$file" ]]; then
    [[ -r "$file" ]] || { echo "Error: Could not open file \"$file\": No such file or directory" >&2; exit 1; }
    if (( check == 0 )) && [[ -z "${FAKE_NFT_INTERNAL:-}" ]]; then
        prim "nft:-f:$(basename "$file")"; pr=$?
        if (( pr == 10 )); then echo "Error: injected failure" >&2; exit 1; fi
    else
        pr=0
    fi
    W="$(mktemp -d "$FAKE_T/work.XXXXXX")"
    cp -a "$K/." "$W/"
    err=0
    while IFS= read -r l || [[ -n "$l" ]]; do
        l="${l#"${l%%[![:space:]]*}"}"
        [[ -z "$l" || "$l" == \#* ]] && continue
        if ! apply_line "$W" "$l" 2>>"$W/.err"; then err=1; break; fi
    done < "$file"
    if (( err )); then
        sed "s|^|${file}: |" "$W/.err" >&2; rm -rf "$W"; exit 1   # one transaction: nothing committed
    fi
    rm -f "$W/.err"
    if (( check == 0 )); then
        rm -rf "$K.old"; mv "$K" "$K.old"; mv "$W" "$K"; rm -rf "$K.old"
    else
        rm -rf "$W"
    fi
    (( pr == 11 )) && { echo "Error: injected failure after commit" >&2; exit 1; }
    exit 0
fi

# ---------------- reads -------------------------------------------------------
case "$cmd" in
    "list tables")
        query_gate; while read -r f t; do printf 'table %s %s\n' "$f" "$t"; done < "$K/tables"; exit 0 ;;
    "list sets "*)
        query_gate; fam="${A[2]:-}"
        while read -r f t; do
            [[ "$f" == "$fam" ]] || continue
            printf 'table %s %s {\n' "$f" "$t"
            for sf in "$(sdir "$K" "$f" "$t")"/*; do [[ -e "$sf" ]] && print_set "$f" "$t" "$(basename "$sf")"; done
            printf '}\n'
        done < "$K/tables"; exit 0 ;;
    "list set "*)
        query_gate; f="${A[2]:-}"; t="${A[3]:-}"; c="${A[4]:-}"
        if ! have_table "$K" "$f" "$t" || [[ ! -e "$(sdir "$K" "$f" "$t")/$c" ]]; then
            printf 'Error: No such file or directory\nlist set %s %s %s\n' "$f" "$t" "$c" >&2; exit 1
        fi
        printf 'table %s %s {\n' "$f" "$t"; print_set "$f" "$t" "$c"; printf '}\n'; exit 0 ;;
    "list ruleset")
        query_gate
        while read -r f t; do
            printf 'table %s %s {\n' "$f" "$t"
            for sf in "$(sdir "$K" "$f" "$t")"/*; do [[ -e "$sf" ]] && print_set "$f" "$t" "$(basename "$sf")"; done
            for c in "$(cdir "$K" "$f" "$t")"/*; do [[ -e "$c" ]] && print_chain "$f" "$t" "$(basename "$c")" "$annot"; done
            printf '}\n'
        done < "$K/tables"; exit 0 ;;
    "list chains "*)
        query_gate; fam="${A[2]:-}"
        while read -r f t; do
            [[ "$f" == "$fam" ]] || continue
            printf 'table %s %s {\n' "$f" "$t"
            for c in "$(cdir "$K" "$f" "$t")"/*; do
                [[ -e "$c" ]] || continue
                printf '\tchain %s {\n' "$(basename "$c")"
                if [[ -r "$(tdir "$K" "$f" "$t")/$(basename "$c")" ]]; then printf '\t\t%s\n' "$(cat "$(tdir "$K" "$f" "$t")/$(basename "$c")")"
                elif [[ "$(basename "$c")" == "input" ]]; then printf '\t\ttype filter hook input priority filter; policy accept;\n'; fi
                printf '\t}\n'
            done
            printf '}\n'
        done < "$K/tables"; exit 0 ;;
    "list chain "*)
        query_gate; f="${A[2]:-}"; t="${A[3]:-}"; c="${A[4]:-}"
        if ! have_table "$K" "$f" "$t" || [[ ! -e "$(cdir "$K" "$f" "$t")/$c" ]]; then
            printf 'Error: No such file or directory\nlist chain %s %s %s\n' "$f" "$t" "$c" >&2; exit 1
        fi
        printf 'table %s %s {\n' "$f" "$t"; print_chain "$f" "$t" "$c" "$annot"; printf '}\n'; exit 0 ;;
    "list table "*)
        query_gate; f="${A[2]:-}"; t="${A[3]:-}"
        have_table "$K" "$f" "$t" || { printf 'Error: No such file or directory\n' >&2; exit 1; }
        printf 'table %s %s {\n' "$f" "$t"
        for sf in "$(sdir "$K" "$f" "$t")"/*; do [[ -e "$sf" ]] && print_set "$f" "$t" "$(basename "$sf")"; done
        for c in "$(cdir "$K" "$f" "$t")"/*; do [[ -e "$c" ]] && print_chain "$f" "$t" "$(basename "$c")" "$annot"; done
        printf '}\n'; exit 0 ;;
esac

# ---------------- single mutating statements ---------------------------------
case "$cmd" in
    "add "*|"insert "*|"delete "*|"flush "*)
        verb="${A[0]}"
        pr=0
        if [[ -z "${FAKE_NFT_INTERNAL:-}" ]]; then prim "nft:${verb}"; pr=$?; fi
        if (( pr == 10 )); then echo "Error: injected failure" >&2; exit 1; fi
        apply_line "$K" "$cmd" || exit 1
        (( pr == 11 )) && { echo "Error: injected failure after effect" >&2; exit 1; }
        exit 0 ;;
esac
echo "UNSUPPORTED command: $cmd" >> "$FAKE_T/unsupported"
echo "fake nft: unsupported command: $cmd" >&2
exit 99
NFT

# ---- fake socat: the daemon's IPC endpoint ----------------------------------
cat > "$BIN/socat" <<'SOCAT'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "$FAKE_T/prim.sh"
req="$(cat)"
if [[ "$(cat "$FAKE_K/daemon" 2>/dev/null)" != "up" ]]; then
    echo "socat E connect(, AF=1 \"$FAKE_T/sock\"): Connection refused" >&2; exit 1
fi
method="$(jq -r '.method' <<<"$req" 2>/dev/null)"
case "$method" in
    ping) echo '{"success":true,"data":{"status":"pong"}}' ;;
    apply_ruleset)
        file="$(jq -r '.params.file' <<<"$req")"; chk="$(jq -r '.params.check' <<<"$req")"
        if [[ "$chk" == "true" ]]; then
            if out="$(FAKE_NFT_INTERNAL=1 "$FAKE_KERNEL_BIN" -c -f "$file" 2>&1)"; then echo '{"success":true}'
            else jq -nc --arg e "nft check failed: $out" '{success:false,error:$e}'; fi
            exit 0
        fi
        prim "ipc:apply_ruleset:$(basename "$file")"; pr=$?
        if (( pr == 10 )); then exit 1; fi
        if out="$(FAKE_NFT_INTERNAL=1 "$FAKE_KERNEL_BIN" -f "$file" 2>&1)"; then
            (( pr == 11 )) && exit 1
            echo '{"success":true,"data":{"status":"applied"}}'
        else
            (( pr == 11 )) && exit 1
            jq -nc --arg e "nft apply ruleset failed: exit status 1: $out" '{success:false,error:$e}'
        fi ;;
    flush_set)
        table="$(jq -r '.params.table' <<<"$req")"; set="$(jq -r '.params.set' <<<"$req")"
        prim "ipc:flush_set:$set"; pr=$?
        if (( pr == 10 )); then exit 1; fi
        tmpf="$FAKE_T/flush_set.$$.nft"; printf 'flush set %s %s\n' "$table" "$set" > "$tmpf"
        if out="$(FAKE_NFT_INTERNAL=1 "$FAKE_KERNEL_BIN" -f "$tmpf" 2>&1)"; then
            rm -f "$tmpf"; (( pr == 11 )) && exit 1
            echo '{"success":true}'
        else
            rm -f "$tmpf"; (( pr == 11 )) && exit 1
            jq -nc --arg e "flush set failed: $out" '{success:false,error:$e}'
        fi ;;
    *) echo "UNSUPPORTED ipc method: $method" >> "$FAKE_T/unsupported"
       echo '{"success":false,"error":"fake daemon: unsupported method"}' ;;
esac
SOCAT

# ---- fake systemctl: nftband lifecycle, mirroring internal/ddos/module.go ----
# Stop(): reconcile only if the module was enabled when the daemon started.
# Start(): reconcile only if the module is enabled now (the Start gate).
# The daemon runs in a CLEAN environment (env -i), as systemd would start it.
cat > "$BIN/systemctl" <<'SCTL'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "$FAKE_T/prim.sh"
intent_enabled() { grep -qE '^DDOS_ENABLED="?true' "$FAKE_CONF/conf.d/ddos/main.conf.local" 2>/dev/null; }
daemon_reconcile() {
    local rc=0
    env -i PATH="$PATH" HOME="$FAKE_T" TMPDIR="$TMPDIR" LANG=C \
        FAKE_K="$FAKE_K" FAKE_T="$FAKE_T" FAKE_CONF="$FAKE_CONF" FAKE_KERNEL_BIN="$FAKE_KERNEL_BIN" \
        FAIL_AT="${FAIL_AT:-0}" FAULT_KIND="${FAULT_KIND:-before}" \
        QUERY_FAULT_FROM="${QUERY_FAULT_FROM:-}" QUERY_FAULT_KIND="${QUERY_FAULT_KIND:-}" \
        FAKE_SURICATA="${FAKE_SURICATA:-}" \
        NFTBAN_CONFIG_DIR="$NFTBAN_CONFIG_DIR" NFTBAN_LIB_DIR="$NFTBAN_LIB_DIR" \
        NFTBAN_LOG_DIR="$NFTBAN_LOG_DIR" NFTBAN_DATA_DIR="$NFTBAN_DATA_DIR" \
        NFTBAN_CACHE_DIR="$NFTBAN_CACHE_DIR" NFTBAN_FRAGMENT_DIR="$NFTBAN_FRAGMENT_DIR" \
        NFTBAN_PLAN_RECORD_DIR="$NFTBAN_PLAN_RECORD_DIR" NFTBAN_RUN_DIR="$NFTBAN_RUN_DIR" \
        NFTBAN_PLAN_GENERATION_FILE="$NFTBAN_PLAN_GENERATION_FILE" \
        NFTBAN_DAEMON_SOCKET="$NFTBAN_DAEMON_SOCKET" NFTBAN_IPC_TIMEOUT="${NFTBAN_IPC_TIMEOUT:-5}" \
        bash --noprofile --norc -c 'source "$1" && nftban_ddos_reconcile' _ \
        "$NFTBAN_LIB_DIR/core/nftban_ddos.sh" >>"$FAKE_T/daemon.log" 2>&1 || rc=$?
    echo "$1 rc=$rc" >> "$FAKE_T/daemon_reconciles"
    return "$rc"
}
case "$*" in
    "is-active --quiet nftband"|"is-active nftband")
        [[ "$(cat "$FAKE_K/daemon" 2>/dev/null)" == "up" ]] || exit 3
        if [[ -n "${FAKE_NEVER_READY_AFTER_RESTART:-}" && -e "$FAKE_T/restarted" ]]; then exit 3; fi
        exit 0 ;;
    "restart nftband")
        prim "systemctl:restart"; pr=$?
        if (( pr == 10 )); then echo "Job for nftband.service failed (injected)" >&2; exit 1; fi
        if [[ "$(cat "$FAKE_K/enabled_at_start" 2>/dev/null)" == "true" ]]; then daemon_reconcile stop || true; fi
        echo up > "$FAKE_K/daemon"; touch "$FAKE_T/restarted"
        if intent_enabled; then echo true > "$FAKE_K/enabled_at_start"; daemon_reconcile start || true
        else echo false > "$FAKE_K/enabled_at_start"; fi
        (( pr == 11 )) && { echo "Job for nftband.service failed (injected after start)" >&2; exit 1; }
        exit 0 ;;
    "is-active --quiet suricata"|"is-active suricata")
        [[ "${FAKE_SURICATA:-}" == "up" ]] && exit 0
        exit 3 ;;
    *) echo "UNSUPPORTED systemctl: $*" >> "$FAKE_T/unsupported"; exit 3 ;;
esac
SCTL
# Suricata availability also consults service(8)/pgrep: both answer "not running".
printf '#!/usr/bin/env bash\nexit 3\n' > "$BIN/service"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/pgrep"
chmod +x "$BIN/nft" "$BIN/socat" "$BIN/systemctl" "$BIN/service" "$BIN/pgrep"

# =============================================================================
# THE WORLD: config (real shipped conf.d/ddos/*.conf), run dir, fake kernel
# =============================================================================
W="$TMPD/world"
export FAKE_K="$W/kernel" FAKE_CONF="$W/etc"
export NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_LIB_DIR="$LIB"
export NFTBAN_LOG_DIR="$W/log" NFTBAN_DATA_DIR="$W/data" NFTBAN_CACHE_DIR="$W/cache"
export NFTBAN_FRAGMENT_DIR="$W/etc/rules.d"
export NFTBAN_PLAN_RECORD_DIR="$W/run" NFTBAN_RUN_DIR="$W/run"
export NFTBAN_PLAN_GENERATION_FILE="$W/run/convergence-generation"
export NFTBAN_DAEMON_SOCKET="$W/run/nftband.sock"
export NFTBAN_IPC_TIMEOUT=5
export PATH="$BIN:$PATH"
export TMPDIR="$TMPD/tmp"; mkdir -p "$TMPDIR"

make_world() {  # fresh "never projected, disabled" host
    rm -rf "$W"; mkdir -p "$W"/{etc/conf.d/ddos,etc/rules.d,log,data,cache,run,kernel}
    cp "$ROOT/etc/nftban/conf.d/ddos/"*.conf "$W/etc/conf.d/ddos/"
    # Hermetic: the Suricata availability probe must not see a host binary or
    # a host EVE file.
    sed -i "s|^DDOS_SURICATA_BINARY=.*|DDOS_SURICATA_BINARY=\"$W/suricata-bin\"|" "$W/etc/conf.d/ddos/main.conf"
    sed -i "s|^DDOS_SURICATA_EVE_FILE=.*|DDOS_SURICATA_EVE_FILE=\"$W/log/eve-alerts.json\"|" "$W/etc/conf.d/ddos/suricata.conf"
    printf 'ip nftban\nip6 nftban\n' > "$FAKE_K/tables"
    echo 200 > "$FAKE_K/next_handle"
    local fam
    for fam in ip ip6; do
        mkdir -p "$FAKE_K/c/$fam/nftban" "$FAKE_K/s/$fam/nftban" "$FAKE_K/ct/$fam/nftban"
        printf '%s\n' \
            $'10\tct state invalid drop' \
            $'11\tcounter name anchor_trusted comment "NFTBAN_ANCHOR:ANCHOR_TRUSTED"' \
            $'12\tct state established,related accept' \
            $'13\tcounter name anchor_established comment "NFTBAN_ANCHOR:ANCHOR_ESTABLISHED"' \
            $'14\tcounter name anchor_service comment "NFTBAN_ANCHOR:ANCHOR_SERVICE"' \
            $'15\ttcp dport 22 accept' > "$FAKE_K/c/$fam/nftban/input"
    done
    echo up > "$FAKE_K/daemon"; echo false > "$FAKE_K/enabled_at_start"
    python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$NFTBAN_DAEMON_SOCKET"
}
snapshot() { rm -rf "$TMPD/snap.$1"; cp -a "$W" "$TMPD/snap.$1"; }
restore()  { rm -rf "$W"; cp -a "$TMPD/snap.$1" "$W"; }
reset_counters() { : > "$FAKE_T/ptrace"; : > "$FAKE_T/pfired"; echo 0 > "$FAKE_T/pcount"
                   : > "$FAKE_T/qtrace"; : > "$FAKE_T/qfired"; echo 0 > "$FAKE_T/qcount"
                   : > "$FAKE_T/daemon_reconciles"; rm -f "$FAKE_T/restarted"; }
: > "$FAKE_T/unsupported"

# =============================================================================
# INDEPENDENT ORACLES — read the world directly, never through product code
# =============================================================================
STAGES="ddos_sanity ddos_prefix ddos_protection ddos_penalty"   # required with shipped defaults
ALL_STAGES="ddos_sanity ddos_synproxy ddos_prefix ddos_protection ddos_penalty"
oracle_intent() {
    local v="false" f="$W/etc/conf.d/ddos/main.conf.local" line
    if [[ -f "$f" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^DDOS_ENABLED=\"?([a-z]+) ]] && v="${BASH_REMATCH[1]}"
        done < "$f"
    fi
    echo "$v"
}
oracle_drops() {  # <fam> -> total DROP rules in module chains
    local fam="$1" c n=0 cf
    for c in $ALL_STAGES; do
        cf="$FAKE_K/c/$fam/nftban/$c"
        [[ -e "$cf" ]] || continue
        n=$(( n + $(grep -cE '(^|[[:space:]])drop([[:space:]]|$)' "$cf" || true) ))
    done
    echo "$n"
}
oracle_kclass() {
    local fam c cf any=0 active=0 need=0 raw bl
    for fam in ip ip6; do
        for c in $ALL_STAGES; do
            cf="$FAKE_K/c/$fam/nftban/$c"
            [[ -s "$cf" ]] && any=1
        done
        raw="$FAKE_K/c/$fam/raw/prerouting"
        [[ -e "$raw" ]] && grep -q '"SYNPROXY:' "$raw" && any=1
        for c in $STAGES; do
            need=$((need + 1)); cf="$FAKE_K/c/$fam/nftban/$c"
            if [[ -s "$cf" ]] && grep -qE '(^|[[:space:]])drop([[:space:]]|$)' "$cf" \
               && grep -qE "jump ${c}([[:space:]]|$)" "$FAKE_K/c/$fam/nftban/input"; then
                active=$((active + 1))
            fi
        done
    done
    bl="$FAKE_K/s/ip/nftban/ddos_blocked"
    if (( active == need )); then echo CLASSIC_ACTIVE
    elif (( any == 1 )); then echo PARTIAL
    elif [[ -s "$bl" ]]; then echo SURICATA_BLOCKING
    else echo EMPTY; fi
}
oracle_gen() { local g=0; [[ -r "$NFTBAN_PLAN_GENERATION_FILE" ]] && read -r g < "$NFTBAN_PLAN_GENERATION_FILE"; echo "${g:-0}"; }
oracle_plan_eff() {
    local g; g="$(oracle_gen)"
    local f="$W/run/module-plan-ddos.env.$g"
    [[ -r "$f" ]] || { echo "none"; return 0; }
    sed -n 's/^NFTBAN_PLAN_EFFECTIVE_MODE=//p' "$f"
}
oracle_state() { echo "intent=$(oracle_intent) kernel=$(oracle_kclass) drops(ip/ip6)=$(oracle_drops ip)/$(oracle_drops ip6) plan=$(oracle_plan_eff)"; }

# =============================================================================
# RUN ONE COMMAND through the REAL router arm, under product strict mode
# =============================================================================
# The production router invokes `nftban_cmd_<x> "$@" || return $?`, so errexit
# is SUSPENDED for the whole call tree. The harness reproduces exactly that.
OUT="$TMPD/out"; ERR="$TMPD/err"; RCF="$TMPD/rc"
run_cmd() {  # <enable|disable|status>
    local op="$1"
    RUNS=$((RUNS + 1))
    (
        set -Eeuo pipefail
        # shellcheck source=/dev/null
        source "$LIB/lib/strict.sh"
        # shellcheck source=/dev/null
        source "$LIB/cli/cmd_ddos.sh"
        # shellcheck source=/dev/null
        source "$LIB/lib/module_authority.sh"
        # shellcheck source=/dev/null
        source "$LIB/core/nftban_ddos.sh"
        # --- function-level mutation primitives (fault shim) ---------------------
        # shellcheck source=/dev/null
        . "$FAKE_T/prim.sh"
        wrap() {  # <fn> <prim-name>
            local fn="$1" pn="$2"
            declare -F "$fn" >/dev/null 2>&1 || return 0
            eval "__real_${fn}$(declare -f "$fn" | sed '1s/^[^ ]*//')"
            eval "${fn}() { local _pr=0; prim \"${pn}\" || _pr=\$?; if (( _pr == 10 )); then return 1; fi; __real_${fn} \"\$@\"; local _rc=\$?; if (( _pr == 11 )); then return 1; fi; return \$_rc; }"
        }
        wrap nftban_module_set_enabled "intent:set"
        wrap nftban_plan_txn_commit "plan:commit"
        wrap _nftban_ddos_txn_record_write "txn:record"
        if [[ -n "${FAKE_FAST_SLEEP:-}" ]]; then sleep() { :; }; fi
        rc=0
        nftban_cmd_ddos "$op" >"$OUT" 2>"$ERR" || rc=$?
        echo "$rc" > "$RCF"
    ) || echo "HARNESS_SUBSHELL_RC=$?" >> "$ERR"
    [[ -s "$RCF" ]] || { echo 255 > "$RCF"; echo "HARNESS: subject did not complete" >> "$ERR"; }
}

outcome_of() { sed -n '/^NFTBAN_OUTCOME=/{s/^NFTBAN_OUTCOME=\([A-Z_]*\) .*/\1/p;q;}' "$OUT"; }
rc_for() { case "$1" in CONVERGED) echo 0;; FAILED_ROLLED_BACK) echo 1;; DEGRADED) echo 3;; PENDING_TIMED_OUT) echo 4;; REFUSED) echo "5|7";; *) echo "?";; esac; }
EXPECT_EFF_ENABLE="classic"
expected_kclass() { if [[ "$1" == "enable" ]]; then [[ "$EXPECT_EFF_ENABLE" == suricata ]] && echo "EMPTY|SURICATA_BLOCKING" || echo CLASSIC_ACTIVE; else echo "EMPTY"; fi; }
expected_eff() { [[ "$1" == "enable" ]] && echo "$EXPECT_EFF_ENABLE" || echo inactive; }
rec_field() { sed -n "s/^$1=//p" "$W/run/module-txn-ddos.env" 2>/dev/null; }

# check_invariants <label> <op> <pre-intent> <pre-kclass> <pre-gen> <pre-record-sum> <pre-eff>
check_invariants() {
    local label="$1" op="$2" pintent="$3" pk="$4" pgen="$5" precsum="$6" peff="${7:-classic}"
    local rc outc n want post_i post_k post_e post_g recphase recout expected_rc
    rc="$(cat "$RCF")"
    n=$(grep -c '^NFTBAN_OUTCOME=' "$OUT" || true)
    outc="$(outcome_of)"
    want=$([[ "$op" == enable ]] && echo true || echo false)
    post_i="$(oracle_intent)"; post_k="$(oracle_kclass)"; post_e="$(oracle_plan_eff)"; post_g="$(oracle_gen)"
    local ctx="[$label rc=$rc outcome=${outc:-none} state: intent=$post_i kernel=$post_k plan=$post_e gen=$post_g]"

    if [[ "$n" != "1" ]]; then fail "$ctx expected exactly ONE NFTBAN_OUTCOME record, found $n"; return 0; fi
    ok "$label one outcome record"
    expected_rc="$(rc_for "$outc")"
    if [[ "|$expected_rc|" != *"|$rc|"* ]]; then fail "$ctx rc does not match the outcome table (expected $expected_rc)"; else ok "$label rc/outcome agree"; fi
    if [[ "$outc" != "CONVERGED" ]]; then
        if grep -q '✅' "$OUT" "$ERR"; then fail "$ctx a success mark was printed for a non-CONVERGED outcome: $(grep -h -m1 '✅' "$OUT" "$ERR")"; else ok "$label no success mark"; fi
        [[ "$rc" != "0" ]] || fail "$ctx non-CONVERGED outcome with rc 0"
    elif (( $(grep -c '✅' "$OUT" || true) != 1 )); then
        fail "$ctx CONVERGED must print exactly one success mark (found $(grep -c '✅' "$OUT" || true)): $(grep -h '✅' "$OUT" | tr '\n' '|')"
    fi
    local reason; reason="$(sed -n 's/^NFTBAN_OUTCOME=.* reason=//p' "$OUT")"
    [[ -n "$reason" ]] || fail "$ctx outcome record carries no reason"

    case "$outc" in
        CONVERGED)
            [[ "$post_i" == "$want" ]] || fail "$ctx CONVERGED but intent is $post_i"
            [[ "|$(expected_kclass "$op")|" == *"|$post_k|"* ]] || fail "$ctx CONVERGED but the kernel is $post_k (expected $(expected_kclass "$op"))"
            [[ "$post_e" == "$(expected_eff "$op")" ]] || fail "$ctx CONVERGED but the committed plan says $post_e"
            if [[ "$op" == disable ]] && (( $(oracle_drops ip) + $(oracle_drops ip6) > 0 )); then
                fail "$ctx CONVERGED disable with DROP rules left in module chains (ip=$(oracle_drops ip) ip6=$(oracle_drops ip6))"
            fi
            if grep -q ' rc=[1-9]' "$FAKE_T/daemon_reconciles" 2>/dev/null && [[ ! -s "$FAKE_T/pfired" && ! -s "$FAKE_T/qfired" ]]; then
                fail "$ctx daemon start-up reconcile failed after a CONVERGED enable (lock not released before restart?): $(cat "$FAKE_T/daemon_reconciles")"
            fi ;;
        FAILED_ROLLED_BACK|REFUSED)
            [[ "$post_i" == "$pintent" ]] || fail "$ctx $outc but intent is $post_i (previous $pintent)"
            [[ "$post_k" == "$pk" ]] || fail "$ctx $outc but the kernel is $post_k (previous $pk)"
            if [[ "$pintent" == "false" ]]; then
                [[ "$post_e" == "inactive" || "$post_e" == "none" ]] || fail "$ctx $outc but the committed plan says $post_e over intent=false"
            else
                [[ "$post_e" == "$peff" ]] || fail "$ctx $outc but the committed plan says $post_e over intent=true (previous $peff)"
            fi
            if [[ "$outc" == "REFUSED" ]]; then
                [[ "$post_g" == "$pgen" ]] || fail "$ctx REFUSED but the generation moved $pgen -> $post_g"
                local nowsum; nowsum="$(cksum 2>/dev/null < "$W/run/module-txn-ddos.env" || echo none)"
                if [[ "$nowsum" != "$precsum" ]] \
                   && [[ "$(rec_field NFTBAN_TXN_PHASE)" != "CLOSED" || "$(rec_field NFTBAN_TXN_OUTCOME)" != "REFUSED" ]]; then
                    fail "$ctx REFUSED but the transaction record changed to a non-terminal/other state"
                fi
            fi ;;
        DEGRADED|PENDING_TIMED_OUT) : ;;
        *) fail "$ctx unknown outcome '$outc'" ;;
    esac

    if [[ "$outc" != "REFUSED" ]]; then
        recphase="$(rec_field NFTBAN_TXN_PHASE)"; recout="$(rec_field NFTBAN_TXN_OUTCOME)"
        if [[ "$recphase" == "CLOSED" ]]; then
            [[ "$recout" == "$outc" ]] || fail "$ctx record says $recout, printed $outc"
            [[ "$(rec_field NFTBAN_TXN_MODULE)" == "ddos" ]] || fail "$ctx transaction record module is '$(rec_field NFTBAN_TXN_MODULE)'"
        else
            if [[ "$outc" == "CONVERGED" ]]; then fail "$ctx CONVERGED with the transaction record not CLOSED (phase=$recphase)"; fi
            grep -q 'txn:record' "$FAKE_T/pfired" 2>/dev/null || fail "$ctx record left in phase '$recphase' without a record-write fault"
        fi
    fi
    return 0
}

arm() {  # <label> <snapshot> <op> [pre-eff]
    local label="$1" snap="$2" op="$3" peff="${4:-classic}" pi pk pg ps
    restore "$snap"; reset_counters
    pi="$(oracle_intent)"; pk="$(oracle_kclass)"; pg="$(oracle_gen)"
    ps="$(cksum 2>/dev/null < "$W/run/module-txn-ddos.env" || echo none)"
    run_cmd "$op"
    check_invariants "$label" "$op" "$pi" "$pk" "$pg" "$ps" "$peff"
}

# =============================================================================
# 1. TRANSITION MATRIX
# =============================================================================
say ""; say "1. transition matrix..."
unset FAIL_AT FAULT_KIND QUERY_FAULT_FROM QUERY_FAULT_KIND FAKE_FAST_SLEEP FAKE_NEVER_READY_AFTER_RESTART FAKE_SURICATA || true
make_world; snapshot DISABLED_ABSENT
reset_counters; run_cmd enable
check_invariants "T1 disabled(absent)->enable" enable false EMPTY 0 none
[[ "$(outcome_of)" == "CONVERGED" ]] && ok "T1 converged" || fail "T1 disabled(absent)->enable did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|') :: $(tail -n 5 "$ERR" | tr '\n' '|')"
# W1 — WITNESS lab3 ARM1: an enable must never tear the module down.
if grep -q '99-ddos-[a-z]*-cleanup\|99-ddos-synproxy-cleanup' "$FAKE_T/ptrace" \
   || grep -q 'Disabling DDoS Protection\|Removing DDoS runtime\|DDoS Protection DISABLED' "$OUT"; then
    fail "W1 TEARDOWN-ON-ENABLE: the enable path ran the disable/cleanup projection ($(grep -m1 -h 'cleanup\|Disabling DDoS\|DISABLED' "$FAKE_T/ptrace" "$OUT" || true))"
else ok "W1 enable never runs teardown"; fi
# W3 — the banner must not describe a stale plan.
if grep -q 'ENABLED (INACTIVE)\|ENABLED (UNKNOWN)' "$OUT"; then fail "W3 STALE BANNER: $(grep -m1 'ENABLED (' "$OUT")"; else ok "W3 banner mode from the committed plan"; fi
if grep -q 'now active' "$OUT"; then fail "W3b 'now active' claimed from a restart exit code: $(grep -m1 'now active' "$OUT")"; else ok "W3b no restart-rc activity claim"; fi
snapshot ENABLED
say "   after enable: $(oracle_state)"
ENABLE_PRIMS="$(cat "$FAKE_T/ptrace")"; ENABLE_Q="$(cat "$FAKE_T/qcount")"

reset_counters; run_cmd enable
check_invariants "T2 enabled->enable (idempotent)" enable true CLASSIC_ACTIVE "$(oracle_gen)" x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T2 idempotent enable did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|')"

restore ENABLED; reset_counters; run_cmd disable
check_invariants "T3 enabled->disable" disable true CLASSIC_ACTIVE 1 x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T3 enabled->disable did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|') :: $(tail -n 5 "$ERR" | tr '\n' '|')"
snapshot DISABLED_EMPTY
say "   after disable: $(oracle_state)"
DISABLE_PRIMS="$(cat "$FAKE_T/ptrace")"; DISABLE_Q="$(cat "$FAKE_T/qcount")"

reset_counters; run_cmd disable
check_invariants "T4 disabled->disable (idempotent)" disable false EMPTY "$(oracle_gen)" x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T4 idempotent disable did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|')"
if grep -q 'nft:\|ipc:' "$FAKE_T/ptrace"; then fail "T4 idempotent disable wrote the kernel: $(grep -m3 'nft:\|ipc:' "$FAKE_T/ptrace" | tr '\n' ' ')"; else ok "T4 no kernel write when already empty"; fi

restore DISABLED_EMPTY; reset_counters; run_cmd enable
check_invariants "T5 disabled(empty chains)->enable" enable false EMPTY "$(oracle_gen)" x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T5 enable from empty retained chains did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|')"

restore DISABLED_ABSENT; reset_counters; run_cmd disable
check_invariants "T6 disabled(absent)->disable (never projected)" disable false EMPTY 0 none
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T6 disable on a never-projected host did not CONVERGE (non-idempotent teardown): $(tail -n 3 "$OUT" | tr '\n' '|') :: $(tail -n 5 "$ERR" | tr '\n' '|')"
if grep -q 'nft:\|ipc:' "$FAKE_T/ptrace"; then fail "T6 never-projected disable wrote the kernel: $(grep -m3 'nft:\|ipc:' "$FAKE_T/ptrace" | tr '\n' ' ')"; else ok "T6 no kernel write when never projected"; fi

# The lab3 shape: enabled, prefix + protection chains empty (0 rules), sanity
# 5 DROP + penalty 4 DROP per family still jumped from input.
restore ENABLED
for fam in ip ip6; do : > "$FAKE_K/c/$fam/nftban/ddos_prefix"; : > "$FAKE_K/c/$fam/nftban/ddos_protection"; done
snapshot LAB3_SHAPE
say "   lab3 shape: $(oracle_state)"
if [[ "$(oracle_drops ip)" != "9" || "$(oracle_drops ip6)" != "9" ]]; then
    fail "L0 the lab3-shaped world does not hold 9 DROP rules per family ($(oracle_drops ip)/$(oracle_drops ip6)) — witness arms would be vacuous"
fi
arm "T7 lab3-shape enabled->enable (re-projects)" LAB3_SHAPE enable
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T7 enable over the lab3 partial projection did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|')"

# W2 — WITNESS lab3 ARM2: IPC down, 9 DROP rules per family live, `disable`.
restore LAB3_SHAPE; echo down > "$FAKE_K/daemon"; snapshot LAB3_IPC_DOWN
arm "W2 ipc-down lab3-shape->disable" LAB3_IPC_DOWN disable
if grep -q '✅' "$OUT" && (( $(oracle_drops ip) + $(oracle_drops ip6) > 0 )); then
    fail "W2 SUCCESS WITH RETAINED DROP RULES: '$(grep -m1 '✅' "$OUT")' rc=$(cat "$RCF") while the kernel still holds $(oracle_drops ip)/$(oracle_drops ip6) DDoS DROP rules (ip/ip6)"
fi
case "$(outcome_of)" in
    FAILED_ROLLED_BACK|DEGRADED) ok "W2 not a success" ;;
    *) fail "W2 expected FAILED_ROLLED_BACK or DEGRADED, got '$(outcome_of)' rc=$(cat "$RCF")" ;;
esac
[[ "$(cat "$RCF")" != "0" ]] || fail "W2 rc 0 on a disable that could not remove the DROP rules"
if grep -q '^NFTBAN_OUTCOME=.*ip/sanity=rules:6,drops:5.*ip6/sanity=rules:6,drops:5' "$OUT" && grep -q '^NFTBAN_OUTCOME=.*ip/penalty=rules:7,drops:4.*ip6/penalty=rules:7,drops:4' "$OUT"; then
    ok "W2 the retained DROP rules are reported in the outcome"
else
    fail "W2 the outcome does not report the retained DROP rules (sanity 5 / penalty 4): $(grep '^NFTBAN_OUTCOME=' "$OUT" | cut -c1-400)"
fi

restore ENABLED; echo down > "$FAKE_K/daemon"; snapshot ENABLED_IPC_DOWN
arm "T8 ipc-down enabled->disable" ENABLED_IPC_DOWN disable
[[ "$(cat "$RCF")" != "0" ]] || fail "T8 rc 0 with IPC down"

restore DISABLED_ABSENT; echo down > "$FAKE_K/daemon"; snapshot DISABLED_IPC_DOWN
arm "T9 ipc-down disabled->enable" DISABLED_IPC_DOWN enable
[[ "$(outcome_of)" == "FAILED_ROLLED_BACK" ]] || fail "T9 expected FAILED_ROLLED_BACK, got '$(outcome_of)'"

# PENDING: restart succeeds, daemon never becomes ready (bounded wait).
restore DISABLED_ABSENT; reset_counters
FAKE_FAST_SLEEP=1 FAKE_NEVER_READY_AFTER_RESTART=1 run_cmd enable
check_invariants "T10 restart-never-ready" enable false EMPTY 0 none
[[ "$(outcome_of)" == "PENDING_TIMED_OUT" ]] || fail "T10 expected PENDING_TIMED_OUT, got '$(outcome_of)'"

# REFUSED: the canonical lock is held by someone else.
restore ENABLED; reset_counters
T11_I="$(oracle_intent)"; T11_K="$(oracle_kclass)"; T11_G="$(oracle_gen)"
T11_S="$(cksum 2>/dev/null < "$W/run/module-txn-ddos.env" || echo none)"
exec {LK}>>"$W/run/nft_operations.lock"; flock -n "$LK"
run_cmd disable
eval "exec ${LK}>&-"
check_invariants "T11 lock-busy disable" disable "$T11_I" "$T11_K" "$T11_G" "$T11_S"
[[ "$(outcome_of)" == "REFUSED" && "$(cat "$RCF")" == "7" ]] || fail "T11 expected REFUSED rc 7, got '$(outcome_of)' rc $(cat "$RCF")"

# An interrupted record is never rendered as success by the transaction engine.
restore ENABLED
cat > "$W/run/module-txn-ddos.env" <<'REC'
NFTBAN_TXN_ID=test-open
NFTBAN_TXN_MODULE=ddos
NFTBAN_TXN_OP=enable
NFTBAN_TXN_PHASE=INTENT_PERSISTED
NFTBAN_TXN_OUTCOME=
NFTBAN_TXN_PID=999999
REC
S1_OUT="$(
    source "$LIB/lib/module_authority.sh"; source "$LIB/lib/module_txn.sh"
    nftban_mtxn_status_lines ddos; echo "UNSETTLED=${NFTBAN_MTXN_UNSETTLED}"
)" || true
if [[ "$S1_OUT" == *"INTERRUPTED"* && "$S1_OUT" == *"UNSETTLED=true"* && "$S1_OUT" != *"✅"* ]]; then
    ok "S1 interrupted ddos transaction visible, not success"
else
    fail "S1 the shared status reader does not report the interrupted ddos transaction: $(tr '\n' '|' <<<"$S1_OUT")"
fi

# Suricata mode: DDOS_MODE=suricata with Suricata available (fake binary,
# service, fresh EVE). The classic projection must be purged, the block-set
# drop rule projected; disable must flush the set.
restore ENABLED
printf 'DDOS_MODE="suricata"\n' >> "$W/etc/conf.d/ddos/main.conf.local"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/suricata-bin"; chmod +x "$W/suricata-bin"
: > "$W/log/eve-alerts.json"
snapshot SURI_FROM_CLASSIC
export FAKE_SURICATA=up EXPECT_EFF_ENABLE=suricata
touch "$W/log/eve-alerts.json"; reset_counters; run_cmd enable
check_invariants "T12 classic->suricata enable" enable true CLASSIC_ACTIVE "$(oracle_gen)" x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T12 suricata-mode enable did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|') :: $(tail -n 5 "$ERR" | tr '\n' '|')"
grep -q '@ddos_blocked' "$FAKE_K/c/ip/nftban/input" && ok "T12 block-set drop rule projected" || fail "T12 no block-set drop rule in ip input"
printf '192.0.2.10\n' > "$FAKE_K/s/ip/nftban/ddos_blocked" 2>/dev/null || fail "T12 no ddos_blocked set was created"
snapshot SURI_BLOCKING
say "   suricata blocking: $(oracle_state)"
arm "T13 suricata(blocking)->disable" SURI_BLOCKING disable suricata
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T13 suricata-mode disable did not CONVERGE: $(tail -n 3 "$OUT" | tr '\n' '|') :: $(tail -n 5 "$ERR" | tr '\n' '|')"
[[ -s "$FAKE_K/s/ip/nftban/ddos_blocked" ]] && fail "T13 the Suricata block set still holds elements after a CONVERGED disable"
restore SURI_BLOCKING; echo down > "$FAKE_K/daemon"; snapshot SURI_IPC_DOWN
arm "T14 ipc-down suricata(blocking)->disable" SURI_IPC_DOWN disable suricata
[[ "$(cat "$RCF")" != "0" ]] || fail "T14 rc 0 while the block set could not be flushed"
unset FAKE_SURICATA; EXPECT_EFF_ENABLE=classic

# Development convenience only (never set in CI): stop after the transition matrix.
if [[ -n "${DDOS_TXN_TEST_SMOKE:-}" ]]; then
    say "SMOKE: runs=$RUNS checks=$CHECKS failures=$FAILURES (sections 2-3 skipped — NOT a verdict)"
    exit 3
fi

# =============================================================================
# 2. DERIVED FAULT MATRIX — pass k+1 fails primitive k
# =============================================================================
say ""; say "2. derived fault matrix..."
declare -A BASE_SNAP=( [enable]=DISABLED_ABSENT [disable]=ENABLED )
declare -A BASE_PRIMS=( [enable]="$ENABLE_PRIMS" [disable]="$DISABLE_PRIMS" )
for op in enable disable; do
    N=$(printf '%s\n' "${BASE_PRIMS[$op]}" | grep -c . || true)
    if (( N == 0 )); then fail "F-$op pass 1 recorded ZERO mutation primitives — the shim observed nothing"; continue; fi
    say "   $op: $N primitives reached: $(printf '%s\n' "${BASE_PRIMS[$op]}" | awk '{print $2}' | tr '\n' ' ')"
    for kind in before after; do
        for (( k = 1; k <= N; k++ )); do
            export FAIL_AT="$k" FAULT_KIND="$kind" FAKE_FAST_SLEEP=1
            arm "F-$op k=$k/$N($(printf '%s\n' "${BASE_PRIMS[$op]}" | sed -n "${k}p" | awk '{print $2}')) $kind" "${BASE_SNAP[$op]}" "$op"
            [[ -s "$FAKE_T/pfired" ]] || fail "F-$op k=$k $kind: the injected fault never fired (primitive sequence not deterministic?)"
            FMATRIX+=("$op k=$k $kind $(sed -n "${k}p" <<<"${BASE_PRIMS[$op]}" | awk '{print $2}') -> $(outcome_of) rc=$(cat "$RCF") [$(oracle_state)]")
        done
    done
    unset FAIL_AT FAULT_KIND FAKE_FAST_SLEEP
done

# 2b. no plan generation may be committed for a failed classic stage apply.
say ""; say "2b. enable with each classic stage apply failing (no commit on a failed apply)..."
for frag in 12-ddos-sanity 18-ddos-prefix 20-ddos-classic 07-ddos-penalty-enforce; do
    KA="$(awk -v f="ipc:apply_ruleset:${frag}" '$2 ~ "^"f {print $1; exit}' <<<"$ENABLE_PRIMS")"
    if [[ -z "$KA" ]]; then fail "A1 the enable pass never reached the ${frag} apply — arm cannot be executed"; continue; fi
    restore DISABLED_ABSENT; reset_counters
    A1_G="$(oracle_gen)"
    FAIL_AT="$KA" FAULT_KIND=before FAKE_FAST_SLEEP=1 run_cmd enable
    check_invariants "A1 enable, ${frag} apply fails" enable false EMPTY "$A1_G" none
    committed_before_rollback="$(awk -v k="$KA" '
        $1 > k && $2 ~ /^intent:set/ {exit}
        $1 > k && $2 == "plan:commit" {print $1; exit}' "$FAKE_T/ptrace")"
    if [[ -n "$committed_before_rollback" ]]; then
        fail "A1 COMMIT ON FAILED APPLY: plan:commit (#$committed_before_rollback) after the failed ${frag} apply (#$KA), before any rollback — outcome $(outcome_of)"
    else ok "A1 ${frag}: no generation committed for the failed apply"; fi
    [[ "$(cat "$RCF")" != "0" ]] || fail "A1 rc 0 for an enable whose ${frag} rules were never applied"
    say "   A1 ${frag}: outcome=$(outcome_of) rc=$(cat "$RCF") state: $(oracle_state) gen=$(oracle_gen)"
done

# =============================================================================
# 3. UNMEASURED ARMS — every kernel query from j onward fails
# =============================================================================
say ""; say "3. unmeasured arms (query failure / timeout / malformed)..."
declare -A BASE_Q=( [enable]="$ENABLE_Q" [disable]="$DISABLE_Q" )
KINDS=(fail timeout malformed)
for op in enable disable; do
    Q="${BASE_Q[$op]}"
    (( Q > 0 )) || { fail "U-$op pass 1 made ZERO kernel queries — no postcondition was ever read"; continue; }
    # Sampled unless DDOS_TXN_TEST_FULL=1: j=1, j=Q and a stride that yields ~16
    # points per kind. Each point fails EVERY query from j on, so any j inside a
    # postcondition window exercises that window.
    stride=$(( Q / 16 )); (( stride >= 1 )) || stride=1
    say "   $op: $Q kernel queries in pass 1; stride ${stride}${DDOS_TXN_TEST_FULL:+ (FULL: every j)}"
    for qk in "${KINDS[@]}"; do
        for (( j = 1; j <= Q; j++ )); do
            if [[ -z "${DDOS_TXN_TEST_FULL:-}" ]] && (( j != 1 && j != Q && j % stride != 0 )); then continue; fi
            export QUERY_FAULT_FROM="$j" QUERY_FAULT_KIND="$qk" FAKE_FAST_SLEEP=1
            arm "U-$op j=$j/$Q $qk" "${BASE_SNAP[$op]}" "$op"
            oc="$(outcome_of)"
            if [[ "$oc" == "CONVERGED" ]]; then
                fail "U-$op j=$j $qk: CONVERGED although kernel queries from #$j on were $qk (postcondition UNMEASURED)"
            elif [[ "$oc" != "DEGRADED" ]]; then
                fail "U-$op j=$j $qk: expected DEGRADED for an UNMEASURED postcondition, got '$oc'"
            fi
            UMATRIX+=("$op j=$j $qk -> $oc rc=$(cat "$RCF")")
        done
    done
    unset QUERY_FAULT_FROM QUERY_FAULT_KIND FAKE_FAST_SLEEP
done

if [[ -s "$FAKE_T/unsupported" ]]; then
    fail "the fake kernel was driven outside its model (test incomplete, not a pass): $(sort -u "$FAKE_T/unsupported" | awk 'NR<=5' | tr '\n' '|')"
fi

# =============================================================================
say ""
say "fault matrix (op k kind primitive -> outcome):"
for l in "${FMATRIX[@]}"; do say "   $l"; done
say "fault matrix summary: $(printf '%s\n' "${FMATRIX[@]}" | awk '{for(i=1;i<=NF;i++) if($i=="->") print $1" "$(i+1)" "$(i+2)}' | sort | uniq -c | tr '\n' ';')"
say "unmeasured matrix: $(printf '%s\n' "${UMATRIX[@]}" | awk '{print $1" "$NF" "$(NF-1)}' | sort | uniq -c | tr '\n' ';')"
say ""
say "runs=$RUNS checks=$CHECKS failures=$FAILURES"
if (( FAILURES > 0 )); then
    echo "::error::ddos enable/disable transaction model FAILED: $FAILURES"
    exit 1
fi
echo "ddos enable/disable transaction model PASSED"
