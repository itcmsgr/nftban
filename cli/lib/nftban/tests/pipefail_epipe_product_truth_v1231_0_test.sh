#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.231.0 - pipefail/EPIPE product-truth behavioral regression (Lane H)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="pipefail_epipe_product_truth_v1231_0_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-18"
# meta:description="BEHAVIORAL (never source-shape) regression guard for the three v1.231.0 Lane H pipefail/EPIPE product-truth defects. Under set -o pipefail a 'producer | short-circuit-consumer' pipeline reports FAILED on a SUCCESSFUL match: the consumer (grep -q) exits at the first hit, the producer keeps writing, fills the 64 KiB pipe buffer and takes SIGPIPE (141), while PIPESTATUS[1]=0 proves the match succeeded. Where the call site treats pipeline-true AS the detection, a match silently becomes a miss. Three confirmed product instances are covered, each driven through its REAL function with a stubbed nft whose output is a file-backed fixture: (1) nftban_detect_xt_compat mis-reported HEALTH_OK for conflicting_firewalls while iptables-nft xt-compat rules were present, a false negative on a detector that only ever fires when there IS something to find; (2) nftban_validate_hook_authority downgraded a FOREIGN table owning an input hook from CRITICAL competing-authority to CLEAR -- the table skip above it excludes only NFTBan's own tables, so a large competing firewall is exactly what reaches the parse; (3) nftban_ddos_list_banned (DDoS CLASSIC mode only) rendered '  (none)' for a POPULATED ban set, an enforcement-visibility truth defect telling the operator nothing is banned while thousands are. Every positive arm passes a VACUITY GATE asserting the fixture really is over the threshold and really does carry the marker, so an 'absent' answer can never bank a free pass; every site also carries a genuine-absence NEGATIVE arm, because over-reporting is its own defect. Closes with a DECLARED INVERSION that reconstructs the pre-fix 'producer | grep -q' shape INLINE (never read from origin/main, which inverts the moment this merges) and proves the false-absence reproduces against the same fixtures."
#
# meta:input="Synthetic nft-rendering fixtures + a stubbed nft on PATH, in a mktemp sandbox"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_firewall_conflicts.sh,cli/lib/nftban/core/nftban_ddos_classic.sh"
# meta:inventory.binaries="bash,awk,grep,head,wc"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="pipefail_epipe_product_truth_v1231_0_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="pipefail-epipe-product-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFLICTS_LIB="$LIB_ROOT/core/nftban_firewall_conflicts.sh"
DDOS_CLASSIC_LIB="$LIB_ROOT/core/nftban_ddos_classic.sh"

PASS=0; FAIL=0; NOTEXEC=0
ok()       { PASS=$((PASS+1));    printf '  [PASS] %s\n' "$1"; }
bad()      { FAIL=$((FAIL+1));    printf '  [FAIL] %s\n' "$1"; }
notexec()  { NOTEXEC=$((NOTEXEC+1)); printf '  [NOT_EXECUTED] %s\n' "$1"; }

for f in "$CONFLICTS_LIB" "$DDOS_CLASSIC_LIB"; do
    [[ -r "$f" ]] || { notexec "subject not readable: $f"; printf 'RESULT: NOT_EXECUTED\n'; exit 1; }
done

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
FIX="$SANDBOX/fixtures"; mkdir -p "$FIX"

# -----------------------------------------------------------------------------
# Threshold note (measured on bash 5.3, Linux default 64 KiB pipe capacity):
#   producer | grep -q  with the marker on line 3 first misses well below the
#   sizes used here. `nft list ruleset` on a fleet host renders 168-196 KB, so
#   the positive fixtures below are sized at ~192-196 KB: comfortably over the
#   threshold for both the external-producer and the echo-of-a-variable form.
#   Fixtures are FILES. Nothing large is passed through the environment --
#   `export BIG=...` then exec gives E2BIG (rc=126), an environment failure and
#   never a verdict.
# -----------------------------------------------------------------------------
BIG_BYTES=196608

# gen_padded <bytes> <out> <header-line-3>
gen_padded() {
    local bytes="$1" out="$2" line3="$3"
    {
        printf 'table ip filter {\n'
        printf '\tchain INPUT {\n'
        printf '%s\n' "$line3"
        awk 'BEGIN{for(i=0;i<200000;i++) printf "\t\tip saddr 10.%d.%d.%d counter drop\n", i/65536%256, i/256%256, i%256}'
    } > "$out.full"
    head -c "$bytes" "$out.full" > "$out"
    printf '\n' >> "$out"
    rm -f "$out.full"
}

# gen_banset <elements> <out>   -- reproduces real `nft list set` rendering:
# `elements = { ` opens on one line and continues one element per line.
gen_banset() {
    local n="$1" out="$2"
    {
        printf 'table ip nftban {\n\tset ddos_banned {\n\t\ttype ipv4_addr\n\t\tflags timeout\n'
        if (( n > 0 )); then
            printf '\t\telements = { 203.0.113.1 timeout 1h expires 59m58s,\n'
            awk -v n="$n" 'BEGIN{for(i=1;i<n;i++) printf "\t\t\t     198.51.%d.%d timeout 1h expires 59m58s,\n", i/256%256, i%256}'
            printf '\t\t\t     192.0.2.254 timeout 1h expires 59m58s }\n'
        fi
        printf '\t}\n}\n'
    } > "$out"
}

# vacuity_gate <file> <needle> <expected-count 0|1+> <label>
# Returns 0 when the fixture really is what the arm claims it is.
vacuity_gate() {
    local f="$1" needle="$2" want="$3" label="$4" n sz
    sz=$(wc -c < "$f")
    n=$(grep -c -- "$needle" "$f") || n=0
    if [[ "$want" == "0" ]]; then
        if (( n != 0 )); then
            notexec "$label: negative fixture CONTAINS '$needle' ($n hits) -- refusing a free pass"
            return 1
        fi
    else
        if (( n == 0 )); then
            notexec "$label: positive fixture LACKS '$needle' -- refusing a free pass"
            return 1
        fi
        if (( sz < 131072 )); then
            notexec "$label: positive fixture is ${sz}B, under the measured miss threshold -- not a valid subject"
            return 1
        fi
    fi
    printf '    vacuity: %s bytes=%s needle=%q hits=%s\n' "$label" "$sz" "$needle" "$n"
    return 0
}

# make_nft_stub <dir> <mode> <fixture>
#   mode=ruleset   : `nft list ruleset`   streams the fixture
#   mode=tableonly : `nft list tables` -> "table ip filter"; `nft list table ...`
#                    streams the fixture
#   mode=set       : `nft list set ...`   streams the fixture
make_nft_stub() {
    local dir="$1" mode="$2" fx="$3"
    mkdir -p "$dir"
    {
        printf '#!/usr/bin/env bash\n'
        case "$mode" in
          ruleset)   printf 'if [ "$1" = "list" ] && [ "$2" = "ruleset" ]; then exec cat %q; fi\n' "$fx" ;;
          tableonly) printf 'if [ "$1" = "list" ] && [ "$2" = "tables" ]; then echo "table ip filter"; exit 0; fi\n'
                     printf 'if [ "$1" = "list" ] && [ "$2" = "table" ]; then exec cat %q; fi\n' "$fx" ;;
          set)       printf 'if [ "$1" = "list" ] && [ "$2" = "set" ]; then exec cat %q; fi\n' "$fx" ;;
        esac
        printf 'exit 0\n'
    } > "$dir/nft"
    chmod +x "$dir/nft"
}

# run_child <script-body-file> <lib> -> stdout of a REAL child process.
# A real child is required: the subject libs run `set -Eeuo pipefail` at file
# scope, so sourcing arms errexit; `( ... ) || true` would disarm it INSIDE the
# subshell and stop exercising the product's actual shell semantics.
CHILD="$SANDBOX/child.sh"

# =============================================================================
printf '\n== SITE 1: nftban_detect_xt_compat (firewall conflict detector) ==\n'
# =============================================================================
cat > "$CHILD" <<'CHILD_EOF'
#!/usr/bin/env bash
source "$1"
rc=0; nftban_detect_xt_compat || rc=$?
# the function returns 1 when xt-compat rules were detected, 0 when not found
[[ "$rc" -eq 1 ]] && echo DETECTED || echo MISSED
CHILD_EOF
chmod +x "$CHILD"

gen_padded "$BIG_BYTES" "$FIX/ruleset_xt.txt"   '		counter packets 0 bytes 0 xt target "REJECT"'
gen_padded "$BIG_BYTES" "$FIX/ruleset_noxt.txt" '		counter packets 0 bytes 0 accept'

if vacuity_gate "$FIX/ruleset_xt.txt" 'xt target' 1 "xt-compat POSITIVE"; then
    make_nft_stub "$SANDBOX/stub1" ruleset "$FIX/ruleset_xt.txt"
    out="$(PATH="$SANDBOX/stub1:$PATH" "$CHILD" "$CONFLICTS_LIB" 2>/dev/null)" || out="CHILD_RC_FAIL"
    if [[ "$out" == "DETECTED" ]]; then
        ok "xt-compat rules present in a ${BIG_BYTES}B ruleset are DETECTED (no EPIPE false negative)"
    else
        bad "xt-compat rules present in a ${BIG_BYTES}B ruleset reported '$out' -- conflict detector false negative"
    fi
fi

if vacuity_gate "$FIX/ruleset_noxt.txt" 'xt target' 0 "xt-compat NEGATIVE"; then
    make_nft_stub "$SANDBOX/stub1n" ruleset "$FIX/ruleset_noxt.txt"
    out="$(PATH="$SANDBOX/stub1n:$PATH" "$CHILD" "$CONFLICTS_LIB" 2>/dev/null)" || out="CHILD_RC_FAIL"
    if [[ "$out" == "MISSED" ]]; then
        ok "a ${BIG_BYTES}B ruleset with genuinely NO xt-compat rules still reports no conflict"
    else
        bad "genuine absence reported '$out' -- over-reporting is its own defect"
    fi
fi

# =============================================================================
printf '\n== SITE 2: nftban_validate_hook_authority (foreign hook ownership) ==\n'
# =============================================================================
cat > "$CHILD" <<'CHILD_EOF'
#!/usr/bin/env bash
source "$1"
# NOT inside $( ): that is a subshell and NFTBAN_HOOK_AUTHORITY_LEVEL would not
# propagate back -- a harness defect, never a verdict.
rc=0; nftban_validate_hook_authority --quiet >/dev/null 2>&1 || rc=$?
echo "${NFTBAN_HOOK_AUTHORITY_LEVEL:-unset}"
CHILD_EOF
chmod +x "$CHILD"

gen_padded "$BIG_BYTES" "$FIX/table_hooked.txt" '		type filter hook input priority 0; policy accept;'
gen_padded "$BIG_BYTES" "$FIX/table_nohook.txt" '		comment "no base chain in this table"'

if vacuity_gate "$FIX/table_hooked.txt" 'hook input' 1 "hook-authority POSITIVE"; then
    make_nft_stub "$SANDBOX/stub2" tableonly "$FIX/table_hooked.txt"
    out="$(PATH="$SANDBOX/stub2:$PATH" "$CHILD" "$CONFLICTS_LIB" 2>/dev/null)" || out="CHILD_RC_FAIL"
    if [[ "$out" == "critical" ]]; then
        ok "a FOREIGN table owning an input hook in ${BIG_BYTES}B of content is CRITICAL"
    else
        bad "foreign input hook in ${BIG_BYTES}B reported authority='$out' -- competing authority silently cleared"
    fi
fi

if vacuity_gate "$FIX/table_nohook.txt" 'hook input' 0 "hook-authority NEGATIVE"; then
    make_nft_stub "$SANDBOX/stub2n" tableonly "$FIX/table_nohook.txt"
    out="$(PATH="$SANDBOX/stub2n:$PATH" "$CHILD" "$CONFLICTS_LIB" 2>/dev/null)" || out="CHILD_RC_FAIL"
    if [[ "$out" == "info" || "$out" == "ok" ]]; then
        ok "a ${BIG_BYTES}B foreign table with genuinely NO hooks stays CLEAR (authority='$out')"
    else
        bad "genuine absence of hooks reported authority='$out' -- over-reporting is its own defect"
    fi
fi

# =============================================================================
printf '\n== SITE 3: nftban_ddos_list_banned -- DDoS CLASSIC MODE ONLY ==\n'
# =============================================================================
# Scope: this is the CLASSIC execution mode (nftban_ddos_classic.sh). The
# Suricata DDoS mode implements the operator-facing ban surface differently --
# nftban_ddos_suricata_status renders a COUNT via `... | grep -c "timeout"`,
# a consumer that reads to EOF and therefore cannot short-circuit. It is NOT
# covered here and must not be inferred from this result.
cat > "$CHILD" <<'CHILD_EOF'
#!/usr/bin/env bash
export NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/nonexistent-lib-dir}"
source "$1" 2>/dev/null
out="$(nftban_ddos_list_banned 2>/dev/null)" || true
v4="$(printf '%s\n' "$out" | sed -n '/IPv4 banned IPs/,/IPv6 banned IPs/p')"
if printf '%s' "$v4" | grep -q '(none)'; then echo RENDERED_NONE
elif printf '%s' "$v4" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then echo RENDERED_ENTRIES
else echo RENDERED_OTHER; fi
CHILD_EOF
chmod +x "$CHILD"

gen_banset 5000 "$FIX/set_populated.txt"
gen_banset 0    "$FIX/set_empty.txt"

if vacuity_gate "$FIX/set_populated.txt" 'elements' 1 "ban-list POSITIVE"; then
    make_nft_stub "$SANDBOX/stub3" set "$FIX/set_populated.txt"
    out="$(PATH="$SANDBOX/stub3:$PATH" "$CHILD" "$DDOS_CLASSIC_LIB" 2>/dev/null)" || out="CHILD_RC_FAIL"
    if [[ "$out" == "RENDERED_ENTRIES" ]]; then
        ok "a POPULATED ban set (5000 elements) renders its entries, not '(none)'"
    else
        bad "a POPULATED ban set rendered '$out' -- enforcement-visibility truth defect"
    fi
fi

# The empty-set arm is deliberately NOT size-gated: genuine emptiness is small
# by construction, and that is exactly the answer that must stay correct.
if (( $(grep -c 'elements' "$FIX/set_empty.txt" || true) == 0 )); then
    printf '    vacuity: ban-list NEGATIVE bytes=%s needle="elements" hits=0\n' "$(wc -c < "$FIX/set_empty.txt")"
    make_nft_stub "$SANDBOX/stub3n" set "$FIX/set_empty.txt"
    out="$(PATH="$SANDBOX/stub3n:$PATH" "$CHILD" "$DDOS_CLASSIC_LIB" 2>/dev/null)" || out="CHILD_RC_FAIL"
    if [[ "$out" == "RENDERED_NONE" ]]; then
        ok "a genuinely EMPTY ban set still renders '(none)'"
    else
        bad "an empty ban set rendered '$out' -- over-reporting is its own defect"
    fi
else
    notexec "ban-list NEGATIVE: empty fixture contains 'elements' -- refusing a free pass"
fi

# =============================================================================
printf '\n== DECLARED INVERSION: the pre-fix shape, reconstructed inline ==\n'
# =============================================================================
# The old `producer | grep -q` shape is SPELLED OUT HERE, never read from
# origin/main -- a negative control sourced from the mainline inverts the
# moment this fix merges and would then silently stop controlling anything.
# If any arm below reports DETECTED/CRITICAL/ENTRIES, the defect class no
# longer reproduces on this machine and every PASS above is unproven.
cat > "$CHILD" <<'CHILD_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  xt)
    if nft list ruleset 2>/dev/null | grep -qE "xt target|xtables compat"; then echo DETECTED; else echo MISSED; fi ;;
  hook)
    tc="$(nft list table ip filter 2>/dev/null)" || tc=""
    has=false
    echo "$tc" | grep -qE "hook[[:space:]]+input" && has=true
    [[ "$has" == "true" ]] && echo CRITICAL || echo CLEAR ;;
  ban)
    if timeout 10s nft list set ip nftban ddos_banned 2>/dev/null | grep -q "elements"; then
        echo RENDERED_ENTRIES; else echo RENDERED_NONE; fi ;;
esac
CHILD_EOF
chmod +x "$CHILD"

inv_xt="$(PATH="$SANDBOX/stub1:$PATH"  "$CHILD" xt   2>/dev/null)" || inv_xt="INV_RC_FAIL"
inv_hk="$(PATH="$SANDBOX/stub2:$PATH"  "$CHILD" hook 2>/dev/null)" || inv_hk="INV_RC_FAIL"
inv_bn="$(PATH="$SANDBOX/stub3:$PATH"  "$CHILD" ban  2>/dev/null)" || inv_bn="INV_RC_FAIL"

if [[ "$inv_xt" == "MISSED" ]]; then
    ok "INVERSION site 1: the pre-fix pipeline still reports 'no conflict' on a matching ${BIG_BYTES}B ruleset"
else
    bad "INVERSION site 1 returned '$inv_xt' -- the defect no longer reproduces; site 1's PASS is unproven"
fi
if [[ "$inv_hk" == "CLEAR" ]]; then
    ok "INVERSION site 2: the pre-fix pipeline still clears a foreign input hook at ${BIG_BYTES}B"
else
    bad "INVERSION site 2 returned '$inv_hk' -- the defect no longer reproduces; site 2's PASS is unproven"
fi
if [[ "$inv_bn" == "RENDERED_NONE" ]]; then
    ok "INVERSION site 3: the pre-fix gate still reports '(none)' for a populated 5000-element ban set"
else
    bad "INVERSION site 3 returned '$inv_bn' -- the defect no longer reproduces; site 3's PASS is unproven"
fi

# =============================================================================
printf '\n=============================================================\n'
printf 'PASS=%d FAIL=%d NOT_EXECUTED=%d\n' "$PASS" "$FAIL" "$NOTEXEC"
if (( FAIL > 0 )); then printf 'RESULT: FAIL\n'; exit 1; fi
if (( NOTEXEC > 0 )); then printf 'RESULT: NOT_EXECUTED (a subject could not be constructed)\n'; exit 1; fi
printf 'RESULT: PASS\n'
exit 0
