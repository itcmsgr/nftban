#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# meta:name="sweep_detector_integrity_v1231_test"
# meta:type="test"
# meta:version="1.231.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-15"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed,mktemp,seq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:description="v1.231.0 D2/D3 - guards the double-zero sweep detector against the two ways it was proven to report PASS without looking. (D2) Its A1/A2 arms piped a producer into grep -q; grep -q exits on the FIRST MATCH, sed takes SIGPIPE, and pipefail reports 141, so a SUCCESSFUL match read as no-match. Measured detection under load: 11/150 and 6/150 - ~95% blind and non-deterministic, while four real grep -c ... || echo 0 sites sat in cmd_health_analysis.sh:535-536 and cmd_support.sh:1475-1476. (D3) Its scan root is derived from BASH_SOURCE, so a relocated copy scanned a non-existent directory, found 0 subjects and reported Passed: 6 Failed: 0 - a scan over nothing is indistinguishable from a clean scan. This test asserts the consumer DRAINS the producer, and that a zero or collapsed population is NOT_EXECUTED (exit 2), never PASS. Hermetic."
# meta:ta.id="sweep_detector_integrity_v1231_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="shell-hygiene"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail

_root=$(cd "${BASH_SOURCE[0]%/*}/../../../.." && pwd)
_subject="$_root/cli/lib/nftban/tests/v131_pr_a_2_double_zero_sweep_test.sh"
_pass=0; _fail=0
ok(){ echo "  [PASS] $1"; _pass=$((_pass+1)); }
no(){ echo "  [FAIL] $1${2:+ — $2}"; _fail=$((_fail+1)); }

echo "=== sweep_detector_integrity_v1231 (D2 drain + D3 population precondition) ==="

[[ -f "$_subject" ]] || { echo "  [FAIL] subject absent: $_subject"; echo "=== PASS=0 FAIL=1 ==="; exit 1; }

# The forbidden token is ASSEMBLED, never written literally, so this file does not
# become an offender in the corpus it protects.
BAR='|'; GQ='grep -q'

# --- D2 structural: the scan arms must not short-circuit the producer ----------
# Mirror the guard's OWN three exemptions exactly — a stricter local matcher
# would report findings the merge gate does not, and the two would disagree:
#   MENTION != CODE      strip leading whitespace, then skip comment lines
#   '||' IS NOT A PIPE   require a single bar
#   BUILTIN PRODUCER     echo/printf complete before grep can exit; no race exists
_hits=""
while IFS=: read -r _ln _; do
    [[ -z "$_ln" ]] && continue
    _line="$(sed -n "${_ln}p" "$_subject")"
    _st="${_line#"${_line%%[![:space:]]*}"}"
    case "$_st" in \#*) continue ;; esac
    _hits+="${_ln} "
done < <(grep -nE "[^|]\\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q" "$_subject" \
         | grep -vE '(^|[^A-Za-z_])(echo|printf)[^|]*\|[[:space:]]*grep' || true)
if [[ -n "$_hits" ]]; then
    no "D2a subject still pipes a real producer into ${GQ}" "line(s): $_hits"
else
    ok "D2a no ${BAR} ${GQ} short-circuit remains in the sweep detector (comments and builtin producers excluded, as the guard does)"
fi

# --- D2 behavioural: the chosen primitive must detect DETERMINISTICALLY --------
# A large producer is required: with a small one the race the bug depends on
# cannot occur, and the arm would pass vacuously.
_big="$(mktemp)"; trap 'rm -f "$_big"' EXIT
{ for i in $(seq 1 4000); do echo "filler line $i"; done
  echo 'x=$(grep -c FOO "$f" 2>/dev/null || echo 0)'
  for i in $(seq 1 4000); do echo "trailing line $i"; done
} > "$_big"
_RE='grep[[:space:]]+-c[a-zA-Z]*.*\|\|[[:space:]]*echo[[:space:]]+("0"|0)([[:space:]]|\)|;|\||$)'
_det=0
for _i in $(seq 1 25); do
    if sed -e 's/[[:space:]]#.*$//' "$_big" | grep -E "$_RE" >/dev/null; then _det=$((_det+1)); fi
done
if [[ "$_det" -eq 25 ]]; then
    ok "D2b drain primitive detects a late-file offender 25/25 (deterministic)"
else
    no "D2b drain primitive is NOT deterministic" "detected $_det/25"
fi

# --- D3: a scan over zero/collapsed subjects must be INVALID, never PASS -------
_sandbox="$(mktemp -d)"; trap 'rm -f "$_big"; rm -rf "$_sandbox"' EXIT
mkdir -p "$_sandbox/a/b/c/d"
cp "$_subject" "$_sandbox/a/b/c/d/relocated.sh"
_out="$(bash "$_sandbox/a/b/c/d/relocated.sh" 2>&1)"; _rc=$?
if [[ "$_rc" -eq 2 ]] && [[ "$_out" != *"Failed:  0"* ]]; then
    ok "D3a a relocated copy refuses to run (exit 2), instead of passing on 0 subjects"
else
    no "D3a relocated copy did not refuse" "rc=$_rc out=$(printf '%s' "$_out" | tr '\n' ' ' | cut -c1-90)"
fi

# a root that EXISTS but is nearly empty must also be refused
mkdir -p "$_sandbox/repo/cli/lib/nftban/tests"
printf '#!/usr/bin/env bash\necho hi\n' > "$_sandbox/repo/cli/lib/nftban/only.sh"
cp "$_subject" "$_sandbox/repo/cli/lib/nftban/tests/relocated2.sh"
_out2="$(bash "$_sandbox/repo/cli/lib/nftban/tests/relocated2.sh" 2>&1)"; _rc2=$?
if [[ "$_rc2" -eq 2 ]] && [[ "$_out2" == *"collapsed"* ]]; then
    ok "D3b an existing-but-collapsed population is refused, not reported clean"
else
    no "D3b collapsed population was not refused" "rc=$_rc2"
fi

echo
echo "=== PASS=$_pass FAIL=$_fail ==="
[[ "$_fail" -eq 0 ]]
