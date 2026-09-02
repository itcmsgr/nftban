#!/usr/bin/env bash
# =============================================================================
# NFTBan — bounded shell predicates
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="shell_predicates"
# meta:type="lib"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-02"
# meta:description="Bounded predicates for questions that must not rewrite their input. nftban_has_non_whitespace answers ONE question — does the supplied string contain at least one non-whitespace character — without allocating a transformed copy. It replaces the idiom [[ -z \${var//[[:space:]]/} \]\], which builds a whole second copy of the payload with every whitespace character removed purely to test emptiness. MEASURED on a CAPTURED PRODUCTION RULESET (srv3, ~168 KB, ~23%% whitespace), benchmarked locally on bash 5.3.9 and independently reproduced with time(1): the rewrite form ~70 s/call, this predicate ~5 ms/call. Isolating the substitution alone reproduces the full cost, so the expense is the copy, not the test. ⛔ THIS MEASURES PREDICATE EXECUTION COST ON CAPTURED PRODUCTION DATA. It is NOT a measurement of production command latency or call frequency, and must not be quoted as \"NFTBan waits 70 seconds\"."
# meta:inventory.files=""
# meta:inventory.privileges="none"
# =============================================================================
#
# ⛔ THIS PREDICATE HAS DELIBERATELY NARROW SEMANTICS.
#
# It answers exactly one question about a string that the caller ALREADY HOLDS:
#
#       does this value contain at least one non-whitespace character?
#
# It knows NOTHING about command success, UNKNOWN, absence, readability, or
# whether an nftables object exists. Those are the caller's decisions and every
# current caller already makes them BEFORE reaching a content test — via
# `|| { echo UNKNOWN; return; }`, `if VAR=$(...) && ...`, or `|| flag=false`.
#
# ⛔ DO NOT EXTEND THIS INTO A THREE-VALUED HELPER. Sites that must distinguish
#    "command failed" from "succeeded with empty output" from "succeeded with
#    evidence" cannot be expressed by a boolean and must NOT be migrated to it.
#    cli/lib/nftban/lib/nft_probe.sh is exactly such a caller: rc=0 with empty
#    output is EMPTY_OUTPUT_NO_ABSENCE_PROOF there, not absence, and collapsing
#    that to a boolean would reintroduce the defect its comment documents.
#
# ⛔ THIS DOES NOT BOUND ACQUISITION. If a caller materialises a large payload
#    ONLY to ask this question, the fix is a smaller query, not this predicate.
#
# `${1-}` rather than `$1`: the predicate must be safe to call under `set -u`
# with no argument, which is indistinguishable from an empty value here.
# =============================================================================

nftban_has_non_whitespace() {
    [[ ${1-} =~ [^[:space:]] ]]
}

export -f nftban_has_non_whitespace 2>/dev/null || true
