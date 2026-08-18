#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 P2 — A LOST STATUS IS NOT A FAILED SCAN
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="trusted-gate-publication-truth-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="P2. The trusted-gate publisher must retry transient transport/server failures, fail fast on definitive client errors, and always keep SCAN_RESULT and PUBLICATION_RESULT independent so a publication failure is never reported as a scan failure. Exercised against an injected gh client replaying scripted `gh api -i` responses (status line + headers), so classification binds to the same surface production parses."
# meta:inventory.files="scripts/ci/publish-trusted-gate-status.sh,.github/workflows/privacy-trusted-merge-gate.yml"
# meta:inventory.privileges="none"
# meta:ta.id="trusted_gate_publication_truth_v1229_4_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="core"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   ⛔ PUBLICATION_FAILURE != SCAN_FAILURE
#
#   WITNESSED (PR #1245): scan computed success, the status POST got HTTP 503, the
#   required context stayed ABSENT, and a PASS looked like a gate failure.
#
#   Responses are injected through NFTBAN_GH_BIN as RAW `gh api -i` output — an HTTP
#   status line plus headers — i.e. the exact surface production parses. No network.
#
#   ⛔ PUBLISHER MAY TRANSPORT A VERDICT. PUBLISHER MUST NOT BECOME A VERDICT PRODUCER.
#   A9 is load-bearing: it proves publication attempts can exceed one while scan
#   executions remain ZERO, so a future refactor cannot put the scan inside the loop.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
PUB="$ROOT/scripts/ci/publish-trusted-gate-status.sh"
WF="$ROOT/.github/workflows/privacy-trusted-merge-gate.yml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== trusted-gate publication truth (v1.229.4 P2) ==="
[[ -f "$PUB" ]] || { echo "  SUBJECT_NOT_FOUND: $PUB"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT
SHA=1111111111111111111111111111111111111111
export PATH="$TMP/bin:$PATH"; mkdir -p "$TMP/bin"

# A fake `gh` that replays scripted responses, one per invocation (last repeats), and
# records every call. Responses are RAW `gh api -i` output: an HTTP status line plus
# headers — the same surface production parses.
make_gh() {   # <response-file...>
    : > "$TMP/gh_calls"
    printf '%s\n' "$@" > "$TMP/gh_script"
    cat > "$TMP/bin/fakegh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(wc -l < "$TMPDIR_T/gh_calls") + 1 ))
echo "call" >> "$TMPDIR_T/gh_calls"
total=$(wc -l < "$TMPDIR_T/gh_script")
[ "$n" -gt "$total" ] && n="$total"
resp=$(sed -n "${n}p" "$TMPDIR_T/gh_script")
case "$resp" in
  NOSTATUS) echo "gh: could not resolve host"; exit 1 ;;
  *)  code=${resp%%:*}; extra=${resp#*:}
      echo "HTTP/2.0 $code X"
      [ "$extra" != "$resp" ] && [ -n "$extra" ] && echo "$extra"
      echo ""; echo "{}"
      case "$code" in 2*) exit 0 ;; *) exit 1 ;; esac ;;
esac
EOF
    chmod +x "$TMP/bin/fakegh"
}
# A sentinel that must NEVER be invoked by the publisher.
cat > "$TMP/bin/scan-sentinel" <<'EOF'
#!/usr/bin/env bash
echo "scan" >> "$TMPDIR_T/scan_calls"
EOF
chmod +x "$TMP/bin/scan-sentinel"; : > "$TMP/scan_calls"
export TMPDIR_T="$TMP"

run_pub() {  # <state>
    NFTBAN_GH_BIN="$TMP/bin/fakegh" \
    NFTBAN_PUBLISH_ATTEMPTS="${ATT:-5}" NFTBAN_PUBLISH_BACKOFF_SECONDS=0 \
    GITHUB_OUTPUT="" \
    bash "$PUB" "$1" itcmsgr/nftban "$SHA" privacy/trusted-private-gate "d" 2>&1
}
calls(){ wc -l < "$TMP/gh_calls" | tr -d ' '; }

# --- A1 · happy path: exactly ONE attempt --------------------------------------
make_gh "201:"
out="$(run_pub success)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'PUBLICATION_RESULT=published' <<<"$out" \
   && grep -q 'SCAN_RESULT=success' <<<"$out" && [[ "$(calls)" -eq 1 ]]; then
    pass "A1 success on first try -> rc0, published, exactly 1 attempt, SCAN_RESULT preserved"
else
    fail "A1 happy path wrong (rc=$rc calls=$(calls))"; sed 's/^/        /' <<<"$out" | head -4
fi

# --- A2 · TRANSIENT 503 then success — the witnessed #1245 failure -------------
make_gh "503:" "503:" "201:"
out="$(run_pub success)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q 'PUBLICATION_RESULT=published' <<<"$out" && [[ "$(calls)" -eq 3 ]]; then
    pass "A2 503,503,201 -> retried ($(calls) attempts) and published (the #1245 failure is survived)"
else
    fail "A2 transient retry failed (rc=$rc calls=$(calls))"; sed 's/^/        /' <<<"$out" | head -5
fi

# --- A3 · exhausted transient: job fails, SCAN_RESULT still success ------------
ATT=3 make_gh "503:"; ATT=3
out="$(run_pub success)"; rc=$?; unset ATT
if [[ $rc -ne 0 ]] && grep -q 'PUBLICATION_RESULT=failed_transient' <<<"$out" \
   && grep -q 'SCAN_RESULT=success' <<<"$out" \
   && grep -qE "verdict was computed as 'success' and did NOT change" <<<"$out"; then
    pass "A3 exhausted transient -> job fails, SCAN_RESULT=success stated and unchanged"
else
    fail "A3 exhaustion did not keep the results distinct (rc=$rc)"; sed 's/^/        /' <<<"$out" | head -5
fi

# --- A4 · STATE-COLLAPSE guard: nothing may claim the scan failed --------------
ATT=2 make_gh "503:"; ATT=2
out="$(run_pub success)"; unset ATT
if grep -qiE 'scan (failed|failure)|SCAN_RESULT=failure' <<<"$out"; then
    fail "A4 a publication failure was rendered as a SCAN failure — the exact defect"
else
    pass "A4 no publication failure is ever rendered as a scan failure"
fi

# --- A5 · definitive 403 (no throttling signal) -> fail fast -------------------
make_gh "403:"
out="$(run_pub success)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'PUBLICATION_RESULT=failed_permanent' <<<"$out" && [[ "$(calls)" -eq 1 ]]; then
    pass "A5 403 without throttling signal -> definitive, 1 attempt, not retried"
else
    fail "A5 definitive refusal retried or misclassified (rc=$rc calls=$(calls))"
fi

# --- A5b · 403 WITH Retry-After IS throttling -> retryable --------------------
make_gh "403:Retry-After: 0" "201:"
out="$(run_pub success)"; rc=$?
if [[ $rc -eq 0 ]] && [[ "$(calls)" -eq 2 ]]; then
    pass "A5b 403 + Retry-After identified POSITIVELY as throttling and retried"
else
    fail "A5b throttling 403 not identified (rc=$rc calls=$(calls))"; sed 's/^/        /' <<<"$out" | head -4
fi

# --- A5c · 403 with exhausted rate budget -> retryable ------------------------
make_gh "403:X-RateLimit-Remaining: 0" "201:"
out="$(run_pub success)"; rc=$?
[[ $rc -eq 0 && "$(calls)" -eq 2 ]] \
  && pass "A5c 403 + X-RateLimit-Remaining:0 identified as throttling and retried" \
  || fail "A5c exhausted-rate-limit 403 not identified (rc=$rc calls=$(calls))"

# --- A6 · 429 is retryable ----------------------------------------------------
make_gh "429:" "201:"
out="$(run_pub success)"; rc=$?
[[ $rc -eq 0 && "$(calls)" -eq 2 ]] && pass "A6 429 retried" || fail "A6 429 not retried (rc=$rc)"

# --- A7 · UNCLASSIFIED is neither transient nor permanent ---------------------
make_gh "NOSTATUS"
out="$(run_pub success)"; rc=$?
if [[ $rc -ne 0 ]] && grep -q 'PUBLICATION_RESULT=failed_unclassified' <<<"$out" && [[ "$(calls)" -eq 1 ]]; then
    pass "A7 unparseable response -> UNCLASSIFIED, NOT retried (no class is guessed)"
else
    fail "A7 unclassifiable response was guessed into a class (rc=$rc calls=$(calls))"
    sed 's/^/        /' <<<"$out" | head -4
fi

# --- A8 · a genuine FAILURE verdict is published unchanged --------------------
make_gh "201:"
out="$(run_pub failure)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'SCAN_RESULT=failure' <<<"$out" \
  && pass "A8 a real scan FAILURE is transported faithfully (retry never rewrites a verdict)" \
  || fail "A8 failing verdict not published faithfully (rc=$rc)"

# --- A9 · LOAD-BEARING: retries > 1 while scan executions stay EXACTLY 0 ------
# A future refactor could put scan+publish inside the retry loop. This proves it did not.
: > "$TMP/scan_calls"
make_gh "503:" "503:" "503:" "201:"
out="$(run_pub success)"; rc=$?
scans=$(wc -l < "$TMP/scan_calls" | tr -d ' ')
if [[ "$(calls)" -gt 1 && "$scans" -eq 0 ]]; then
    pass "A9 publication attempts=$(calls) while scan executions=$scans (retry republishes ONLY)"
else
    fail "A9 the retry loop touched the scan (attempts=$(calls) scans=$scans)"
fi

# --- A10 · input refusal before any transport ---------------------------------
out="$(NFTBAN_GH_BIN=/bin/false bash "$PUB" success itcmsgr/nftban deadbeef ctx d 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && grep -q 'non-canonical SHA' <<<"$out" \
  && pass "A10 refuses a non-canonical SHA before contacting anything" \
  || fail "A10 accepted a non-canonical SHA (rc=$rc)"

# --- A11 · the publisher is not a verdict producer ----------------------------
if grep -qE 'private-identifier-gate|--mode |pr-head|git rev-parse|git diff' "$PUB"; then
    fail "A11 publisher references scan/subject machinery — it could become a verdict producer"
else
    pass "A11 publisher contains no scan/verdict/subject machinery (transports only)"
fi

# --- A12 · workflow invokes the TRUSTED copy ----------------------------------
grep -qE '\./trusted/scripts/ci/publish-trusted-gate-status\.sh' "$WF" \
  && pass "A12 workflow invokes the publisher from the TRUSTED checkout" \
  || fail "A12 workflow does not invoke the trusted publisher path"
grep -qE 'pr-head/scripts/ci/publish-trusted-gate-status\.sh' "$WF" \
  && fail "A12b publisher would execute from PR-controlled content" \
  || pass "A12b publisher is never executed from pr-head"

# --- A13 · INVERSION: a single-attempt publisher DOES lose the status ---------
make_gh "503:" "201:"
ATT=1 out="$(ATT=1 run_pub success)"; rc=$?
if [[ $rc -ne 0 ]] && [[ "$(calls)" -eq 1 ]]; then
    pass "A13 INVERSION: with attempts=1 the 503 DOES lose the status (A2 is falsifiable)"
else
    fail "A13 inversion did not reproduce the single-shot loss (rc=$rc calls=$(calls))"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
