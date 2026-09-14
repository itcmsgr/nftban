#!/usr/bin/env bash
# =============================================================================
# NFTBan - trust provider CIDR validation + breadth floor (v1.231.0 Lane 1B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="trust_cidr_validation_v1231_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Locks BUG-TRUST-WHITELIST-NO-CIDR-VALIDATION. Provider-controlled cache text reached nft add/delete element operands and the durable whitelist.d conf with NO validation of any kind: malformed tokens, over-broad prefixes (0.0.0.0/0 confers membership on every address), IPv6 tokens in an ip/whitelist_ipv4 statement, unstripped comments, and nft STATEMENT INJECTION that executed as root. FIVE ingress points are covered: _trust_apply_to_nft add-v4/add-v6, _trust_remove_from_nft delete-v4/delete-v6, and _trust_write_whitelist -- the last is the PRIMARY daemon path (the IPC sites are only the fallback) and a fix that omitted it would leave the bypass fully live. Also locks the two trust-policy breadth floors TRUST_PROVIDER_MIN_PREFIX_V4=10 / _V6=28 at the values measured from the declared provider sources, per-entry rejection (one bad line must not abort the batch), and fail-closed behaviour when validation.sh is unavailable. Hermetic: TMPDIR sandbox, IPC surface stubbed, no host or nft state touched."
# meta:input="cli/lib/nftban/core/nftban_trust.sh, cli/lib/nftban/lib/validation.sh"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure; exit 2 on INVALID_TEST"
# meta:depends="bash,mktemp,grep,sed,cat"
# meta:ta.id="trust_cidr_validation_v1231_test"
# meta:ta.owner="trust"
# meta:ta.module="trust"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/core/nftban_trust.sh,cli/lib/nftban/lib/validation.sh"
# meta:inventory.binaries="bash,mktemp,grep,sed,cat"
# meta:inventory.env_vars="TRUST_CACHE_DIR,TRUST_DATA_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LOG_DIR,NFTBAN_RUN_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
MOD="$ROOT/cli/lib/nftban/core/nftban_trust.sh"
VALIDATION="$ROOT/cli/lib/nftban/lib/validation.sh"

PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); [[ -n "${2:-}" ]] && printf '         observed: %s\n' "$2"; }
inv() { printf '  [INVALID_TEST] %s\n' "$1"; printf 'RESULT: INVALID_TEST — PRODUCT VERDICT = NONE\n'; exit 2; }

# =============================================================================
# PRECONDITIONS — asserted BEFORE any negative result is believed
# =============================================================================
echo "=== PRECONDITIONS ==="
[[ -r "$MOD" ]]        || inv "module unreadable: $MOD"
[[ -r "$VALIDATION" ]] || inv "validation lib unreadable: $VALIDATION"
ok "P0 subjects readable"

SANDBOX="$(mktemp -d -t nftban-trustval-XXXXXX)" || inv "mktemp failed"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/cache" "$SANDBOX/whitelist.d" "$SANDBOX/log" "$SANDBOX/run" \
    || inv "sandbox layout could not be created"

export TRUST_CACHE_DIR="$SANDBOX/cache"
export TRUST_DATA_DIR="$SANDBOX/data"
export NFTBAN_CONFIG_DIR="$SANDBOX"
export NFTBAN_LOG_DIR="$SANDBOX/log"
export TRUST_LOG_FILE="$SANDBOX/log/trust.log"
export NFTBAN_RUN_DIR="$SANDBOX/run"
# Point the module's validation lookup at the REPO lib, not an installed one.
export NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban"

CAPTURE="$SANDBOX/captured.nft"

# Stub the IPC surface BEFORE sourcing so the module's `type -t` guard is
# satisfied and it never sources /usr/lib/nftban/lib/nft_ipc.sh. The stub is the
# instrument: it records the exact fragment the module hands to nft.
nft_ipc_apply_ruleset() { cp -f "$1" "$CAPTURE"; return 0; }
nft_ipc_sync_or_apply() { cp -f "$2" "$CAPTURE"; return 0; }

_saved_ifs="$IFS"
set +e
# shellcheck disable=SC1090
source "$MOD" >/dev/null 2>&1
set +e
IFS="$_saved_ifs"

type -t _trust_apply_to_nft    >/dev/null 2>&1 || inv "_trust_apply_to_nft undefined after source"
type -t _trust_remove_from_nft >/dev/null 2>&1 || inv "_trust_remove_from_nft undefined after source"
type -t _trust_write_whitelist >/dev/null 2>&1 || inv "_trust_write_whitelist undefined after source"
ok "P1 all three consumer functions defined after source"

# P2/P3 are PRODUCT assertions, not instrument assertions: a module that
# defines no sanitiser, or that never wires in the canonical validator, is
# defective. They must therefore FAIL (and let the fixtures below run and say
# exactly what leaked) rather than abort as INVALID_TEST.
if type -t _trust_valid_elements >/dev/null 2>&1; then
    ok "P2 sanitiser _trust_valid_elements is defined"
else
    bad "P2 _trust_valid_elements (the sanitiser) is not defined — provider text is unsanitised"
fi

if type -t nftban_validate_cidr >/dev/null 2>&1; then
    ok "P3 module sources the canonical validator (nftban_validate_cidr reachable)"
else
    bad "P3 the module does not source lib/validation.sh — no canonical validator is reachable from the trust path"
fi

# =============================================================================
# FIXTURE DRIVERS
# =============================================================================
FRAG=""
_clear() { rm -f "$CAPTURE" "$TRUST_CACHE_DIR"/cloudflare-ipv4.txt "$TRUST_CACHE_DIR"/cloudflare-ipv6.txt; }

# add_v4 <content> -> FRAG
add_v4() { _clear; printf '%s\n' "$1" > "$TRUST_CACHE_DIR/cloudflare-ipv4.txt"
           _trust_apply_to_nft CLOUDFLARE >/dev/null 2>&1; FRAG="$(cat "$CAPTURE" 2>/dev/null)"; }
# add_v6 <content> -> FRAG
add_v6() { _clear; printf '%s\n' "$1" > "$TRUST_CACHE_DIR/cloudflare-ipv6.txt"
           _trust_apply_to_nft CLOUDFLARE >/dev/null 2>&1; FRAG="$(cat "$CAPTURE" 2>/dev/null)"; }
# del_v4 <content> -> FRAG
del_v4() { _clear; printf '%s\n' "$1" > "$TRUST_CACHE_DIR/cloudflare-ipv4.txt"
           _trust_remove_from_nft CLOUDFLARE >/dev/null 2>&1; FRAG="$(cat "$CAPTURE" 2>/dev/null)"; }
# write_v4 <content> -> WL (content of the durable whitelist.d conf)
WL=""
write_v4() { _clear; rm -f "$SANDBOX/whitelist.d/30-trust-cloudflare.conf"
             printf '%s\n' "$1" > "$TRUST_CACHE_DIR/cloudflare-ipv4.txt"
             _trust_write_whitelist CLOUDFLARE >/dev/null 2>&1
             WL="$(cat "$SANDBOX/whitelist.d/30-trust-cloudflare.conf" 2>/dev/null)"; }
write_v6() { _clear; rm -f "$SANDBOX/whitelist.d/30-trust-cloudflare.conf"
             printf '%s\n' "$1" > "$TRUST_CACHE_DIR/cloudflare-ipv6.txt"
             _trust_write_whitelist CLOUDFLARE >/dev/null 2>&1
             WL="$(cat "$SANDBOX/whitelist.d/30-trust-cloudflare.conf" 2>/dev/null)"; }

# reject <label> <needle>   — the needle must NOT appear in FRAG
reject() { case "$FRAG" in *"$2"*) bad "$1" "$FRAG";; *) ok "$1";; esac; }
# accept <label> <needle>   — the needle MUST appear in FRAG
accept() { case "$FRAG" in *"$2"*) ok "$1";; *) bad "$1" "$FRAG";; esac; }
# wl_reject / wl_accept — same, against the durable whitelist.d conf
wl_reject() { case "$WL" in *"$2"*) bad "$1" "$WL";; *) ok "$1";; esac; }
wl_accept() { case "$WL" in *"$2"*) ok "$1";; *) bad "$1" "$WL";; esac; }

# =============================================================================
# INSTRUMENT VALIDATION — the harness must reach the product AND discriminate
# =============================================================================
echo
echo "=== INSTRUMENT VALIDATION ==="
add_v4 '104.16.0.0/13'
if [[ "$FRAG" == *"add element ip nftban whitelist_ipv4"* && "$FRAG" == *"104.16.0.0/13"* ]]; then
    ok "PC1 a CLEAN v4 cache produces the real add-element fragment"
else
    inv "PC1 no fragment captured for a CLEAN cache — every negative below would be uninterpretable. Captured: <<<$FRAG>>>"
fi
add_v4 ''
[[ -z "$FRAG" ]] && ok "PC2 instrument discriminates (empty cache -> no fragment)" \
                 || inv "PC2 instrument emits for empty input — it cannot discriminate"
write_v4 '104.16.0.0/13'
wl_accept "PC3 a CLEAN v4 cache reaches the durable whitelist.d conf" "104.16.0.0/13"

# =============================================================================
# SYNTACTIC VALIDITY  (N1-N3)
# =============================================================================
echo
echo "=== SYNTACTIC VALIDITY ==="
add_v4 'NOT_AN_IP';    reject "N1 malformed token rejected"                  "NOT_AN_IP"
add_v4 '10.0.0.0/99';  reject "N2 out-of-range prefix length rejected"       "10.0.0.0/99"
add_v4 '999.1.2.3/24'; reject "N3 out-of-range octet rejected"               "999.1.2.3/24"

# =============================================================================
# TRUST BREADTH POLICY  (N4, N5, N11 + the newly ruled floors)
# =============================================================================
echo
echo "=== TRUST BREADTH POLICY ==="
# The two floors are a TRUST-POLICY constraint, not CIDR syntax. They must exist
# by name, with the ruled values, and must NOT be aliases of a blocklist policy.
[[ "${TRUST_PROVIDER_MIN_PREFIX_V4:-unset}" == "10" ]] \
    && ok "B0 TRUST_PROVIDER_MIN_PREFIX_V4 == 10 (measured broadest provider /10)" \
    || bad "B0 TRUST_PROVIDER_MIN_PREFIX_V4 is '${TRUST_PROVIDER_MIN_PREFIX_V4:-unset}', expected 10"
[[ "${TRUST_PROVIDER_MIN_PREFIX_V6:-unset}" == "28" ]] \
    && ok "B1 TRUST_PROVIDER_MIN_PREFIX_V6 == 28 (measured broadest provider /28)" \
    || bad "B1 TRUST_PROVIDER_MIN_PREFIX_V6 is '${TRUST_PROVIDER_MIN_PREFIX_V6:-unset}', expected 28"
# The owner ruling is that the blocklist constant setsync.MinAllowedPrefixLen
# belongs to a different policy domain and must NOT be reused here. Assert that
# no EXECUTABLE line of the module reaches for it (comments explaining the
# non-reuse are fine and are stripped before the check).
_exec_lines="$(sed 's/#.*//' "$MOD")"
if printf '%s' "$_exec_lines" | grep -qiE 'setsync|MinAllowedPrefixLen'; then
    bad "B2 the module imports a blocklist-domain prefix constant into trust policy" \
        "$(printf '%s' "$_exec_lines" | grep -inE 'setsync|MinAllowedPrefixLen' | head -3)"
else
    ok "B2 no executable line imports the setsync blocklist constant into trust policy"
fi

add_v4 '0.0.0.0/0';    reject "N4 IPv4 /0 (whole internet) rejected"          "0.0.0.0/0"
add_v4 '8.0.0.0/4';    reject "N5 IPv4 /4 rejected"                          "8.0.0.0/4"
add_v4 '0.0.0.0/1';    reject "B3 IPv4 /1 rejected (rejecting /0 alone is not sufficient)" "0.0.0.0/1"
add_v4 '10.0.0.0/8';   reject "B4 IPv4 /8 rejected (one below-floor step)"    "10.0.0.0/8"
add_v4 '10.0.0.0/9';   reject "B5 IPv4 /9 rejected — the floor is /10, NOT the setsync /9" "10.0.0.0/9"
add_v4 '34.64.0.0/10'; accept "B6 IPv4 /10 ACCEPTED (Google 34.64.0.0/10 must survive)"    "34.64.0.0/10"
add_v4 '44.192.0.0/11';accept "B7 IPv4 /11 ACCEPTED (AWS 44.192.0.0/11 must survive)"      "44.192.0.0/11"
add_v4 '1.2.3.4/32';   accept "B8 IPv4 /32 ACCEPTED"                         "1.2.3.4/32"
add_v4 '1.2.3.4';      accept "B9 BARE IPv4 ACCEPTED (QUIC.cloud publishes bare IPs)"      "1.2.3.4"

add_v6 '::/0';               reject "N11 IPv6 /0 rejected"                                  "::/0"
add_v6 '2000::/3';           reject "B10 IPv6 /3 (entire global unicast space) rejected"    "2000::/3"
add_v6 '2600:1900::/27';     reject "B11 IPv6 /27 rejected (one below-floor step)"          "2600:1900::/27"
add_v6 '2600:1900::/28';     accept "B12 IPv6 /28 ACCEPTED (Google 2600:1900::/28 must survive)" "2600:1900::/28"
add_v6 '2a06:98c0::/29';     accept "B13 IPv6 /29 ACCEPTED (Cloudflare 2a06:98c0::/29 must survive)" "2a06:98c0::/29"
add_v6 '2406:da1e::/32';     accept "B14 IPv6 /32 ACCEPTED (AWS 2406:da1e::/32 must survive)"       "2406:da1e::/32"

# =============================================================================
# FAMILY ROUTING  (N6)
# =============================================================================
echo
echo "=== FAMILY ROUTING ==="
add_v4 '2606:4700::/32'
reject "N6 a v6 token in the v4 cache never enters ip/whitelist_ipv4" "whitelist_ipv4 { 2606:4700::/32"
add_v6 '1.2.3.0/24'
reject "F1 a v4 token in the v6 cache never enters ip6/whitelist_ipv6" "whitelist_ipv6 { 1.2.3.0/24"

# =============================================================================
# COMMENT / FIELD SEMANTICS  (N7, N8) — must match feeds.ParseFeedLine
# =============================================================================
echo
echo "=== COMMENT AND FIELD SEMANTICS ==="
add_v4 '   # indented comment'
reject "N7 a comment indented past column 0 is stripped" "indented comment"
add_v4 '104.16.0.0/13 # cloudflare'
reject "N8 an inline '#' comment never becomes part of the operand" "# cloudflare"
add_v4 '104.16.0.0/13 # cloudflare'
accept "C1 the address on an inline-commented line still ships"     "104.16.0.0/13"
add_v4 '  ;  semicolon comment'
reject "C2 a ';' comment at any column is stripped"                 "semicolon comment"
add_v4 '104.16.0.0/13   reason   2026-01-01'
reject "C3 whitespace-separated trailing fields are stripped"        "reason"
add_v4 '   104.16.0.0/13   '
accept "C4 leading/trailing whitespace is trimmed, address survives" "104.16.0.0/13"

# =============================================================================
# nft STATEMENT INJECTION  (N9) — highest-severity consequence
# =============================================================================
echo
echo "=== nft STATEMENT INJECTION ==="
INJ='1.2.3.4 }; add table ip lane1b_pwn; add element ip nftban whitelist_ipv4 { 5.6.7.8'
add_v4 "$INJ"; reject "N9 add path: injected nft STATEMENT rejected"    "add table ip lane1b_pwn"
del_v4 "$INJ"; reject "I1 delete path: injected nft STATEMENT rejected" "add table ip lane1b_pwn"
write_v4 "$INJ"
wl_reject "I2 durable whitelist.d conf: injected nft STATEMENT rejected" "add table ip lane1b_pwn"

# No emitted operand may carry an nft metacharacter, whatever the vector.
add_v4 '1.2.3.4;5.6.7.8'; reject "I3 ';' never survives into an operand" "1.2.3.4;5.6.7.8"
add_v4 '1.2.3.4}';        reject "I4 '}' never survives into an operand" "1.2.3.4}"
add_v4 '{1.2.3.4';        reject "I5 '{' never survives into an operand" "{1.2.3.4"

# The injected line does not vanish: it reduces to its FIRST FIELD, exactly as
# feeds.ParseFeedLine would reduce it (cut at ';', take field 1). Assert the
# resulting SHAPE, so the outcome is a stated contract and not an unexamined
# side effect: one statement per family, no statement separator anywhere.
add_v4 "$INJ"
if [[ "$(printf '%s\n' "$FRAG" | grep -c 'add element')" == "1" ]]; then
    ok "I6 the injected line yields exactly ONE add-element statement"
else
    bad "I6 more than one nft statement emitted from a single cache" "$FRAG"
fi
case "$FRAG" in
    *";"*) bad "I7 a statement separator survived into the fragment" "$FRAG" ;;
    *)     ok "I7 no ';' anywhere in the emitted fragment" ;;
esac
accept "I8 the injected line reduces to its first field (1.2.3.4), which a provider could have published on its own line anyway" "1.2.3.4"

# =============================================================================
# REMOVAL PATH  (N10) — rc is discarded there, so sanitising is the only control
# =============================================================================
echo
echo "=== REMOVAL PATH ==="
del_v4 '0.0.0.0/0'
reject "N10 removal path validates too" "delete element ip nftban whitelist_ipv4 { 0.0.0.0/0"
del_v4 '104.16.0.0/13'
accept "R1 removal path still emits VALID elements" "delete element ip nftban whitelist_ipv4 { 104.16.0.0/13"

# =============================================================================
# PRIMARY DAEMON PATH — _trust_write_whitelist (whitelist.d conf)
# =============================================================================
# The IPC sites are only the fallback (nft_ipc_sync_or_apply). The daemon loads
# /etc/nftban/whitelist.d/30-trust-<provider>.conf. A fix that patched only the
# IPC sites would leave the over-broad bypass fully live on the path that
# actually runs.
echo
echo "=== PRIMARY DAEMON PATH (whitelist.d) ==="
write_v4 '0.0.0.0/0';       wl_reject "W1 /0 never reaches the durable whitelist.d conf" "0.0.0.0/0"
write_v4 '10.0.0.0/9';      wl_reject "W2 below-floor /9 never reaches whitelist.d"      "10.0.0.0/9"
write_v4 'NOT_AN_IP';       wl_reject "W3 malformed token never reaches whitelist.d"     "NOT_AN_IP"
write_v4 '2606:4700::/32';  wl_reject "W4 v6 token in the v4 cache never reaches whitelist.d from the v4 section" "2606:4700::/32"
write_v6 '::/0';            wl_reject "W5 IPv6 /0 never reaches whitelist.d"             "::/0"
write_v6 '2a06:98c0::/29';  wl_accept "W6 a legitimate v6 provider prefix still reaches whitelist.d" "2a06:98c0::/29"

# =============================================================================
# PER-ENTRY REJECTION — one bad line must NOT abort the batch
# =============================================================================
# `nft -f` is all-or-nothing per file: one malformed element destroys the good
# elements in the same statement. Sanitising must therefore drop the entry and
# keep the rest, never fall back to emitting nothing and never emit the bad one.
echo
echo "=== PER-ENTRY REJECTION ==="
MIXED='104.16.0.0/13
0.0.0.0/0
NOT_AN_IP
172.64.0.0/13
2606:4700::/32
   # a comment
131.0.72.0/22'
add_v4 "$MIXED"
accept "E1 good entry 1 survives alongside rejected ones" "104.16.0.0/13"
accept "E2 good entry 2 survives alongside rejected ones" "172.64.0.0/13"
accept "E3 good entry 3 survives alongside rejected ones" "131.0.72.0/22"
reject "E4 the /0 in the same batch is still dropped"     "0.0.0.0/0"
reject "E5 the malformed token in the same batch is still dropped" "NOT_AN_IP"
write_v4 "$MIXED"
wl_accept "E6 the durable conf keeps the good entries too" "131.0.72.0/22"
wl_reject "E7 the durable conf still drops the /0"         "0.0.0.0/0"

# A dropped-entry count must be logged, or a silent regression is invisible.
if grep -qiE 'dropped=[0-9]+' "$TRUST_LOG_FILE" 2>/dev/null; then
    ok "E8 a dropped-entry count is logged"
else
    bad "E8 no dropped-entry count in $TRUST_LOG_FILE — a silent regression would be invisible" \
        "$(tail -3 "$TRUST_LOG_FILE" 2>/dev/null)"
fi

# =============================================================================
# FAIL-CLOSED — no validator means no emission
# =============================================================================
echo
echo "=== FAIL-CLOSED WITHOUT THE VALIDATOR ==="
if type -t _trust_valid_elements >/dev/null 2>&1; then
    (
        # Subshell: unset the validator and confirm the sanitiser refuses to
        # emit rather than falling back to raw passthrough.
        unset -f nftban_validate_ip nftban_validate_cidr 2>/dev/null
        printf '%s\n' '104.16.0.0/13' > "$TRUST_CACHE_DIR/cloudflare-ipv4.txt"
        out="$(_trust_valid_elements "$TRUST_CACHE_DIR/cloudflare-ipv4.txt" 4 2>/dev/null)"
        [[ -z "$out" ]] && exit 0 || { printf '%s' "$out" > "$SANDBOX/failopen.out"; exit 1; }
    )
    if [[ $? -eq 0 ]]; then
        ok "FC1 sanitiser emits NOTHING when the canonical validator is absent (fail-closed)"
    else
        bad "FC1 sanitiser emitted unvalidated text with the validator absent (fail-OPEN)" \
            "$(cat "$SANDBOX/failopen.out" 2>/dev/null)"
    fi
else
    bad "FC1 cannot be evaluated: _trust_valid_elements is not defined"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo
echo "SUMMARY: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    echo "RESULT: FAIL — trust provider input is not fully sanitised"
    exit 1
fi
echo "RESULT: PASS"
exit 0
