#!/usr/bin/env bash
# =============================================================================
# NFTBan - an announced warning must be readable (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="update_warnings_actionable_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="update"
# meta:ta.id="update_warnings_actionable_v1229_10_test"
# meta:ta.owner="update"
# meta:ta.module="update-report-truth"
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
# meta:description="Pins OPEN_UPDATE_SUMMARY_ANNOUNCES_WARNINGS_WITHOUT_A_WAY_TO_READ_THEM. The update summary said 'review N warning(s) requiring action' and then neither printed the warnings nor named where they were; they existed only inside a per-run record the operator was never pointed at. Also pins that an unreadable warning source reports UNKNOWN rather than zero."
# meta:inventory.files="cli/lib/nftban/cli/cmd_update_helpers.sh,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
#   A COUNT IS NOT A FINDING.
#   ABSENT SOURCE != NO FINDINGS.
# =============================================================================
set -Eeuo pipefail
ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
H="$ROOT/cli/lib/nftban/cli/cmd_update_helpers.sh"
U="$ROOT/cli/lib/nftban/cli/cmd_update.sh"
F=0; ok(){ echo "  ok    $*"; }; bad(){ F=$((F+1)); echo "  FAIL  $*"; }
for f in "$H" "$U"; do [[ -f "$f" ]] || { echo "::error::SUBJECT_NOT_FOUND: $f"; exit 1; }; done
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

run_render() { # <logfile> -> rendered output
    bash --noprofile --norc -c '
        set +u
        source "$1" 2>/dev/null || exit 9
        _update_classify_warnings "$2" 0
        echo "COUNT=$_NFTBAN_WARN_REAL SOURCE=$_NFTBAN_WARN_SOURCE"
        _update_render_actionable_warnings "/var/log/nftban/update-runs/TESTRUN" "$2"
    ' _ "$H" "$1" 2>/dev/null
}

echo "=== an announced warning must be readable (v1.229.10) ==="
echo ""
printf '2026 [WARN] cadence oneshot re-run did NOT clean\n2026 [WARN] ASSERT failed_units_postinstall_ok: FAIL\n' > "$TMP/w.log"
out="$(run_render "$TMP/w.log")"

# P1 — warnings exist -> the actual content is rendered, not just a number
if grep -q "COUNT=2" <<<"$out" && grep -q "cadence oneshot re-run did NOT clean" <<<"$out" \
   && grep -q "ASSERT failed_units_postinstall_ok" <<<"$out"; then
    ok "P1 announced warnings are rendered as CONTENT, not only counted"
else
    bad "P1 the summary counted warnings but did not render them — A COUNT IS NOT A FINDING"
fi
# ...and a durable location is always named
if grep -q "full run record:" <<<"$out" && grep -q "installer log:" <<<"$out"; then
    ok "P1b a durable location is named (terminal scrollback is not a record)"
else
    bad "P1b no durable path named for the warnings"
fi

# P2 — zero warnings -> no fabricated warning section
: > "$TMP/empty.log"
out0="$(run_render "$TMP/empty.log")"
if grep -q "COUNT=0" <<<"$out0" && ! grep -q "Warnings requiring action" <<<"$out0"; then
    ok "P2 zero warnings -> no fake warning section"
else
    bad "P2 a warning section was rendered with zero warnings"
fi

# N2 — unreadable source must be UNKNOWN, never "0 warnings"
outu="$(run_render "$TMP/does-not-exist.log")"
if grep -q "SOURCE=UNREADABLE" <<<"$outu" && grep -qi "UNKNOWN" <<<"$outu" \
   && grep -qi "NOT a report of zero warnings" <<<"$outu"; then
    ok "N2 unreadable source -> explicit UNKNOWN, stated as not-zero"
else
    bad "N2 unreadable warning source did not report UNKNOWN — ABSENT SOURCE != NO FINDINGS"
fi

# N1 — structural: the summary must actually call the renderer. Comments stripped, because
# this file and the source both DISCUSS the call.   MENTION != CODE
ucode="$(sed 's/[[:space:]]*#.*$//' "$U")"
if grep -q '_update_render_actionable_warnings' <<<"$ucode"; then
    ok "N1 the update summary invokes the renderer"
else
    bad "N1 summary no longer renders warnings — count-only output has returned"
fi
# and the classifier must retain the lines, not just increment
hcode="$(sed 's/[[:space:]]*#.*$//' "$H")"
if grep -q '_NFTBAN_WARN_REAL_LINES+=' <<<"$hcode"; then
    ok "N1b the classifier retains the warning TEXT alongside the count"
else
    bad "N1b classifier increments a counter and discards the text — the original defect"
fi

echo ""
if [[ $F -gt 0 ]]; then echo "::error::update warnings actionable FAILED: $F"; exit 1; fi
echo "update warnings actionable PASSED"
