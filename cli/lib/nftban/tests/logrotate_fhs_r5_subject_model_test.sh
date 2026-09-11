#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="logrotate-fhs-r5-subject-model"
# meta:type="test"
# meta:description="v1.230.0. Behavioural controls for the R-5 subject model in scripts/ci/check-logrotate-fhs-authority.sh (handle CI-LOGROTATE-FHS-R5-TEST-FIXTURE-FALSE-POSITIVE). R-5 must keep catching PRODUCTION report destinations that resolve outside /var/log - including VARIABLE-DERIVED ones - while no longer judging a test sandbox assignment as a product configuration declaration. The narrowing is authority-based: a file declared in scripts/ci/test-authority-index.tsv is fixture code. Each negative injects a synthetic PRODUCTION declaration and asserts R-5 FAILS for the expected reason; a pattern-only fix (renaming the reporting test's sandbox variable) would pass control 1 and FAIL controls 2 and 3."
# meta:ta.id="logrotate_fhs_r5_subject_model_test"
# meta:ta.owner="core"
# meta:ta.module="logrotate-fhs-authority"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:inventory.files="scripts/ci/check-logrotate-fhs-authority.sh,scripts/ci/test-authority-index.tsv"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
GUARD="$ROOT/scripts/ci/check-logrotate-fhs-authority.sh"
PROBE="$ROOT/cli/lib/nftban/core/zz_r5_control_probe.sh"   # PRODUCTION path, not a test subject
P=0; F=0
ok(){ printf '  [PASS] %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  [FAIL] %s\n' "$1"; F=$((F+1)); }
_cleanup(){ rm -f "$PROBE"; }
trap _cleanup EXIT INT TERM
[[ -r "$GUARD" ]] || { echo "FAIL: guard not reachable: $GUARD" >&2; exit 1; }

echo "=== CONTROL 5: population floor / subject model is non-vacuous ==="
base_out="$(bash "$GUARD" 2>&1)"; base_rc=$?
n=$(printf '%s' "$base_out" | sed -n 's/.*model: \([0-9]\+\) declared test subjects.*/\1/p')
d=$(printf '%s' "$base_out" | sed -n 's/.*(\([0-9]\+\) declarations examined).*/\1/p')
[[ -n "$n" && "$n" -ge 100 ]] && ok "declared test-subject population non-vacuous: $n" || bad "test-subject population missing/low: '${n:-none}'"
[[ -n "$d" && "$d" -ge 10 ]] && ok "production declaration corpus non-vacuous: $d examined" || bad "production corpus missing/low: '${d:-none}'"

echo "=== CONTROL 1: the reporting sandbox fixture must NOT trigger R-5 ==="
[[ "$base_rc" -eq 0 ]] && ok "baseline PASS (rc=0) with the reporting fixture present" || bad "baseline still FAILS (rc=$base_rc)"
grep -q 'report_generator_content_truth' <<<"$base_out" && bad "fixture still named in guard output" || ok "reporting fixture no longer flagged"

echo "=== CONTROL 2: VARIABLE-DERIVED production declaration MUST trigger ==="
printf '#!/usr/bin/env bash\nNFTBAN_REPORTS_DIR="${NFTBAN_DATA_DIR}/reports"\n' > "$PROBE"
o2="$(bash "$GUARD" 2>&1)"; r2=$?
[[ "$r2" -ne 0 ]] && ok "variable-derived production declaration FAILS the guard" || bad "variable-derived production declaration passed — R-5 was over-narrowed"
grep -q 'zz_r5_control_probe' <<<"$o2" && ok "failure names the injected production subject" || bad "failure did not name the probe"
rm -f "$PROBE"

echo "=== CONTROL 3: LITERAL /var/lib production destination MUST trigger ==="
printf '#!/usr/bin/env bash\nNFTBAN_REPORTS_DIR="/var/lib/nftban/reports"\n' > "$PROBE"
o3="$(bash "$GUARD" 2>&1)"; r3=$?
[[ "$r3" -ne 0 ]] && ok "literal /var/lib production destination FAILS the guard" || bad "literal /var/lib destination passed — R-5 is not load-bearing"
grep -q 'zz_r5_control_probe' <<<"$o3" && ok "failure names the injected production subject" || bad "failure did not name the probe"
rm -f "$PROBE"

echo "=== CONTROL 4: legitimate /var/log declaration must PASS ==="
printf '#!/usr/bin/env bash\nNFTBAN_REPORTS_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}/reports"\n' > "$PROBE"
bash "$GUARD" >/dev/null 2>&1; r4=$?
[[ "$r4" -eq 0 ]] && ok "correct /var/log declaration PASSES (no false positive)" || bad "correct /var/log declaration FAILED (rc=$r4)"
rm -f "$PROBE"

echo "=== CONTROL 6: exemption population must stay test-only ==="
grep -q 'all under cli/lib/nftban/tests/' <<<"$base_out" && ok "closure asserted: every declared subject is under the test tree" || bad "closure assertion absent"

_cleanup; trap - EXIT INT TERM
post=0; bash "$GUARD" >/dev/null 2>&1 || post=$?
[[ "$post" -eq 0 ]] && ok "tree restored, guard green again" || bad "tree not restored (rc=$post)"
echo
printf 'logrotate-fhs-r5-subject-model: %s (passed=%d failed=%d)\n' "$([[ $F -eq 0 ]] && echo PASS || echo FAIL)" "$P" "$F"
exit $(( F > 0 ? 1 : 0 ))
