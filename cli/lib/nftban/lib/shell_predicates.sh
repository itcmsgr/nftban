#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="shell_predicates" meta:type="lib" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Bounded-cost shell predicates for large captured payloads"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

# =============================================================================
# GUARD: Prevent double-loading
# =============================================================================
[[ -n "${_NFTBAN_SHELL_PREDICATES_LOADED:-}" ]] && return 0
_NFTBAN_SHELL_PREDICATES_LOADED=1

# =============================================================================
# nftban_has_non_whitespace <value>
# =============================================================================
# Answers exactly one question: does the value contain at least one character
# that is not whitespace?
#
# WHY THIS EXISTS (v1.229.12, P0-2 / TUNE-001a):
#   The idiom it replaces — [[ -n "${var//[[:space:]]/}" ]] — is semantically
#   correct but builds a whitespace-stripped COPY of the whole value only to
#   throw it away. On nft-sized payloads that is a measured superlinear
#   performance pathology, approximately quadratic over the tested 10KB-200KB
#   range (10K 50ms · 50K 1,041ms · 100K 4,213ms · 200K 17,265ms · 500K did not
#   complete in 30s). On a live 176,761-byte ruleset `nftban status` did not
#   finish inside 150s. This form measured 0-3ms across the same range.
#
# WHAT IT MUST NOT BECOME:
#   [[ -n "$1" ]]          — accepts whitespace-only output as meaningful
#   [[ -n "${1:0:1}" ]]    — answers "has at least one byte"; "   " tests TRUE
#   Both silently break the B04 invariant this predicate exists to preserve:
#   rc=0 with empty/whitespace-only output is NOT valid empty state.
#
# CONTRACT (see tests/shell_predicates_v1229_12_test.sh):
#   ""  "   "  "\t"  "\n"  " \t\n "        -> false
#   "x"  " x"  "x "  " \n\t x \t\n "       -> true
#
# The argument is referenced as "$1" only: no echo, no pipe, no command
# substitution, no secondary copy. Callers MUST quote: fn "$payload".
nftban_has_non_whitespace() {
    [[ $1 =~ [^[:space:]] ]]
}

export -f nftban_has_non_whitespace 2>/dev/null || true
