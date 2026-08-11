#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.0 R0 — CSF OBSERVATION PURITY (release-blocking)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="csf-observation-purity-v1229-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-11"
# meta:description="R0 release gate. Proves CSF observation executes no vendor firewall binary, that activity is read from csf.service OR lfd.service, that an unobservable host yields cannot-verify (never 'disabled'), and that cannot-verify can never cross the observation->mutation boundary into the drift-policy consumer."
# meta:inventory.files="cli/lib/nftban/core/nftban_firewall_conflicts.sh,cli/lib/nftban/cli/cmd_health_analysis.sh,cli/lib/nftban/lib/nftban_checks.sh,cli/lib/nftban/core/nftban_output.sh"
# meta:inventory.privileges="none"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# =============================================================================
#
# PROVEN DEFECT THIS GUARDS (el9-clean, 2026-08-11):
#   `nftban firewall conflicts` — a read-only report — installed 129 kernel
#   rules (measured 0 -> 129) because the detector used `csf -s`, which is
#   CSF's START command. Reachable from nftban-maintenance.timer and
#   nftban-health.timer: unattended root re-arming a competing firewall.
#   Second defect: activity was read from `lfd` alone, so an enforcing host
#   with csf.service active + lfd failed reported "disabled (no conflict)".
#
# HARNESS POLICY: no `producer | grep -q` under pipefail anywhere — that
# returns 141 on a MATCH and reads as no-match.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIB="$REPO_ROOT/cli/lib/nftban"
CONFLICTS_LIB="$LIB/core/nftban_firewall_conflicts.sh"

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; echo "       $2"; FAIL=$((FAIL+1)); }

SANDBOX="$(mktemp -d)"
# The EXIT trap is INHERITED by every ( ) subshell below. Without the PID guard
# the FIRST arm's subshell deletes the sandbox on exit, and every later arm then
# runs with no mocks: `command -v csf` fails, the detector never enters its body,
# severity stays 0, and T6 passes VACUOUSLY. Caught by the T-VAC control below.
MAIN_PID=$$
trap '[[ $BASHPID == "$MAIN_PID" ]] && rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"

# --- mock vendor binary: records every invocation, mutates nothing ----------
cat > "$SANDBOX/bin/csf" <<'MOCK'
#!/usr/bin/env bash
echo "csf $*" >> "${CSF_INVOCATION_LOG:?}"
# A real `csf -s` would install a ruleset here. The mock only records, so an
# invocation is observable without the test ever touching a firewall.
exit 0
MOCK
chmod +x "$SANDBOX/bin/csf"

# --- mock systemctl: scripted per-unit answers via SYSTEMCTL_MODE -----------
cat > "$SANDBOX/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
unit=""
for a in "$@"; do case "$a" in *.service|csf|lfd) unit="$a";; esac; done
case "${SYSTEMCTL_MODE:-inactive}" in
  inactive)      echo "inactive";      [ "$1" = "is-active" ] && exit 3 ;;
  csf-active)    case "$unit" in csf.service) echo "active"; exit 0;; *) echo "failed"; exit 3;; esac ;;
  lfd-active)    case "$unit" in lfd.service|lfd) echo "active"; exit 0;; *) echo "inactive"; exit 3;; esac ;;
  unusable)      exit 1 ;;   # no stdout at all -> systemd/D-Bus unusable
esac
exit 3
MOCK
chmod +x "$SANDBOX/bin/systemctl"

export CSF_INVOCATION_LOG="$SANDBOX/csf-invocations.log"
: > "$CSF_INVOCATION_LOG"

# CSF must look INSTALLED so the detector enters its body at all.
mkdir -p "$SANDBOX/etc/csf"
printf 'TESTING = "1"\n' > "$SANDBOX/etc/csf/csf.conf"

run_detector() { # $1=SYSTEMCTL_MODE -> prints severity; fills conflicts array
    : > "$CSF_INVOCATION_LOG"
    ( export PATH="$SANDBOX/bin:$PATH" SYSTEMCTL_MODE="$1"
      # shellcheck disable=SC1090
      # The lib does `set -Eeuo pipefail` at load (nftban_firewall_conflicts.sh:34),
      # so sourcing it turns errexit ON here. nftban_detect_csf returns 2 by
      # contract (0=none 1=installed 2=active) — without `|| true` the subshell
      # dies on that return and every assertion below reads empty output as a
      # pass. That is how the first draft of this test passed vacuously.
      source "$CONFLICTS_LIB" >/dev/null 2>&1
      set +e
      # shellcheck disable=SC2034  # FIXES is written by the detector, not read here
      NFTBAN_FIREWALL_CONFLICTS=(); NFTBAN_FIREWALL_FIXES=()
      NFTBAN_FIREWALL_SEVERITY=$CONFLICT_NONE
      nftban_detect_csf >/dev/null 2>&1 || true
      printf '%s\n' "SEVERITY=$NFTBAN_FIREWALL_SEVERITY"
      printf '%s\n' "${NFTBAN_FIREWALL_CONFLICTS[@]}"
    )
}

echo "── T1  observation executes NO vendor binary ──────────────────────────"
OUT="$(run_detector inactive)"
N=$(wc -l < "$CSF_INVOCATION_LOG")
[ "$N" -eq 0 ] && ok "mock csf invocation count == 0" \
               || no "detector executed the vendor binary" "invocations: $(cat "$CSF_INVOCATION_LOG")"
case "$OUT" in *ACTIVE*) no "report must not claim ACTIVE" "$OUT";; *) ok "report != ACTIVE";; esac

echo "── T2  NEGATIVE CONTROL: the witness can fire ─────────────────────────"
# Fixture copy of the PRE-FIX branch. If this does NOT record an invocation the
# harness is blind and every other arm is vacuous.
: > "$CSF_INVOCATION_LOG"
( export PATH="$SANDBOX/bin:$PATH" SYSTEMCTL_MODE=inactive
  _prefix_probe() {
      if systemctl is-active lfd &>/dev/null 2>&1; then return 0
      elif csf -s 2>&1 | grep -q "csf is enabled"; then return 0; fi
      return 1
  }
  _prefix_probe >/dev/null 2>&1
) || true
N2=$(wc -l < "$CSF_INVOCATION_LOG")
[ "$N2" -gt 0 ] && ok "pre-fix branch OBSERVED invoking csf ($N2) — witness valid" \
                || no "witness blind: pre-fix branch recorded nothing" "T1 would be vacuous"

echo "── T3  csf.service active + lfd failed => ACTIVE + CRITICAL ───────────"
OUT3="$(run_detector csf-active)"
case "$OUT3" in *"SEVERITY=3"*) ok "severity == CONFLICT_CRITICAL";; *) no "wrong-unit defect present" "$OUT3";; esac
case "$OUT3" in *"CSF: ACTIVE"*) ok "reported ACTIVE";; *) no "enforcing CSF not reported ACTIVE" "$OUT3";; esac

echo "── T4  systemd unusable => cannot-verify, never 'disabled' ────────────"
OUT4="$(run_detector unusable)"
case "$OUT4" in *"CANNOT-VERIFY"*) ok "cannot-verify asserted";; *) no "no cannot-verify wording" "$OUT4";; esac
case "$OUT4" in *"DISABLED (no conflict)"*) no "asserted safety it cannot observe" "$OUT4";; *) ok "did NOT claim disabled/no-conflict";; esac
SEV4=$(printf '%s\n' "$OUT4" | sed -n 's/^SEVERITY=//p')
[ "${SEV4:-9}" -le 1 ] && ok "severity <= CONFLICT_INFO (=$SEV4)" \
                       || no "cannot-verify escalated" "severity=$SEV4"

echo "── T-VAC  non-vacuity: the mocks survived every arm ──────────────────"
[ -x "$SANDBOX/bin/csf" ] && ok "mock csf still present after all runtime arms" \
                          || no "sandbox destroyed mid-run" "later arms were vacuous"
OUTV="$(run_detector inactive)"
case "$OUTV" in *CSF*) ok "detector still enters its body (report non-empty)";; *) no "detector produced nothing" "arms above prove nothing";; esac

echo "── T5  static guard: edited blocks carry no grep -q pipeline ──────────"
# GUARD_SUBJECT == GUARD_INPUT: comments are stripped, so prose about the old
# defect can neither satisfy nor violate this assertion.
BAD=$(awk '/^_nftban_csf_activity\(\)/,/^}/' "$CONFLICTS_LIB" | sed 's/#.*//' | grep -c -- '| *grep -q')
[ "$BAD" -eq 0 ] && ok "probe body has no grep -q pipeline" || no "pipeline in probe" "count=$BAD"
BADX=$(awk '/^_nftban_csf_activity\(\)/,/^}/' "$CONFLICTS_LIB" | sed 's/#.*//' | grep -cE '\bcsf +-[sexr]\b')
[ "$BADX" -eq 0 ] && ok "probe body executes no csf subcommand" || no "vendor binary in probe" "count=$BADX"

echo "── T6  cannot-verify MUST NOT reach the destructive consumer ──────────"
# The consumer gate is maintenance.sh:893 `NFTBAN_FIREWALL_SEVERITY -ge 3`,
# then it string-matches *CSF* and calls nftban_remove_csf. Our cannot-verify
# message CONTAINS "CSF", so the severity cap is the only thing standing
# between an unobservable host and `csf -x`. Drive it end-to-end.
for POLICY in auto quarantine; do
    : > "$CSF_INVOCATION_LOG"
    REMOVED="$(
      export PATH="$SANDBOX/bin:$PATH" SYSTEMCTL_MODE=unusable NFTBAN_DRIFT_POLICY="$POLICY"
      # shellcheck disable=SC1090
      source "$CONFLICTS_LIB" >/dev/null 2>&1
      set +e
      NFTBAN_FIREWALL_CONFLICTS=(); NFTBAN_FIREWALL_SEVERITY=$CONFLICT_NONE
      nftban_detect_csf >/dev/null 2>&1 || true
      # exact consumer gate, verbatim from maintenance.sh:893
      if [[ ${NFTBAN_FIREWALL_SEVERITY:-0} -ge 3 ]]; then
          for c in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
              case "$c" in *CSF*|*LFD*) echo "REMOVE_CSF_REACHED";; esac
          done
      fi
    )"
    [ -z "$REMOVED" ] && ok "policy=$POLICY: destructive branch NOT reached" \
                      || no "policy=$POLICY: cannot-verify reached removal" "$REMOVED"
    N6=$(wc -l < "$CSF_INVOCATION_LOG")
    [ "$N6" -eq 0 ] && ok "policy=$POLICY: no csf/csf -x invocation" \
                    || no "policy=$POLICY: vendor binary invoked" "$(cat "$CSF_INVOCATION_LOG")"
done
# T6(b): prove the consumer keys on severity ALONE — if it ever gained another
# trigger, capping severity would stop being sufficient and this test would lie.
GATES=$(sed -n '893p' "$LIB/cron/maintenance.sh" | sed 's/#.*//')
case "$GATES" in
  *'NFTBAN_FIREWALL_SEVERITY'*'-ge 3'*) ok "consumer gate is severity-only (line 893 unchanged)";;
  *) no "consumer gate changed — T6 no longer proves the invariant" "$GATES";;
esac

echo
echo "══ RESULT: PASS=$PASS FAIL=$FAIL ══"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
