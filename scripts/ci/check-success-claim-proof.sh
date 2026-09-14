#!/usr/bin/env bash
# =============================================================================
# NFTBan - SUCCESS_CLAIM_REQUIRES_PROVEN_SUCCESS (v1.231.0, cross-cutting control)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-success-claim-proof"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Narrow structural control for the class SUCCESS_CLAIM_REQUIRES_PROVEN_SUCCESS. Within the declared subject files, an affirmative success emitter must not be reached from a lexical region in which a declared transport command ran with its exit status DISCARDED. Starts at the two proven v1.231.0 instances (cmd_connector.sh syslog + kafka push) and expands only on a demonstrated miss."
# meta:input="the declared SUBJECTS below; or --scan FILE --emitter NAME"
# meta:output="one FAIL line per violation; SUCCESS_CLAIM_UNPROVEN_SITES = N"
# meta:depends="bash"
# meta:inventory.files="cli/lib/nftban/cli/cmd_connector.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# THE CLASS
#     <transport command>          # exit status never examined
#     print_success "..."          # affirmative claim, unconditional
#
# PROVEN INSTANCES (lab4, Rocky Linux 9.8, tree @0c7ad204, before the fix):
#   cmd_connector.sh syslog  `echo "$msg" | nc ...` with nc ABSENT on the host:
#       stderr "nc: command not found", stdout "OK Event pushed to syslog", rc=0.
#   cmd_connector.sh kafka   `... | kafka-console-producer.sh ... 2>/dev/null`
#       with a producer exiting 1: the diagnostic is swallowed by the redirect
#       and the rc discarded; stdout "OK Event pushed to Kafka", rc=0.
#
# THE PREDICATE, EXACTLY
#   Per subject file and declared emitter the file is walked as LOGICAL
#   statements (backslash continuations joined, blank/comment lines ignored).
#   A REGION is reset at every case-arm label, every `;;`, every `esac`, and
#   every function boundary. Inside a region the guard records a statement that
#     (a) invokes a command word drawn from the declared TRANSPORTS list, and
#     (b) is UNCHECKED -- its status is neither consumed by a conditional head
#         (`if`/`elif`/`while`/`until`), nor by `&&` / `||`, nor captured by an
#         `rc=$?`-style next statement, nor taken as the value of a command
#         substitution assignment.
#   Reaching the emitter while such a record still stands is a FAIL.
#
# WHAT THIS GUARD DOES NOT PROVE -- read before making any claim on it.
#   1. IT DOES NOT PROVE CONTROL-FLOW DOMINANCE. It reasons about LEXICAL
#      REGIONS, not about which statements actually dominate the emitter on
#      every execution path. An unchecked transport call that can never reach
#      the emitter would still be flagged; an unchecked call in a DIFFERENT
#      region that does reach the emitter would not be.
#   2. IT DOES NOT PROVE THE SUCCESS CLAIM IS TRUE. Any checked status
#      satisfies it. Whether the check is the RIGHT check (curl -sf versus an
#      HTTP 500 body; a zero-byte write that "succeeded") is a semantic
#      question a structural control cannot answer.
#   3. IT DOES NOT SEE A TRANSPORT INSIDE A QUOTED SPAN. Quoted string literals
#      are stripped before the command-word search, so that an error message
#      NAMING the transport ("... (nc exit 1)") is not read as an invocation of
#      it -- MENTION != CODE. The cost is symmetric and declared: a transport
#      invoked inside a quoted command substitution (x="$(curl ...)") or via
#      `eval` of a string is NOT seen. Unquoted command substitutions are.
#      Escaped quotes inside a literal are not modelled.
#   4. ITS COVERAGE IS THE DECLARED LIST, NOT THE REPOSITORY. Only SUBJECTS are
#      scanned and only TRANSPORTS are recognised. Shell builtins and plain
#      redirections (`echo ... >> "$path"`) are deliberately NOT transports, so
#      the `file` connector arm is NOT covered and is NOT claimed safe.
#   5. THE SIBLING EMITTERS ARE ENUMERATED BUT OUT OF SCOPE. Enumerated from
#      the code (definitions under cli/lib/nftban/, tests excluded):
#        _connector_print_success  cli/cmd_connector.sh          IN SCOPE
#        _zabbix_print_success     cli/cmd_zabbix.sh             17 call sites, unaudited
#        nftban_success            core/nftban_geoban.sh         unaudited
#        nft_ipc_success           lib/nft_ipc.sh                unaudited
#        nftban_log_success        helpers/nftban_logger.sh      unaudited
#        log_success               helpers/nftban_logger.sh      unaudited
#        log_success               setup/install_vmagent.sh      unaudited
#        cmd_success               lib/cmd_common.sh             unaudited
#        json_success              helpers/json_output.sh        unaudited
#      They are RECORDED AS UNASSESSED, not asserted clean. Adding one is an
#      owner decision and must arrive with its own audited call sites; wiring
#      them blind converts this control into pre-existing-debt noise.
#   6. F-02 (health readiness PASS across install-failure states) and the
#      Lane-2 postinst exit-0 defect are members of the same CLASS but are NOT
#      members of this guard's subject set. A generic guard does not substitute
#      for a semantic fix -- each instance keeps its own defect handle.
#
# Exit: 0 clean - 1 violations found - 2 tool/config failure, which includes a
#       subject that yields ZERO emitter call sites: an empty scan is never a
#       pass, and a drifted/renamed subject must fail loudly.
# =============================================================================
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- declared scope ----------------------------------------------------------
# file<TAB>emitter. Start narrow; expand only when an actual missed case proves
# the checker incomplete (owner ruling, v1.231.0).
SUBJECTS=(
    "cli/lib/nftban/cli/cmd_connector.sh	_connector_print_success"
)

# Command words whose exit status IS the evidence for the claim that follows.
TRANSPORTS=(
    nc ncat curl wget socat logger
    kafka-console-producer.sh kafkacat kcat mosquitto_pub
)

SCAN_FILE=""; SCAN_EMITTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scan)    SCAN_FILE="${2:?--scan needs a path}"; shift 2 ;;
        --emitter) SCAN_EMITTER="${2:?--emitter needs a name}"; shift 2 ;;
        -h|--help) sed -n '2,94p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

SCAN_SITES=0
SCAN_VIOL=0
STRIPPED=""
TRANSPORT_VERB=""

# MENTION != CODE.
# Remove quoted string literals and trailing comments from a logical statement
# before looking for a command word, so that an ERROR MESSAGE naming the
# transport ("... (nc exit 1)") is never mistaken for an invocation of it.
# Sets the global STRIPPED. No subshell: the caller needs this ~900x per file.
_strip_literals() {
    local s="$1" ch q="" prev=" " i n
    STRIPPED=""
    n=${#s}
    for (( i=0; i<n; i++ )); do
        ch="${s:i:1}"
        if [[ -z "$q" ]]; then
            if [[ "$ch" == '"' || "$ch" == "'" ]]; then q="$ch"; prev="$ch"; continue; fi
            # unquoted '#' at a word boundary starts a trailing comment
            if [[ "$ch" == "#" && "$prev" == " " ]]; then break; fi
            STRIPPED+="$ch"
        elif [[ "$ch" == "$q" ]]; then
            q=""
        fi
        prev="$ch"
    done
}

# Sets the global TRANSPORT_VERB when the (literal-stripped) statement invokes
# a declared transport in command-word position; returns 1 otherwise.
_transport_word() {   # $1 = literal-stripped logical statement
    local st="$1" v
    TRANSPORT_VERB=""
    for v in "${TRANSPORTS[@]}"; do
        if [[ "$st" =~ (^|[[:space:]\;\|\&\(\{])"$v"([[:space:]]|$) ]]; then
            TRANSPORT_VERB="$v"; return 0
        fi
    done
    return 1
}

_is_checked() {       # $1 = logical statement, $2 = next logical statement
    local st="$1" nxt="${2:-}"
    # status consumed by a conditional head
    [[ "$st" =~ ^(if|elif|while|until)[[:space:]] ]] && return 0
    # status consumed by a list operator
    [[ "$st" == *" && "* || "$st" == *" || "* ]] && return 0
    # the transport is the value of a command substitution: its status becomes
    # the assignment's status, which errexit or the next statement can consume
    [[ "$st" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*\$\( ]] && return 0
    [[ "$st" =~ ^(local|declare|readonly|export)[[:space:]] ]] && return 0
    # status captured explicitly by the next statement
    [[ "$nxt" =~ ^[A-Za-z_][A-Za-z0-9_]*=\$\? ]] && return 0
    [[ "$nxt" =~ \$\? ]] && [[ "$nxt" =~ ^(if|\[\[|case|test) ]] && return 0
    return 1
}

# scan_one <file> <emitter>
#   prints FAIL lines on stdout; sets SCAN_SITES / SCAN_VIOL.  No subshell, so
#   the counters are real globals and cannot be lost to a pipeline.
scan_one() {
    local file="$1" emitter="$2"
    local -a raw=() lno=() stmt=()
    mapfile -t raw < "$file"

    # --- fold backslash continuations into logical statements ---------------
    local i n acc="" start=0 line trimmed
    n=${#raw[@]}
    for (( i=0; i<n; i++ )); do
        line="${raw[$i]}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "$acc" ]]; then
            [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
            start=$(( i + 1 ))
        fi
        if [[ "$line" == *\\ ]]; then
            acc+="${trimmed%\\} "
            continue
        fi
        acc+="$trimmed"
        acc="$(printf '%s' "$acc" | tr -s '[:space:]' ' ')"
        acc="${acc#"${acc%%[![:space:]]*}"}"
        acc="${acc%"${acc##*[![:space:]]}"}"
        lno+=( "$start" ); stmt+=( "$acc" )
        acc=""
    done

    SCAN_SITES=0; SCAN_VIOL=0
    local pending_line=0 pending_cmd="" s ln nxt verb reset
    local m=${#stmt[@]}
    for (( i=0; i<m; i++ )); do
        s="${stmt[$i]}"; ln="${lno[$i]}"

        # --- region boundaries ------------------------------------------------
        reset=0
        [[ "$s" == ";;" || "$s" == "esac" || "$s" == "}" ]] && reset=1
        [[ "$s" =~ ^[^\(\)]*\)$ ]] && reset=1                       # case-arm label
        [[ "$s" =~ ^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{?$ ]] && reset=1
        [[ "$s" == *" ;;" ]] && reset=1                              # one-line arm
        if [[ $reset -eq 1 ]]; then
            pending_line=0; pending_cmd=""
            # a bare boundary carries no body; a one-line arm does, so fall through
            [[ "$s" == *" ;;" ]] || continue
        fi

        # --- emitter call site ------------------------------------------------
        if [[ "$s" =~ (^|[[:space:]\;\|\&])"$emitter"[[:space:]] ]]; then
            SCAN_SITES=$(( SCAN_SITES + 1 ))
            if [[ $pending_line -ne 0 ]]; then
                printf 'FAIL [SUCCESS_CLAIM_UNPROVEN] %s:%s - %s is reached from a region in which `%s` ran at %s:%s with its exit status discarded. Check the status and emit FAILURE when it failed; do not claim success.\n' \
                    "$file" "$ln" "$emitter" "$pending_cmd" "$file" "$pending_line"
                SCAN_VIOL=$(( SCAN_VIOL + 1 ))
            fi
            continue
        fi

        # --- transport statement ----------------------------------------------
        _strip_literals "$s"
        if _transport_word "$STRIPPED"; then
            verb="$TRANSPORT_VERB"
            nxt=""; (( i + 1 < m )) && nxt="${stmt[$(( i + 1 ))]}"
            if _is_checked "$s" "$nxt"; then
                pending_line=0; pending_cmd=""
            else
                pending_line="$ln"; pending_cmd="$verb"
            fi
        fi
    done
}

# --- ad-hoc scan (used by the falsifiability control's fixtures) -------------
if [[ -n "$SCAN_FILE" ]]; then
    [[ -n "$SCAN_EMITTER" ]] || { echo "ERROR: --scan requires --emitter" >&2; exit 2; }
    [[ -r "$SCAN_FILE" ]]    || { printf 'ERROR: unreadable subject: %s\n' "$SCAN_FILE" >&2; exit 2; }
    scan_one "$SCAN_FILE" "$SCAN_EMITTER"
    if [[ "$SCAN_SITES" -eq 0 ]]; then
        printf 'ERROR: %s yields ZERO call sites of %s - an empty scan is not a pass.\n' \
            "$SCAN_FILE" "$SCAN_EMITTER" >&2
        exit 2
    fi
    printf 'SUCCESS_CLAIM_UNPROVEN_SITES = %d   (call sites examined: %d)\n' "$SCAN_VIOL" "$SCAN_SITES"
    exit $(( SCAN_VIOL > 0 ? 1 : 0 ))
fi

# --- declared-subject scan ---------------------------------------------------
cd "$ROOT"
echo "== SUCCESS_CLAIM_REQUIRES_PROVEN_SUCCESS (narrow: declared subjects only) =="
total_viol=0
for entry in "${SUBJECTS[@]}"; do
    IFS=$'\t' read -r f emitter <<<"$entry"
    [[ -r "$f" ]] || { printf 'ERROR: declared subject missing: %s\n' "$f" >&2; exit 2; }
    scan_one "$f" "$emitter"
    if [[ "$SCAN_SITES" -eq 0 ]]; then
        printf 'ERROR: %s yields ZERO call sites of %s - subject drifted; an empty scan is not a pass.\n' \
            "$f" "$emitter" >&2
        exit 2
    fi
    printf '  %s  emitter=%s  call_sites=%d  violations=%d\n' "$f" "$emitter" "$SCAN_SITES" "$SCAN_VIOL"
    total_viol=$(( total_viol + SCAN_VIOL ))
done

[[ $total_viol -eq 0 ]] && echo "  [OK] every declared success emitter is reached only from a checked-status region"
printf 'SUCCESS_CLAIM_UNPROVEN_SITES = %d\n' "$total_viol"
exit $(( total_viol > 0 ? 1 : 0 ))
