#!/usr/bin/env bash
# =============================================================================
# NFTBan - zabbix lifecycle verb parity (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="zabbix_lifecycle_verb_parity_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="metrics"
# meta:ta.id="zabbix_lifecycle_verb_parity_v1229_10_test"
# meta:ta.owner="metrics"
# meta:ta.module="zabbix-lifecycle-verbs"
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
# meta:description="v1.229.10 — `nftban zabbix` had no top-level enable/disable while 6/6 sibling modules (portscan, ddos, geoban, botguard, rbl, metrics) do; the equivalents existed only as `zabbix config enable|disable`, one level down under a verb that reads as show/set settings, and the Commands block printed by `zabbix status` never mentioned them, so an operator could not find how to stop metric push. Locks: top-level enable/disable are dispatched; they DELEGATE to the existing config implementation rather than creating a second enable/disable authority; the legacy `config enable|disable` path still works; help and the status Commands block both advertise the stop path. Also pins the NOT_AFFECTED verdict that made this a discoverability fix and not a fail-open one: the unified exporter gates zabbix push on NFTBAN_ZABBIX_ENABLED, and the shared exporter timer is deliberately NOT stopped because other consumers use it."
# meta:inventory.files="cli/lib/nftban/cli/cmd_zabbix.sh,cli/lib/nftban/exporters/nftban_unified_exporter.sh"
# meta:inventory.binaries="bash,grep"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/../cli/cmd_zabbix.sh"
EXPORTER="$SCRIPT_DIR/../exporters/nftban_unified_exporter.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }

echo "=== zabbix lifecycle verb parity (v1.229.10) ==="
echo ""

# --- the dispatch table is the subject; located by content, never by line ------
dispatch=$(sed -n '/case "\$subcommand" in/,/^    esac/p' "$CLI")

# P1 the verbs the operator could not find are now dispatched at the top level
for v in enable disable; do
    grep -qE "^\s+${v}\)" <<<"$dispatch" \
        && ok "P1 top-level '${v}' is dispatched" \
        || no "P1 top-level '${v}' NOT dispatched"
done

# P2 they DELEGATE — no second enable/disable authority was created
for v in enable disable; do
    grep -qE "^\s+${v}\).*_cmd_zabbix_config ${v}" <<<"$dispatch" \
        && ok "P2 '${v}' delegates to the existing _cmd_zabbix_config ${v}" \
        || no "P2 '${v}' does not delegate — a second authority may have been created"
done

# P3 the legacy path must keep working (this is parity, not replacement)
cfg=$(sed -n '/^_cmd_zabbix_config()/,/^}/p' "$CLI")
for v in enable disable; do
    grep -qE "^\s+${v}\)" <<<"$cfg" \
        && ok "P3 legacy 'config ${v}' still present" \
        || no "P3 legacy 'config ${v}' was removed — that is a regression, not a fix"
done

# P4 the two surfaces the operator actually read must name the stop path
grep -qE '^\s+disable\s+Disable the Zabbix integration' "$CLI" \
    && ok "P4 help advertises disable" || no "P4 help does not advertise disable"
grep -q 'nftban zabbix disable' "$CLI" \
    && ok "P4b the status Commands block names the stop command" \
    || no "P4b status Commands block still omits the stop command"

# --- N1 NEGATIVE CONTROL -------------------------------------------------------
# The control must hit the MOTIVATING defect: a verb absent from the dispatch
# table must be rejected. If unknown verbs were silently accepted, P1 would
# prove nothing.
grep -qE "^\s+\*\)" <<<"$dispatch" && grep -q "Unknown command" <<<"$dispatch" \
    && ok "N1 negative control: an undispatched verb IS rejected (so P1 is meaningful)" \
    || no "N1 negative control failed — unknown verbs are not rejected"

grep -qE "^\s+(stop|start)\)" <<<"$dispatch" \
    && no "N2 stop/start were added — product vocabulary is enable/disable" \
    || ok "N2 no stop/start verb invented — the product vocabulary is enable/disable"

# --- N3 the NOT_AFFECTED verdict this fix rests on -----------------------------
# This is a DISCOVERABILITY fix, not a fail-open fix. That is only true because
# disabling actually stops the push. Pin the gate so a later change cannot
# quietly turn this into a fail-open without failing here.
grep -qE '\$\{NFTBAN_ZABBIX_ENABLED:-false\}"? == "true"' "$EXPORTER" \
    && ok "N3 the exporter GATES zabbix push on NFTBAN_ZABBIX_ENABLED" \
    || no "N3 exporter gate missing — disable would be FAIL-OPEN"

# The shared timer must NOT be stopped by disable: other consumers use it.
dis=$(sed -n '/^        disable)/,/^            ;;/p' <<<"$cfg")
grep -q 'systemctl' <<<"$dis" \
    && no "N4 disable touches systemd — the exporter timer is SHARED with other consumers" \
    || ok "N4 disable does not stop the shared exporter timer (correct: shared authority)"

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "zabbix lifecycle verb parity PASSED"
