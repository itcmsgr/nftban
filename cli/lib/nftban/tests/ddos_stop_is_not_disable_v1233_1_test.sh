#!/usr/bin/env bash
# =============================================================================
# NFTBan - DDoS: daemon Stop() != Disable(); replace is one transaction (v1.233.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="ddos_stop_is_not_disable_v1233_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="ddos"
# meta:ta.id="ddos_stop_is_not_disable_v1233_1_test"
# meta:ta.owner="ddos"
# meta:ta.module="ddos-lifecycle"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="180"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.233.1 BUG-DDOS-DAEMON-SHUTDOWN-RECONCILE-FAILURE-LEAVES-PROTECTION-CHAINS-FLUSHED (witnessed lab3 2026-09-24). Drives the REAL nftban_ddos_classic.sh enable/disable (under lib/strict.sh, called exactly as nftban_ddos_apply calls it) against a STATEFUL fake kernel: a fake nft that keeps a chain/rule/set store, applies -f fragments atomically (all-or-nothing, with set/chain reference checks), records every committed kernel state, and a fake socat daemon whose listener can be closed while its socket file remains (the witnessed state). Arms: STOP-PRESERVES-PROTECTION (what Stop() runs is DERIVED from internal/ddos/module.go and the listener state from gracefulShutdown ordering), RESTART-NO-HOLE (no recorded state with ddos_prefix/ddos_protection empty), DISABLE-STILL-TEARS-DOWN, STOP-vs-DISABLE, IPC-CLOSED (rc!=0 and no partial state), UNINSTALL-STILL-REMOVES (the DEB postrm/RPM %postun table deletions, extracted and executed), and UNINSTALL-REMOVES-SYNPROXY-RAW (A7, formerly a KNOWN_GAP: the DEB postrm remove) arm's own comment-scoped raw cleanup removes the NFTBan notrack rule while an operator notrack rule in ip/ip6 raw prerouting survives; I5 proves lane Stop() + the v1.233.0 postrm leaves it). Every defect arm is inverted against the v1.233.0 subject (eef635a6), extracted from git: the direct-flush + IPC-closed path must reproduce empty prefix/protection."
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos_classic.sh,cli/lib/nftban/lib/nft_fragment.sh,cli/lib/nftban/lib/nft_ipc.sh,cli/lib/nftban/lib/strict.sh,internal/ddos/module.go,cmd/nftband/daemon_lifecycle.go,packaging/deb/postrm,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,git,tar,jq,python3,grep,awk,cp,find"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SD/../../../.." && pwd)"
# v1.233.0 release commit (tag v1.233.0). Immutable subject for every inversion arm.
HIST_SHA="eef635a692a4802464e399b74cdbf0f4e562fc53"

PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

for b in jq python3 git tar; do
    command -v "$b" >/dev/null 2>&1 || { echo "NOT_EXECUTED: required binary '$b' missing — this is not a PASS"; exit 1; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FK="$TMP/fk"; mkdir -p "$FK/bin" "$FK/state" "$TMP/etc" "$TMP/log" "$TMP/rules.d"
export FAKE_NFT_ROOT="$FK"
ST="$FK/state"

# -----------------------------------------------------------------------------
# STATEFUL FAKE KERNEL — fake nft
# -----------------------------------------------------------------------------
cat >"$FK/bin/nft" <<'FAKENFT'
#!/usr/bin/env bash
# Hermetic stateful nft double. State: $FAKE_NFT_ROOT/state/<fam>__<table>/{chains,sets}/<name>.
# Rules are "<handle>\t<text>". -f applies ALL statements to a copy and commits only
# if every statement succeeds. Unsupported statements FAIL (never silently accepted).
set -uo pipefail
FK="${FAKE_NFT_ROOT:?}"; ST="$FK/state"
terse=0; handles=0; check=0; file=""; args=()
while (($#)); do
    case "$1" in
        -t|--terse) terse=1 ;;
        -a|--handle) handles=1 ;;
        -c|--check) check=1 ;;
        -f|--file) file="${2:-}"; shift ;;
        -j|--json) echo "fake nft: -j unsupported" >&2; exit 2 ;;
        *) args+=("$1") ;;
    esac
    shift
done
: "$terse"
cmd="${args[*]:-}"
printf '%s\n' "argv: ${cmd}${file:+ -f $file}" >>"$FK/calls.log"
shopt -s nullglob
err(){ printf 'Error: %s\n' "$*" >&2; }
tdir(){ printf '%s/%s__%s' "$1" "$2" "$3"; }
next_handle(){ local h; h=$(cat "$FK/next_handle" 2>/dev/null || echo 100); echo $((h+1)) >"$FK/next_handle"; echo "$h"; }
count(){ local f; f="$(tdir "$ST" "$1" nftban)/chains/$2"; if [[ -f "$f" ]]; then grep -c . "$f" || true; else echo absent; fi; }
snap(){
    local line="$1" fam ch
    for fam in ip ip6; do for ch in ddos_sanity ddos_prefix ddos_protection ddos_penalty; do
        line+=" ${fam}/${ch}=$(count "$fam" "$ch")"
    done; done
    printf '%s\n' "$line" >>"$FK/history"
}
refs_set(){ local td="$1" n="$2" f; for f in "$td"/chains/*; do grep -qE "@${n}([^A-Za-z0-9_]|\$)" "$f" && return 0; done; return 1; }
refs_chain(){ local td="$1" n="$2" f; for f in "$td"/chains/*; do grep -qE "(jump|goto) ${n}([^A-Za-z0-9_]|\$)" "$f" && return 0; done; return 1; }
apply_one(){
    local R="$1" line="$2"
    local -a t
    IFS=' ' read -ra t <<<"$line"
    local verb="${t[0]:-}" obj="${t[1]:-}" fam="${t[2]:-}" tbl="${t[3]:-}" name="${t[4]:-}" td
    td="$(tdir "$R" "$fam" "$tbl")"
    case "$verb $obj" in
        "add table") mkdir -p "$td/chains" "$td/sets"; return 0 ;;
        "delete table") [[ -d "$td" ]] || { err "No such file or directory: table $fam $tbl"; return 1; }; rm -rf "$td"; return 0 ;;
        "flush table") [[ -d "$td" ]] || { err "No such file or directory: table $fam $tbl"; return 1; }
                       local f; for f in "$td"/chains/*; do : >"$f"; done; return 0 ;;
    esac
    [[ -d "$td" ]] || { err "No such file or directory: table $fam $tbl ($line)"; return 1; }
    local cf="$td/chains/$name" sf="$td/sets/$name"
    case "$verb $obj" in
        "add chain") [[ -f "$cf" ]] || : >"$cf" ;;
        "flush chain") [[ -f "$cf" ]] || { err "No such file or directory: chain $name"; return 1; }; : >"$cf" ;;
        "delete chain") [[ -f "$cf" ]] || { err "No such file or directory: chain $name"; return 1; }
                        if refs_chain "$td" "$name"; then err "Device or resource busy: chain $name"; return 1; fi
                        rm -f "$cf" ;;
        "add set") [[ -f "$sf" ]] || printf '%s\n' "${line#*" $name "}" >"$sf" ;;
        "delete set") [[ -f "$sf" ]] || { err "No such file or directory: set $name"; return 1; }
                      if refs_set "$td" "$name"; then err "Device or resource busy: set $name"; return 1; fi
                      rm -f "$sf" ;;
        "add rule") [[ -f "$cf" ]] || { err "No such file or directory: chain $name"; return 1; }
                    printf '%s\t%s\n' "$(next_handle)" "${line#*" $name "}" >>"$cf" ;;
        "delete rule") [[ -f "$cf" ]] || { err "No such file or directory: chain $name"; return 1; }
                       local h="${t[6]:-x}"
                       grep -q "^${h}"$'\t' "$cf" || { err "No such file or directory: rule handle $h"; return 1; }
                       grep -v "^${h}"$'\t' "$cf" >"$cf.tmp" || true; mv "$cf.tmp" "$cf" ;;
        *) err "fake nft: unsupported statement: $line"; return 1 ;;
    esac
    return 0
}
txn(){
    local label="$1" W="$FK/work.$$" line n=0
    rm -rf "$W"; cp -a "$ST" "$W"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n+1))
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if ! apply_one "$W" "$line"; then
            err "transaction aborted at statement $n; nothing applied"
            rm -rf "$W"; return 1
        fi
    done
    if ((check)); then rm -rf "$W"; return 0; fi
    rm -rf "$ST.old"; mv "$ST" "$ST.old"; mv "$W" "$ST"; rm -rf "$ST.old"
    snap "$label"
}
print_chain(){ # td name
    local td="$1" c="$2" h r
    printf '\tchain %s {\n' "$c"
    while IFS=$'\t' read -r h r; do
        if ((handles)); then printf '\t\t%s # handle %s\n' "$r" "$h"; else printf '\t\t%s\n' "$r"; fi
    done <"$td/chains/$c"
    printf '\t}\n'
}
if [[ -z "$file" ]]; then
    IFS=' ' read -ra t <<<"$cmd"
    case "${t[0]:-} ${t[1]:-}" in
        "list tables")
            if [[ "${FAKE_NFT_READ_FAIL:-0}" == 1 ]]; then err "Operation not permitted"; exit 1; fi
            for d in "$ST"/*__*; do [[ -d "$d" ]] || continue; b="${d##*/}"; printf 'table %s %s\n' "${b%%__*}" "${b#*__}"; done
            exit 0 ;;
        "list table"|"list chain")
            if [[ "${FAKE_NFT_READ_FAIL:-0}" == 1 ]]; then err "Operation not permitted"; exit 1; fi
            td="$(tdir "$ST" "${t[2]:-}" "${t[3]:-}")"
            [[ -d "$td" ]] || { err "No such file or directory: table ${t[2]:-} ${t[3]:-}"; exit 1; }
            if [[ "${t[1]}" == chain ]]; then
                [[ -f "$td/chains/${t[4]:-}" ]] || { err "No such file or directory: chain ${t[4]:-}"; exit 1; }
                printf 'table %s %s {\n' "${t[2]}" "${t[3]}"; print_chain "$td" "${t[4]}"; printf '}\n'; exit 0
            fi
            printf 'table %s %s {\n' "${t[2]}" "${t[3]}"
            for s in "$td"/sets/*; do printf '\tset %s {\n\t\t%s\n\t}\n' "${s##*/}" "$(cat "$s")"; done
            for c in "$td"/chains/*; do print_chain "$td" "${c##*/}"; done
            printf '}\n'; exit 0 ;;
        "list "*) err "fake nft: unsupported read: $cmd"; exit 1 ;;
    esac
    txn "direct: $cmd" <<<"$cmd"; exit $?
fi
[[ -f "$file" ]] || { err "Could not open file $file"; exit 1; }
txn "apply: ${file##*/}" <"$file"; exit $?
FAKENFT

# -----------------------------------------------------------------------------
# FAKE DAEMON (socat): listener can be CLOSED while the socket file remains
# -----------------------------------------------------------------------------
cat >"$FK/bin/socat" <<'FAKESOCAT'
#!/usr/bin/env bash
set -uo pipefail
FK="${FAKE_NFT_ROOT:?}"; target=""
for a in "$@"; do case "$a" in UNIX-CONNECT:*) target="${a#UNIX-CONNECT:}" ;; esac; done
if [[ ! -S "$target" || ! -e "$FK/daemon.listening" ]]; then
    printf 'ipc: REFUSED\n' >>"$FK/calls.log"
    echo "socat E connect(5, AF=1 \"$target\"): Connection refused" >&2; exit 1
fi
req=$(cat); method=$(jq -r '.method' <<<"$req")
case "$method" in
    apply_ruleset)
        f=$(jq -r '.params.file' <<<"$req"); chk=$(jq -r '.params.check' <<<"$req")
        fl=(); [[ "$chk" == true ]] && fl=(-c)
        if e=$("$FK/bin/nft" "${fl[@]}" -f "$f" 2>&1); then echo '{"success":true,"data":{"status":"applied"}}'
        else jq -nc --arg e "$e" '{success:false,error:$e}'; fi ;;
    *) echo '{"success":false,"error":"fake daemon: unsupported method"}' ;;
esac
FAKESOCAT
chmod +x "$FK/bin/nft" "$FK/bin/socat"
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$FK/nftband.sock" \
    || { echo "NOT_EXECUTED: cannot create fake daemon socket"; exit 1; }
export PATH="$FK/bin:$PATH"

# -----------------------------------------------------------------------------
# CHILD: the REAL classic layer under the product strict mode
# -----------------------------------------------------------------------------
cat >"$TMP/child.sh" <<'CHILD'
#!/usr/bin/env bash
LIBROOT="$1"; ACTION="$2"
# shellcheck source=/dev/null
source "$LIBROOT/lib/strict.sh"            # set -Eeuo pipefail + IFS=$'\n\t' (product)
export NFTBAN_LIB_DIR="$LIBROOT"
# shellcheck source=/dev/null
source "$LIBROOT/core/nftban_ddos_classic.sh"
rc=0
case "$ACTION" in
    # Same call shape as nftban_ddos_apply (nftban_ddos.sh): `fn || enable_result=$?`.
    enable)  nftban_ddos_classic_enable  || rc=$? ;;
    disable) nftban_ddos_classic_disable || rc=$? ;;
    *) echo "unknown action $ACTION" >&2; exit 97 ;;
esac
echo "CHILD_COMPLETED action=$ACTION rc=$rc"
exit "$rc"
CHILD

export NFTBAN_CONFIG_DIR="$TMP/etc" NFTBAN_LOG_DIR="$TMP/log" NFTBAN_FRAGMENT_DIR="$TMP/rules.d"
export NFTBAN_DAEMON_SOCKET="$FK/nftband.sock" NFTBAN_IPC_TIMEOUT=10 NFTBAN_ENABLE_ERROR_LOGGING=0

CHILD_RC=0; CHILD_OUT=""
run_child(){ # <lib root> <action>
    CHILD_RC=0
    CHILD_OUT="$(bash "$TMP/child.sh" "$1" "$2" 2>&1)" || CHILD_RC=$?
    if [[ "$CHILD_OUT" != *"CHILD_COMPLETED action=$2"* ]]; then
        no "NOT_EXECUTED: subject did not run to completion ($2, rc=$CHILD_RC) — not a verdict"
        printf '%s\n' "$CHILD_OUT" | tail -15
        return 1
    fi
    return 0
}
cnt(){ local f="$ST/${1}__nftban/chains/$2"; if [[ -f "$f" ]]; then grep -c . "$f" || true; else echo absent; fi; }
dump(){ (cd "$ST" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do echo "== $f"; cat "$f"; done); }
listener_up(){ : >"$FK/daemon.listening"; }
listener_closed(){ rm -f "$FK/daemon.listening"; }
reset_converged(){ rm -rf "$ST"; cp -a "$FK/converged" "$ST"; : >"$FK/history"; listener_up; }
nonzero_both(){ local ch="$1" fam v; for fam in ip ip6; do v=$(cnt "$fam" "$ch"); [[ "$v" =~ ^[1-9][0-9]*$ ]] || return 1; done; }

# extract_go_fn <file> <signature prefix> — body of ONE method, comments stripped.
extract_go_fn(){ awk -v sig="$2" 'index($0,sig)==1{i=1;next} i&&/^\}/{exit} i{print}' "$1" | grep -vE '^[[:space:]]*//' || true; }
# Does this subject's Stop() reach nftban_ddos_reconcile (directly or one method hop)?
stop_reaches_reconcile(){
    local gof="$1" body m mb
    body="$(extract_go_fn "$gof" "func (m *Module) Stop(")"
    [[ -n "$body" ]] || { echo "SUBJECT_NOT_FOUND"; return 0; }
    if grep -qE 'nftban_ddos_reconcile|runReconcile\(' <<<"$body"; then echo yes; return 0; fi
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        mb="$(extract_go_fn "$gof" "func (m *Module) ${m}(")"
        if grep -qE 'nftban_ddos_reconcile|runReconcile\(' <<<"$mb"; then echo yes; return 0; fi
    done < <(grep -oE 'm\.[A-Za-z_]+\(\)' <<<"$body" | sed -E 's/^m\.//; s/\(\)$//' | sort -u)
    echo no
}
# During registry.StopAll(), is the daemon's IPC listener already closed? (gracefulShutdown order)
listener_closed_during_stopall(){
    local body a b
    body="$(extract_go_fn "$1" "func (d *Daemon) gracefulShutdown(")"
    # first occurrence of each, read in full (no short-circuiting consumer)
    a=$(awk '/socketLn\.Close\(\)/ && !n {n=NR} END{print n}' <<<"$body")
    b=$(awk '/registry\.StopAll\(\)/ && !n {n=NR} END{print n}' <<<"$body")
    [[ -n "$a" && -n "$b" ]] || { echo "SUBJECT_NOT_FOUND"; return 0; }
    if (( a < b )); then echo yes; else echo no; fi
}
# Simulate a graceful daemon stop for a subject: listener per gracefulShutdown order,
# then exactly what that subject's Stop() runs.
simulate_daemon_stop(){ # <lib root> <module.go> <daemon_lifecycle.go>
    local lc sr
    lc="$(listener_closed_during_stopall "$3")"; sr="$(stop_reaches_reconcile "$2")"
    STOP_FACTS="listener_closed_during_stopall=$lc stop_reaches_reconcile=$sr"
    [[ "$lc" == SUBJECT_NOT_FOUND || "$sr" == SUBJECT_NOT_FOUND ]] && return 2
    [[ "$lc" == yes ]] && listener_closed
    if [[ "$sr" == yes ]]; then
        # Stop() -> nftban_ddos_reconcile -> (plan=classic) nftban_ddos_apply -> nftban_ddos_classic_enable
        run_child "$1" enable || return 3
    fi
    return 0
}

# -----------------------------------------------------------------------------
# SUBJECTS
# -----------------------------------------------------------------------------
LANE_LIB="$ROOT/cli/lib/nftban"
LANE_MOD="$ROOT/internal/ddos/module.go"
LANE_LC="$ROOT/cmd/nftband/daemon_lifecycle.go"
HIST="$TMP/hist"; mkdir -p "$HIST"
HIST_OK=0
if git -C "$ROOT" cat-file -e "${HIST_SHA}^{commit}" 2>/dev/null \
   && git -C "$ROOT" archive "$HIST_SHA" cli/lib/nftban internal/ddos/module.go cmd/nftband/daemon_lifecycle.go packaging/deb/postrm \
        | tar -x -C "$HIST" 2>/dev/null \
   && [[ -f "$HIST/cli/lib/nftban/core/nftban_ddos_classic.sh" ]]; then
    HIST_OK=1
fi
HIST_LIB="$HIST/cli/lib/nftban"; HIST_MOD="$HIST/internal/ddos/module.go"; HIST_LC="$HIST/cmd/nftband/daemon_lifecycle.go"

echo "=== DDoS Stop() != Disable(); replace is one transaction (v1.233.1) ==="
echo ""

# --- fixture: nftban tables with base input chain + the ddos jumps (anchors) ----
for fam in ip ip6; do
    "$FK/bin/nft" add table "$fam" nftban
    "$FK/bin/nft" add chain "$fam" nftban input
    for ch in ddos_sanity ddos_penalty ddos_prefix ddos_protection; do
        "$FK/bin/nft" add rule "$fam" nftban input jump "$ch"
    done
    "$FK/bin/nft" add rule "$fam" nftban input tcp dport @tcp_ports_in accept comment '"NFTBAN_ANCHOR:ANCHOR_SERVICE"'
done
: >"$FK/history"; listener_up

# --- A0 BOOTSTRAP (positive control: fake + real code converge) --------------
if run_child "$LANE_LIB" enable; then
    if [[ "$CHILD_RC" -eq 0 ]] && nonzero_both ddos_sanity && nonzero_both ddos_prefix \
       && nonzero_both ddos_protection && nonzero_both ddos_penalty; then
        ok "A0 bootstrap: lane enable converges (prefix=$(cnt ip ddos_prefix) protection=$(cnt ip ddos_protection) sanity=$(cnt ip ddos_sanity) penalty=$(cnt ip ddos_penalty))"
    else
        no "A0 bootstrap did not converge (rc=$CHILD_RC prefix=$(cnt ip ddos_prefix) protection=$(cnt ip ddos_protection))"
        printf '%s\n' "$CHILD_OUT" | tail -20
    fi
fi
cp -a "$ST" "$FK/converged"
CONVERGED_DUMP="$(dump)"
C_PREFIX="$(cnt ip ddos_prefix)"; C_PROT="$(cnt ip ddos_protection)"

# --- A1 STOP-PRESERVES-PROTECTION (lane) --------------------------------------
reset_converged
simulate_daemon_stop "$LANE_LIB" "$LANE_MOD" "$LANE_LC"; src=$?
if [[ $src -ne 0 ]]; then
    no "A1 STOP simulation could not derive its subject ($STOP_FACTS, rc=$src)"
elif [[ "$(dump)" == "$CONVERGED_DUMP" && ! -s "$FK/history" ]]; then
    ok "A1 STOP-PRESERVES-PROTECTION: daemon stop leaves the kernel byte-identical ($STOP_FACTS)"
else
    no "A1 daemon stop changed the kernel ($STOP_FACTS; prefix=$(cnt ip ddos_prefix) protection=$(cnt ip ddos_protection))"
fi
STOP_DUMP="$(dump)"; STOP_PREFIX="$(cnt ip ddos_prefix)"
[[ "$STOP_FACTS" == *"listener_closed_during_stopall=yes"* ]] \
    && ok "A1b precondition derived from gracefulShutdown: the listener IS closed during StopAll (the arm is not vacuous)" \
    || no "A1b gracefulShutdown order no longer closes the listener before StopAll — re-derive this arm"
# The kernel postcondition above also holds if Stop() re-applied into a closed
# listener, because the replace is now atomic. The CONTRACT is stronger: Stop()
# must not reach the reconcile root at all (Stop() != Disable()).
[[ "$STOP_FACTS" == *"stop_reaches_reconcile=no"* ]] \
    && ok "A1c lane Stop() does not reach nftban_ddos_reconcile (derived from internal/ddos/module.go)" \
    || no "A1c lane Stop() reaches the reconcile root ($STOP_FACTS) — Stop() must not re-apply or tear down"

# --- A2 RESTART-NO-HOLE (lane): Start() re-apply over IPC on a converged kernel --
reset_converged
if run_child "$LANE_LIB" enable; then
    hole="$(grep -E '(ip|ip6)/ddos_(prefix|protection)=(0|absent)( |$)' "$FK/history" || true)"
    commits=$(grep -c . "$FK/history" || true)
    if [[ "$CHILD_RC" -eq 0 && -z "$hole" && "${commits:-0}" -gt 0 && "$(cnt ip ddos_prefix)" == "$C_PREFIX" && "$(cnt ip6 ddos_protection)" == "$C_PROT" ]]; then
        ok "A2 RESTART-NO-HOLE: $commits recorded kernel states, none with empty prefix/protection"
    else
        no "A2 re-apply exposed a hole or did not converge (rc=$CHILD_RC commits=$commits): ${hole:-<none>}"
    fi
fi

# --- A3 DISABLE-STILL-TEARS-DOWN (lane) ---------------------------------------
reset_converged
if run_child "$LANE_LIB" disable; then
    left=""
    for fam in ip ip6; do for ch in ddos_sanity ddos_prefix ddos_protection ddos_penalty; do
        v=$(cnt "$fam" "$ch"); [[ "$v" == 0 || "$v" == absent ]] || left+=" $fam/$ch=$v"
    done; done
    pj="$(grep -h 'jump ddos_penalty' "$ST"/ip__nftban/chains/input "$ST"/ip6__nftban/chains/input || true)"
    if [[ "$CHILD_RC" -eq 0 && -z "$left" && -z "$pj" ]]; then
        ok "A3 DISABLE-STILL-TEARS-DOWN: module-owned rules converged to zero (penalty chain+jump removed)"
    else
        no "A3 explicit disable left enforcement behind (rc=$CHILD_RC):${left:- none}${pj:+ penalty-jump-present}"
    fi
fi
DISABLE_DUMP="$(dump)"; DISABLE_PREFIX="$(cnt ip ddos_prefix)"

# --- A4 STOP-vs-DISABLE -------------------------------------------------------
if [[ "$STOP_DUMP" != "$DISABLE_DUMP" && "$STOP_PREFIX" =~ ^[1-9] && "$DISABLE_PREFIX" == 0 ]]; then
    ok "A4 STOP-vs-DISABLE: different kernel postconditions (prefix after stop=$STOP_PREFIX, after disable=$DISABLE_PREFIX)"
else
    no "A4 stop and disable are not distinguishable (stop prefix=$STOP_PREFIX, disable prefix=$DISABLE_PREFIX)"
fi

# --- A5 IPC-CLOSED (lane): apply must fail loudly and move NOTHING -------------
reset_converged; listener_closed
if run_child "$LANE_LIB" enable; then
    if [[ "$CHILD_RC" -ne 0 && "$(dump)" == "$CONVERGED_DUMP" && ! -s "$FK/history" ]] && grep -q 'ERROR' <<<"$CHILD_OUT"; then
        ok "A5 IPC-CLOSED: rc=$CHILD_RC, ERROR surfaced, kernel byte-identical, no intermediate state"
    else
        no "A5 IPC-closed apply (rc=$CHILD_RC) left prefix=$(cnt ip ddos_prefix) protection=$(cnt ip ddos_protection); history=$(grep -c . "$FK/history" || true)"
    fi
fi

# --- A5b UNREADABLE (lane): the replace-preamble read fails -> UNKNOWN, no mutation
reset_converged
export FAKE_NFT_READ_FAIL=1
if run_child "$LANE_LIB" enable; then
    if [[ "$CHILD_RC" -ne 0 && "$(cnt ip ddos_prefix)" == "$C_PREFIX" && "$(cnt ip ddos_protection)" == "$C_PROT" ]] \
       && ! grep -qE 'ddos_(prefix|protection)=(0|absent)( |$)' "$FK/history"; then
        ok "A5b unreadable table: rc=$CHILD_RC, prefix/protection untouched (UNKNOWN never authorises the replace)"
    else
        no "A5b unreadable table mutated prefix/protection or returned 0 (rc=$CHILD_RC)"
    fi
fi
unset FAKE_NFT_READ_FAIL

# --- A6 UNINSTALL-STILL-REMOVES: packaging removal statements, executed --------
extract_removals(){ # <postrm> -> DEB remove) arm nft table statements
    awk '/^    remove\)/{i=1;next} i&&/^        ;;/{exit} i{print}' "$1" \
        | grep -E '^[[:space:]]*nft (flush|delete) table ' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*2>.*$//' || true
}
extract_rpm_removals(){
    awk '/^%postun/{i=1;next} i&&/^%[a-z]/{exit} i{print}' "$ROOT/packaging/build_nftban.sh" \
        | grep -E '^[[:space:]]*nft (flush|delete) table ' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*2>.*$//' || true
}
for pkg in DEB RPM; do
    reset_converged; listener_closed
    if [[ "$pkg" == DEB ]]; then stmts="$(extract_removals "$ROOT/packaging/deb/postrm")"; else stmts="$(extract_rpm_removals)"; fi
    n=$(grep -c . <<<"$stmts" || true)
    if [[ "${n:-0}" -lt 2 ]] || ! grep -q 'delete table ip nftban' <<<"$stmts" || ! grep -q 'delete table ip6 nftban' <<<"$stmts"; then
        no "A6 $pkg: removal population not found (n=$n) — cannot prove uninstall removes DDoS rules"; continue
    fi
    while IFS= read -r s; do
        IFS=' ' read -ra a <<<"$s"; "$FK/bin/nft" "${a[@]:1}" 2>/dev/null || true
    done <<<"$stmts"
    if [[ ! -d "$ST/ip__nftban" && ! -d "$ST/ip6__nftban" ]] && ! grep -rqs 'ddos_' "$ST"; then
        ok "A6 UNINSTALL-STILL-REMOVES ($pkg, $n statements, daemon down, no Stop() run): every DDoS chain/set gone"
    else
        no "A6 $pkg removal left DDoS objects behind"
    fi
done
if grep -qE 'nftban_ddos|nft_ipc|nftband\.sock' <<<"$(extract_removals "$ROOT/packaging/deb/postrm")$(extract_rpm_removals)"; then
    no "A6b removal statements route through the daemon/DDoS module"
else
    ok "A6b removal statements are direct table deletions (no daemon, no module entry point)"
fi

# --- A7 UNINSTALL-REMOVES-SYNPROXY-RAW (was KNOWN_GAP) -------------------------
# ip/ip6 raw prerouting are FOREIGN tables. On v1.233.0 the prerm daemon stop
# removed NFTBan's notrack rule as a side effect (Stop() -> reconcile ->
# classic_enable -> _nft_cleanup_synproxy_raw). Stop() no longer does that, so
# the DEB postrm now removes it explicitly (_nftban_uninstall_synproxy_raw,
# comment-scoped, by handle). An OPERATOR notrack rule in the same chain is the
# positive control: it must survive.
seed_raw(){
    for fam in ip ip6; do
        "$FK/bin/nft" add table "$fam" raw
        "$FK/bin/nft" add chain "$fam" raw prerouting
        "$FK/bin/nft" add rule "$fam" raw prerouting udp dport 53 notrack comment '"operator: keep"'
        "$FK/bin/nft" add rule "$fam" raw prerouting tcp dport 443 notrack comment '"SYNPROXY: notrack SYN"'
    done
}
extract_raw_cleanup(){ # <postrm> -> the self-contained raw cleanup function (empty on v1.233.0)
    awk '/^# >>> NFTBAN_SYNPROXY_RAW_CLEANUP_BEGIN >>>$/{f=1} f{print} /^# <<< NFTBAN_SYNPROXY_RAW_CLEANUP_END <<<$/{f=0}' "$1"
}
package_remove(){ # <lib> <module.go> <lifecycle.go> <postrm> — prerm stop, then that postrm's remove)
    local fn
    simulate_daemon_stop "$1" "$2" "$3" || true
    while IFS= read -r s; do IFS=' ' read -ra a <<<"$s"; "$FK/bin/nft" "${a[@]:1}" 2>/dev/null || true
    done <<<"$(extract_removals "$4")"
    fn="$(extract_raw_cleanup "$4")"
    if [[ -n "$fn" ]] && awk '/^    remove\)/{i=1;next} i&&/^        ;;/{exit} i{print}' "$4" | grep -qE '^[[:space:]]*_nftban_uninstall_synproxy_raw[[:space:]]*$'; then
        printf 'set -e\n%s\n_nftban_uninstall_synproxy_raw\n' "$fn" >"$TMP/raw_cleanup.sh"
        RAW_CLEANUP_OUT="$(sh "$TMP/raw_cleanup.sh" 2>&1)"; RAW_CLEANUP_RC=$?
    else
        RAW_CLEANUP_OUT="<no raw cleanup in this postrm remove) arm>"; RAW_CLEANUP_RC=0
    fi
}
raw_has(){ grep -qs -- "$2" "$ST/${1}__raw/chains/prerouting"; }
reset_converged; seed_raw; package_remove "$LANE_LIB" "$LANE_MOD" "$LANE_LC" "$ROOT/packaging/deb/postrm"
if [[ "$RAW_CLEANUP_RC" -eq 0 ]] && ! raw_has ip 'SYNPROXY: notrack' && ! raw_has ip6 'SYNPROXY: notrack' \
   && raw_has ip 'operator: keep' && raw_has ip6 'operator: keep' && [[ -d "$ST/ip__raw" && -d "$ST/ip6__raw" ]]; then
    ok "A7 UNINSTALL removes the NFTBan SYNPROXY raw notrack rules (ip+ip6) with the daemon's Stop() no longer touching them"
    ok "A7b positive control: the operator notrack rule in ip/ip6 raw prerouting and the raw tables survive"
else
    no "A7 package remove left NFTBan raw rules or removed operator rules (rc=$RAW_CLEANUP_RC): $RAW_CLEANUP_OUT"
fi
[[ "$STOP_FACTS" == *"stop_reaches_reconcile=no"* ]] \
    && ok "A7c the removal is the postrm's own: lane Stop() does not reach the reconcile ($STOP_FACTS)" \
    || no "A7c lane Stop() reaches the reconcile again ($STOP_FACTS)"

# --- INVERSIONS against the v1.233.0 subject ------------------------------------
echo ""
echo "  inversion subject: v1.233.0 @ ${HIST_SHA:0:8}"
if [[ "$HIST_OK" -ne 1 ]]; then
    no "NOT_EXECUTED: v1.233.0 subject ${HIST_SHA:0:8} unavailable (shallow clone?) — inversion is not optional"
else
    # I1: the witnessed defect — daemon stop with DDoS enabled empties prefix/protection
    reset_converged
    simulate_daemon_stop "$HIST_LIB" "$HIST_MOD" "$HIST_LC"; src=$?
    if [[ $src -eq 0 && "$STOP_FACTS" == *"stop_reaches_reconcile=yes"* ]] \
       && [[ "$(cnt ip ddos_prefix)" == 0 && "$(cnt ip6 ddos_prefix)" == 0 && "$(cnt ip ddos_protection)" == 0 && "$(cnt ip6 ddos_protection)" == 0 ]] \
       && nonzero_both ddos_sanity && nonzero_both ddos_penalty; then
        ok "I1 v1.233.0 daemon stop REPRODUCES the witness: prefix/protection empty, sanity/penalty retained ($STOP_FACTS)"
    else
        no "I1 harness cannot reproduce the witnessed defect on v1.233.0 (src=$src $STOP_FACTS prefix=$(cnt ip ddos_prefix) protection=$(cnt ip ddos_protection))"
    fi
    # I2: v1.233.0 IPC-closed apply leaves chains flushed (partial state)
    reset_converged; listener_closed
    if run_child "$HIST_LIB" enable; then
        if [[ "$(cnt ip ddos_prefix)" == 0 && "$(cnt ip ddos_protection)" == 0 ]]; then
            ok "I2 v1.233.0 IPC-closed apply leaves prefix/protection EMPTY (rc=$CHILD_RC) — A5 discriminates"
        else
            no "I2 v1.233.0 IPC-closed apply did not flush — A5 would be vacuous"
        fi
    fi
    # I3: v1.233.0 re-apply with IPC UP still exposes a hole (direct flush before apply)
    reset_converged
    if run_child "$HIST_LIB" enable; then
        hole="$(grep -E '(ip|ip6)/ddos_(prefix|protection)=(0|absent)( |$)' "$FK/history" || true)"
        if [[ -n "$hole" && "$(cnt ip ddos_prefix)" == "$C_PREFIX" ]]; then
            ok "I3 v1.233.0 restart re-apply exposes a transient hole even when IPC succeeds — A2 discriminates"
        else
            no "I3 no transient hole recorded on v1.233.0 — A2 would be vacuous"
        fi
    fi
    # I4: v1.233.0 package remove DID clean the raw notrack rule via the Stop() side effect
    reset_converged; seed_raw; package_remove "$HIST_LIB" "$HIST_MOD" "$HIST_LC" "$HIST/packaging/deb/postrm"
    if ! raw_has ip 'SYNPROXY: notrack' && [[ "$RAW_CLEANUP_OUT" == "<no raw cleanup"* ]]; then
        ok "I4 v1.233.0 package remove removed the raw notrack rule ONLY through Stop() (its postrm has no raw cleanup)"
    else
        no "I4 v1.233.0 did not remove the raw rule, or its postrm already cleans raw — A7's attribution is wrong"
    fi
    # I5: lane Stop() + the v1.233.0 postrm = the gap. A7 passes because of the
    # new postrm cleanup, not because of anything else in the harness.
    reset_converged; seed_raw; package_remove "$LANE_LIB" "$LANE_MOD" "$LANE_LC" "$HIST/packaging/deb/postrm"
    if raw_has ip 'SYNPROXY: notrack' && raw_has ip6 'SYNPROXY: notrack'; then
        ok "I5 lane Stop() with the v1.233.0 postrm LEAVES the raw notrack rule — A7 discriminates"
    else
        no "I5 raw rule vanished without the new postrm cleanup — A7 would be vacuous"
    fi
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ddos stop-is-not-disable PASSED"
