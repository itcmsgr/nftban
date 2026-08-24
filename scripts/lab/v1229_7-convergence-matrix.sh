#!/usr/bin/env bash
# =============================================================================
# NFTBan — v1.229.7 package-native convergence matrix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v1229_7_convergence_matrix"
# meta:type="lab"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-24"
# meta:description="One deterministic state machine per distro. Drives the five mode states through five lifecycle operations and asserts, at EVERY resulting state: plan identity/currency, base Layer-0 presence, classic-XOR-suricata projection with no opposite-mode residue, BOTH address families, both modules, health without UNKNOWN collapsed to PASS, and that no lifecycle operation silently rewrote durable intent. Runs ON the target host; the driver copies it there."
# =============================================================================
#
# ⛔ SUBSTRATE, NOT SYMMETRY. The oracle encodes what each module actually
#    projects. PortScan/Suricata owns NO nft projection -- demanding one would
#    make a correct host fail by design.
#       SAME MODE CONTRACT != SAME KERNEL OBJECT SHAPE
#
# ⛔ AUTO IS CAUSED, NOT INJECTED. auto->classic and auto->suricata are produced
#    by changing the real availability precondition (suricata service + eve),
#    never by writing a plan record. PR-4B fixed exactly the case where auto
#    resolved suricata while the daemon consumed classic config; a matrix that
#    injected the plan would not have caught it.
#
# ⛔ A FAMILY THAT CANNOT BE OBSERVED IS UNKNOWN, NEVER SKIPPED.
# =============================================================================

set -uo pipefail

DISTRO="${1:?usage: $0 <distro-label>}"
EVID="${EVIDENCE_DIR:-/var/tmp/nftban-matrix}"
mkdir -p "$EVID"
ROWS="$EVID/matrix.tsv"
: > "$ROWS"
FATAL=0; FAILROWS=0; UNKNOWNROWS=0

log(){ printf '%s\n' "$*" >&2; }
fatal(){ log "FATAL: $*"; FATAL=1; }

# --- observation -------------------------------------------------------------
# ⛔ An nft read failure is an OBSERVATION FAILURE, never "absent".
nft_json(){ nft -j list ruleset 2>/dev/null; }

chain_present(){ # <family> <chain>
  local fam="$1" ch="$2" j; j="$(nft_json)"
  [[ -z "$j" ]] && { echo UNKNOWN; return; }
  if jq -e --arg f "$fam" --arg c "$ch" \
      '[.nftables[]?.chain? | select(.!=null) | select(.family==$f and .name==$c)] | length > 0' \
      <<<"$j" >/dev/null 2>&1; then echo PRESENT; else echo ABSENT; fi
}
set_present(){ # <family> <set>
  local fam="$1" s="$2" j; j="$(nft_json)"
  [[ -z "$j" ]] && { echo UNKNOWN; return; }
  if jq -e --arg f "$fam" --arg s "$s" \
      '[.nftables[]?.set? | select(.!=null) | select(.family==$f and .name==$s)] | length > 0' \
      <<<"$j" >/dev/null 2>&1; then echo PRESENT; else echo ABSENT; fi
}

module_enabled(){ # <module> -> true|false
  local k=DDOS_ENABLED; [[ "$1" == portscan ]] && k=PORTSCAN_ENABLED
  local b="/etc/nftban/conf.d/$1/main.conf" v="false" x
  [[ -r "$b" ]]       && { x="$(sed -n "s/^[[:space:]]*$k=\"\?\([^\"]*\)\"\?/\\1/p" "$b" | tail -1)"; [[ -n "$x" ]] && v="$x"; }
  [[ -r "$b.local" ]] && { x="$(sed -n "s/^[[:space:]]*$k=\"\?\([^\"]*\)\"\?/\\1/p" "$b.local" | tail -1)"; [[ -n "$x" ]] && v="$x"; }
  echo "$v"
}

plan_field(){ # <module> <field>
  local f="/run/nftban/module-plan-$1.env"
  [[ -r "$f" ]] || { echo ""; return; }
  sed -n "s/^NFTBAN_PLAN_$2=//p" "$f" | tail -1
}
configured_mode(){ # <module>
  local k=DDOS_MODE; [[ "$1" == portscan ]] && k=PORTSCAN_MODE
  local v="" b="/etc/nftban/conf.d/$1/main.conf"
  [[ -r "$b" ]]        && v="$(sed -n "s/^[[:space:]]*$k=\"\?\([^\"]*\)\"\?/\1/p" "$b" | tail -1)"
  [[ -r "$b.local" ]]  && { local l; l="$(sed -n "s/^[[:space:]]*$k=\"\?\([^\"]*\)\"\?/\1/p" "$b.local" | tail -1)"; [[ -n "$l" ]] && v="$l"; }
  echo "${v:-auto}"
}

# --- BASE Layer-0: must survive every transition -----------------------------
# Ground-truthed against a live host: the base chains are input/forward in
# table nftban (NOT nftban_input/nftban_forward, which was an invented guess
# that made every row report BASE_LAYER0_ABSENT).
BASE_CHAINS=(input forward)
base_intact(){
  local fam r=PRESENT
  for fam in ip ip6; do
    local seen=0 c
    for c in "${BASE_CHAINS[@]}"; do
      case "$(chain_present "$fam" "$c")" in
        PRESENT) seen=1 ;;
        UNKNOWN) echo UNKNOWN; return ;;
      esac
    done
    [[ $seen -eq 1 ]] || r=ABSENT
  done
  echo "$r"
}

# --- THE ORACLE: expected projection per module/mode/family ------------------
# Returns "<v4-expect> <v6-expect>" where expect is PRESENT|ABSENT|NA.
expect_projection(){ # <module> <effective_mode>
  case "$1:$2" in
    ddos:classic)      echo "PRESENT PRESENT" ;;
    ddos:suricata)     echo "ABSENT ABSENT" ;;   # classic chains must be gone
    ddos:inactive)     echo "ABSENT ABSENT" ;;
    portscan:classic)  echo "PRESENT PRESENT" ;;
    portscan:suricata) echo "ABSENT ABSENT" ;;   # ⛔ suricata portscan projects NOTHING
    portscan:inactive) echo "ABSENT ABSENT" ;;
    *)                 echo "UNKNOWN UNKNOWN" ;;
  esac
}
classic_chain(){ [[ "$1" == ddos ]] && echo ddos_sanity || echo portscan_detection; }

# --- one assertion row -------------------------------------------------------
assert_state(){ # <module> <state-label> <operation> [expected-configured-mode]
  local mod="$1" intent="$2" op="$3" want_cfg="${4:-$2}"
  local cfg eff basis v4 v6 xor verdict notes=""
  cfg="$(configured_mode "$mod")"
  eff="$(plan_field "$mod" EFFECTIVE_MODE)"; [[ -z "$eff" ]] && eff="NO_PLAN"
  basis="$(plan_field "$mod" RESOLUTION_BASIS)"
  local rid gen curgen
  rid="$(plan_field "$mod" RESOLUTION_ID)"
  gen="$(plan_field "$mod" BOUND_GENERATION)"
  curgen="$(cat /run/nftban/convergence-generation 2>/dev/null || echo 0)"

  # DURABLE INTENT: a lifecycle op must not rewrite configured mode.
  # Compare configured mode against what was actually SET, not against the
  # state label: "auto-classic" is a state name, the configured value is "auto".
  if [[ "$cfg" != "$want_cfg" ]]; then
    notes="${notes}INTENT_REWRITTEN($want_cfg->$cfg);"
  fi
  # PLAN CURRENCY
  if [[ "$eff" != "NO_PLAN" ]]; then
    [[ -z "$rid" ]] && notes="${notes}NO_RESOLUTION_ID;"
    [[ "$gen" != "$curgen" ]] && notes="${notes}PLAN_UNBOUND($gen!=$curgen);"
  fi

  local ch; ch="$(classic_chain "$mod")"
  local e; e="$(expect_projection "$mod" "$eff")"
  local e4="${e%% *}" e6="${e##* }"
  local o4 o6; o4="$(chain_present ip "$ch")"; o6="$(chain_present ip6 "$ch")"

  # ⛔ v4 AND v6 both asserted; unobservable => UNKNOWN, never skipped.
  if [[ "$o4" == UNKNOWN || "$o6" == UNKNOWN ]]; then
    v4=UNKNOWN; v6=UNKNOWN; verdict=UNKNOWN; notes="${notes}RULESET_UNOBSERVABLE;"
  else
    [[ "$o4" == "$e4" ]] && v4=OK || { v4="$o4!=$e4"; notes="${notes}V4_MISMATCH;"; }
    [[ "$o6" == "$e6" ]] && v6=OK || { v6="$o6!=$e6"; notes="${notes}V6_MISMATCH;"; }
  fi

  # XOR: the opposite mode's projection must not co-exist.
  xor=NA
  if [[ "$mod" == ddos ]]; then
    # ⛔ ddos_blocked IS SHARED STATE, NOT A SURICATA-ONLY MARKER.
    # This oracle used `set_present ddos_blocked` as the suricata projection and
    # reported SURICATA_RESIDUE whenever it survived into classic mode. It is the
    # ban set BOTH modes use: classic declares it (DDOS_CLASSIC_BLOCK_SET) and
    # suricata writes the same set. On an UNPATCHED control host, suricata ->
    # classic ends with it PRESENT and the product validator reporting
    # Status: PROTECTED -- so its presence in classic mode is not drift, and
    # those FAIL rows were instrument error, not product failure.
    #   SHARED OBJECT != OTHER MODE'"'"'S PROJECTION
    #
    # Suricata mode has NO nft object of its own, so "classic must not carry
    # suricata residue" has nothing observable to assert. That direction is
    # therefore NOT_ASSERTABLE and says so, rather than silently reporting OK --
    # an unasserted axis must never read as a passed one.
    #   SAME MODE CONTRACT != SAME KERNEL OBJECT SHAPE
    case "$eff" in
      classic)  xor=NOT_ASSERTABLE ;;
      suricata) [[ "$o4" == PRESENT || "$o6" == PRESENT ]] && { xor=VIOLATED; notes="${notes}CLASSIC_RESIDUE;"; } || xor=OK ;;
    esac
  else
    # PortScan/Suricata has no nft projection; XOR is one-directional.
    case "$eff" in
      suricata) [[ "$o4" == PRESENT || "$o6" == PRESENT ]] && { xor=VIOLATED; notes="${notes}CLASSIC_RESIDUE;"; } || xor=OK ;;
      classic)  xor=OK ;;
    esac
  fi

  [[ "${SETTLE_TIMEOUT:-0}" == "1" ]] && { notes="${notes}SETTLE_TIMEOUT;"; SETTLE_TIMEOUT=0; }
  local b; b="$(base_intact)"
  [[ "$b" != PRESENT ]] && notes="${notes}BASE_LAYER0_$b;"

  # HEALTH: UNKNOWN must not be reported as a pass.
  local hj hstatus="NA"
  hj="$(nftban health --json 2>/dev/null)"
  if [[ -n "$hj" ]]; then
    hstatus="$(jq -r '.status // "NA"' <<<"$hj" 2>/dev/null || echo NA)"
    local cons; cons="$(jq -r '.consistency.kernel_vs_validator // "NA"' <<<"$hj" 2>/dev/null || echo NA)"
    [[ "$cons" == unknown && "$hstatus" == protected ]] && notes="${notes}UNKNOWN_COLLAPSED_TO_PASS;"
  fi
  # ⛔ FAILED_UNITS_COUNT != FAILED_UNIT_EVIDENCE.
  # The first revision recorded only a count. By the time anyone looked, nothing
  # was failed any more, so two FAIL rows could not be adjudicated at all: a
  # bare "2" names no unit, no state, and no cause. Capture identities AT THE
  # MOMENT the assertion is evaluated -- afterwards is a different system.
  # ⛔ A failed query is UNKNOWN, never zero. ABSENT_QUERY != RESOURCE_ABSENT.
  local failed_raw failed names states
  if failed_raw="$(systemctl list-units --state=failed --no-legend --no-pager 2>/dev/null)"; then
      # ⛔ systemctl prefixes a FAILED unit line with a "●" status glyph, so $1
      # is the bullet and the unit name is $2. The first revision recorded
      # FAILED_UNIT_NAMES=● for every row -- evidence that names nothing is no
      # better than the bare count it replaced.
      #   A FIELD INDEX IS AN ASSUMPTION ABOUT OUTPUT SHAPE. VERIFY IT.
      names="$(awk '/nftban/{ if ($1 ~ /^[●*]$/) print $2; else print $1 }' <<<"$failed_raw" | paste -sd, -)"
      states="$(awk '/nftban/{ if ($1 ~ /^[●*]$/) print $2"="$4"/"$5; else print $1"="$3"/"$4 }' <<<"$failed_raw" | paste -sd, -)"
      failed="$(awk '/nftban/' <<<"$failed_raw" | grep -c . || true)"
      if [[ "${failed:-0}" -gt 0 ]]; then
          notes="${notes}FAILED_UNIT_COUNT=$failed;FAILED_UNIT_NAMES=${names};FAILED_UNIT_STATES=${states};"
      fi
  else
      notes="${notes}FAILED_UNIT_STATE=UNKNOWN;"
  fi

  [[ -z "${verdict:-}" || "$verdict" != UNKNOWN ]] && { [[ -z "$notes" ]] && verdict=PASS || verdict=FAIL; }
  [[ "$verdict" == FAIL ]] && FAILROWS=$((FAILROWS+1))
  [[ "$verdict" == UNKNOWN ]] && UNKNOWNROWS=$((UNKNOWNROWS+1))

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DISTRO" "$mod" "$intent" "$eff" "${basis:-none}" "$op" "$v4" "$v6" "$xor" "$hstatus" "$verdict" "${notes:-clean}" >> "$ROWS"
  nft_json > "$EVID/ruleset-${mod}-${intent}-${op}.json" 2>/dev/null || true
}

set_mode(){ # <module> <mode>
  local k=DDOS_MODE; [[ "$1" == portscan ]] && k=PORTSCAN_MODE
  local ke=DDOS_ENABLED; [[ "$1" == portscan ]] && ke=PORTSCAN_ENABLED
  local f="/etc/nftban/conf.d/$1/main.conf.local"
  mkdir -p "$(dirname "$f")"
  printf '%s="true"\n%s="%s"\n' "$ke" "$k" "$2" > "$f"
}
set_enabled(){ # <module> <true|false>
  local ke=DDOS_ENABLED; [[ "$1" == portscan ]] && ke=PORTSCAN_ENABLED
  local f="/etc/nftban/conf.d/$1/main.conf.local"; mkdir -p "$(dirname "$f")"
  printf '%s="%s"\n' "$ke" "$2" > "$f"
}

# ⛔ CAUSE the availability, never inject the plan.
suricata_up(){   systemctl start suricata 2>/dev/null || true; sleep 3; }
suricata_down(){ systemctl stop  suricata 2>/dev/null || true; }

# ⛔ WAIT FOR CONVERGENCE, DO NOT GUESS A DURATION.
# `firewall rebuild` is a 12-step operation and bumps the generation more than
# once; a fixed sleep sampled it mid-flight and produced 16 spurious
# PLAN_UNBOUND rows plus health=down. Those described the INSTRUMENT, not the
# product -- verified by hand: after a complete rebuild both plan records exist
# and match the current generation.
#   OBSERVING A TRANSITION IN PROGRESS IS NOT OBSERVING ITS RESULT.
#   A FIXED SLEEP IS A GUESS ABOUT SOMEONE ELSE'S DURATION.
# Poll until the generation STOPS MOVING and both module records are bound to
# it. Timeout is a real UNKNOWN, never a silent continue.
settle(){
    local deadline=$(( SECONDS + ${MATRIX_SETTLE_MAX:-90} )) last="" now stable=0
    while (( SECONDS < deadline )); do
        now="$(cat /run/nftban/convergence-generation 2>/dev/null || echo 0)"
        if [[ "$now" == "$last" ]]; then
            local ok=1 m
            for m in ddos portscan; do
                local g ena
                g="$(sed -n 's/^NFTBAN_PLAN_BOUND_GENERATION=//p' "/run/nftban/module-plan-$m.env" 2>/dev/null)"
                # ⛔ An ABSENT record for an ENABLED module is NOT convergence.
                # The earlier condition only rejected a MISMATCH, so an absent
                # record satisfied it and settle returned immediately -- which
                # made 16 rows report PLAN_UNBOUND with an EMPTY generation and
                # left the instrument unable to distinguish "not yet
                # republished" from "never republished".
                #   ABSENT != CONVERGED.
                ena="$(module_enabled "$m")"
                if [[ "$ena" == true ]]; then
                    [[ -z "$g" || "$g" != "$now" ]] && ok=0
                else
                    [[ -n "$g" && "$g" != "$now" ]] && ok=0
                fi
            done
            (( ok == 1 )) && { stable=$((stable+1)); (( stable >= 2 )) && return 0; }
        else
            stable=0
        fi
        last="$now"; sleep 3
    done
    SETTLE_TIMEOUT=1
    return 1
}

run_ops(){ # <module> <state-label> <configured-value>
  local mod="$1" intent="$2" cfgval="$3"
  nftban "$mod" reload >/dev/null 2>&1 || true;          settle; assert_state "$mod" "$intent" reload         "$cfgval"
  nftban firewall rebuild --quiet >/dev/null 2>&1||true; settle; assert_state "$mod" "$intent" rebuild        "$cfgval"
  # ⛔ `--force` is REQUIRED: without it reset prints "Use --force to confirm" and
  # returns without doing anything. The matrix previously ran `reset --quiet`, so
  # all 8 reset rows per host tested a command that REFUSED TO RUN and were
  # reported as failures of the product.
  #   A COMMAND THAT DECLINED TO EXECUTE HAS NOT BEEN TESTED.
  nftban firewall reset --force --quiet >/dev/null 2>&1 || true; settle; assert_state "$mod" "$intent" reset          "$cfgval"
  systemctl restart nftband >/dev/null 2>&1 || true;     settle; assert_state "$mod" "$intent" daemon-restart "$cfgval"
}

main(){
  command -v jq >/dev/null 2>&1 || { fatal "jq absent — ruleset observation impossible"; exit 2; }
  command -v nftban >/dev/null 2>&1 || { fatal "nftban absent — package install failed"; exit 2; }
  nft_json >/dev/null || { fatal "nft ruleset unreadable — every downstream row would be invalid"; exit 2; }

  # ⛔ REBOOT-ONLY MODE. Invoked by v1229_7-reboot-recovery.sh AFTER the host has
  # returned and its identity is verified. It asserts that whatever state was
  # converged before the reboot SURVIVED it -- it must not re-drive the state
  # machine, or it would prove convergence rather than persistence.
  #   RE-CONVERGING AFTER REBOOT IS NOT PERSISTENCE.
  if [[ "${MATRIX_REBOOT_ONLY:-0}" == "1" ]]; then
    for mod in ddos portscan; do
      assert_state "$mod" reboot reboot "$(configured_mode "$mod")"
    done
    log ""
    log "DISTRO|MODULE|INTENT|EFFECTIVE|BASIS|OPERATION|V4|V6|XOR|HEALTH|VERDICT|NOTES"
    column -t -s $'\t' "$ROWS" >&2 2>/dev/null || cat "$ROWS" >&2
    log ""
    log "post-reboot rows=$(wc -l < "$ROWS")  FAIL=$FAILROWS  UNKNOWN=$UNKNOWNROWS"
    [[ $FAILROWS -gt 0 || $UNKNOWNROWS -gt 0 ]] && exit 1
    exit 0
  fi

  for mod in ddos portscan; do
    # 1. disabled
    set_enabled "$mod" false; nftban "$mod" reload >/dev/null 2>&1 || true; settle
    assert_state "$mod" disabled disabled "$(configured_mode "$mod")"

    # 2. classic (explicit)
    set_mode "$mod" classic; run_ops "$mod" classic classic

    # 3. suricata (explicit) — precondition genuinely established
    suricata_up
    set_mode "$mod" suricata; run_ops "$mod" suricata suricata

    # 4. auto -> classic : suricata genuinely UNAVAILABLE
    suricata_down
    set_mode "$mod" auto; run_ops "$mod" auto-classic auto

    # 5. auto -> suricata : suricata genuinely AVAILABLE
    suricata_up
    set_mode "$mod" auto; run_ops "$mod" auto-suricata auto
  done

  log ""
  log "DISTRO|MODULE|INTENT|EFFECTIVE|BASIS|OPERATION|V4|V6|XOR|HEALTH|VERDICT|NOTES"
  column -t -s $'\t' "$ROWS" >&2 2>/dev/null || cat "$ROWS" >&2
  log ""
  log "rows=$(wc -l < "$ROWS")  FAIL=$FAILROWS  UNKNOWN=$UNKNOWNROWS  evidence=$EVID"
  [[ $FATAL -eq 1 ]] && exit 2
  [[ $FAILROWS -gt 0 || $UNKNOWNROWS -gt 0 ]] && exit 1
  exit 0
}
# =============================================================================
# --selftest : falsify the oracle offline, before any green matrix is trusted.
#
# ⛔ A matrix whose assertions were never made to FAIL proves nothing. Each case
#    below injects a synthetic observation and requires the expected verdict.
#    The v4-only teardown case is the one that closes the previously UNGUARDED
#    IPv6 teardown-symmetry subclaim (Pass B §14a).
# =============================================================================
selftest(){
  local pass=0 fail=0
  _case(){ # <name> <expect> <fn>
    local name="$1" expect="$2" fn="$3" got
    got="$($fn)"
    if [[ "$got" == "$expect" ]]; then pass=$((pass+1)); echo "  ok    $name -> $expect"
    else fail=$((fail+1)); echo "  FAIL  $name -> got '$got', want '$expect'"; fi
  }

  # S1 v4-only teardown: classic chain gone from ip, still live in ip6 under a
  #    suricata plan. THE motivating case for the unguarded v6 subclaim.
  s1(){ chain_present(){ [[ "$1" == ip6 ]] && echo PRESENT || echo ABSENT; }
        local e; e="$(expect_projection ddos suricata)"; local e6="${e##* }"
        [[ "$(chain_present ip6 ddos_sanity)" != "$e6" ]] && echo FAIL || echo PASS; }
  _case "S1 v4-only teardown leaves ip6 classic residue" FAIL s1

  # S2 both families torn down -> clean.
  s2(){ chain_present(){ echo ABSENT; }
        local e; e="$(expect_projection ddos suricata)"
        [[ "$(chain_present ip ddos_sanity)" == "${e%% *}" && "$(chain_present ip6 ddos_sanity)" == "${e##* }" ]] && echo PASS || echo FAIL; }
  _case "S2 both families torn down" PASS s2

  # S3 PortScan/Suricata projects NOTHING -> absence is CORRECT, not a failure.
  #    A generic "suricata requires an nft chain" oracle would fail here.
  s3(){ local e; e="$(expect_projection portscan suricata)"
        [[ "$e" == "ABSENT ABSENT" ]] && echo PASS || echo FAIL; }
  _case "S3 portscan/suricata absence is expected, not a defect" PASS s3

  # S4 unobservable ruleset -> UNKNOWN, never skipped or passed.
  s4(){ nft_json(){ echo ""; }; chain_present(){ local j; j="$(nft_json)"; [[ -z "$j" ]] && echo UNKNOWN || echo ABSENT; }
        [[ "$(chain_present ip ddos_sanity)" == UNKNOWN ]] && echo UNKNOWN || echo LEAKED; }
  _case "S4 unobservable ruleset is UNKNOWN" UNKNOWN s4

  # S5 the oracle must not accept an unresolved mode as a projection target.
  s5(){ local e; e="$(expect_projection ddos unknown)"; [[ "$e" == "UNKNOWN UNKNOWN" ]] && echo PASS || echo FAIL; }
  _case "S5 unknown effective_mode yields no projection expectation" PASS s5

  # S6 — THE DEFECT THE SUITE MISSED. Enabled module, generation stable and
  #      current, plan record ABSENT. settle() must NOT report converged.
  #      The original condition `[[ -n "$g" && "$g" != "$now" ]]` left ok=1 when
  #      $g was empty, so absence satisfied the convergence predicate and the
  #      sampler read state mid-transition. An unchanged 5/5 suite still missed
  #      this, which is why the control is written against the CONDITION, not
  #      the outcome.
  #        ABSENT != CONVERGED.
  s6(){
    local now=42 g="" ena=true ok=1
    # replay the CURRENT predicate verbatim
    if [[ "$ena" == true ]]; then
      [[ -z "$g" || "$g" != "$now" ]] && ok=0
    else
      [[ -n "$g" && "$g" != "$now" ]] && ok=0
    fi
    [[ $ok -eq 0 ]] && echo NOT_CONVERGED || echo CONVERGED
  }
  _case "S6 enabled + stable gen + ABSENT record is NOT converged" NOT_CONVERGED s6

  # S6b — the disabled contract still holds: no record is legitimate there.
  s6b(){
    local now=42 g="" ena=false ok=1
    if [[ "$ena" == true ]]; then
      [[ -z "$g" || "$g" != "$now" ]] && ok=0
    else
      [[ -n "$g" && "$g" != "$now" ]] && ok=0
    fi
    [[ $ok -eq 1 ]] && echo CONVERGED || echo NOT_CONVERGED
  }
  _case "S6b disabled + no record IS converged (contract preserved)" CONVERGED s6b

  echo ""
  echo "selftest: $pass passed, $fail failed"
  [[ $fail -eq 0 ]]
}

[[ "${1:-}" == "--selftest" ]] && { selftest; exit $?; }
main "$@"
