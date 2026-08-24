#!/usr/bin/env bash
# =============================================================================
# NFTBan - the configured EVE file is the consumed EVE file (v1.229.9)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="suricata_eve_file_authority_v1229_9_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="suricata"
# meta:ta.id="suricata_eve_file_authority_v1229_9_test"
# meta:ta.owner="suricata"
# meta:ta.module="suricata-eve-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="Pins OPEN_SURICATA_EVE_FILE_SETTING_HONOURED_INCONSISTENTLY. DDoS discarded the operator's configured EVE FILENAME and globbed a hardcoded eve-alerts*.json prefix in its directory, so a host configured with another name was judged by an unrelated sibling. PortScan honoured the setting but dereferenced it with no default at point of use, terminating the shell under set -u when the config had not been loaded. One authority, two failure modes."
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos_suricata.sh,cli/lib/nftban/core/nftban_portscan_suricata.sh"
# meta:inventory.binaries="bash,stat,date"
# meta:inventory.env_vars="DDOS_SURICATA_EVE_FILE,PORTSCAN_SURICATA_EVE_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
#   CONFIGURED EVE FILE -> SAME CANONICAL VALUE CONSUMED BY BOTH MODULE PREDICATES
#   MISSING REQUIRED CONFIG -> EXPLICIT BOUNDED RESULT, NEVER set -u TERMINATION
# =============================================================================
set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
DSRC="$ROOT/cli/lib/nftban/core/nftban_ddos_suricata.sh"
PSRC="$ROOT/cli/lib/nftban/core/nftban_portscan_suricata.sh"
F=0
ok(){ echo "  ok    $*"; }
bad(){ F=$((F+1)); echo "  FAIL  $*"; }
for f in "$DSRC" "$PSRC"; do [[ -f "$f" ]] || { echo "::error::SUBJECT_NOT_FOUND: $f"; exit 1; }; done

# ddos_eve <configured-file> -> rc of the real predicate, in isolation
ddos_eve() {
    bash --noprofile --norc -c '
        set -uo pipefail
        src="$1"; export DDOS_SURICATA_EVE_FILE="$2"
        eval "$(awk "/^nftban_ddos_suricata_eve_active\\(\\) \\{/{i=1} i{print} i&&/^\\}/{exit}" "$src")"
        nftban_ddos_suricata_eve_active
    ' _ "$DSRC" "$1" >/dev/null 2>&1
}
# portscan_eve [configured-file|__UNSET__] -> "rc=<n>" or "TERMINATED"
#
# ⛔ DO NOT "SIMPLIFY" THIS INTO A BARE CALL ON THE SOURCED MODULE.
# nftban_portscan_suricata.sh sets `set -Eeuo pipefail` at file scope. A probe that
# sources the whole module and then calls the predicate BARE inherits `-e`, so a
# CORRECT `return 1` exits the probe's own shell and the arm reports TERMINATED --
# which is exactly the failure this test exists to detect, produced by the harness
# instead of the product. That false failure was observed package-native on both
# families on 2026-08-24 before being traced.
#   INHERITED SHELL OPTIONS ARE PART OF THE CALLER'S STATE.
#   A PROBE THAT DOES NOT REPRODUCE THE CALLER'S CONVENTION TESTS THE PROBE.
# Two independent defences are used here: the function is extracted and evaluated on
# its own (so no file-scope `set -e` is inherited), and the return code is captured
# explicitly rather than allowed to terminate the shell. Production callers reach this
# predicate from conditional context (`if ... ; then`), where `-e` does not fire.
portscan_eve() {
    # The predicate's rc is carried in the echoed RC= marker, not in this shell's $?,
    # so a local rc would be assigned and never read (SC2034). Tolerate a non-zero exit
    # here explicitly rather than capturing a value nothing consumes.
    local out
    out=$(bash --noprofile --norc -c '
        set -uo pipefail
        src="$1"
        if [ "$2" != "__UNSET__" ]; then export PORTSCAN_SURICATA_EVE_FILE="$2"; fi
        eval "$(awk "/^nftban_portscan_suricata_eve_active\\(\\) \\{/{i=1} i{print} i&&/^\\}/{exit}" "$src")"
        nftban_portscan_suricata_eve_active; echo "RC=$?"
    ' _ "$PSRC" "$1" 2>/dev/null) || true
    if grep -q '^RC=' <<<"$out"; then echo "rc=$(grep -o 'RC=[0-9]*' <<<"$out" | cut -d= -f2)"; else echo "TERMINATED"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
echo "=== the configured EVE file is the consumed EVE file (v1.229.9) ==="
echo ""
echo "DDoS — the operator's filename is the authority"

# P1: a custom configured name, fresh -> TRUE
: > "$TMP/custom.json"
if ddos_eve "$TMP/custom.json"; then
    ok "P1 fresh CONFIGURED file (custom.json) -> predicate TRUE"
else
    bad "P1 fresh configured file was not honoured"
fi

# N1: configured file ABSENT while a fresh eve-alerts*.json sits beside it.
# The pre-fix implementation returned TRUE from that unrelated sibling.
rm -f "$TMP/custom.json"; : > "$TMP/eve-alerts.json"
if ddos_eve "$TMP/custom.json"; then
    bad "N1 predicate became TRUE from an unrelated eve-alerts*.json while the CONFIGURED file was absent — the setting is still being ignored"
else
    ok "N1 unrelated eve-alerts*.json does NOT satisfy a different configured filename"
fi

# Threaded siblings of the CONFIGURED name are still supported (7.x feature retained).
rm -f "$TMP"/*.json; : > "$TMP/custom.1.json"
if ddos_eve "$TMP/custom.json"; then
    ok "P1b Suricata 7.x threaded sibling of the CONFIGURED name (custom.1.json) still counts"
else
    bad "P1b threaded logging support for the configured name was lost"
fi
# ...but a threaded sibling of a DIFFERENT name must not count.
rm -f "$TMP"/*.json; : > "$TMP/other.1.json"
if ddos_eve "$TMP/custom.json"; then
    bad "N1b a threaded sibling of a DIFFERENT name satisfied the configured file"
else
    ok "N1b threaded siblings are scoped to the configured name"
fi

echo ""
echo "PortScan — an unset required value is an answer, not a crash"

# P2: valid configured file -> normal behaviour
rm -f "$TMP"/*.json; : > "$TMP/ps.json"
r="$(portscan_eve "$TMP/ps.json")"
[[ "$r" == "rc=0" ]] && ok "P2 fresh configured file -> predicate TRUE ($r)" \
                     || bad "P2 fresh configured file did not return TRUE ($r)"

# N2: required config absent -> bounded result, NOT process termination
r="$(portscan_eve "__UNSET__")"
if [[ "$r" == "TERMINATED" ]]; then
    bad "N2 unset PORTSCAN_SURICATA_EVE_FILE TERMINATED the shell under set -u — a caller mistake must not kill the process"
elif [[ "$r" == "rc=1" ]]; then
    ok "N2 unset required config -> explicit bounded FALSE, no termination ($r)"
else
    bad "N2 unset required config produced an unexpected result ($r)"
fi

echo ""
echo "structural"
# N3: the hardcoded prefix glob must not return. Comments stripped: this file and the
# source both DISCUSS the pattern, and matching prose would pass on prose alone.
#   MENTION != CODE
dcode="$(sed 's/[[:space:]]*#.*$//' "$DSRC")"
if grep -qE '/eve-alerts\*\.json' <<<"$dcode"; then
    bad "N3 DDoS still globs a HARDCODED eve-alerts*.json prefix — the configured filename is being discarded again"
else
    ok "N3 no hardcoded eve-alerts* prefix glob in the DDoS predicate"
fi
# N4: PortScan must not dereference the required value without a fallback.
pcode="$(sed 's/[[:space:]]*#.*$//' "$PSRC")"
if grep -qE 'eve_file="\$\{PORTSCAN_SURICATA_EVE_FILE\}"' <<<"$pcode"; then
    bad "N4 PortScan dereferences PORTSCAN_SURICATA_EVE_FILE with no fallback — set -u termination is back"
else
    ok "N4 PortScan does not dereference the required value unguarded"
fi

echo ""
if [[ $F -gt 0 ]]; then echo "::error::suricata EVE file authority FAILED: $F"; exit 1; fi
echo "suricata EVE file authority PASSED"
