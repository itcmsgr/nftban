#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — TRUSTED-GATE PUBLICATION ADAPTER  (v1.229.4 P2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="publish-trusted-gate-status"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Publishes an ALREADY-COMPUTED trusted-gate verdict as a commit status. Retries only responses it can POSITIVELY identify as retryable, fails fast on definitive refusals, and reports an unparseable response as UNCLASSIFIED rather than guessing a class. Keeps SCAN_RESULT, PUBLICATION_RESULT and JOB_RESULT independent so a lost status can never be reported as a failed scan."
# meta:inventory.files=".github/workflows/privacy-trusted-merge-gate.yml"
# meta:inventory.privileges="none"
# =============================================================================
#
#   ⛔ PUBLISHER MAY TRANSPORT A VERDICT.
#      PUBLISHER MUST NOT BECOME A VERDICT PRODUCER.
#
#   This adapter MAY: attempt publication · retry publication · classify the outcome.
#   It MUST NOT: inspect the repository · inspect PR contents · rerun the privacy
#   scan · calculate STATE · change SHA · decide whether the scan passed.
#
#   ⛔ PUBLICATION_FAILURE != SCAN_FAILURE
#   WITNESSED (PR #1245, run 32055548798): the gate computed STATE=success over the
#   tree, commit messages and PR title/body; a single unretried status POST received
#   HTTP 503; the required context stayed ABSENT and a PASS looked like a failure.
#
#   CLIENT CHOICE. `gh api -i` emits the HTTP status line on BOTH the success and the
#   error path ("HTTP/2.0 422 …", exit 1), so the existing gh authority already
#   supplies a machine-readable status. Classification binds to that protocol status
#   line and to documented GitHub headers — never to gh's human prose, and without
#   introducing a second HTTP client.
#
#   ⛔ HTTP STATUS PARSE FAILURE != PERMANENT != TRANSIENT.
#      An unparseable/unobserved response is reported UNCLASSIFIED and is NOT retried:
#      retrying it would be guessing a class to keep the machinery moving.
set -uo pipefail

STATE="${1:?state (success|failure|error|pending)}"
REPO="${2:?owner/repo}"
SHA="${3:?full 40-hex commit sha}"
CONTEXT="${4:?status context}"
DESCRIPTION="${5:-}"

# Indirection exists ONLY so the retry/classification logic can be exercised with
# injected responses. Production default is the real gh client.
GH_BIN="${NFTBAN_GH_BIN:-gh}"
ATTEMPTS="${NFTBAN_PUBLISH_ATTEMPTS:-5}"
BACKOFF="${NFTBAN_PUBLISH_BACKOFF_SECONDS:-2}"

case "$STATE" in
    success|failure|error|pending) ;;
    *) echo "::error::refusing to publish an unrecognised state: '$STATE'"; exit 2 ;;
esac
if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "::error::refusing to publish against a non-canonical SHA: '$SHA'"; exit 2
fi

# The verdict is an INPUT. It is echoed for the record and never recomputed.
echo "SCAN_RESULT=$STATE"
echo "publishing context '$CONTEXT' -> $SHA"

publication_result="unattempted"
last_code=""
attempt=1
delay="$BACKOFF"

while [[ $attempt -le $ATTEMPTS ]]; do
    resp="$("$GH_BIN" api -i -X POST "repos/$REPO/statuses/$SHA" \
              -f state="$STATE" -f context="$CONTEXT" -f description="$DESCRIPTION" 2>&1)"

    # Protocol status line, not tool prose.
    code="$(sed -n 's|^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*|\1|p' <<<"$resp" | head -1)"
    retry_after="$(sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$resp" | head -1)"
    rl_remaining="$(sed -n 's/^[Xx]-[Rr]ate[Ll]imit-[Rr]emaining:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$resp" | head -1)"

    if [[ -z "$code" ]]; then
        # No status line: the response was never observed (transport failure, client
        # crash). ⛔ Not classified as transient — that would be a guess.
        publication_result="failed_unclassified"
        echo "  attempt $attempt: no HTTP status line — response UNOBSERVED, not classified"
        break
    fi
    last_code="$code"

    # Retryability is identified POSITIVELY, from the status class or from documented
    # GitHub throttling signals — never inferred from "4xx therefore permanent".
    transient=no
    case "$code" in
        2*) publication_result="published"
            echo "  attempt $attempt: HTTP $code — published"
            break ;;
        5*|408|429) transient=yes ;;
        403)
            # GitHub signals throttling as 403 WITH Retry-After or an exhausted
            # rate-limit budget. A 403 without either is a genuine authorization
            # refusal and must not be retried.
            if [[ -n "$retry_after" || "$rl_remaining" == "0" ]]; then transient=yes; fi ;;
    esac

    if [[ "$transient" == yes ]]; then
        publication_result="failed_transient"
        echo "  attempt $attempt: HTTP $code — retryable (retry-after='${retry_after:-none}' rate-remaining='${rl_remaining:-n/a}')"
        if [[ $attempt -lt $ATTEMPTS ]]; then
            sleep "${retry_after:-$delay}"
            delay=$(( delay * 2 ))
        fi
    else
        publication_result="failed_permanent"
        echo "  attempt $attempt: HTTP $code — definitive refusal, not retried"
        break
    fi
    attempt=$(( attempt + 1 ))
done

echo "PUBLICATION_RESULT=$publication_result"
echo "PUBLICATION_HTTP=${last_code:-none}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "scan_result=$STATE"
        echo "publication_result=$publication_result"
        echo "publication_http=${last_code:-none}"
    } >> "$GITHUB_OUTPUT"
fi

[[ "$publication_result" == "published" ]] && exit 0

# ⛔ The message must state BOTH results. Reporting only the job outcome is precisely
# how a successful scan came to look like a failed gate.
echo "::error title=Trusted-gate status PUBLICATION failed::\
The gate verdict was computed as '$STATE' and did NOT change. \
Publishing it to '$CONTEXT' failed: ${publication_result} (HTTP ${last_code:-unobserved}). \
SCAN_RESULT=$STATE is unaffected. The job fails only because branch protection cannot \
see an unpublished status. Re-dispatch republishes the same verdict — it does not re-scan."
exit 1
