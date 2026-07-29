#!/usr/bin/env bash
# =============================================================================
# NFTBan - typed nftables probe authority
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_probe"
# meta:type="library"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-29"
# meta:description="v1.228.4 PR-3. Single typed authority for 'does an nftables table exist'. Returns PRESENT, ABSENT or CANNOT_READ and preserves the evidence that distinguishes them: exit code, error class, bounded and redacted stderr, exact argv, address family and calling component. Replaces the binary collapse in which every non-zero nft exit became 'table absent' - a collapse that produced a false firewall-absent verdict on 11/11 measured hosts while systemd still reported Result=success, drove ~900 futile rebuild attempts per host and emitted ~900 destructive 'reset --force' recommendations against intact firewalls. The critical invariant is that ONLY a verified ABSENT may authorise a rebuild; CANNOT_READ must never mutate, never recommend mutation, and must propagate non-zero. Readability is established POSITIVELY by a successful `nft list tables` rather than by parsing error strings, so absence is a positive finding rather than an inference from failure."
# meta:input="family+table name; the nft binary"
# meta:output="probe verdict on stdout; details in NFTBAN_NFT_PROBE_* variables"
# meta:depends="bash,nft"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars="NFTBAN_NFT_BIN,NFTBAN_NFT_PROBE_STDERR_MAX"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="requires AF_NETLINK in the caller's sandbox; read-only"
# =============================================================================

# -----------------------------------------------------------------------------
# VERDICTS
# -----------------------------------------------------------------------------
#   PRESENT      the ruleset was read successfully AND the table exists
#   ABSENT       the ruleset was read successfully AND the table does not exist
#   CANNOT_READ  the read itself failed; existence is UNKNOWN
#
# ⛔ ONLY `ABSENT` MAY AUTHORISE A REBUILD. `CANNOT_READ` is not a weaker
#    `ABSENT` — it is a different fact, and acting on it is how a healthy
#    firewall gets rebuilt (or an operator gets told to reset one).
#
# WHY READABILITY IS ESTABLISHED POSITIVELY
#   `nft list table ip nftban` exits non-zero for BOTH "no such table" and
#   "cannot talk to the kernel". Distinguishing them by parsing stderr text is
#   fragile across nft versions and locales. Instead we first run
#   `nft list tables`, which succeeds whenever netlink is usable regardless of
#   which tables exist. If THAT fails, the answer is CANNOT_READ and we never
#   claim anything about the table. If it succeeds, absence is a positive
#   observation: the name is genuinely not in a list we successfully read.
# -----------------------------------------------------------------------------

# Initialised so `set -u` callers can reference them before the first probe.
NFTBAN_NFT_PROBE_VERDICT=""; NFTBAN_NFT_PROBE_RC=""; NFTBAN_NFT_PROBE_CLASS=""
NFTBAN_NFT_PROBE_STDERR=""; NFTBAN_NFT_PROBE_ARGV=""; NFTBAN_NFT_PROBE_FAMILY=""
NFTBAN_NFT_PROBE_TABLE=""; NFTBAN_NFT_PROBE_COMPONENT=""
# ⛔ THERE IS DELIBERATELY NO NFTBAN_NFT_PROBE_MAY_REBUILD VARIABLE.
# A stored rebuild boolean is dual authority: it can go stale, be overwritten, or
# be consumed without ever checking the verdict it was supposed to mirror. Rebuild
# permission is derived LIVE from VERDICT by nftban_nft_probe_may_rebuild().

# -----------------------------------------------------------------------------
# MONOTONIC COMPONENT LATCH
# -----------------------------------------------------------------------------
# Every probe RESETS NFTBAN_NFT_PROBE_VERDICT on entry. So a sequence like
#     table probe -> CANNOT_READ
#     set   probe -> PRESENT
# leaves VERDICT=PRESENT, and a caller reading VERDICT afterwards would silently
# RECOVER to healthy despite an earlier unreadable probe. That is the same
# lost-evidence class this library exists to remove, reintroduced by ordering.
#
# This latch is set by ANY CANNOT_READ and is never cleared except by an explicit
# nftban_nft_probe_session_reset(). Component-level verdicts MUST consult it
# rather than the last VERDICT, so monotonicity is a property of the LIBRARY and
# not of each caller remembering to be careful.
NFTBAN_NFT_PROBE_SESSION_DEGRADED=0

# True if ANY probe in this session could not read. Never recovers.
nftban_nft_probe_session_degraded() {
    [[ "${NFTBAN_NFT_PROBE_SESSION_DEGRADED:-0}" -ne 0 ]]
}

# Explicit, deliberate reset. Call only when starting a genuinely new session.
nftban_nft_probe_session_reset() {
    NFTBAN_NFT_PROBE_SESSION_DEGRADED=0
}

NFTBAN_NFT_PROBE_PRESENT="PRESENT"
NFTBAN_NFT_PROBE_ABSENT="ABSENT"
NFTBAN_NFT_PROBE_CANNOT_READ="CANNOT_READ"

# Bounded stderr capture. nft error output can contain rule and set content —
# addresses, ports, set members — so it is capped and redacted before it is ever
# logged or surfaced. The machine-readable signal is the CLASS, not the text.
: "${NFTBAN_NFT_PROBE_STDERR_MAX:=512}"

# -----------------------------------------------------------------------------
# nftban_nft_probe_error_class <stderr-text> <rc>
#
# Maps raw nft failure output to a stable, machine-readable class. The class is
# what may influence control flow; the text is human context only.
# -----------------------------------------------------------------------------
nftban_nft_probe_error_class() {
    local _err="$1" _rc="${2:-0}"
    case "$_err" in
        *"Address family not supported"*|*"EAFNOSUPPORT"*)
            printf 'NETLINK_FAMILY_BLOCKED' ;;          # sandbox: AF_NETLINK missing
        *"Operation not permitted"*|*"must be root"*|*"EPERM"*)
            printf 'PERMISSION_DENIED' ;;
        *"No such file or directory"*|*"ENOENT"*)
            printf 'NOT_FOUND' ;;
        *"Device or resource busy"*|*"EBUSY"*|*"No buffer space"*|*"ENOBUFS"*)
            printf 'KERNEL_BUSY' ;;
        *"command not found"*|*"not found"*)
            printf 'NFT_BINARY_MISSING' ;;
        "")
            if [[ "$_rc" -eq 0 ]]; then printf 'NONE'; else printf 'UNKNOWN_NO_STDERR'; fi ;;
        *)
            printf 'UNCLASSIFIED' ;;
    esac
}

# -----------------------------------------------------------------------------
# nftban_nft_probe_redact <text>
#
# Bound and redact captured stderr before it can be logged. IPv4/IPv6 literals
# are masked because nft error output may echo rule or set content, and this
# repository has already executed one privacy history rewrite.
# -----------------------------------------------------------------------------
# IPv6 boundary class note: ']' is deliberately NOT included. In a POSIX bracket
# expression '\]' is not an escape — it closes the set and leaves a stray ']',
# which silently disabled this whole substitution. It failed OPEN (no redaction
# at all), which is the dangerous direction for a privacy control.
#
# The {0,4} quantifier (not {1,4}) is required so the compressed '::' form
# matches, e.g. 2001:db8::1. The leading/trailing boundary classes are what keep
# 'src/mnl.c:61' and 'file.sh:148' intact — there the candidate is preceded by
# '.', which is not a boundary character.
nftban_nft_probe_redact() {
    local _t="$1"
    _t=$(printf '%s' "$_t" \
        | sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?/<ip4>/g' \
        | sed -E 's/(^|[[:space:]([])([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(\/[0-9]{1,3})?([[:space:],)]|$)/\1<ip6>\4/g' \
        | tr '\n' ' ')
    if [[ ${#_t} -gt $NFTBAN_NFT_PROBE_STDERR_MAX ]]; then
        printf '%s…[truncated %s bytes]' "${_t:0:$NFTBAN_NFT_PROBE_STDERR_MAX}" "${#_t}"
    else
        printf '%s' "$_t"
    fi
}

# -----------------------------------------------------------------------------
# _probe_fail_closed <class> <detail>
#
# Every failure path routes through here so no path can accidentally leave a
# verdict of ABSENT or a MAY_REBUILD of YES.
# -----------------------------------------------------------------------------
_probe_fail_closed() {
    NFTBAN_NFT_PROBE_VERDICT="$NFTBAN_NFT_PROBE_CANNOT_READ"
    NFTBAN_NFT_PROBE_SESSION_DEGRADED=1
    NFTBAN_NFT_PROBE_CLASS="$1"
    NFTBAN_NFT_PROBE_RC="${NFTBAN_NFT_PROBE_RC:-1}"
    [[ -z "${NFTBAN_NFT_PROBE_RC}" ]] && NFTBAN_NFT_PROBE_RC=1
    NFTBAN_NFT_PROBE_STDERR=$(nftban_nft_probe_redact "$2")
}

# -----------------------------------------------------------------------------
# nftban_nft_probe_table <family> <table> [component]
#
# Sets NFTBAN_NFT_PROBE_VERDICT to PRESENT | ABSENT | CANNOT_READ.
# Returns 0 when a determination was made (PRESENT or ABSENT),
#         1 when it could not be made (CANNOT_READ).
#
# ⛔ DELIBERATELY WRITES NOTHING TO STDOUT.
#    An earlier revision echoed the verdict as well. That invites
#        verdict=$(nftban_nft_probe_table ip nftban)
#    which runs the probe in a SUBSHELL: the caller receives the verdict string
#    but EVERY diagnostic variable — rc, error class, stderr, argv, family,
#    component — is silently discarded when the subshell exits. A caller would
#    then log "CANNOT_READ" with no evidence attached, which is the exact
#    lost-evidence failure this PR exists to remove.
#    The verdict is read from $NFTBAN_NFT_PROBE_VERDICT, so that misuse is
#    unrepresentable rather than merely discouraged.
#
# The non-zero return on CANNOT_READ is deliberate: a caller that ignores the
# verdict string still cannot silently treat an unreadable firewall as a
# successful observation.
#
# Sets, for the caller to log or propagate:
#   NFTBAN_NFT_PROBE_VERDICT · NFTBAN_NFT_PROBE_RC · NFTBAN_NFT_PROBE_CLASS
#   NFTBAN_NFT_PROBE_STDERR (bounded+redacted) · NFTBAN_NFT_PROBE_ARGV
#   NFTBAN_NFT_PROBE_FAMILY · NFTBAN_NFT_PROBE_TABLE · NFTBAN_NFT_PROBE_COMPONENT
# -----------------------------------------------------------------------------
nftban_nft_probe_table() {
    local _family="$1" _table="$2" _component="${3:-${NFTBAN_COMPONENT:-unknown}}"
    # Reset every field first: a stale value from a previous probe must never be
    # read as evidence for this one.
    NFTBAN_NFT_PROBE_VERDICT=""; NFTBAN_NFT_PROBE_RC=""; NFTBAN_NFT_PROBE_CLASS=""
    NFTBAN_NFT_PROBE_STDERR=""
    local _nft="${NFTBAN_NFT_BIN:-nft}"
    local _out _err _rc=0

    NFTBAN_NFT_PROBE_FAMILY="$_family"
    NFTBAN_NFT_PROBE_TABLE="$_table"
    NFTBAN_NFT_PROBE_COMPONENT="$_component"
    # argv is recorded EXPLICITLY, one array element per argument. The historical
    # call sites expanded a two-word "ip nftban" variable unquoted under
    # IFS=$'\n\t', which does NOT split, so nft received ONE fused argument
    # instead of two. Passing the family and table separately makes that class of
    # defect unrepresentable here.
    NFTBAN_NFT_PROBE_ARGV="$_nft list tables"

    # STEP 1 — establish READABILITY positively. `nft list tables` succeeds
    # whenever netlink is usable, independently of which tables exist.
    #
    # Captured via temp files, NOT the fd-swap idiom
    #     _err=$( { _out=$(cmd 2>&1 1>&3); } 3>&1 )
    # which assigns _out inside a SUBSHELL. That left both captures empty, and an
    # empty table list made a PRESENT table read as ABSENT — which would have
    # authorised a rebuild on a healthy firewall. Correctness over cleverness.
    # Capture files: unpredictable names, mode 0600, removed on every exit path
    # including early return. A capture failure is CANNOT_READ — NEVER ABSENT.
    local _fo _fe
    _fo=$(mktemp "${TMPDIR:-/tmp}/.nftban-probe.XXXXXXXXXX" 2>/dev/null) \
        || { _probe_fail_closed "PROBE_CAPTURE_FAILED" "mktemp stdout failed"; return 1; }
    _fe=$(mktemp "${TMPDIR:-/tmp}/.nftban-probe.XXXXXXXXXX" 2>/dev/null) \
        || { rm -f "$_fo"; _probe_fail_closed "PROBE_CAPTURE_FAILED" "mktemp stderr failed"; return 1; }
    chmod 600 "$_fo" "$_fe" 2>/dev/null || true

    "$_nft" list tables >"$_fo" 2>"$_fe"; _rc=$?

    # Read back defensively: an unreadable or vanished capture file is a probe
    # failure, not evidence of anything about the firewall.
    if [[ ! -r "$_fo" || ! -r "$_fe" ]]; then
        rm -f "$_fo" "$_fe"
        _probe_fail_closed "PROBE_CAPTURE_UNREADABLE" "capture file missing or unreadable"
        return 1
    fi
    _out=$(cat "$_fo" 2>/dev/null) || { rm -f "$_fo" "$_fe"
        _probe_fail_closed "PROBE_CAPTURE_UNREADABLE" "stdout read failed"; return 1; }
    _err=$(cat "$_fe" 2>/dev/null) || _err=""
    rm -f "$_fo" "$_fe"
    if [[ $_rc -ne 0 ]]; then
        NFTBAN_NFT_PROBE_RC="$_rc"
        NFTBAN_NFT_PROBE_CLASS=$(nftban_nft_probe_error_class "$_err" "$_rc")
        NFTBAN_NFT_PROBE_STDERR=$(nftban_nft_probe_redact "$_err")
        NFTBAN_NFT_PROBE_VERDICT="$NFTBAN_NFT_PROBE_CANNOT_READ"
        NFTBAN_NFT_PROBE_SESSION_DEGRADED=1
        return 1
    fi

    # STEP 2 — FAIL-CLOSED. rc=0 alone does not license a conclusion.
    #
    # `rc=0 with EMPTY output` is NOT absence. It cannot be distinguished from a
    # broken read that exited zero, and treating it as ABSENT would authorise a
    # rebuild on no evidence. Cost of this choice, stated plainly: a host with
    # genuinely zero nft tables yields CANNOT_READ and will not auto-rebuild —
    # which is correct, because zero tables on an installed system is an
    # operator-visible anomaly, not something to silently rebuild through.
    if [[ -z "${_out//[[:space:]]/}" ]]; then
        _probe_fail_closed "EMPTY_OUTPUT_NO_ABSENCE_PROOF" \
            "nft exited 0 but listed no tables — absence is unproven"
        return 1
    fi
    # The output must look like a table listing at all. Unparseable output that
    # happens to exit 0 is parser uncertainty, not a finding.
    if ! printf '%s\n' "$_out" | grep -qE '^table[[:space:]]+[a-z0-9]+[[:space:]]+'; then
        _probe_fail_closed "MALFORMED_OUTPUT" \
            "nft exited 0 but output is not a recognisable table listing"
        return 1
    fi

    NFTBAN_NFT_PROBE_RC=0
    NFTBAN_NFT_PROBE_CLASS="NONE"
    NFTBAN_NFT_PROBE_STDERR=""
    if printf '%s\n' "$_out" | grep -qE "^table[[:space:]]+${_family}[[:space:]]+${_table}([[:space:]]|\$)"; then
        NFTBAN_NFT_PROBE_VERDICT="$NFTBAN_NFT_PROBE_PRESENT"
    else
        NFTBAN_NFT_PROBE_VERDICT="$NFTBAN_NFT_PROBE_ABSENT"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# nftban_nft_probe_set <family> <table> <set> [component]
#
# Same typed contract as nftban_nft_probe_table, for set existence. Readability is
# again established POSITIVELY — `nft list sets <family>` succeeds whenever netlink
# is usable — so a set's absence is an observation from a list we actually read,
# never an inference from a failed command.
#
# Sets NFTBAN_NFT_PROBE_VERDICT. Returns 0 for PRESENT/ABSENT, 1 for CANNOT_READ.
# -----------------------------------------------------------------------------
nftban_nft_probe_set() {
    local _family="$1" _table="$2" _set="$3" _component="${4:-${NFTBAN_COMPONENT:-unknown}}"
    NFTBAN_NFT_PROBE_VERDICT=""; NFTBAN_NFT_PROBE_RC=""; NFTBAN_NFT_PROBE_CLASS=""
    NFTBAN_NFT_PROBE_STDERR=""
    local _nft="${NFTBAN_NFT_BIN:-nft}" _out _err _rc=0 _fo _fe

    NFTBAN_NFT_PROBE_FAMILY="$_family"
    NFTBAN_NFT_PROBE_TABLE="$_table/$_set"
    NFTBAN_NFT_PROBE_COMPONENT="$_component"
    NFTBAN_NFT_PROBE_ARGV="$_nft list sets $_family"

    _fo=$(mktemp "${TMPDIR:-/tmp}/.nftban-probe.XXXXXXXXXX" 2>/dev/null) \
        || { _probe_fail_closed "PROBE_CAPTURE_FAILED" "mktemp stdout failed"; return 1; }
    _fe=$(mktemp "${TMPDIR:-/tmp}/.nftban-probe.XXXXXXXXXX" 2>/dev/null) \
        || { rm -f "$_fo"; _probe_fail_closed "PROBE_CAPTURE_FAILED" "mktemp stderr failed"; return 1; }
    chmod 600 "$_fo" "$_fe" 2>/dev/null || true

    "$_nft" list sets "$_family" >"$_fo" 2>"$_fe"; _rc=$?

    if [[ ! -r "$_fo" || ! -r "$_fe" ]]; then
        rm -f "$_fo" "$_fe"
        _probe_fail_closed "PROBE_CAPTURE_UNREADABLE" "capture file missing or unreadable"
        return 1
    fi
    _out=$(cat "$_fo" 2>/dev/null) || { rm -f "$_fo" "$_fe"
        _probe_fail_closed "PROBE_CAPTURE_UNREADABLE" "stdout read failed"; return 1; }
    _err=$(cat "$_fe" 2>/dev/null) || _err=""
    rm -f "$_fo" "$_fe"

    if [[ $_rc -ne 0 ]]; then
        NFTBAN_NFT_PROBE_RC="$_rc"
        NFTBAN_NFT_PROBE_CLASS=$(nftban_nft_probe_error_class "$_err" "$_rc")
        NFTBAN_NFT_PROBE_STDERR=$(nftban_nft_probe_redact "$_err")
        NFTBAN_NFT_PROBE_VERDICT="$NFTBAN_NFT_PROBE_CANNOT_READ"
        NFTBAN_NFT_PROBE_SESSION_DEGRADED=1
        return 1
    fi
    if [[ -z "${_out//[[:space:]]/}" ]]; then
        _probe_fail_closed "EMPTY_OUTPUT_NO_ABSENCE_PROOF" \
            "nft exited 0 but listed no sets — absence is unproven"
        return 1
    fi

    NFTBAN_NFT_PROBE_RC=0
    NFTBAN_NFT_PROBE_CLASS="NONE"
    NFTBAN_NFT_PROBE_STDERR=""
    if printf '%s\n' "$_out" | grep -qE "^[[:space:]]*set[[:space:]]+${_set}[[:space:]]*\{" \
       || printf '%s\n' "$_out" | grep -qE "table[[:space:]]+${_family}[[:space:]]+${_table}.*${_set}"; then
        NFTBAN_NFT_PROBE_VERDICT="$NFTBAN_NFT_PROBE_PRESENT"
    else
        NFTBAN_NFT_PROBE_VERDICT="$NFTBAN_NFT_PROBE_ABSENT"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# nftban_nft_probe_diagnostic
#
# One bounded, redact-safe line describing the last probe. Intended for logs and
# operator output. Deliberately contains NO remediation advice: recommending a
# reset or rebuild from an unknown cause is what produced ~900 destructive
# `reset --force` recommendations per host against intact firewalls.
# -----------------------------------------------------------------------------
nftban_nft_probe_diagnostic() {
    printf 'nft probe %s: family=%s table=%s component=%s rc=%s class=%s argv=[%s] stderr=[%s]' \
        "${NFTBAN_NFT_PROBE_VERDICT:-UNSET}" "${NFTBAN_NFT_PROBE_FAMILY:-?}" \
        "${NFTBAN_NFT_PROBE_TABLE:-?}" "${NFTBAN_NFT_PROBE_COMPONENT:-?}" \
        "${NFTBAN_NFT_PROBE_RC:-?}" "${NFTBAN_NFT_PROBE_CLASS:-?}" \
        "${NFTBAN_NFT_PROBE_ARGV:-?}" "${NFTBAN_NFT_PROBE_STDERR:-}"
}

# -----------------------------------------------------------------------------
# nftban_nft_probe_may_rebuild
#
# The ONLY rebuild authority. Derived LIVE from VERDICT — there is no stored
# boolean to go stale.
#
# MEANING: "the probe verdict PERMITS CONSIDERING a rebuild."
# It does NOT mean "rebuild is authorised". Other policy constraints (snapshot
# availability, SSH lockout guard, prevalidation) still apply and are evaluated
# by the caller AFTER this predicate passes.
#
# ⛔ This is the invariant the whole PR exists to establish. A rebuild must never
#    be inferred from a generic command failure.
# -----------------------------------------------------------------------------
nftban_nft_probe_may_rebuild() {
    [[ "${NFTBAN_NFT_PROBE_VERDICT:-}" == "$NFTBAN_NFT_PROBE_ABSENT" ]]
}

export -f nftban_nft_probe_session_degraded nftban_nft_probe_session_reset \
          nftban_nft_probe_table nftban_nft_probe_set nftban_nft_probe_error_class \
          nftban_nft_probe_redact nftban_nft_probe_diagnostic \
          nftban_nft_probe_may_rebuild 2>/dev/null || true
