#!/usr/bin/env bash
# =============================================================================
# NFTBan - report what the rule keys on: connlimit is GLOBAL (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="ddos_connlimit_label_global_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="ddos"
# meta:ta.id="ddos_connlimit_label_global_v1229_10_test"
# meta:ta.owner="ddos"
# meta:ta.module="ddos-status-truth"
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
# meta:description="v1.229.10 closes the REPORT half of S4 in STATUS-HEALTH-TRUTH-AUDIT-2026-08-20. nftban ddos status advertised 'SSH Conn: max N/IP' and 'HTTP Conn: max N/IP' while the shipped rules are ct count over N with NO ip saddr key, making the limit GLOBAL — one busy source can consume the whole allowance and every other source is then dropped. Kernel-confirmed on srv3 2026-08-25 across five live rules (SSH, HTTP(S), MAIL, SMTP, DNS/TCP), none keyed by source. Locks that the operator-facing output says GLOBAL and states the consequence, that the per-IP claim cannot return, and that this wording fix performs ZERO nftables mutation and does not touch the rule generator — the keying defect itself remains OPEN under OPEN_CT_COUNT_CONNLIMIT_GLOBAL_KEY_SCOPE and is deliberately NOT smuggled into a report PR."
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos_classic.sh"
# meta:inventory.binaries="bash,grep"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$SD/../core/nftban_ddos_classic.sh"
FRAG="$SD/../lib/nft_fragment.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# MENTION != CODE
body="$(grep -vE '^[[:space:]]*#' "$F" || true)"

echo "=== report what the rule keys on: connlimit is GLOBAL (v1.229.10) ==="
echo ""

# --- P1 the output says GLOBAL -----------------------------------------------
n=$(grep -c 'concurrent GLOBAL (not per-source)' <<<"$body" || true)
[[ "$n" -ge 2 ]] && ok "P1 both connlimit lines report GLOBAL ($n renderings)" \
                 || no "P1 GLOBAL wording missing (found $n)"
grep -q 'one busy source can consume the whole allowance' <<<"$body" \
  && ok "P1b the operator consequence is stated, not just the keying" \
  || no "P1b consequence not stated"

# --- N1 the per-IP claim must not return -------------------------------------
if grep -qE '(SSH|HTTP) Conn:.*/IP' <<<"$body"; then
    no "N1 a per-IP connlimit claim still renders"
else
    ok "N1 no per-IP connlimit claim remains in rendered output"
fi

# --- N2 ZERO nftables mutation: the rule generator is untouched --------------
# The report must not smuggle a semantic change. Assert the generator still emits
# the UNKEYED rule — i.e. this PR changed the description, not the rule.
if grep -qE 'ct count over \$\{(smtp|dns)_limit\}' "$FRAG"; then
    ok "N2 the rule generator still emits the existing unkeyed ct count rule"
else
    no "N2 the rule generator changed — semantics were altered in a report PR"
fi
if grep -qE 'ip saddr .*ct count over|ct count over .*ip saddr' "$FRAG"; then
    no "N2b per-source keying was introduced — that is the CT_COUNT lane, not this PR"
else
    ok "N2b no per-source keying introduced (CT_COUNT semantics untouched)"
fi

# --- N3 the substantive defect stays visible, not papered over ---------------
# The wording must SAY the limit is not per-source. It must not read as though
# the keying were now correct.
grep -q 'not per-source' <<<"$body" \
  && ok "N3 the wording states the limit is NOT per-source (defect stays visible)" \
  || no "N3 wording obscures the keying"

# --- N4 NEGATIVE CONTROL: the guard must detect the pre-fix wording ----------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '    echo "    SSH Conn:  max ${DDOS_CLASSIC_SSH_CONN_LIMIT}/IP"' > "$TMP/pre.sh"
if grep -qE '(SSH|HTTP) Conn:.*/IP' "$TMP/pre.sh"; then
    ok "N4 negative control: the guard detects the pre-fix claim (N1 is meaningful)"
else
    no "N4 negative control failed"
fi

# --- N5 a comment mentioning /IP must not trip N1 ----------------------------
printf '%s\n' '# these lines claimed "SSH Conn: max N/IP" which was false' > "$TMP/c.sh"
cb="$(grep -vE '^[[:space:]]*#' "$TMP/c.sh" || true)"
if grep -qE 'Conn:.*/IP' <<<"$cb"; then
    no "N5 a COMMENT satisfied the check — MENTION != CODE not enforced"
else
    ok "N5 a commented mention does not trip the guard (MENTION != CODE)"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ddos connlimit label global PASSED"
