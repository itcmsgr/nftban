#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="config-kv-mutation-truth"
# meta:type="test"
# meta:description="v1.230.0 PR-5c-A. Locks CONFIG-MUTATION-SILENT-DROP-WHEN-KEY-ABSENT. `sed -i \"s|^KEY=.*|KEY=v|\"` substitutes ONLY when the key already exists; against an absent key it changes nothing and still exits 0, so the caller reports success for a request that was never written. Asserts both branches of nftban_config_kv_set (replace-exactly-once / append-exactly-once), the exactly-one cardinality invariant that stops a naive append converting silent-drop into duplicate-key ambiguity, fail-closed refusal on ambiguous or malformed input, and post-write verification. Negative control reproduces the OLD sed idiom and proves it silently drops — so a regression to that idiom fails here. SCOPE: REQUESTED == PERSISTED. It does NOT assert REQUESTED == EFFECTIVE; that is PR-5c-B (CONFIG-SHELL-CENTRAL-OVERRIDE-OVERWRITTEN-BY-LATE-BASE)."
# meta:ta.id="config_kv_mutation_truth_test"
# meta:ta.owner="core"
# meta:ta.module="config-mutation-safety"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="cli/lib/nftban/lib/nftban_config_kv.sh,cli/lib/nftban/cli/cmd_connector.sh,cli/lib/nftban/cli/cmd_report.sh"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
HELPER="$ROOT/cli/lib/nftban/lib/nftban_config_kv.sh"
P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
[[ -r "$HELPER" ]] || { echo "FAIL: helper not reachable: $HELPER" >&2; exit 1; }
# shellcheck source=/dev/null
source "$HELPER" || { echo "FAIL: helper did not load" >&2; exit 1; }
SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT INT TERM
_card(){ grep -cE "^[[:space:]]*$2=" "$1" 2>/dev/null || true; }
_val(){ sed -n "s/^[[:space:]]*$2=\"\([^\"]*\)\".*$/\1/p" "$1" | head -1; }

echo "=== 1. key EXISTS -> replaced exactly once, neighbours intact ==="
printf 'A=1\nCONNECTOR_ENABLED="false"\nB=2\n' > "$SB/x.conf"
if nftban_config_kv_set "$SB/x.conf" CONNECTOR_ENABLED "true"; then ok "mutation returned success"; else bad "mutation failed on an existing key"; fi
[[ "$(_val "$SB/x.conf" CONNECTOR_ENABLED)" == "true" ]] && ok "REQUESTED == PERSISTED (true)" || bad "persisted value is not the request"
[[ "$(_card "$SB/x.conf" CONNECTOR_ENABLED)" -eq 1 ]] && ok "cardinality == 1" || bad "cardinality != 1"
{ grep -q '^A=1$' "$SB/x.conf" && grep -q '^B=2$' "$SB/x.conf"; } && ok "neighbouring keys preserved" || bad "neighbouring keys damaged"

echo "=== 2. key ABSENT -> appended exactly once (THE DEFECT) ==="
printf 'CONNECTOR_NAME="demo"\n' > "$SB/y.conf"
if nftban_config_kv_set "$SB/y.conf" CONNECTOR_ENABLED "true"; then ok "mutation returned success"; else bad "mutation failed on an absent key"; fi
[[ "$(_val "$SB/y.conf" CONNECTOR_ENABLED)" == "true" ]] && ok "REQUESTED == PERSISTED (absent-key branch)" || bad "absent key was not written"
[[ "$(_card "$SB/y.conf" CONNECTOR_ENABLED)" -eq 1 ]] && ok "cardinality == 1 (no duplicate-key ambiguity)" || bad "append produced cardinality != 1"

echo "=== 3. NEGATIVE CONTROL — the OLD sed idiom must be shown to drop silently ==="
printf 'CONNECTOR_NAME="demo"\n' > "$SB/z.conf"
sed -i 's/^CONNECTOR_ENABLED=.*/CONNECTOR_ENABLED="true"/' "$SB/z.conf"; sed_rc=$?
if [[ "$sed_rc" -eq 0 && "$(_card "$SB/z.conf" CONNECTOR_ENABLED)" -eq 0 ]]; then
  ok "old idiom exits 0 while writing NOTHING — regression to it is detectable here"
else bad "negative control did not reproduce the silent drop (rc=$sed_rc card=$(_card "$SB/z.conf" CONNECTOR_ENABLED))"; fi

echo "=== 4. FAIL-CLOSED on ambiguity / malformed input ==="
printf 'K="x"\nK="y"\n' > "$SB/dup.conf"; before=$(cat "$SB/dup.conf")
nftban_config_kv_set "$SB/dup.conf" K "z" >/dev/null 2>&1; rc=$?
[[ "$rc" -eq "${NFTBAN_KV_AMBIGUOUS}" ]] && ok "duplicate key REFUSED (rc=$rc)" || bad "duplicate key not refused (rc=$rc)"
[[ "$before" == "$(cat "$SB/dup.conf")" ]] && ok "refused mutation left the target untouched" || bad "target mutated despite refusal"
nftban_config_kv_set "$SB/x.conf" "BAD KEY" v >/dev/null 2>&1; [[ $? -eq "${NFTBAN_KV_BAD_KEY}" ]] && ok "malformed key refused" || bad "malformed key accepted"
nftban_config_kv_set "$SB/missing.conf" K v >/dev/null 2>&1; [[ $? -eq "${NFTBAN_KV_NO_TARGET}" ]] && ok "absent target refused" || bad "absent target accepted"

echo "=== 5. values hostile to the old delimiter-based sed ==="
printf 'MAIL="old"\n' > "$SB/m.conf"
nftban_config_kv_set "$SB/m.conf" MAIL 'a|b/c d' >/dev/null 2>&1
[[ "$(_val "$SB/m.conf" MAIL)" == 'a|b/c d' ]] && ok "value containing | and / persisted intact" || bad "delimiter-hostile value corrupted"

echo "=== 6. the four converted call sites no longer use the bare idiom ==="
n=$(grep -cE "sed -i .*\^(CONNECTOR_ENABLED|NFTBAN_MAIL_SYSTEM)=" \
      "$ROOT/cli/lib/nftban/cli/cmd_connector.sh" "$ROOT/cli/lib/nftban/cli/cmd_report.sh" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
[[ "$n" -eq 0 ]] && ok "no bare absent-key-unsafe sed remains at the converted sites" || bad "$n bare sed site(s) remain"
for f in cmd_connector.sh cmd_report.sh; do
  grep -q 'nftban_config_kv.sh' "$ROOT/cli/lib/nftban/cli/$f" && ok "$f sources the mutation authority" || bad "$f does not source the helper"
done

echo
printf 'config-kv-mutation-truth: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
