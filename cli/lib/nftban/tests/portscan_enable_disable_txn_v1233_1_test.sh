#!/usr/bin/env bash
# =============================================================================
# NFTBan - portscan enable/disable TRANSACTION, stateful model (v1.233.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_enable_disable_txn_v1233_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-24"
# meta:description="T1 hermetic STATEFUL model of `nftban portscan enable|disable` (V1_234_0 claim-truth contract, owner rulings L1-L3). A fake kernel (a chain/rule store on disk) is read and written by a fake nft binary and by a fake daemon behind the REAL IPC client (fake socat); the intent file, the plan/generation authority, the reconcile root, the classic module and the CLI router arm are all REAL product code, run under the product's strict mode with errexit suspended exactly as the router suspends it. Covers the transition matrix (disabled->enable, enabled->disable, idempotent repeats, IPC down) and a DERIVED fault matrix: pass 1 records every mutation primitive the command reaches (IPC apply, nft -f/insert/delete, intent writer, plan commit, transaction-record writes, systemctl restart); pass k+1 fails primitive k (before-effect and after-effect). Every run must emit exactly one NFTBAN_OUTCOME record whose rc agrees with the outcome table, print no success mark unless CONVERGED, and leave the authoritative state (fake kernel + intent + committed plan) either the requested one (CONVERGED), the previous one (FAILED_ROLLED_BACK, REFUSED) or an explicitly reported DEGRADED/PENDING. UNMEASURED arms fail every kernel query from query j onward (error, timeout, malformed) and must end DEGRADED. Witness arms reproduce the dns4/lab3 v1.233.0 signatures (teardown on enable; success mark with retained rules) so the test FAILS against pre-fix sources. Stateless always-succeed stubs are not used for any transactional property."
# meta:ta.id="portscan_enable_disable_txn_v1233_1_test"
# meta:ta.owner="firewall"
# meta:ta.module="daemon-runtime-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="900"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/cli/cmd_portscan.sh,cli/lib/nftban/core/nftban_portscan.sh,cli/lib/nftban/core/nftban_portscan_classic.sh,cli/lib/nftban/lib/nft_fragment.sh,cli/lib/nftban/lib/module_authority.sh"
# meta:inventory.binaries="bash,jq,python3,flock,grep,sed,awk"
# meta:inventory.env_vars="NFTBAN_ROOT,PORTSCAN_TXN_TEST_QUICK"
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

echo "=== portscan enable/disable transaction — stateful model (v1.233.1) ==="
echo "subject root: $ROOT"

for f in "$LIB/cli/cmd_portscan.sh" "$LIB/core/nftban_portscan.sh" \
         "$LIB/core/nftban_portscan_classic.sh" "$LIB/lib/nft_fragment.sh" \
         "$LIB/lib/module_authority.sh" "$ROOT/etc/nftban/conf.d/portscan/main.conf"; do
    [[ -f "$f" ]] || { echo "::error::SUBJECT_NOT_FOUND: $f"; exit 1; }
done
for b in jq python3 flock; do
    command -v "$b" >/dev/null 2>&1 || { echo "::error::NOT_EXECUTED: required tool '$b' missing (precondition, not a verdict)"; exit 2; }
done

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
# --- v1.235 host isolation (TEST-HARNESS-MUTATES-LIVE-HOST-STATE-WHEN-RUN-AS-ROOT) ---
# Run as root, this test wrote live host state (2026-10-07 overlay sweep). Every product
# root it can reach now defaults into the sandbox, EXPORTED so every child shell inherits it;
# arms that need their own value still override locally.
_HI="$TMPD/hi"
export NFTBAN_CONFIG_DIR="$_HI/etc" NFTBAN_DATA_DIR="$_HI/data" NFTBAN_LOG_DIR="$_HI/log" \
       NFTBAN_CACHE_DIR="$_HI/cache" NFTBAN_RUN_DIR="$_HI/run" NFTBAN_STATE_DIR="$_HI/data/state"
mkdir -p "$NFTBAN_CONFIG_DIR" "$NFTBAN_DATA_DIR/state" "$NFTBAN_LOG_DIR" "$NFTBAN_CACHE_DIR" "$NFTBAN_RUN_DIR"
# v1.235: the IPC client sends nothing without firewall authority; this world is an authorized install.
printf 'INSTALL_STATE=COMMITTED\nAUTHORITY=TAKEOVER\n' > "$NFTBAN_STATE_DIR/install_state"
export FAKE_T="$TMPD/t"
BIN="$TMPD/bin"; mkdir -p "$BIN" "$FAKE_T"
# The fake daemon applies fragments to the FAKE kernel through this path; it is
# the fake store's own writer, never the nft binary.
export FAKE_KERNEL_BIN="$BIN/nft"

# =============================================================================
# FAKE KERNEL + FAKE PRIMITIVE ACCOUNTING
# =============================================================================
# prim <name>: every MUTATION primitive the command reaches passes through here.
#   rc 0  proceed
#   rc 10 injected failure BEFORE the effect
#   rc 11 injected failure AFTER the effect (effect happened, caller told "failed")
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
# State: $FAKE_K/tables ("<fam> <table>" lines), $FAKE_K/c/<fam>/<table>/<chain>
# (one "<handle>\t<rule text>" line per rule), $FAKE_K/next_handle.
# nft joins argv with spaces, so a fused "ip nftban" argument works as it does
# on a real host.
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

enoent() { printf 'Error: Could not process rule: No such file or directory\n%s\n' "$1" >&2; return 1; }
cdir() { printf '%s/c/%s/%s' "$1" "$2" "$3"; }
have_table() { grep -qxF "$2 $3" "$1/tables" 2>/dev/null; }
next_handle() { local h; h=$(cat "$1/next_handle" 2>/dev/null || echo 100); echo $((h + 1)) > "$1/next_handle"; echo "$h"; }

# apply_line <state-dir> <line>  -> 0 ok, 1 error (message on stderr)
apply_line() {
    local S="$1" line="$2" f t c rest h tmp
    local -a w
    read -ra w <<<"$line"
    case "${w[0]:-} ${w[1]:-}" in
        "add table") have_table "$S" "${w[2]}" "${w[3]}" || echo "${w[2]} ${w[3]}" >> "$S/tables"
                     mkdir -p "$(cdir "$S" "${w[2]}" "${w[3]}")"; return 0 ;;
        "add chain") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     have_table "$S" "$f" "$t" || { enoent "$line"; return 1; }
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || : > "$(cdir "$S" "$f" "$t")/$c"; return 0 ;;
        "flush chain") f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     : > "$(cdir "$S" "$f" "$t")/$c"; return 0 ;;
        "add rule")  f="${w[2]}"; t="${w[3]}"; c="${w[4]}"
                     [[ -e "$(cdir "$S" "$f" "$t")/$c" ]] || { enoent "$line"; return 1; }
                     rest="${line#*"$c" }"; h=$(next_handle "$S")
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
                         rest="${line#*"$c" }"; h=$(next_handle "$S"); tmp="$(cdir "$S" "$f" "$t")/$c.tmp"
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
                         printf 'Error: Could not process rule: Device or resource busy\n%s\n' "$line" >&2; return 1
                     fi
                     rm -f "$(cdir "$S" "$f" "$t")/$c"; return 0 ;;
    esac
    echo "UNSUPPORTED statement: $line" >> "$FAKE_T/unsupported"
    printf 'Error: syntax error (fake nft does not model: %s)\n' "$line" >&2
    return 1
}

print_chain() {  # <fam> <table> <chain> <annot>
    local d; d="$(cdir "$K" "$1" "$2")"
    printf '\tchain %s {\n' "$3"
    [[ "$3" == "input" ]] && printf '\t\ttype filter hook input priority filter; policy accept;\n'
    while IFS=$'\t' read -r h r; do
        [[ -n "$h" ]] || continue
        if (( $4 )); then printf '\t\t%s # handle %s\n' "$r" "$h"; else printf '\t\t%s\n' "$r"; fi
    done < "$d/$3"
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
        # nft -f is ONE transaction: nothing of it is committed.
        sed "s|^|${file}: |" "$W/.err" >&2; rm -rf "$W"; exit 1
    fi
    rm -f "$W/.err"
    if (( check == 0 )); then
        # commit: replace the kernel store atomically enough for a single writer
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
    "list set "*|"list sets "*)
        # Sets are not modelled: the kernel answer is "absent", which is a real
        # nft answer (status reads the open-port sets).
        query_gate; printf 'Error: No such file or directory\n%s\n' "$cmd" >&2; exit 1 ;;
    "list ruleset")
        query_gate
        while read -r f t; do
            printf 'table %s %s {\n' "$f" "$t"
            for c in "$(cdir "$K" "$f" "$t")"/*; do [[ -e "$c" ]] && print_chain "$f" "$t" "$(basename "$c")" "$annot"; done
            printf '}\n'
        done < "$K/tables"; exit 0 ;;
    "list chains "*)
        query_gate; fam="${args[2]:-}"
        while read -r f t; do
            [[ "$f" == "$fam" ]] || continue
            printf 'table %s %s {\n' "$f" "$t"
            for c in "$(cdir "$K" "$f" "$t")"/*; do
                [[ -e "$c" ]] || continue
                printf '\tchain %s {\n' "$(basename "$c")"
                [[ "$(basename "$c")" == "input" ]] && printf '\t\ttype filter hook input priority filter; policy accept;\n'
                printf '\t}\n'
            done
            printf '}\n'
        done < "$K/tables"; exit 0 ;;
    "list chain "*)
        query_gate; f="${args[2]:-}"; t="${args[3]:-}"; c="${args[4]:-}"
        if [[ -z "$c" ]]; then read -r f t c <<<"${cmd#list chain }"; fi
        if ! have_table "$K" "$f" "$t" || [[ ! -e "$(cdir "$K" "$f" "$t")/$c" ]]; then
            printf 'Error: No such file or directory\nlist chain %s %s %s\n' "$f" "$t" "$c" >&2; exit 1
        fi
        printf 'table %s %s {\n' "$f" "$t"; print_chain "$f" "$t" "$c" "$annot"; printf '}\n'; exit 0 ;;
    "list table "*)
        query_gate; read -r f t <<<"${cmd#list table }"
        have_table "$K" "$f" "$t" || { printf 'Error: No such file or directory\n' >&2; exit 1; }
        printf 'table %s %s {\n' "$f" "$t"
        for c in "$(cdir "$K" "$f" "$t")"/*; do [[ -e "$c" ]] && print_chain "$f" "$t" "$(basename "$c")" "$annot"; done
        printf '}\n'; exit 0 ;;
esac

# ---------------- single mutating statements ---------------------------------
case "$cmd" in
    "add "*|"insert "*|"delete "*|"flush "*)
        verb="${args[0]}"
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
# The REAL client (lib/nft_ipc.sh) builds the request and pipes it here.
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
        if (( pr == 10 )); then exit 1; fi            # daemon not responding
        if out="$(FAKE_NFT_INTERNAL=1 "$FAKE_KERNEL_BIN" -f "$file" 2>&1)"; then
            (( pr == 11 )) && exit 1                  # applied, response lost
            echo '{"success":true,"data":{"status":"applied"}}'
        else
            (( pr == 11 )) && exit 1
            jq -nc --arg e "nft apply ruleset failed: exit status 1: $out" '{success:false,error:$e}'
        fi ;;
    *) echo "UNSUPPORTED ipc method: $method" >> "$FAKE_T/unsupported"
       echo '{"success":false,"error":"fake daemon: unsupported method"}' ;;
esac
SOCAT

# ---- fake systemctl: nftband lifecycle, mirroring internal/portscan/module.go -
# Stop(): reconcile only if the module was enabled when the daemon started.
# Start(): reconcile only if the module is enabled now (the Start gate).
# The daemon runs in a CLEAN environment (env -i), as systemd would start it, so
# a lock or a transaction variable leaked by the CLI cannot reach it.
cat > "$BIN/systemctl" <<'SCTL'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=/dev/null
. "$FAKE_T/prim.sh"
intent_enabled() { grep -qE '^PORTSCAN_ENABLED="?true' "$FAKE_CONF/conf.d/portscan/main.conf.local" 2>/dev/null; }
daemon_reconcile() {
    local rc=0
    env -i PATH="$PATH" HOME="$FAKE_T" TMPDIR="$TMPDIR" LANG=C \
        FAKE_K="$FAKE_K" FAKE_T="$FAKE_T" FAKE_CONF="$FAKE_CONF" FAKE_KERNEL_BIN="$FAKE_KERNEL_BIN" \
        FAIL_AT="${FAIL_AT:-0}" FAULT_KIND="${FAULT_KIND:-before}" \
        QUERY_FAULT_FROM="${QUERY_FAULT_FROM:-}" QUERY_FAULT_KIND="${QUERY_FAULT_KIND:-}" \
        NFTBAN_CONFIG_DIR="$NFTBAN_CONFIG_DIR" NFTBAN_LIB_DIR="$NFTBAN_LIB_DIR" \
        NFTBAN_LOG_DIR="$NFTBAN_LOG_DIR" NFTBAN_DATA_DIR="$NFTBAN_DATA_DIR" NFTBAN_STATE_DIR="$NFTBAN_STATE_DIR" \
        NFTBAN_CACHE_DIR="$NFTBAN_CACHE_DIR" NFTBAN_FRAGMENT_DIR="$NFTBAN_FRAGMENT_DIR" \
        NFTBAN_PLAN_RECORD_DIR="$NFTBAN_PLAN_RECORD_DIR" NFTBAN_RUN_DIR="$NFTBAN_RUN_DIR" \
        NFTBAN_PLAN_GENERATION_FILE="$NFTBAN_PLAN_GENERATION_FILE" \
        NFTBAN_DAEMON_SOCKET="$NFTBAN_DAEMON_SOCKET" \
        PORTSCAN_CLASSIC_STATE_FILE="$PORTSCAN_CLASSIC_STATE_FILE" \
        PORTSCAN_CLASSIC_MODULE_LOG="$PORTSCAN_CLASSIC_MODULE_LOG" \
        bash --noprofile --norc -c 'source "$1" && nftban_portscan_reconcile' _ \
        "$NFTBAN_LIB_DIR/core/nftban_portscan.sh" >>"$FAKE_T/daemon.log" 2>&1 || rc=$?
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
    "is-active --quiet suricata"|"is-active suricata") exit 3 ;;
    *) echo "UNSUPPORTED systemctl: $*" >> "$FAKE_T/unsupported"; exit 3 ;;
esac
SCTL
chmod +x "$BIN/nft" "$BIN/socat" "$BIN/systemctl"

# =============================================================================
# THE WORLD: config (real shipped main.conf), run dir, fake kernel
# =============================================================================
W="$TMPD/world"
export FAKE_K="$W/kernel" FAKE_CONF="$W/etc"
export NFTBAN_CONFIG_DIR="$W/etc" NFTBAN_LIB_DIR="$LIB"
export NFTBAN_LOG_DIR="$W/log" NFTBAN_DATA_DIR="$W/data" NFTBAN_CACHE_DIR="$W/cache"
export NFTBAN_FRAGMENT_DIR="$W/etc/rules.d"
export NFTBAN_PLAN_RECORD_DIR="$W/run" NFTBAN_RUN_DIR="$W/run"
export NFTBAN_PLAN_GENERATION_FILE="$W/run/convergence-generation"
export NFTBAN_DAEMON_SOCKET="$W/run/nftband.sock"
export PORTSCAN_CLASSIC_STATE_FILE="$W/data/portscan-state.db"
export PORTSCAN_CLASSIC_MODULE_LOG="$W/log/portscan-classic.log"
export NFTBAN_IPC_TIMEOUT=5
export PATH="$BIN:$PATH"
export TMPDIR="$TMPD/tmp"; mkdir -p "$TMPDIR"

make_world() {  # fresh "never projected, disabled" host
    rm -rf "$W"; mkdir -p "$W"/{etc/conf.d/portscan,etc/rules.d,log,data,cache,run,kernel/c/ip/nftban,kernel/c/ip6/nftban}
    cp "$ROOT/etc/nftban/conf.d/portscan/"*.conf "$W/etc/conf.d/portscan/"
    # v1.235 host isolation: the shipped classic/suricata confs carry ABSOLUTE host paths
    # (e.g. /var/log/nftban/ddos-classic.log, /var/lib/nftban/portscan-state.db). Copied
    # verbatim they sent this test's writes to the live host when run as root (2026-10-07
    # overlay sweep). Rewrite them, in the COPY only, to this world's directories.
    sed -i -e "s|/var/log/nftban/|$W/log/|g" -e "s|/var/lib/nftban/|$W/data/|g" -e "s|/run/nftban/|$W/run/|g" \
        "$W/etc/conf.d/portscan/"*.conf
    # Hermetic: the Suricata availability probe must not see a host binary.
    sed -i "s|^PORTSCAN_SURICATA_BINARY=.*|PORTSCAN_SURICATA_BINARY=\"$W/no-suricata\"|" "$W/etc/conf.d/portscan/main.conf"
    printf 'ip nftban\nip6 nftban\n' > "$FAKE_K/tables"
    echo 200 > "$FAKE_K/next_handle"
    local fam
    for fam in ip ip6; do
        printf '10\tct state established,related accept\n11\tmeta l4proto tcp comment "NFTBAN_ANCHOR:ANCHOR_DETECT"\n12\ttcp dport 22 accept\n' \
            > "$FAKE_K/c/$fam/nftban/input"
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
oracle_intent() {
    local v="false" f="$W/etc/conf.d/portscan/main.conf.local" line
    if [[ -f "$f" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^PORTSCAN_ENABLED=\"?([a-z]+) ]] && v="${BASH_REMATCH[1]}"
        done < "$f"
    fi
    echo "$v"
}
oracle_kclass() {
    local fam empty=0 active=0 cf jumps
    for fam in ip ip6; do
        cf="$FAKE_K/c/$fam/nftban/portscan_detection"
        if [[ ! -e "$cf" || ! -s "$cf" ]]; then empty=$((empty + 1)); continue; fi
        jumps=$(grep -cE 'jump portscan_detection' "$FAKE_K/c/$fam/nftban/input" || true)
        if grep -q 'NFTBAN_PORTSCAN:SYN' "$cf" && grep -q 'NFTBAN_PORTSCAN:UDP' "$cf" && (( jumps >= 1 )); then
            active=$((active + 1))
        fi
    done
    if (( empty == 2 )); then echo EMPTY; elif (( active == 2 )); then echo CLASSIC_ACTIVE; else echo PARTIAL; fi
}
oracle_gen() { local g=0; [[ -r "$NFTBAN_PLAN_GENERATION_FILE" ]] && read -r g < "$NFTBAN_PLAN_GENERATION_FILE"; echo "${g:-0}"; }
oracle_plan_eff() {
    local g; g="$(oracle_gen)"
    local f="$W/run/module-plan-portscan.env.$g"
    [[ -r "$f" ]] || { echo "none"; return 0; }
    sed -n 's/^NFTBAN_PLAN_EFFECTIVE_MODE=//p' "$f"
}
oracle_state() { echo "intent=$(oracle_intent) kernel=$(oracle_kclass) plan=$(oracle_plan_eff)"; }

# =============================================================================
# RUN ONE COMMAND through the REAL router arm, under product strict mode
# =============================================================================
# The production router invokes `nftban_cmd_<x> "$@" || return $?` and main runs
# as `main "$@" || exit $?`, so errexit is SUSPENDED for the whole call tree.
# The harness reproduces exactly that (the `||` below); running the subject with
# errexit armed would test semantics production never has.
OUT="$TMPD/out"; ERR="$TMPD/err"; RCF="$TMPD/rc"
run_cmd() {  # <enable|disable|status>
    local op="$1"
    RUNS=$((RUNS + 1))
    (
        set -Eeuo pipefail
        # shellcheck source=/dev/null
        source "$LIB/lib/strict.sh"
        # shellcheck source=/dev/null
        source "$LIB/cli/cmd_portscan.sh"
        # shellcheck source=/dev/null
        source "$LIB/lib/module_authority.sh"
        # shellcheck source=/dev/null
        source "$LIB/core/nftban_portscan.sh"
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
        wrap _nftban_portscan_txn_record_write "txn:record"
        if [[ -n "${FAKE_FAST_SLEEP:-}" ]]; then sleep() { :; }; fi
        rc=0
        nftban_cmd_portscan "$op" >"$OUT" 2>"$ERR" || rc=$?
        echo "$rc" > "$RCF"
    ) || echo "HARNESS_SUBSHELL_RC=$?" >> "$ERR"
    [[ -s "$RCF" ]] || { echo 255 > "$RCF"; echo "HARNESS: subject did not complete" >> "$ERR"; }
}

outcome_of() { sed -n '/^NFTBAN_OUTCOME=/{s/^NFTBAN_OUTCOME=\([A-Z_]*\) .*/\1/p;q;}' "$OUT"; }
rc_for() { case "$1" in CONVERGED) echo 0;; FAILED_ROLLED_BACK) echo 1;; DEGRADED) echo 3;; PENDING_TIMED_OUT) echo 4;; REFUSED) echo "5|7";; *) echo "?";; esac; }
expected_kclass() { [[ "$1" == "enable" ]] && echo CLASSIC_ACTIVE || echo EMPTY; }
expected_eff() { [[ "$1" == "enable" ]] && echo classic || echo inactive; }
rec_field() { sed -n "s/^$1=//p" "$W/run/module-txn-portscan.env" 2>/dev/null; }

# check_invariants <label> <op> <pre-intent> <pre-kclass> <pre-gen> <pre-record-sum>
check_invariants() {
    local label="$1" op="$2" pintent="$3" pk="$4" pgen="$5" precsum="$6"
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
    fi
    local reason; reason="$(sed -n 's/^NFTBAN_OUTCOME=.* reason=//p' "$OUT")"
    [[ -n "$reason" ]] || fail "$ctx outcome record carries no reason"

    case "$outc" in
        CONVERGED)
            [[ "$post_i" == "$want" ]] || fail "$ctx CONVERGED but intent is $post_i"
            [[ "$post_k" == "$(expected_kclass "$op")" ]] || fail "$ctx CONVERGED but the kernel is $post_k (expected $(expected_kclass "$op"))"
            [[ "$post_e" == "$(expected_eff "$op")" ]] || fail "$ctx CONVERGED but the committed plan says $post_e"
            if grep -q ' rc=[1-9]' "$FAKE_T/daemon_reconciles" 2>/dev/null && [[ ! -s "$FAKE_T/pfired" && ! -s "$FAKE_T/qfired" ]]; then
                fail "$ctx daemon start-up reconcile failed after a CONVERGED enable (lock not released before restart?): $(cat "$FAKE_T/daemon_reconciles")"
            fi ;;
        FAILED_ROLLED_BACK|REFUSED)
            [[ "$post_i" == "$pintent" ]] || fail "$ctx $outc but intent is $post_i (previous $pintent)"
            [[ "$post_k" == "$pk" ]] || fail "$ctx $outc but the kernel is $post_k (previous $pk)"
            if [[ "$pintent" == "false" ]]; then
                [[ "$post_e" == "inactive" || "$post_e" == "none" ]] || fail "$ctx $outc but the committed plan says $post_e over intent=false"
            else
                [[ "$post_e" == "classic" ]] || fail "$ctx $outc but the committed plan says $post_e over intent=true"
            fi
            if [[ "$outc" == "REFUSED" ]]; then
                [[ "$post_g" == "$pgen" ]] || fail "$ctx REFUSED but the generation moved $pgen -> $post_g"
                local nowsum; nowsum="$(cksum 2>/dev/null < "$W/run/module-txn-portscan.env" || echo none)"
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
        else
            if [[ "$outc" == "CONVERGED" ]]; then fail "$ctx CONVERGED with the transaction record not CLOSED (phase=$recphase)"; fi
            grep -q 'txn:record' "$FAKE_T/pfired" 2>/dev/null || fail "$ctx record left in phase '$recphase' without a record-write fault"
        fi
    fi
    return 0
}

# One full run + invariants. Globals: SCEN snapshot, OP.
arm() {  # <label> <snapshot> <op>
    local label="$1" snap="$2" op="$3" pi pk pg ps
    restore "$snap"; reset_counters
    pi="$(oracle_intent)"; pk="$(oracle_kclass)"; pg="$(oracle_gen)"
    ps="$(cksum 2>/dev/null < "$W/run/module-txn-portscan.env" || echo none)"
    run_cmd "$op"
    check_invariants "$label" "$op" "$pi" "$pk" "$pg" "$ps"
}

# =============================================================================
# 1. TRANSITION MATRIX
# =============================================================================
say ""; say "1. transition matrix..."
unset FAIL_AT FAULT_KIND QUERY_FAULT_FROM QUERY_FAULT_KIND FAKE_FAST_SLEEP FAKE_NEVER_READY_AFTER_RESTART || true
make_world; snapshot DISABLED_ABSENT
reset_counters; run_cmd enable
check_invariants "T1 disabled(absent)->enable" enable false EMPTY 0 none
[[ "$(outcome_of)" == "CONVERGED" ]] && ok "T1 converged" || fail "T1 disabled(absent)->enable did not CONVERGE: $(tail -n 3 "$OUT") :: $(tail -n 3 "$ERR")"
# W1 — WITNESS dns4/lab3 ARM1: an enable must never tear the module down.
if grep -q '99-portscan-classic-cleanup' "$FAKE_T/ptrace" || grep -qi 'Disabling portscan detection\|Removing portscan runtime' "$OUT"; then
    fail "W1 TEARDOWN-ON-ENABLE: the enable path ran the disable/cleanup projection ($(grep -m1 -i 'cleanup\|Disabling\|Removing' "$FAKE_T/ptrace" "$OUT" || true))"
else ok "W1 enable never runs teardown"; fi
# W3 — the banner must not describe a stale plan.
if grep -q 'ENABLED (INACTIVE)\|ENABLED (UNKNOWN)' "$OUT"; then fail "W3 STALE BANNER: $(grep -m1 'ENABLED (' "$OUT")"; else ok "W3 banner mode from the committed plan"; fi
snapshot ENABLED
say "   after enable: $(oracle_state)"
ENABLE_PRIMS="$(cat "$FAKE_T/ptrace")"; ENABLE_Q="$(cat "$FAKE_T/qcount")"

reset_counters; run_cmd enable
check_invariants "T2 enabled->enable (idempotent)" enable true CLASSIC_ACTIVE "$(oracle_gen)" x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T2 idempotent enable did not CONVERGE: $(tail -n 3 "$OUT")"

restore ENABLED; reset_counters; run_cmd disable
check_invariants "T3 enabled->disable" disable true CLASSIC_ACTIVE 1 x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T3 enabled->disable did not CONVERGE: $(tail -n 3 "$OUT") :: $(tail -n 3 "$ERR")"
snapshot DISABLED_EMPTY
say "   after disable: $(oracle_state)"
DISABLE_PRIMS="$(cat "$FAKE_T/ptrace")"; DISABLE_Q="$(cat "$FAKE_T/qcount")"

reset_counters; run_cmd disable
check_invariants "T4 disabled->disable (idempotent)" disable false EMPTY "$(oracle_gen)" x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T4 idempotent disable did not CONVERGE: $(tail -n 3 "$OUT")"
if grep -q 'nft:\|ipc:' "$FAKE_T/ptrace"; then fail "T4 idempotent disable wrote the kernel: $(grep -m2 'nft:\|ipc:' "$FAKE_T/ptrace" | tr '\n' ' ')"; else ok "T4 no kernel write when already empty"; fi

restore DISABLED_EMPTY; reset_counters; run_cmd enable
check_invariants "T5 disabled(empty chain)->enable" enable false EMPTY "$(oracle_gen)" x
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T5 enable from an empty retained chain did not CONVERGE: $(tail -n 3 "$OUT")"

restore DISABLED_ABSENT; reset_counters; run_cmd disable
check_invariants "T6 disabled(absent)->disable (never projected)" disable false EMPTY 0 none
[[ "$(outcome_of)" == "CONVERGED" ]] || fail "T6 disable on a never-projected chain did not CONVERGE (non-idempotent teardown): $(tail -n 3 "$OUT") :: $(tail -n 3 "$ERR")"

# W2 — WITNESS lab3 ARM2: IPC down, rules live, `disable`.
restore ENABLED; echo down > "$FAKE_K/daemon"; snapshot ENABLED_IPC_DOWN
arm "W2 ipc-down enabled->disable" ENABLED_IPC_DOWN disable
if grep -q '✅' "$OUT" && [[ "$(oracle_kclass)" == "CLASSIC_ACTIVE" ]]; then
    fail "W2 SUCCESS WITH RETAINED RULES: '$(grep -m1 '✅' "$OUT")' rc=$(cat "$RCF") while the kernel still holds the portscan rules"
fi
[[ "$(outcome_of)" == "FAILED_ROLLED_BACK" ]] && ok "W2 rolled back" || fail "W2 expected FAILED_ROLLED_BACK, got '$(outcome_of)' rc=$(cat "$RCF")"
[[ "$(cat "$RCF")" != "0" ]] || fail "W2 rc 0 on a disable that could not remove the rules"

restore DISABLED_ABSENT; echo down > "$FAKE_K/daemon"; snapshot DISABLED_IPC_DOWN
arm "T7 ipc-down disabled->enable" DISABLED_IPC_DOWN enable
[[ "$(outcome_of)" == "FAILED_ROLLED_BACK" ]] || fail "T7 expected FAILED_ROLLED_BACK, got '$(outcome_of)'"

# Status must not render an unsettled transaction as success.
restore ENABLED; reset_counters
cat > "$W/run/module-txn-portscan.env" <<'REC'
NFTBAN_TXN_ID=test-open
NFTBAN_TXN_OP=enable
NFTBAN_TXN_PHASE=INTENT_PERSISTED
NFTBAN_TXN_OUTCOME=
NFTBAN_TXN_PID=999999
REC
run_cmd status
if grep -q '✅ ENABLED' "$OUT"; then fail "S1 status renders ✅ ENABLED over an OPEN/interrupted transaction"; else ok "S1 open transaction not rendered as success"; fi
grep -q 'INTERRUPTED' "$OUT" && ok "S1 interruption visible" || fail "S1 status does not show the interrupted transaction: $(awk 'NR<=12' "$OUT" | tr '\n' '|')"

# PENDING: restart succeeds, daemon never becomes ready (bounded wait).
restore DISABLED_ABSENT; reset_counters
FAKE_FAST_SLEEP=1 FAKE_NEVER_READY_AFTER_RESTART=1 run_cmd enable
check_invariants "T8 restart-never-ready" enable false EMPTY 0 none
[[ "$(outcome_of)" == "PENDING_TIMED_OUT" ]] || fail "T8 expected PENDING_TIMED_OUT, got '$(outcome_of)'"

# REFUSED: the canonical lock is held by someone else (taken AFTER the world is
# restored — restoring replaces the lock file's inode).
restore ENABLED; reset_counters
T9_I="$(oracle_intent)"; T9_K="$(oracle_kclass)"; T9_G="$(oracle_gen)"
T9_S="$(cksum 2>/dev/null < "$W/run/module-txn-portscan.env" || echo none)"
exec {LK}>>"$W/run/nft_operations.lock"; flock -n "$LK"
run_cmd disable
eval "exec ${LK}>&-"
check_invariants "T9 lock-busy disable" disable "$T9_I" "$T9_K" "$T9_G" "$T9_S"
[[ "$(outcome_of)" == "REFUSED" && "$(cat "$RCF")" == "7" ]] || fail "T9 expected REFUSED rc 7, got '$(outcome_of)' rc $(cat "$RCF")"

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

# -----------------------------------------------------------------------------
# 2b. BUG-PORTSCAN-RECONCILE-COMMITS-GENERATION-ON-FAILED-APPLY
# The classic apply (add_rules via IPC) fails. The forward reconcile must NOT
# commit a plan generation for it: between the injected fault and the rollback's
# first intent write, no plan:commit may appear in the primitive trace.
# -----------------------------------------------------------------------------
say ""; say "2b. enable with the classic rule apply failing (no commit on a failed apply)..."
KA="$(awk '$2 ~ /^ipc:apply_ruleset:10-portscan-classic/ {print $1; exit}' <<<"$ENABLE_PRIMS")"
if [[ -z "$KA" ]]; then
    fail "A1 the enable pass never reached the classic rule apply — arm cannot be executed"
else
    restore DISABLED_ABSENT; reset_counters
    A1_G="$(oracle_gen)"
    FAIL_AT="$KA" FAULT_KIND=before FAKE_FAST_SLEEP=1 run_cmd enable
    check_invariants "A1 enable, add_rules apply fails" enable false EMPTY "$A1_G" none
    A1_OC="$(outcome_of)"
    committed_before_rollback="$(awk -v k="$KA" '
        $1 > k && $2 ~ /^intent:set/ {exit}
        $1 > k && $2 == "plan:commit" {print $1; exit}' "$FAKE_T/ptrace")"
    if [[ -n "$committed_before_rollback" ]]; then
        fail "A1 COMMIT ON FAILED APPLY: plan:commit (#$committed_before_rollback) after the failed classic apply (#$KA), before any rollback — outcome ${A1_OC}"
    else ok "A1 no generation committed for the failed apply"; fi
    [[ "$A1_OC" == "FAILED_ROLLED_BACK" || "$A1_OC" == "DEGRADED" ]] \
        || fail "A1 expected FAILED_ROLLED_BACK or DEGRADED, got '$A1_OC'"
    [[ "$(cat "$RCF")" != "0" ]] || fail "A1 rc 0 for an enable whose rules were never applied"
    [[ "$(oracle_gen)" == "$A1_G" ]] || say "   A1 note: generation moved $A1_G -> $(oracle_gen) (rollback reconcile)"
    say "   A1: outcome=$A1_OC rc=$(cat "$RCF") state: $(oracle_state) gen=$(oracle_gen)"
fi

# =============================================================================
# 3. UNMEASURED ARMS — every kernel query from j onward fails
# =============================================================================
say ""; say "3. unmeasured arms (query failure / timeout / malformed)..."
declare -A BASE_Q=( [enable]="$ENABLE_Q" [disable]="$DISABLE_Q" )
KINDS=(fail timeout malformed)
for op in enable disable; do
    Q="${BASE_Q[$op]}"
    (( Q > 0 )) || { fail "U-$op pass 1 made ZERO kernel queries — no postcondition was ever read"; continue; }
    for qk in "${KINDS[@]}"; do
        for (( j = 1; j <= Q; j++ )); do
            if [[ -n "${PORTSCAN_TXN_TEST_QUICK:-}" ]] && (( j % 4 != 1 && j != Q )); then continue; fi
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
say "unmeasured matrix: $(printf '%s\n' "${UMATRIX[@]}" | awk '{print $NF" "$(NF-1)}' | sort | uniq -c | tr '\n' ';')"
say ""
say "runs=$RUNS checks=$CHECKS failures=$FAILURES"
if (( FAILURES > 0 )); then
    echo "::error::portscan enable/disable transaction model FAILED: $FAILURES"
    exit 1
fi
echo "portscan enable/disable transaction model PASSED"
