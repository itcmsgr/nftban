#!/usr/bin/env bash
# =============================================================================
# NFTBan - Shared result vocabulary for dataset recovery/apply steps
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban-recovery-status"
# meta:type="library"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="One result vocabulary shared by every producer that restores a dataset into the firewall (threat feeds, GeoBan). Feeds and GeoBan are sibling restoration stages; before this, each expressed its outcome in its own ad-hoc wording and both could print an affirmative success message without having established any state. The governing invariant is: NO RECOVERY STEP MAY EMIT AN AFFIRMATIVE SUCCESS MESSAGE UNLESS IT CAN PROVE THE INTENDED STATE WAS ACTUALLY APPLIED."
# meta:inventory.files="cli/lib/nftban/core/nftban_feeds.sh,cli/lib/nftban/core/nftban_geoban.sh"
# meta:inventory.privileges="none"
# =============================================================================
#
# THE VOCABULARY (frozen — see the v1.229.12 recovery-truth lane)
#
#   DISABLED     The producer is not enabled by its canonical enablement
#                authority. Nothing was attempted. This is a correct, quiet
#                outcome and MUST NOT be rendered as a failure.
#   SYNCED       The intended state was applied AND that was verified. This is
#                the ONLY value that licenses an affirmative success message.
#   PARTIAL      Some of the intended state was applied and some was not, and
#                the split is known. Never collapse this into SYNCED.
#   FAILED       The step ran and did not establish the intended state.
#   UNAVAILABLE  The outcome could not be determined — a query failed, a tool was
#                missing, verification could not run. ⛔ UNAVAILABLE IS NOT
#                SYNCED AND IT IS NOT FAILED. Rendering an undetermined outcome
#                as either is how a silent zero becomes a green check.
#
# ⛔ Absence of a result is UNAVAILABLE, never SYNCED. A caller that cannot reach
#    this library at all must treat the step as UNAVAILABLE, not assume success.
# =============================================================================

NFTBAN_RECOVERY_DISABLED="DISABLED"
NFTBAN_RECOVERY_SYNCED="SYNCED"
NFTBAN_RECOVERY_PARTIAL="PARTIAL"
NFTBAN_RECOVERY_FAILED="FAILED"
NFTBAN_RECOVERY_UNAVAILABLE="UNAVAILABLE"

# nftban_recovery_is_valid <state> -> 0 if it is one of the five frozen values.
# Guards against a caller inventing a sixth token that downstream readers and the
# support bundle would not recognise.
nftban_recovery_is_valid() {
    case "${1:-}" in
        DISABLED|SYNCED|PARTIAL|FAILED|UNAVAILABLE) return 0 ;;
        *) return 1 ;;
    esac
}

# nftban_recovery_permits_success <state> -> 0 ONLY for SYNCED.
# The single chokepoint every producer must ask before printing an affirmative
# message. Deliberately not "not FAILED": PARTIAL and UNAVAILABLE are both
# non-failures and neither may be announced as success.
nftban_recovery_permits_success() {
    [[ "${1:-}" == "SYNCED" ]]
}

# nftban_recovery_render <producer> <state> <detail>
# Single rendering point so the five states read identically wherever they are
# emitted, and so an invalid token is loud rather than silently printed.
nftban_recovery_render() {
    local producer="${1:-unknown}" state="${2:-}" detail="${3:-}"
    if ! nftban_recovery_is_valid "$state"; then
        printf '[%s] INVALID_RECOVERY_STATE(%s) %s\n' "$producer" "${state:-<empty>}" "$detail"
        return 1
    fi
    printf '[%s] %s%s\n' "$producer" "$state" "${detail:+ — $detail}"
    return 0
}
