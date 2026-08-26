#!/usr/bin/env bash
# =============================================================================
# NFTBan - a coverage verdict is not an enforcement verdict (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="botscan_enforcement_claim_evidence_backed_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="botscan"
# meta:ta.id="botscan_enforcement_claim_evidence_backed_v1229_10_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-report-truth"
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
# meta:description="v1.229.10 — nftban status and nftban health both printed 'NOT currently enforcing (scanner blind/degraded)' whenever BotScan's health_state matched DEGRADED_* or NO_INPUT_*, consulting nothing that speaks to enforcement. Measured false on srv3 2026-08-25: the scanner reported DEGRADED_BUDGET_HIT while actively banning an xmlrpc.php flood, with three attackers held in ip nftban blacklist_manual_ipv4 and 1,241 records in the daemon's durable botscan_ban_evidence.jsonl. Locks the authority direction: durable ban evidence informs the report, and the report never reinterprets proven enforcement as absent. A degraded state now reports COVERAGE degradation; the enforcement axis is reported separately as PROVEN (durable evidence present) or UNPROVEN (absent evidence is explicitly NOT proven-absent). The broken-handoff branch, which IS enforcement-backed, is unchanged, and DEGRADED still raises HEALTH_WARNING."
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/core/nftban_health_checks_modules.sh"
# meta:inventory.binaries="bash,grep"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ST="$SD/../cli/cmd_status.sh"; HM="$SD/../core/nftban_health_checks_modules.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== a coverage verdict is not an enforcement verdict (v1.229.10) ==="
echo ""

# Strip comments: a rule about RENDERED OUTPUT must not be satisfied by prose.
#   MENTION != CODE
# Capture, never pipe into `grep -q`: under `set -o pipefail` a successful
# `grep -q` closes the pipe, the producer takes SIGPIPE, and the PIPELINE reports
# failure — a match is then read as "not found".
#   SIGPIPE + PIPEFAIL + grep -q  =  A TRUE MATCH REPORTED AS ABSENT.
code(){ grep -vE '^[[:space:]]*#' "$1" || true; }
has(){ local body; body="$(code "$1")"; grep -q "$2" <<<"$body"; }

# --- P1 the false claim is gone from every renderer --------------------------
for f in "$ST" "$HM"; do
    n=$(code "$f" | grep -c 'NOT currently enforcing' || true)
    [[ "$n" -eq 0 ]] && ok "P1 $(basename "$f"): no coverage-derived 'NOT currently enforcing' claim" \
                     || no "P1 $(basename "$f"): still asserts NOT currently enforcing ($n)"
done

# --- P2 coverage degradation is still reported (not suppressed) --------------
for f in "$ST" "$HM"; do
    has "$f" 'COVERAGE DEGRADED' \
      && ok "P2 $(basename "$f"): degraded coverage is still surfaced" \
      || no "P2 $(basename "$f"): degradation was suppressed instead of reworded"
done

# --- P3 enforcement is reported from DURABLE EVIDENCE ------------------------
for f in "$ST" "$HM"; do
    has "$f" 'botscan_ban_evidence\.jsonl' \
      && ok "P3 $(basename "$f"): consults the daemon's durable ban evidence" \
      || no "P3 $(basename "$f"): enforcement still claimed without evidence"
done

# --- P4 absent evidence is UNPROVEN, never 'proven absent' -------------------
for f in "$ST" "$HM"; do
    has "$f" 'enforcement UNPROVEN' \
      && ok "P4 $(basename "$f"): absent evidence -> UNPROVEN" \
      || no "P4 $(basename "$f"): absent evidence not reported as UNPROVEN"
done
has "$ST" 'not the same as proven absent' \
  && ok "P4b status states ABSENCE OF EVIDENCE != EVIDENCE OF ABSENCE" \
  || no "P4b the distinction is not stated to the operator"

# --- P5 the enforcement-BACKED branch is untouched ---------------------------
has "$HM" 'bans NOT reaching the kernel' \
  && ok "P5 broken-handoff branch (genuinely enforcement-backed) is unchanged" \
  || no "P5 the handoff branch was altered — that claim WAS evidence-backed"

# --- P6 severity not weakened -------------------------------------------------
# Degraded coverage remains an operator concern. Fixing the wording must not
# quietly downgrade the health status.
awk '/elif \[\[ "\$hs" == DEGRADED_\*/,/status=\$HEALTH_WARNING/' "$HM" | grep -q 'status=$HEALTH_WARNING' \
  && ok "P6 DEGRADED still raises HEALTH_WARNING (verdict softened, severity not)" \
  || no "P6 severity was weakened along with the wording"

# --- N1 NEGATIVE CONTROL: the guard must reject the pre-fix text --------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' 'verdict="ENABLED but ${hs} — NOT currently enforcing (scanner blind/degraded)"' > "$TMP/prefix.sh"
if has "$TMP/prefix.sh" 'NOT currently enforcing'; then
    ok "N1 negative control: the guard DOES detect the pre-fix claim (P1 is meaningful)"
else
    no "N1 negative control failed — the guard cannot see the defect it exists to prevent"
fi

# --- N2 a commented mention must NOT satisfy the guard ------------------------
printf '%s\n' '# historical: it printed "NOT currently enforcing" from a coverage verdict' > "$TMP/comment.sh"
if has "$TMP/comment.sh" 'NOT currently enforcing'; then
    no "N2 a COMMENT satisfied the check — MENTION != CODE is not enforced"
else
    ok "N2 a commented mention does not satisfy the guard (MENTION != CODE)"
fi

# --- N3 authority direction is one-way ---------------------------------------
# The report reads evidence. Nothing here may write bans or touch the kernel to
# make its own output agree.
for f in "$ST" "$HM"; do
    if { code "$f" | grep -E 'nft (add|delete) element|nftban_ban_ip|ban_ip ' >/dev/null; }; then
        no "N3 $(basename "$f"): a REPORT surface acquired enforcement capability"
    else
        ok "N3 $(basename "$f"): report reads evidence only — never mutates enforcement"
    fi
done

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "botscan enforcement claim evidence-backed PASSED"
