#!/usr/bin/env bash
# =============================================================================
# NFTBan - zabbix status must not report a shared timer as its own health (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="zabbix_status_shared_timer_verdict_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="zabbix"
# meta:ta.id="zabbix_status_shared_timer_verdict_v1229_10_test"
# meta:ta.owner="zabbix"
# meta:ta.module="zabbix-status-truth"
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
# meta:description="v1.229.10 — `nftban zabbix status` printed a bare 'Timer: OK Active' under an 'Exporter Service:' heading inside the Zabbix panel, derived ONLY from systemctl is-active nftban-unified-exporter.timer and never cross-referencing the ZABBIX_ENABLED value it had already printed as 'Enabled: false' a few lines above. Reproduced on srv4: Zabbix disabled, no server configured, green check shown. That timer is SHARED (JSON/Prometheus/Zabbix/connectors), so its state says nothing about Zabbix. Locks: every timer branch now emits a subject-specific 'Zabbix push:' verdict; disabled never renders as a Zabbix-favourable state; enabled-but-no-timer is reported as the contradiction it is; no-timer-installed with Zabbix enabled reports UNKNOWN rather than a favourable or a false negative. English-only operator strings."
# meta:inventory.files="cli/lib/nftban/cli/cmd_zabbix.sh"
# meta:inventory.binaries="bash,grep,sed"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/../cli/cmd_zabbix.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== zabbix status: a shared timer is not this subject's verdict (v1.229.10) ==="
echo ""

# Subject located by content, never by line number.
block=$(sed -n '/# Check exporter timer status/,/^    # Check zabbix_sender/p' "$CLI")
[[ -n "$block" ]] && ok "P0 the Exporter Service block was located" || { no "P0 block not found"; echo "PASS=$PASS FAIL=$FAIL"; exit 1; }

# --- P1 the verdict exists at all ---------------------------------------------
n=$(grep -c 'Zabbix push:' <<<"$block" || true)
[[ "$n" -ge 1 ]] && ok "P1 a subject-specific 'Zabbix push:' verdict is emitted ($n renderings)" \
                 || no "P1 no subject-specific verdict — the panel still reports only shared state"

# --- P2 EVERY timer branch must carry a verdict --------------------------------
# Completeness, not sampling: a branch without a verdict is exactly the hole the
# defect lived in. Count the timer-state branches and require one verdict each.
# Each timer branch prints exactly one `echo "  Timer:` line. Segment the block
# on those lines and require a verdict inside every segment. Counting raw
# if/elif would count the nested per-branch conditionals and prove nothing.
segs=0; missing=0; cur=""; started=false
while IFS= read -r line; do
    if [[ "$line" == *'echo "  Timer:'* ]]; then
        if [[ "$started" == true ]]; then
            grep -q 'Zabbix push:' <<<"$cur" || missing=$((missing+1))
        fi
        started=true; segs=$((segs+1)); cur="$line"
    elif [[ "$started" == true ]]; then
        cur="$cur"$'\n'"$line"
    fi
done <<<"$block"
if [[ "$started" == true ]]; then
    grep -q 'Zabbix push:' <<<"$cur" || missing=$((missing+1))
fi
if [[ "$segs" -ge 3 && "$missing" -eq 0 ]]; then
    ok "P2 every timer branch emits a verdict (timer branches=$segs, none missing)"
else
    no "P2 $missing of $segs timer branches emit NO verdict"
fi

# --- P3 the reported case: disabled must never read as favourable --------------
# Extract the disabled renderings and prove none of them is a green claim.
dis=$(grep -A1 'NFTBAN_ZABBIX_ENABLED=false' <<<"$block" || true)
grep -q '✅' <<<"$dis" && no "P3 a disabled rendering contains a green check" \
                      || ok "P3 no disabled rendering is a green/favourable claim"
grep -q 'NOT running' <<<"$block" && ok "P3b disabled states NOT running explicitly" \
                                  || no "P3b disabled does not state NOT running"

# --- P4 the shared nature is named where the green check is -------------------
grep -qE 'Timer:.*Active.*shared exporter' <<<"$block" \
    && ok "P4 the active-timer line names it as SHARED" \
    || no "P4 the active-timer line still implies the timer is Zabbix's own"

# --- P5 enabled-but-no-timer is the contradiction that matters -----------------
grep -q 'ENABLED but no timer is active' <<<"$block" \
    && ok "P5 enabled-with-inactive-timer is reported as a contradiction" \
    || no "P5 enabled-with-inactive-timer is not surfaced"

# --- P6 unestablished state reports UNKNOWN, not a verdict --------------------
grep -q 'UNKNOWN' <<<"$block" \
    && ok "P6 no-timer-installed + enabled reports UNKNOWN, not a favourable state" \
    || no "P6 an unestablished state is being reported as established"

# --- N1 NEGATIVE CONTROL ------------------------------------------------------
# The control must hit the MOTIVATING defect: reconstruct the pre-fix block
# (timer state only, no $enabled reference) and prove this guard rejects it.
prefix_block='    echo "Exporter Service:"
    if systemctl is-active nftban-unified-exporter.timer &>/dev/null; then
        echo "  Timer:      ✅ Active"
    else
        echo "  Timer:      ℹ️  Not installed"
    fi'
if grep -q 'Zabbix push:' <<<"$prefix_block"; then
    no "N1 negative control is not the defect (pre-fix text already has a verdict)"
else
    ok "N1 negative control: the pre-fix block has NO subject verdict, so P1/P2 are meaningful"
fi
grep -q 'enabled' <<<"$prefix_block" \
    && no "N2 negative control still references \$enabled — not the pre-fix shape" \
    || ok "N2 negative control never consults \$enabled — that WAS the defect"

# --- N3 operator strings must be English --------------------------------------
strings=$(grep -oE 'echo "[^"]*"' <<<"$block" || true)
if grep -qP '[\x{0370}-\x{03FF}\x{0400}-\x{04FF}]' <<<"$strings" 2>/dev/null; then
    no "N3 non-English (Greek/Cyrillic) characters in operator output"
else
    ok "N3 operator strings are English only"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "zabbix status shared-timer verdict PASSED"
