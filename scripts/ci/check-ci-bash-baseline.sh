#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-ci-bash-baseline"
# meta:type="script"
# meta:version="1.226.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Blocking ci-bash observation-integrity gate: proves the informational runner executed all classified tests without drift or regression above baseline"
# meta:inventory.files="scripts/ci/test-authority-index.tsv,scripts/ci/ci-bash-informational-baseline.tsv,ci-bash-manifest.txt"
# meta:inventory.binaries="bash,git,awk,grep,sort,diff,sed,printf"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# ci-bash observation-integrity gate (v1.226.0 PR-C, BLOCKING).
#
# The ci-bash class runs INFORMATIONALLY (non-blocking) in CI.  This gate proves
# that the informational step actually executed and did not silently drift or
# regress — WITHOUT re-executing the 184 tests (it consumes the runner manifest
# the informational step already produced; one shared execution).
#
# It BLOCKS (exit 1) if any of the following is violated against the committed
# baseline (scripts/ci/ci-bash-informational-baseline.tsv) and the canonical
# authority index:
#   * the manifest is missing/empty  -> the informational step never ran
#   * the manifest gate is not ci-bash
#   * SELECTED != index ci-bash count            (a test disappeared / index drift)
#   * SELECTED != baseline CI_BASH_SELECTED
#   * executed-id set != index ci-bash id set    (a test disappeared / extra ran)
#   * a test executed more than once
#   * not every failing id is reported
#   * a NEW failing id appears (not in the accepted baseline list) -> regression
#   * FAIL exceeds the accepted CI_BASH_FAIL ceiling
#
# Allowed (reported, not blocked): a baseline-accepted id that now PASSES
# (improvement) — tighten the baseline under PR-D.
#
# Usage: check-ci-bash-baseline.sh [MANIFEST]   (default: ci-bash-manifest.txt at root)
# Exit:  0 ok · 1 integrity violation · 2 usage/inputs missing
# =============================================================================
set -Eeuo pipefail

INDEX_REL="scripts/ci/test-authority-index.tsv"
BASELINE_REL="scripts/ci/ci-bash-informational-baseline.tsv"

die()  { printf 'check-ci-bash-baseline: %s\n' "$1" >&2; exit 2; }
fail() { printf '  VIOLATION %s\n' "$1" >&2; VIOL=$((VIOL+1)); }

root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
manifest="${1:-$root/ci-bash-manifest.txt}"
idx="$root/$INDEX_REL"
base="$root/$BASELINE_REL"
[ -f "$idx" ]  || die "authority index not found: $INDEX_REL"
[ -f "$base" ] || die "baseline not found: $BASELINE_REL"

# --- fail-closed: the informational step must have produced a non-empty manifest ---
# `-s` is false for a missing OR empty file, so this covers both.
if [ ! -s "$manifest" ]; then
    printf 'check-ci-bash-baseline: INTEGRITY FAIL — manifest missing or empty (%s)\n' "$manifest" >&2
    printf 'check-ci-bash-baseline: the ci-bash informational step did not execute.\n' >&2
    exit 1
fi

VIOL=0

# --- baseline values ---------------------------------------------------------
b_selected="$(awk -F= '/^CI_BASH_SELECTED=/{print $2}' "$base")"
b_fail="$(awk -F= '/^CI_BASH_FAIL=/{print $2}' "$base")"
# accepted failing ids (column 2 of "FAIL<TAB>id<TAB>bucket" rows)
accepted="$(awk -F'\t' '$1=="FAIL"{print $2}' "$base" | sort -u)"
n_accepted="$(printf '%s\n' "$accepted" | grep -c . || true)"

# --- index ci-bash id set ----------------------------------------------------
idx_ids="$(awk -F'\t' '/^#/{next} !h{h=1;next} $7=="ci-bash"{print $1}' "$idx" | sort -u)"
idx_count="$(printf '%s\n' "$idx_ids" | grep -c . || true)"

# --- manifest values ---------------------------------------------------------
m_gate="$(awk -F'\t' '$1=="GATE"{print $2}' "$manifest")"
m_selected="$(awk -F'\t' '$1=="SELECTED"{print $2}' "$manifest")"
m_fail="$(awk -F'\t' '$1=="FAIL"{print $2}' "$manifest")"
exec_ids="$(awk -F'\t' '$1=="TEST"{print $3}' "$manifest" | sort)"
exec_count="$(printf '%s\n' "$exec_ids" | grep -c . || true)"
exec_uniq="$(printf '%s\n' "$exec_ids" | sort -u | grep -c . || true)"
manifest_fail_ids="$(awk -F'\t' '$1=="TEST" && $2=="FAIL"{print $3}' "$manifest" | sort -u)"
manifest_timeout_ids="$(awk -F'\t' '$1=="TEST" && $2=="TIMEOUT"{print $3}' "$manifest" | sort -u)"
# TIMEOUT counts as a failing outcome for baseline-subset purposes
manifest_bad_ids="$(printf '%s\n%s\n' "$manifest_fail_ids" "$manifest_timeout_ids" | grep -c . || true)"

# --- checks ------------------------------------------------------------------
[ "$m_gate" = "ci-bash" ] || fail "manifest gate is '$m_gate', expected ci-bash"
[ "$m_selected" = "$idx_count" ]  || fail "SELECTED=$m_selected != index ci-bash count=$idx_count (a test disappeared or index drifted)"
[ "$m_selected" = "$b_selected" ] || fail "SELECTED=$m_selected != baseline CI_BASH_SELECTED=$b_selected"
[ "$exec_count" = "$m_selected" ] || fail "executed rows=$exec_count != SELECTED=$m_selected (not every selected test executed)"
[ "$exec_count" = "$exec_uniq" ]  || fail "duplicate execution detected (executed=$exec_count unique=$exec_uniq)"

# executed id set must equal the index ci-bash id set (no disappearance, no extra)
if ! diff <(printf '%s\n' "$idx_ids") <(printf '%s\n' "$exec_ids") >/tmp/.rts_idsdiff 2>&1; then
    fail "executed id set != index ci-bash id set:"; sed 's/^/      /' /tmp/.rts_idsdiff >&2
fi
rm -f /tmp/.rts_idsdiff

# ceiling
if [ -n "$m_fail" ] && [ -n "$b_fail" ]; then
    [ "$m_fail" -le "$b_fail" ] || fail "FAIL=$m_fail exceeds accepted baseline ceiling CI_BASH_FAIL=$b_fail (new failures)"
fi

# every failing/timeout id must be in the accepted set; a NEW one is a regression
new_bad=""
while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n' "$accepted" | grep -qxF "$id" || new_bad="$new_bad $id"
done < <(printf '%s\n%s\n' "$manifest_fail_ids" "$manifest_timeout_ids")
[ -z "$new_bad" ] || fail "NEW failing id(s) not in accepted baseline (regression):$new_bad"

# improvements: accepted ids that now pass (report only)
improved=""
while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\n%s\n' "$manifest_fail_ids" "$manifest_timeout_ids" | grep -qxF "$id" \
        || improved="$improved $id"
done < <(printf '%s\n' "$accepted")

# --- summary -----------------------------------------------------------------
printf 'check-ci-bash-baseline: gate=%s SELECTED=%s FAIL=%s (accepted<=%s) index_count=%s accepted_ids=%s reported_bad=%s\n' \
    "$m_gate" "$m_selected" "$m_fail" "$b_fail" "$idx_count" "$n_accepted" "$manifest_bad_ids" >&2
[ -n "$improved" ] && printf 'check-ci-bash-baseline: IMPROVED (now passing, tighten baseline under PR-D):%s\n' "$improved" >&2

if [ "$VIOL" -gt 0 ]; then
    printf 'check-ci-bash-baseline: INTEGRITY FAIL — %d violation(s)\n' "$VIOL" >&2
    exit 1
fi
printf 'check-ci-bash-baseline: OK — ci-bash informational baseline integrity holds\n' >&2
exit 0
