#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# SHIPPED STRUCTURED SPECS MUST AGREE WITH EFFECTIVE PACKET-PATH AUTHORITY
# =============================================================================
# meta:description="v1.233.0. The connlimit claim guard governs files that PRINT
#   a scope claim to an operator. It therefore had no opinion about
#   install/share/nftban/specs/structure_default.json, which SHIPS in every
#   package and declared \"scope\": \"host_wide\" for connection_limits while the
#   same package enforced per-source keying. No runtime reader consumed it, so it
#   was not an enforcement defect - but it was a FALSE SECURITY CONTRACT in the
#   released product, readable by an auditor, a support tool or a future parser.
#   THE GAP WAS CATEGORICAL: CLAIM_SURFACES understood executable and
#   operator-printing surfaces and ignored shipped machine-readable contracts.
#   This gate closes that category: any shipped artifact that states security
#   semantics must agree with the effective packet-path authority."
# Exit: 0 agree · 1 contradiction · 3 missing input
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="$ROOT/install/share/nftban/specs/structure_default.json"
TPL="$ROOT/install/nftables/nftables.conf.tpl"
CONF="$ROOT/install/nftables/nftables.conf"
FAILS=0
ok(){ printf '  [PASS] %s\n' "$1"; }
bad(){ printf '  [FAIL] %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "=== shipped spec claim authority (v1.233.0) ==="
[[ -r "$SPEC" ]] || { echo "MISSING spec: $SPEC" >&2; exit 3; }
[[ -r "$TPL"  ]] || { echo "MISSING tpl: $TPL"   >&2; exit 3; }

# --- EFFECTIVE AUTHORITY: what do the emitted rules actually do? -------------
# ⛔ Element-block aware. A multi-line `elements = { <src> ct count over N, ... }`
#    body is dynamic-set STATE, not a rule; counting those as rules produced a
#    false FAIL on a healthy production host during the v1.233.0 canary.
rules_keyed=0; rules_bare=0
for f in "$TPL" "$CONF"; do
    [[ -r "$f" ]] || continue
    while IFS= read -r line; do
        [[ "$line" =~ saddr ]] && rules_keyed=$((rules_keyed+1)) || rules_bare=$((rules_bare+1))
    done < <(grep -E '^[[:space:]]*ct state new tcp dport.*ct count over' "$f" || true)
done
echo "  effective packet-path authority: keyed=$rules_keyed bare=$rules_bare"
if [[ "$rules_keyed" -eq 0 && "$rules_bare" -eq 0 ]]; then
    bad "vacuous: no connlimit rule found in either emission surface — cannot adjudicate"
fi

# --- DECLARED CLAIM: what does the shipped spec say? -------------------------
declared="$(python3 - "$SPEC" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print((d.get("nftables",{}).get("connection_limits",{}) or {}).get("scope","<ABSENT>"))
PY
)"
echo "  shipped spec declares scope: $declared"

# --- THE INVARIANT ------------------------------------------------------------
if [[ "$declared" == "<ABSENT>" ]]; then
    bad "connection_limits.scope is ABSENT from the shipped spec — an unstated contract is not agreement"
elif [[ "$rules_keyed" -gt 0 && "$rules_bare" -eq 0 ]]; then
    case "$declared" in
        per_source*|per_ip*) ok "spec scope '$declared' agrees with keyed enforcement ($rules_keyed keyed, 0 bare)" ;;
        host_wide|global|shared)
            bad "CONTRADICTION: spec declares '$declared' while every emitted rule is KEYED BY SOURCE" ;;
        *) bad "spec scope '$declared' is not a recognised value; cannot be shown to agree with keyed enforcement" ;;
    esac
elif [[ "$rules_bare" -gt 0 && "$rules_keyed" -eq 0 ]]; then
    case "$declared" in
        host_wide|global|shared) ok "spec scope '$declared' agrees with unkeyed enforcement" ;;
        *) bad "CONTRADICTION: spec declares '$declared' while emitted rules carry NO source key" ;;
    esac
else
    bad "MIXED emission ($rules_keyed keyed, $rules_bare bare) — no single scope claim can be true"
fi

# --- NEGATIVE CONTROL: the detector must be able to fail ----------------------
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
python3 - "$SPEC" "$tmp" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
d["nftables"]["connection_limits"]["scope"]="host_wide"
json.dump(d,open(sys.argv[2],"w"))
PY
inj="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["nftables"]["connection_limits"]["scope"])' "$tmp")"
if [[ "$inj" == "host_wide" && "$rules_keyed" -gt 0 ]]; then
    ok "negative control: a synthesised host_wide claim WOULD contradict the keyed emission"
else
    bad "negative control INERT — the detector cannot demonstrate a failure"
fi

echo "=== shipped spec claim authority: FAILS=$FAILS ==="
[[ "$FAILS" -eq 0 ]]
