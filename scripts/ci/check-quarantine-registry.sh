#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-quarantine-registry"
# meta:type="script"
# meta:version="1.226.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Blocking validator for the ci-bash quarantine registry: every quarantined test has valid metadata, exists as a ci-bash test, is not expired, and the count stays under the committed ceiling"
# meta:inventory.files="scripts/ci/ci-bash-quarantine.tsv,scripts/ci/test-authority-index.tsv"
# meta:inventory.binaries="bash,git,awk,grep,date,sort"
# meta:inventory.env_vars="NFTBAN_TODAY"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# ci-bash quarantine registry validator (v1.226.0 PR-D, BLOCKING).
#
# A quarantined ci-bash test STILL EXECUTES and is REPORTED, but is excluded from
# the blocking tally under explicit, audited policy. This gate proves that policy
# is honest — it fails closed if any quarantine entry is malformed, unowned,
# unexplained, unreferenced, expired, not actually a ci-bash test, duplicated, or
# if the quarantine count exceeds the committed ceiling (so a new failure cannot
# silently enter quarantine — raising the ceiling is an explicit, reviewable edit).
#
# Registry format (scripts/ci/ci-bash-quarantine.tsv), tab-separated:
#   QUARANTINE_CEILING=<n>
#   QT id path owner reason finding introduced review_or_expiry disposition \
#      expected_failure_class remediation_lane expected_failure_pattern
#     path                     = must equal the authority-index path for id
#     introduced               = YYYY-MM-DD
#     review_or_expiry         = YYYY-MM-DD hard expiry (must not be past) OR a review condition
#     disposition              = one of the 7 PR-D dispositions
#     expected_failure_class   = normalized failure classification (e.g. MISSING_MATCHER_BINARY)
#     remediation_lane         = owning lane (PR-E, a finding lane, ...)
#     expected_failure_pattern = substring the runner binds the failure to (may be empty = outcome-only)
#
# Exit: 0 ok · 1 registry invalid · 2 usage/inputs missing
# =============================================================================
set -Eeuo pipefail

INDEX_REL="scripts/ci/test-authority-index.tsv"
REG_REL="scripts/ci/ci-bash-quarantine.tsv"

die()  { printf 'check-quarantine-registry: %s\n' "$1" >&2; exit 2; }
fail() { printf '  VIOLATION %s\n' "$1" >&2; VIOL=$((VIOL+1)); }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
idx="$root/$INDEX_REL"; reg="$root/$REG_REL"
[ -f "$idx" ] || die "authority index not found: $INDEX_REL"
[ -f "$reg" ] || die "quarantine registry not found: $REG_REL"
# NFTBAN_TODAY override keeps the expiry check deterministic in tests; else real date.
today="${NFTBAN_TODAY:-$(date -u +%F)}"
date_re='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

VIOL=0
DISPOSITIONS=" TEST_EXPECTATION_STALE CONFIRMED_PRODUCT_DEFECT ENVIRONMENT_SENSITIVE TIMING_OR_ISOLATION_DEBT PR_E_RBL_FIXTURE FALSE_OR_OBSOLETE_TEST INSUFFICIENT_EVIDENCE "

# ci-bash id->path map from the index (quarantine only applies to ci-bash tests)
declare -A idxpath
while IFS=$'\t' read -r iid ipath; do idxpath["$iid"]="$ipath"; done < <(
    awk -F'\t' '/^#/{next} !h{h=1;next} $7=="ci-bash"{print $1"\t"$2}' "$idx")

ceiling="$(awk -F= '/^QUARANTINE_CEILING=/{print $2}' "$reg" | tr -d '[:space:]')"
[ -n "$ceiling" ] || fail "missing QUARANTINE_CEILING"
case "$ceiling" in ''|*[!0-9]*) [ -n "$ceiling" ] && fail "QUARANTINE_CEILING not an integer: '$ceiling'";; esac

count=0
declare -A seen
while IFS=$'\t' read -r tag id path owner reason finding introduced review disposition efc lane _pat; do
    [ "$tag" = "QT" ] || continue
    count=$((count+1))
    [ -n "$id" ] || { fail "row $count: empty id"; continue; }
    [ -z "${seen[$id]:-}" ] || fail "duplicate quarantine id: $id"
    seen[$id]=1
    # id must be a real ci-bash test AND path must match the authority index
    if [ -z "${idxpath[$id]:-}" ]; then
        fail "$id: not a ci-bash test in the authority index"
    elif [ "$path" != "${idxpath[$id]}" ]; then
        fail "$id: path '$path' != authority-index path '${idxpath[$id]}'"
    fi
    # required metadata presence + non-placeholder (expected_failure_pattern MAY be empty)
    for pair in "path=$path" "owner=$owner" "reason=$reason" "finding=$finding" \
                "introduced=$introduced" "review_or_expiry=$review" "disposition=$disposition" \
                "expected_failure_class=$efc" "remediation_lane=$lane"; do
        k="${pair%%=*}"; v="${pair#*=}"
        case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
            ''|todo|tbd|none|n/a|na|-) fail "$id: quarantine field '$k' missing or placeholder";;
        esac
    done
    # introduced must be a date
    [[ "$(printf '%s' "$introduced" | grep -cE "$date_re" || true)" -gt 0 ]] || fail "$id: 'introduced' must be YYYY-MM-DD (got '$introduced')"
    # review_or_expiry: a date is a HARD expiry (must not be past); else a condition string
    if [[ "$(printf '%s' "$review" | grep -cE "$date_re" || true)" -gt 0 ]]; then
        if [[ "$review" < "$today" ]]; then fail "$id: quarantine EXPIRED (review_or_expiry=$review < today=$today)"; fi
    fi
    # disposition must be one of the 7 PR-D dispositions
    case "$DISPOSITIONS" in *" $disposition "*) ;; *) fail "$id: unknown disposition '$disposition'";; esac
    # PR-E items must keep PR-E ownership
    if [ "$disposition" = "PR_E_RBL_FIXTURE" ] && [ "$lane" != "PR-E" ]; then
        fail "$id: disposition PR_E_RBL_FIXTURE requires remediation_lane=PR-E (got '$lane')"
    fi
done < "$reg"

# ceiling enforcement: a new failure cannot silently enter quarantine
if [ -n "$ceiling" ] && [ "$count" -gt "$ceiling" ]; then
    fail "quarantine count $count exceeds committed ceiling $ceiling (raise the ceiling explicitly to add)"
fi

printf 'check-quarantine-registry: quarantined=%d ceiling=%s ci-bash-pool=%d today=%s\n' \
    "$count" "${ceiling:-?}" "${#idxpath[@]}" "$today" >&2
if [ "$VIOL" -gt 0 ]; then
    printf 'check-quarantine-registry: INVALID — %d violation(s)\n' "$VIOL" >&2
    exit 1
fi
printf 'check-quarantine-registry: OK — quarantine registry valid\n' >&2
exit 0
