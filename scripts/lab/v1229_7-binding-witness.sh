#!/usr/bin/env bash
# =============================================================================
# NFTBan — v1.229.7 targeted plan-binding witness (PR-5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v1229_7_binding_witness"
# meta:type="lab"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-24"
# meta:description="Targeted package-native proof that every convergence root publishes a plan bound to the CURRENT generation. Requires an EXECUTION WITNESS per command, not rc=0, because this campaign proved repeatedly that COMMAND_RC0 != COMMAND_EXECUTED."
# =============================================================================
set -uo pipefail
LABEL="${1:?usage: $0 <distro-label>}"
F=0
say(){ printf '%s\n' "$*"; }
ok(){  say "  ok    $*"; }
bad(){ F=$((F+1)); say "  FAIL  $*"; }

gen(){ cat /run/nftban/convergence-generation 2>/dev/null || echo 0; }

# ⛔ RUNTIME/IPC AUTHORITY INVARIANTS. /run/nftban is declared by systemd-tmpfiles
# (0755 nftban nftban) and holds the daemon socket. No convergence root may
# change its ownership/mode or remove the socket. The socket inode MAY change --
# the daemon can legitimately recreate it -- so presence and type are asserted,
# not identity.
rt_stat(){ stat -c '%U:%G:%a' /run/nftban 2>/dev/null || echo "ABSENT"; }
sock_ok(){ [[ -S /run/nftban/nftband.sock ]]; }
daemon_ok(){ [[ "$(systemctl is-active nftband 2>/dev/null)" == active ]]; }
bound(){ sed -n 's/^NFTBAN_PLAN_BOUND_GENERATION=//p' "/run/nftban/module-plan-$1.env" 2>/dev/null; }
rid(){ sed -n 's/^NFTBAN_PLAN_RESOLUTION_ID=//p' "/run/nftban/module-plan-$1.env" 2>/dev/null; }
valcons(){ /usr/lib/nftban/bin/nftban-validate 2>&1 | grep -c 'VAL-CONS-002' || true; }

# ⛔ THE EXPECTED POPULATION IS DERIVED FROM DURABLE INTENT, NOT FROM WHICH
#    FILES HAPPEN TO EXIST.
#      NO MALFORMED RECORD FOUND != ALL REQUIRED RECORDS EXIST
#    An unmatched glob would otherwise report "clean" for a host with no records
#    at all -- turning shell globbing behaviour into evidence.
# ⛔ REUSE THE CANONICAL AUTHORITY. An earlier revision of this function parsed
# main.conf + main.conf.local itself -- a SECOND config resolver, which is the
# exact defect class this lane exists to remove. It would also have traded
# "population from files" for "population from an invented resolver".
#   THE HARNESS MUST NOT REIMPLEMENT PRODUCT CONFIG SEMANTICS.
# nftban_module_effective_enabled IS the product's durable-intent authority and
# owns the base + .local precedence; the witness calls it rather than copying it.
# ⛔ The authority returns 0=enabled, 1=disabled, 2=unknown module. Treating
# rc=2 as "disabled" would silently drop a module from the expected population --
# EMPTY_PARSE != ZERO in another costume. Anything outside {0,1} refuses
# classification instead.
AUTH_UNKNOWN=""
expected_modules(){
    local m rc
    AUTH_UNKNOWN=""
    for m in ddos portscan; do
        nftban_module_effective_enabled "$m" >/dev/null 2>&1; rc=$?
        case "$rc" in
            0) printf '%s\n' "$m" ;;
            1) : ;;                                   # legitimately disabled
            *) AUTH_UNKNOWN="$AUTH_UNKNOWN $m(rc=$rc)" ;;
        esac
    done
}

# Enumerate ACTUAL record files explicitly -- never rely on glob expansion.
actual_records(){ local m; for m in ddos portscan; do [[ -f "/run/nftban/module-plan-$m.env" ]] && printf '%s\n' "$m"; done; }

# Fails on EITHER: a required record missing, OR present but unbound/stale.
# scope: "" = all expected modules (convergence roots) | "<mod>" = that one only
population_ok(){
    local scope="${1:-}" g m b miss="" unb=""
    g="$(gen)"
    while read -r m; do
        [[ -n "$scope" && "$m" != "$scope" ]] && continue
        [[ -z "$m" ]] && continue
        if [[ ! -f "/run/nftban/module-plan-$m.env" ]]; then miss="$miss $m"; continue; fi
        b="$(bound "$m")"
        [[ -z "$b" ]] && { unb="$unb $m(empty)"; continue; }
        [[ "$b" != "$g" ]] && unb="$unb $m($b!=$g)"
    done < <(expected_modules)
    POP_DETAIL=""
    [[ -n "$AUTH_UNKNOWN" ]] && POP_DETAIL="AUTHORITY_UNKNOWN:$AUTH_UNKNOWN "
    [[ -n "$miss" ]] && POP_DETAIL="${POP_DETAIL}MISSING:$miss "
    [[ -n "$unb"  ]] && POP_DETAIL="${POP_DETAIL}UNBOUND:$unb"
    [[ -z "$POP_DETAIL" ]]
}

# The canonical authority must be present; without it the witness has no
# legitimate way to know the expected population, and inventing one is forbidden.
# shellcheck source=/dev/null
if ! source /usr/lib/nftban/lib/module_authority.sh 2>/dev/null \
   || ! declare -F nftban_module_effective_enabled >/dev/null 2>&1; then
    echo "FATAL: canonical module authority unavailable — refusing to substitute a local resolver" >&2
    exit 2
fi

say "=== v1.229.7 plan-binding witness — $LABEL ==="
say "--- PRECONDITION ---"
PKG="$(rpm -q nftban-core 2>/dev/null || dpkg-query -W -f='${Package} ${Version}' nftban-core 2>/dev/null || echo NONE)"
say "  package        : $PKG"
say "  configured ddos: $(sed -n 's/^[[:space:]]*DDOS_MODE=//p' /etc/nftban/conf.d/ddos/main.conf.local 2>/dev/null | tr -d '\"')"
say "  generation     : $(gen)"
say "  VAL-CONS-002   : $(valcons)"
say "  /run/nftban    : $(rt_stat)   socket=$(sock_ok && echo present || echo ABSENT)"
# ⛔ The witness must NOT wipe /run/nftban. An earlier run did, which removed the
# daemon socket, broke IPC apply, dropped module chains 16 -> 6, and produced a
# false PRODUCT_FAIL for rebuild. Restoration is the tmpfiles owner's job.
#   DESTROYING A RUNTIME NAMESPACE IS NOT A COLD-START TEST.
if [[ "$(rt_stat)" != "nftban:nftban:755" ]] || ! sock_ok; then
    say "  FATAL: runtime namespace not in canonical state — restore with:"
    say "         systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf && systemctl restart nftband"
    exit 2
fi
[[ "$PKG" == NONE ]] && { say "  FATAL: package not installed"; exit 2; }

# step <n> <label> <execution-witness-cmd> -- <command...>
step(){
    local n="$1" label="$2"; shift 2
    # A per-module reload publishes ONLY its own record; asserting the full
    # population after it reported a product failure for correct behaviour.
    local scope=""
    case "$label" in "ddos reload") scope=ddos ;; "portscan reload") scope=portscan ;; esac
    local g0 g1 out rc rt0 rt1
    g0="$(gen)"; rt0="$(rt_stat)"
    out="$("$@" 2>&1)"; rc=$?
    sleep 8
    g1="$(gen)"; rt1="$(rt_stat)"
    # ⛔ EXECUTION WITNESS IS OPERATION-SPECIFIC. Generation movement is a valid
    # witness only where the contract says that operation bumps it; making it a
    # universal oracle would invent a synthetic requirement (module reload does
    # NOT bump -- only the firewall convergence roots do).
    local witness="none"
    case "$label" in
        "ddos reload"|"portscan reload")
            grep -qiE 'reload|re-?appl|Mode:' <<<"$out" && witness="reconcile-path-entered" ;;
        "firewall reload")
            grep -qiE 're-?appl|reload' <<<"$out" && witness="reload-path-entered"
            [[ "$g1" != "$g0" ]] && witness="${witness}+generation($g0->$g1)" ;;
        "firewall rebuild")
            grep -qiE '\[[0-9]+/[0-9]+\]|schema|rebuild' <<<"$out" && witness="serialized-rebuild-entered"
            [[ "$g1" != "$g0" ]] && witness="${witness}+generation($g0->$g1)" ;;
        "firewall reset")
            # Must prove the FORCE-AUTHORISED path ran, not the declined one.
            grep -qiE 'Use --force' <<<"$out" && witness="DECLINED"
            grep -qiE 'Performing complete firewall reset|reset' <<<"$out" && [[ "$witness" != DECLINED ]] && witness="reset-path-entered"
            [[ "$g1" != "$g0" && "$witness" != DECLINED ]] && witness="${witness}+generation($g0->$g1)" ;;
    esac
    [[ "$witness" == DECLINED ]] && { bad "$n $label — command DECLINED to execute (confirmation gate). Not a product test."; return; }
    if [[ "$witness" == "none" ]]; then
        bad "$n $label — NO EXECUTION WITNESS (rc=$rc). COMMAND_RC0 != COMMAND_EXECUTED"
    elif [[ $rc -ne 0 ]]; then
        bad "$n $label — rc=$rc (witness: $witness)"
    else
        ok "$n $label — rc=0, executed [$witness]"
    fi
    # runtime-authority invariants, per operation
    [[ "$rt0" == "$rt1" ]] && ok "    /run/nftban ownership/mode unchanged ($rt1)" \
                           || bad "    /run/nftban CHANGED $rt0 -> $rt1 — a convergence root seized the runtime directory"
    sock_ok   && ok "    nftband.sock present" || bad "    nftband.sock ABSENT after $label — IPC broken"
    daemon_ok && ok "    nftband active"       || bad "    nftband not active after $label"
    local v; v="$(valcons)"
    local exp act; exp="$(expected_modules | tr '\n' ' ')"; act="$(actual_records | tr '\n' ' ')"
    if population_ok "$scope"; then ok "    expected[${scope:-$exp}] present and bound to current gen $g1"
    else bad "    population expected[${scope:-$exp}] actual[$act] -> $POP_DETAIL"; fi
    local rid_bad=""
    for m in ${scope:-$exp}; do [[ -z "$(rid "$m")" ]] && rid_bad="$rid_bad $m"; done
    [[ -z "$rid_bad" ]] && ok "    resolution_id present for [${scope:-$exp}]" \
                        || bad "    resolution_id missing for:$rid_bad"
    [[ "$v" -eq 0 ]] && ok "    VAL-CONS-002 = 0" || bad "    VAL-CONS-002 = $v"
}

printf 'DDOS_ENABLED="true"\nDDOS_MODE="classic"\n'         > /etc/nftban/conf.d/ddos/main.conf.local
printf 'PORTSCAN_ENABLED="true"\nPORTSCAN_MODE="classic"\n' > /etc/nftban/conf.d/portscan/main.conf.local

say "--- WITNESS ---"
step 1 "ddos reload"       nftban ddos reload
step 2 "portscan reload"   nftban portscan reload
step 3 "firewall reload"   nftban firewall reload --quiet
step 4 "firewall rebuild"  nftban firewall rebuild --quiet
step 5 "firewall reset"    nftban firewall reset --force --quiet

say "--- 6 daemon restart ---"
b0="$(cat /proc/sys/kernel/random/boot_id)"
systemctl restart nftband >/dev/null 2>&1; sleep 12
pid="$(systemctl show -p MainPID --value nftband 2>/dev/null)"
[[ -n "$pid" && "$pid" != 0 ]] && ok "6 daemon restart — active (MainPID=$pid), same boot ($([[ "$b0" == "$(cat /proc/sys/kernel/random/boot_id)" ]] && echo yes || echo NO))" \
                               || bad "6 daemon restart — not active"
population_ok && ok "    expected[$(expected_modules | tr '\n' ' ')] present and bound to gen $(gen)" \
              || bad "    population -> $POP_DETAIL"
[[ "$(valcons)" -eq 0 ]] && ok "    VAL-CONS-002 = 0" || bad "    VAL-CONS-002 = $(valcons)"

# --- 7 nftban modes: OBSERVATION FOLLOWS THE PLAN, NOT THE ENVIRONMENT -------
say "--- 7 nftban modes read/report (PR-5C) ---"
# ⛔ The environment is rigged to DISAGREE with the plan. Before PR-5C,
# `_modes_resolve_effective` re-resolved `auto` here and could report an
# effective mode the system never decided.
#   OBSERVATION CHANGE != DECISION CHANGE
# ⛔ CANONICAL PREDICATE. `systemctl is-active suricata` is NOT the same question
# as "does the nftban resolver consider Suricata available" -- the product also
# requires a fresh eve file at ITS configured path. Equating the two is how this
# campaign spent a whole run with AUTO_SURICATA never actually exercised.
#   PROCESS LIVENESS != PRODUCT AVAILABILITY PREDICATE
suricata_available_per_product(){   # <module>
    local mod="$1"
    # ⛔ LOAD THE MODULE CONFIG FIRST, as the real caller path does. The
    # predicate does NOT load its own config (0 sites), and PortScan reads
    # ${PORTSCAN_SURICATA_EVE_FILE} with NO default -- so under `set -u` an
    # unloaded config makes it CRASH with "unbound variable" rather than return
    # false. DDoS uses ${DDOS_SURICATA_EVE_FILE:-<path>} and degrades cleanly.
    # Evaluating the predicate without its config is not evaluating the product.
    #   A PREDICATE MUST BE EVALUATED IN ITS OWN CONTEXT.
    bash -c "
        export NFTBAN_LIB_DIR=/usr/lib/nftban
        set +u
        for c in /etc/nftban/conf.d/${mod}/main.conf /etc/nftban/conf.d/${mod}/main.conf.local \
                 /etc/nftban/conf.d/${mod}/suricata.conf /etc/nftban/conf.d/${mod}/suricata.conf.local; do
            [ -r \"\$c\" ] && . \"\$c\"
        done
        source /usr/lib/nftban/core/nftban_${mod}_suricata.sh 2>/dev/null || exit 1
        nftban_${mod}_suricata_is_available" >/dev/null 2>&1
}

modes_eff(){   # <module> -> what `nftban modes` reports
    local mod="$1" row
    row="$(nftban modes 2>/dev/null | grep -iE "^\s*${mod}\b" | head -1)"
    awk '{print $3}' <<<"$row"
}
plan_eff(){ sed -n 's/^NFTBAN_PLAN_EFFECTIVE_MODE=//p' "/run/nftban/module-plan-$1.env" 2>/dev/null; }

for mod in ddos portscan; do
    pre_avail=""; post_avail=""
    K="$( [[ $mod == ddos ]] && echo DDOS || echo PORTSCAN )"
    printf '%s_ENABLED="true"\n%s_MODE="auto"\n' "$K" "$K" > "/etc/nftban/conf.d/$mod/main.conf.local"
    # Suricata DOWN -> auto must resolve classic; then bring it UP so the
    # environment now contradicts the published plan.
    # ARM A — plan=classic, then make Suricata GENUINELY available.
    # ⛔ PROVE THE TRANSITION, do not assume it. The predicate must be observed
    # FALSE, then TRUE. Without this the environment could have been in the same
    # state both times and the "contradiction" would be imaginary.
    #   BELIEVING YOU CHANGED THE ENVIRONMENT != HAVING CHANGED IT
    # ⛔ Per module: ddos and portscan availability are separate predicates and
    #   are not assumed equal.
    systemctl stop suricata >/dev/null 2>&1; sleep 3
    pre_avail=false; suricata_available_per_product "$mod" && pre_avail=true
    nftban "$mod" reload >/dev/null 2>&1; sleep 4
    p="$(plan_eff "$mod")"
    systemctl start suricata >/dev/null 2>&1; sleep 8
    post_avail=false; suricata_available_per_product "$mod" && post_avail=true
    if [[ "$pre_avail" != "false" || "$post_avail" != "true" ]]; then
        bad "7 $mod ARM A LAB_PRECONDITION_FAIL — predicate did not transition false->true (saw $pre_avail->$post_avail); the contradiction was never established"
    elif [[ "$p" != "classic" ]]; then
        bad "7 $mod ARM A LAB_PRECONDITION_FAIL — plan resolved '$p', expected classic with Suricata down"
    else
        m="$(modes_eff "$mod")"
        [[ "$m" == "classic" ]] \
            && ok "7 $mod ARM A plan=classic, product says Suricata AVAILABLE -> modes reports classic" \
            || bad "7 $mod ARM A modes reported '$m' while the plan says '$p' — READ PATH RE-RESOLVED"
    fi

    # Inverse: plan=suricata, then take the environment away.
    # ARM B — plan=suricata, then remove availability. REQUIRED evidence: an
    # unmet precondition is not a pass.
    #   UNMET PRECONDITION != PRODUCT FAILURE
    #   UNMET REQUIRED PRECONDITION != PASS
    # ⛔ Same discipline inverted: the predicate must be observed TRUE, then FALSE.
    pre_avail=false; suricata_available_per_product "$mod" && pre_avail=true
    nftban "$mod" reload >/dev/null 2>&1; sleep 4
    p="$(plan_eff "$mod")"
    systemctl stop suricata >/dev/null 2>&1; sleep 5
    post_avail=false; suricata_available_per_product "$mod" && post_avail=true
    if [[ "$pre_avail" != "true" || "$post_avail" != "false" ]]; then
        bad "7 $mod ARM B LAB_PRECONDITION_FAIL — predicate did not transition true->false (saw $pre_avail->$post_avail)"
    elif [[ "$p" != "suricata" ]]; then
        bad "7 $mod ARM B LAB_PRECONDITION_FAIL — plan resolved '$p' with Suricata available; cannot establish the inverse contradiction"
    else
        m="$(modes_eff "$mod")"
        [[ "$m" == "suricata" ]] \
            && ok "7 $mod ARM B plan=suricata, Suricata now UNAVAILABLE -> modes reports suricata" \
            || bad "7 $mod ARM B modes reported '$m' while the plan says '$p' — READ PATH RE-RESOLVED"
    fi

    # Plan absent -> unknown, never a re-resolution.
    rm -f "/run/nftban/module-plan-$mod.env"
    m="$(modes_eff "$mod")"
    # ARM C — plan absent.
    [[ "$m" == "unknown" ]] \
        && ok "7 $mod ARM C plan absent -> modes reports unknown (no re-resolution)" \
        || bad "7 $mod ARM C plan absent but modes reported '$m' — READ PATH RE-RESOLVED"
    nftban "$mod" reload >/dev/null 2>&1; sleep 3
done
systemctl start suricata >/dev/null 2>&1 || true

say ""
[[ $F -eq 0 ]] && { say "WITNESS PASS — $LABEL"; exit 0; }
say "WITNESS FAIL — $LABEL ($F failures)"; exit 1
