#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="capability" meta:type="lib" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="B03 capability-path model: classify a mechanism as capable/idle/active/incapable/unknown from structural evidence"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

[[ -n "${_NFTBAN_CAPABILITY_LOADED:-}" ]] && return 0
_NFTBAN_CAPABILITY_LOADED=1

# =============================================================================
# B03 — CAPABILITY PATH
# =============================================================================
# CONFIGURED -> PROJECTED/REACHABLE -> PRODUCER CAPABLE -> OBSERVED ACTIVITY
#            -> STATE -> CONSUMER/ACTION
#
# WHY THIS EXISTS. The v1.229.12 audit made both possible errors, in both
# directions, against the same subsystem:
#
#   FALSE HEALTHY  penalty sets and consumers existed, so the ladder "looked
#                  configured" — while nothing could place an IP into a tier.
#   FALSE BROKEN   the ladder's sets were empty on 9/9 hosts, which was read as
#                  "the producer does not exist". The producer existed and was
#                  wired; there was simply no qualifying traffic.
#
# Capability must therefore never be inferred from the PRESENCE OR ABSENCE OF
# OBJECTS. An empty set proves nothing on its own; a populated one proves only
# that something once wrote to it.
#
# ⛔ NOT A NEW USER-FACING VERDICT LANGUAGE. These are internal facts that feed
# the existing HEALTH_* vocabulary via nftban_capability_to_health.
# =============================================================================

# Evidence values accepted by nftban_capability_classify: yes | no | unknown
# (passed as literals by callers; no constants, to keep this library dependency-free)

# nftban_capability_classify <configured> <reachable> <producer> <consumer> <observation> <activity> [converging]
#
# Each argument is yes|no|unknown. `activity` may legitimately be "no" — that is
# an idle mechanism, not a broken one. `observation` reports whether the evidence
# above could be READ at all.
#
# Precedence is deliberate and ordered:
#   1. CONVERGING  — a projection/mutation is mid-flight; nothing else is stable.
#   2. UNKNOWN     — an input could not be established. Cannot prove absence.
#   3. DISABLED    — not configured; capability is not expected.
#   4. INCAPABLE   — a REQUIRED structural edge is definitively absent.
#   5. DEGRADED    — capability partially present.
#   6. CAPABLE_ACTIVE / CAPABLE_IDLE — structurally whole; activity decides which.
nftban_capability_classify() {
    local configured="${1:-unknown}" reachable="${2:-unknown}" producer="${3:-unknown}"
    local consumer="${4:-unknown}" observation="${5:-unknown}" activity="${6:-unknown}"
    local converging="${7:-no}"

    [[ "$converging" == "yes" ]] && { printf 'CONVERGING'; return 0; }

    # An unreadable observation is its own outcome. It is NEVER "absent" and
    # NEVER zero — that conflation is the defect this whole model exists to stop.
    [[ "$observation" == "unknown" || "$observation" == "no" ]] && { printf 'UNKNOWN'; return 0; }

    [[ "$configured" == "no" ]] && { printf 'DISABLED'; return 0; }
    [[ "$configured" == "unknown" ]] && { printf 'UNKNOWN'; return 0; }

    # A required edge we could not establish is UNKNOWN, not INCAPABLE. Declaring
    # a mechanism broken on unread evidence is the same error as declaring it
    # healthy on unread evidence.
    local e
    for e in "$reachable" "$producer" "$consumer"; do
        [[ "$e" == "unknown" ]] && { printf 'UNKNOWN'; return 0; }
    done

    # Definitively absent required edge.
    if [[ "$reachable" == "no" || "$producer" == "no" || "$consumer" == "no" ]]; then
        printf 'INCAPABLE'; return 0
    fi

    # Structurally whole. Activity distinguishes proven-working from idle;
    # ⛔ absence of activity is NOT evidence of breakage.
    case "$activity" in
        yes) printf 'CAPABLE_ACTIVE' ;;
        no)  printf 'CAPABLE_IDLE' ;;
        *)   printf 'CAPABLE_IDLE' ;;   # activity unproven: structure is sound
    esac
    return 0
}

# nftban_capability_to_health <capability> [required]
#
# Maps an internal capability fact onto the SHIPPED HEALTH_* vocabulary so B03
# does not introduce a parallel language. `required` (default yes) decides how
# harshly INCAPABLE is reported.
#
# ⛔ The health vocabulary has no UNKNOWN member (OK/WARNING/ERROR/CRITICAL/
# NOT_INSTALLED/DISABLED). UNKNOWN therefore maps to WARNING — never to OK — so
# an unproven mechanism can never be reported as healthy. Adding a first-class
# HEALTH_UNKNOWN belongs to B01/B04, not here.
nftban_capability_to_health() {
    local cap="${1:-UNKNOWN}" required="${2:-yes}"
    case "$cap" in
        CAPABLE)        printf '%s' "${HEALTH_OK:-0}" ;;
        CAPABLE_ACTIVE) printf '%s' "${HEALTH_OK:-0}" ;;
        CAPABLE_IDLE)   printf '%s' "${HEALTH_OK:-0}" ;;
        CONVERGING)     printf '%s' "${HEALTH_WARNING:-1}" ;;
        DEGRADED)       printf '%s' "${HEALTH_WARNING:-1}" ;;
        UNKNOWN)        printf '%s' "${HEALTH_WARNING:-1}" ;;
        DISABLED)       printf '%s' "${HEALTH_DISABLED:-5}" ;;
        INCAPABLE)
            if [[ "$required" == "yes" ]]; then printf '%s' "${HEALTH_CRITICAL:-3}"
            else printf '%s' "${HEALTH_WARNING:-1}"; fi ;;
        *)              printf '%s' "${HEALTH_WARNING:-1}" ;;
    esac
}

# nftban_capability_explain <capability> <mechanism>
# One operator-facing line that states what is known, and what is NOT.
nftban_capability_explain() {
    local cap="${1:-UNKNOWN}" what="${2:-mechanism}"
    case "$cap" in
        CAPABLE)        printf '%s: capability present — required structural path is whole' "$what" ;;
        CAPABLE_ACTIVE) printf '%s: capability proven — producer reached and activity observed' "$what" ;;
        CAPABLE_IDLE)   printf '%s: capability present, currently idle — no qualifying activity (this is not a fault)' "$what" ;;
        DEGRADED)       printf '%s: capability partially present — see findings' "$what" ;;
        INCAPABLE)      printf '%s: a required edge is absent — the mechanism CANNOT act' "$what" ;;
        CONVERGING)     printf '%s: projection in progress — capability not yet stable' "$what" ;;
        DISABLED)       printf '%s: not configured' "$what" ;;
        UNKNOWN)        printf '%s: capability NOT ESTABLISHED — evidence unreadable (this is not a pass)' "$what" ;;
        # ⛔ An unrecognised state must be LOUD. A silent fallthrough once reported a
        # live CAPABLE verdict as "NOT ESTABLISHED", because an adapter introduced a
        # state name the model did not know. Misreporting a healthy capability is as
        # bad as misreporting a broken one.
        *)              printf '%s: UNRECOGNISED CAPABILITY STATE %s — model/adapter mismatch' "$what" "$cap" ;;
    esac
}

export -f nftban_capability_classify nftban_capability_to_health nftban_capability_explain 2>/dev/null || true
