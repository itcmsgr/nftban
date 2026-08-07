#!/usr/bin/env bash
# =============================================================================
# NFTBan - bounded-limiter authority guard (v1.228.6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-nft-bounded-limiters"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-07"
# meta:description="BLOCKING guard for the v1.228.6 meter-capacity fix. The nft meter shorthand creates an implicit dynamic set: 65535 cap, no timeout, monotonic growth, unflushable inline form on nft <= 1.0.9 — measured DNS outages on four resolvers (2026-08-04). Rules: R1 no meter-shorthand rule construct in any render source. R2 every update-statement limiter resolves to a declaration carrying type+size+timeout+flags dynamic in the same source authority. R3 v4/v6 declaration parity. R4 the pre-rendered boot copy carries IDENTICAL limiter lines to the template. R5 every limiter has a deliberate at-capacity policy row in the manifest, and every manifest row a limiter. Comments are stripped before matching (guard subject == guard input)."
# meta:input="install/nftables/nftables.conf.tpl, install/nftables/nftables.conf, cli/lib/nftban/lib/nft_fragment.sh, scripts/ci/data/nft-limiter-capacity-policy.tsv"
# meta:output="PASS/FAIL per rule; exit 1 on any violation"
# meta:depends="bash,grep,sed,awk,diff"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,awk,diff"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

TPL="install/nftables/nftables.conf.tpl"
CONF="install/nftables/nftables.conf"
FRAG="cli/lib/nftban/lib/nft_fragment.sh"
MANIFEST="scripts/ci/data/nft-limiter-capacity-policy.tsv"

FAILS=0
ok()  { printf '  [PASS] %s\n' "$1"; }
bad() { printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

for f in "$TPL" "$CONF" "$FRAG" "$MANIFEST"; do
    [[ -f "$f" ]] || { bad "MISSING SOURCE: $f"; echo "=== bounded-limiters: FAILS=$FAILS ==="; exit 1; }
done

# GUARD SUBJECT == GUARD INPUT: strip comment lines and trailing nft comment
# strings so prose can neither satisfy nor violate the rules below.
strip() { grep -vE '^[[:space:]]*#' "$1" | sed 's/ comment "[^"]*"//'; }

echo "=== check-nft-bounded-limiters (v1.228.6) ==="

# ---------------------------------------------------------------------------
# R1 — the meter shorthand must not exist as a rule construct anywhere.
# Shape: ' meter <name-or-var> {' in non-comment text.
# ---------------------------------------------------------------------------
R1_HITS=$(for f in "$TPL" "$CONF" "$FRAG"; do
    strip "$f" | grep -nE '[[:space:]]meter[[:space:]]+[$@{a-zA-Z_][^{]*\{' | sed "s|^|$f:|"
done)
if [[ -z "$R1_HITS" ]]; then
    ok "R1 no meter-shorthand rule construct in any render source"
else
    bad "R1 meter shorthand present (implicit unbounded dynamic set):"
    printf '%s\n' "$R1_HITS" | head -10 | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# R2 — every `update @X {` limiter statement resolves to a declaration of X
# carrying size + timeout + flags dynamic, in the SAME source authority.
# Names may be literals or ${var} tokens; token text must match exactly.
# ---------------------------------------------------------------------------
R2_BAD=0
for f in "$TPL" "$CONF" "$FRAG"; do
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # Declaration forms: 'set NAME {' (declarative) or 'add set <table> NAME {'
        block=""
        if [[ "$f" == "$FRAG" ]]; then
            block=$(strip "$f" | grep -E "add set .*[[:space:]]$(printf '%s' "$name" | sed 's/[]$.*[\^]/\\&/g')[[:space:]]*\{" | head -1)
        else
            block=$(strip "$f" | sed -n "/^[[:space:]]*set $(printf '%s' "$name" | sed 's/[]$.*[\^]/\\&/g') {/,/^[[:space:]]*}/p")
        fi
        if [[ -z "$block" ]]; then
            bad "R2 $f: update @$name has NO set declaration in the same source"
            R2_BAD=1; continue
        fi
        for req in "size" "timeout" "dynamic"; do
            if ! grep -q "$req" <<<"$block"; then
                bad "R2 $f: declaration of $name lacks '$req'"
                R2_BAD=1
            fi
        done
    done < <(strip "$f" | grep -oE 'update @[^ ]+' | sed 's/update @//' | sort -u)
done
[[ "$R2_BAD" -eq 0 ]] && ok "R2 every update-statement limiter declares size + timeout + flags dynamic"

# ---------------------------------------------------------------------------
# R3 — v4/v6 parity of DECLARED limiters, driven by the manifest pairs.
# Pairing convention: NAME6 <-> NAME, and NAME_v6 <-> NAME_v4.
# Fragment limiters are declared through shell variables; the alias map below
# binds each manifest name to its declaration token, and the variable's
# DEFAULT ASSIGNMENT is verified so the map cannot drift from the fragment.
# ---------------------------------------------------------------------------
declare -A VAR_ALIAS=(
    [ddos_icmp_flood]='${icmp_meter}'   [ddos_icmp_flood6]='${icmp_meter}6'
    [ddos_udp_flood]='${udp_meter}'     [ddos_udp_flood6]='${udp_meter}6'
    [ddos_prefix_syn]='${syn_meter}'    [ddos_prefix_syn6]='${syn_meter}6'
    [ddos_prefix_conn]='${conn_meter}'  [ddos_prefix_conn6]='${conn_meter}6'
)
R3_BAD=0
# The alias map is only trustworthy if the fragment's defaults still resolve
# each variable to the manifest name.
for pair in "icmp_meter:ddos_icmp_flood" "udp_meter:ddos_udp_flood" \
            "syn_meter:ddos_prefix_syn" "conn_meter:ddos_prefix_conn"; do
    var="${pair%%:*}"; def="${pair##*:}"
    if ! grep -qE "local ${var}=\"\\\$\{[A-Z_]+:-${def}\}\"" "$FRAG"; then
        bad "R3 fragment default for \$${var} no longer resolves to '${def}' — update the guard alias map"
        R3_BAD=1
    fi
done
mapfile -t MANIFEST_NAMES < <(grep -vE '^[[:space:]]*(#|$)' "$MANIFEST" | cut -f1)
ALL_DECLS=$(for f in "$TPL" "$FRAG"; do strip "$f"; done)
for name in "${MANIFEST_NAMES[@]}"; do
    base=""
    case "$name" in
        *_v6) base="${name%_v6}_v4" ;;
        *6)   base="${name%6}" ;;
    esac
    if [[ -n "$base" ]] && ! printf '%s\n' "${MANIFEST_NAMES[@]}" | grep -qx "$base"; then
        # A missing v4 pair is legal ONLY when the manifest row records it.
        if ! grep -P "^$name\t" "$MANIFEST" | grep -q "no v4 counterpart by design"; then
            bad "R3 $name has no v4 counterpart '$base' in the manifest"
            R3_BAD=1
        fi
    fi
    token="${VAR_ALIAS[$name]:-$name}"
    esc=$(printf '%s' "$token" | sed 's/[]$.*[\^{}]/\\&/g')
    if ! grep -qE "(set[[:space:]]+${esc}[[:space:]]*\{|add set .*[[:space:]]${esc}[[:space:]]*\{)" <<<"$ALL_DECLS"; then
        bad "R3 manifest limiter '$name' (token $token) has no declaration in the sources"
        R3_BAD=1
    fi
done
[[ "$R3_BAD" -eq 0 ]] && ok "R3 v4/v6 manifest parity and declaration existence"

# ---------------------------------------------------------------------------
# R4 — boot-copy parity: the limiter-relevant lines of the pre-rendered
# nftables.conf must be IDENTICAL to the template's. The 28-anchor count
# check cannot see a divergent limiter definition; this can.
# ---------------------------------------------------------------------------
lim_lines() { strip "$1" | grep -E 'update @|flags dynamic' | sed 's/^[[:space:]]*//'; }
if diff <(lim_lines "$TPL") <(lim_lines "$CONF") >/dev/null; then
    ok "R4 boot copy carries IDENTICAL limiter lines to the template"
else
    bad "R4 template/boot-copy limiter divergence:"
    diff <(lim_lines "$TPL") <(lim_lines "$CONF") | head -8 | sed 's/^/         /'
fi

# ---------------------------------------------------------------------------
# R5 — capacity-policy completeness, both directions:
# every DECLARED dynamic limiter has a manifest row with a valid policy,
# and every manifest row was already proven to exist by R3.
# ---------------------------------------------------------------------------
R5_BAD=0
while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    row=$(grep -P "^$(printf '%s' "$name")\t" "$MANIFEST" || true)
    if [[ -z "$row" ]]; then
        bad "R5 declared limiter '$name' has NO capacity-policy row — a new limiter requires a deliberate at-capacity decision"
        R5_BAD=1
    elif ! grep -qE 'FAIL_(CLOSED|OPEN)_VISIBLE' <<<"$row"; then
        bad "R5 limiter '$name' policy is not FAIL_CLOSED_VISIBLE/FAIL_OPEN_VISIBLE"
        R5_BAD=1
    fi
done < <({
    # Template: multi-line set blocks — a state machine over the stripped text,
    # printing the name only when the BLOCK carries flags dynamic.
    strip "$TPL" | awk '
        /^[[:space:]]*set [a-z0-9_]+ \{/ { name=$2; body="" ; inblock=1; next }
        inblock { body=body $0 ; if (/^[[:space:]]*\}/) { if (body ~ /dynamic/) print name; inblock=0 } }'
    # Fragment: one-line add-set declarations carrying flags dynamic — the name
    # is the token immediately before the opening brace.
    strip "$FRAG" | grep 'add set' | grep 'dynamic' | \
        awk '{for(i=1;i<=NF;i++) if($i=="{"){print $(i-1); break}}' | \
        sed -e 's/^${icmp_meter}$/ddos_icmp_flood/' -e 's/^${icmp_meter}6$/ddos_icmp_flood6/' \
            -e 's/^${udp_meter}$/ddos_udp_flood/'   -e 's/^${udp_meter}6$/ddos_udp_flood6/' \
            -e 's/^${syn_meter}$/ddos_prefix_syn/'  -e 's/^${syn_meter}6$/ddos_prefix_syn6/' \
            -e 's/^${conn_meter}$/ddos_prefix_conn/' -e 's/^${conn_meter}6$/ddos_prefix_conn6/'
  } | sort -u)
[[ "$R5_BAD" -eq 0 ]] && ok "R5 every declared limiter carries a deliberate at-capacity policy"

echo "=== bounded-limiters: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]]
