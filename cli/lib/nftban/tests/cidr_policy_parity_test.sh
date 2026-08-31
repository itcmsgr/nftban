#!/usr/bin/env bash
# =============================================================================
# NFTBan - the shell CIDR-policy mirror must not drift from the Go authority
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="cidr-policy-parity-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="STRUCTURAL GUARD. The D8 producer-attribution oracle must compare live coverage against EFFECTIVE intent (raw minus the entries the single writer filters), or it reports FAILED on a healthy host whose GeoBan source merely contains reserved space — measured on lab4 2026-08-31, where a TEST-NET source produced '[SYNC] CIDR filter: removed 2 problematic entries (bogon=2)' and an empty kernel set. The filtering policy is owned by Go (internal/setsync/cidr.go BogonPrefixes / MinAllowedPrefixLen). nftban-core exposes no cidr-filter subcommand to call, and /var/lib/nftban/state/filter.json records only global last-sync totals across feeds+geoban+blacklist.d, so it cannot attribute a filtered entry to one producer. The shell mirror is therefore unavoidable; this test makes drift a build failure. Asserts BOTH sides parse non-vacuously before comparing, then exact set equality of the bogon list and equality of the minimum prefix length."
# meta:inventory.files="cli/lib/nftban/lib/derived_state_reconcile.sh,internal/setsync/cidr.go"
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GO_SRC="$ROOT/internal/setsync/cidr.go"
SH_SRC="$ROOT/cli/lib/nftban/lib/derived_state_reconcile.sh"
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

for f in "$GO_SRC" "$SH_SRC"; do
    [[ -r "$f" ]] || { echo "  [FAIL] unreadable: $f"; exit 1; }
done

# --- Go authority -----------------------------------------------------------
GO_BOGONS="$(awk '/^var BogonPrefixes = \[\]string\{/,/^\}/' "$GO_SRC" \
             | grep -oE '"[0-9./]+"' | tr -d '"' | sort -u)"
GO_MINLEN="$(grep -oE 'MinAllowedPrefixLen[[:space:]]*=[[:space:]]*[0-9]+' "$GO_SRC" \
             | grep -oE '[0-9]+$' | head -1)"

# --- shell mirror -----------------------------------------------------------
# shellcheck source=/dev/null
# Strip the assignment prefix, the line continuations and BOTH quotes before
# tokenising. The first attempt matched on line shape and silently lost the two
# prefixes glued to a quote (0.0.0.0/8 and 255.255.255.255/32) — an
# UNDER-matching checker that would have reported drift that did not exist.
SH_BOGONS="$(sed -n '/^NFTBAN_DSR_BOGON_PREFIXES=/,/"[[:space:]]*$/p' "$SH_SRC" \
             | tr -d '"\\' | tr ' ' '\n' \
             | grep -oE '[0-9]+(\.[0-9]+){3}/[0-9]+' | sort -u)"
SH_MINLEN="$(grep -oE '^NFTBAN_DSR_MIN_PREFIX_LEN=[0-9]+' "$SH_SRC" | grep -oE '[0-9]+$' | head -1)"

# ⛔ NON-VACUITY FIRST. An empty parse on either side would make every
#    comparison below trivially pass — the checker would be asserting nothing.
[[ -n "$GO_BOGONS" && "$(wc -l <<<"$GO_BOGONS")" -ge 10 ]] \
    && ok "Go authority parsed ($(wc -l <<<"$GO_BOGONS") prefixes)" \
    || { bad "Go BogonPrefixes parsed as empty/short — the guard would pass vacuously"; exit 1; }
[[ -n "$SH_BOGONS" && "$(wc -l <<<"$SH_BOGONS")" -ge 10 ]] \
    && ok "shell mirror parsed ($(wc -l <<<"$SH_BOGONS") prefixes)" \
    || { bad "shell mirror parsed as empty/short — the guard would pass vacuously"; exit 1; }
[[ -n "$GO_MINLEN" ]] && ok "Go MinAllowedPrefixLen parsed ($GO_MINLEN)" || { bad "Go MinAllowedPrefixLen unparsed"; exit 1; }
[[ -n "$SH_MINLEN" ]] && ok "shell NFTBAN_DSR_MIN_PREFIX_LEN parsed ($SH_MINLEN)" || { bad "shell min prefix unparsed"; exit 1; }

# --- parity -----------------------------------------------------------------
if diff_out="$(diff <(echo "$GO_BOGONS") <(echo "$SH_BOGONS"))"; then
    ok "bogon list is IDENTICAL to the Go authority ($(wc -l <<<"$GO_BOGONS") entries)"
else
    bad "bogon list DRIFTED from internal/setsync/cidr.go — the verifier would use a policy the daemon does not"
    echo "$diff_out" | sed 's/^/        /'
fi

[[ "$GO_MINLEN" == "$SH_MINLEN" ]] \
    && ok "minimum prefix length matches the Go authority (/$GO_MINLEN)" \
    || bad "min prefix length drift: Go=/$GO_MINLEN shell=/$SH_MINLEN"

# --- the guard must be able to FAIL (negative control) ----------------------
# Prove the comparison discriminates, rather than trusting that it does.
if diff -q <(echo "$GO_BOGONS") <(echo "$GO_BOGONS"; echo "1.2.3.0/24") >/dev/null 2>&1; then
    bad "negative control: the comparison did NOT detect an injected extra prefix"
else
    ok "negative control: an injected extra prefix IS detected (guard discriminates)"
fi

echo
echo "=== cidr_policy_parity: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
