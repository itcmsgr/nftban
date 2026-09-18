#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# gen-pipefail-epipe-inventory.sh — regenerate the two ratchet baselines consumed
# by scripts/ci/check-pipefail-epipe-shortcircuit.sh:
#
#   scripts/ci/data/pipefail-epipe-test-corpus-inventory.tsv
#       per-file COUNTS for the BLOCKING shell-test corpus
#   scripts/ci/data/pipefail-epipe-exposure-registry.tsv
#       content-anchored DECLARED EXPOSURE rows for the gate and product planes
#
# Both are GENERATED so they cannot drift into hand-curated lists, and so
# "fix a site, regenerate" is a mechanical step rather than an editorial one.
#
# v1.231.0 LANE G: the matcher is no longer duplicated here. The guard is sourced
# with EPIPE_GUARD_LIB_ONLY=1 and its detector and populations are used directly,
# because a second copy of a matcher is how a generated baseline silently stops
# describing the population the gate actually scans. The dependency is one-way:
# the gate does not need this generator to run.
#
# The class, mode, reproduction_status and note columns of the registry are ALL
# CARRIED FORWARD from the existing file whenever a row's (plane, file,
# fingerprint) identity survives, so regenerating never discards a measurement
# someone earned. A regeneration that reset any of them to a default would erase
# exactly the evidence those columns exist to hold, and would do it invisibly.
set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Named OUT_* so they cannot collide with any name the sourced guard owns.
OUT_INV="scripts/ci/data/pipefail-epipe-test-corpus-inventory.tsv"
OUT_REG="scripts/ci/data/pipefail-epipe-exposure-registry.tsv"

EPIPE_GUARD_LIB_ONLY=1
# shellcheck source=scripts/ci/check-pipefail-epipe-shortcircuit.sh
. scripts/ci/check-pipefail-epipe-shortcircuit.sh

# ---- carry forward existing classifications ---------------------------------
# ⛔ class, mode, reproduction_status AND note are ALL carried forward. Each is
# evidence someone had to measure; a regeneration that silently reset any of them
# to a default would erase exactly what the column exists to hold — and it would
# do it invisibly, because the file would still look complete.
declare -A PRIOR_CLASS=() PRIOR_MODE=() PRIOR_REPRO=() PRIOR_NOTE=()
if [[ -f "$OUT_REG" ]]; then
    # ⛔ BRANCH ON FIELD COUNT, never on positional `read`. The registry shipped
    # with 7 columns before the mode axis; reading such a row with a 9-name
    # `read` silently slides the NOTE into `mode` and produces a file where every
    # row carries a sentence where a vocabulary term belongs. That is what
    # happened on the first attempt here, and it is only visible if you look at
    # the values — the row count, the site count and the exit code were all
    # identical. A schema migration that can be mistaken for a clean run is the
    # same defect class as an empty population that reports OK.
    while IFS= read -r _line; do
        [[ -z "$_line" || "$_line" == \#* ]] && continue
        IFS=$'\t' read -r -a _f <<< "$_line"
        [[ "${#_f[@]}" -ge 6 ]] || continue
        _key="${_f[0]}|${_f[1]}|${_f[2]}"
        PRIOR_CLASS["$_key"]="${_f[5]:-}"
        if [[ "${#_f[@]}" -ge 9 ]]; then
            PRIOR_MODE["$_key"]="${_f[6]:-}"
            PRIOR_REPRO["$_key"]="${_f[7]:-}"
            PRIOR_NOTE["$_key"]="${_f[8]:-}"
        else
            # legacy 7-column row: column 7 is the note; mode/status not yet measured
            PRIOR_NOTE["$_key"]="${_f[6]:-}"
        fi
    done < "$OUT_REG"
fi

# =============================================================================
# MODE AUTHORITY — which operating mode of a two-mode component a site belongs to
# =============================================================================
#
# DDoS and PortScan each run in exactly one of two modes, selected by DDOS_MODE /
# PORTSCAN_MODE (`auto|classic|suricata`); PortScan records the resolved value in
# _PORTSCAN_ACTIVE_MODE. Without this axis a Classic-only finding and a
# whole-component finding are the same row, which is how "DDoS is covered" gets
# said about a component where only one of two modes was ever looked at.
#
# ⛔ `shared` IS A CLAIM ABOUT EXECUTION AUTHORITY, not a shrug. It is assigned
# only where BOTH mode paths demonstrably reach the code. Where that could not be
# established the value is `n/a` WITH A NOTE saying what was measured instead.
#
# EXECUTION POPULATION (verified at 4654bb21, all six files present):
#   DDoS      core/nftban_ddos.sh · nftban_ddos_classic.sh · nftban_ddos_suricata.sh
#   PortScan  core/nftban_portscan.sh · nftban_portscan_classic.sh · nftban_portscan_suricata.sh
#   config    etc/nftban/conf.d/{ddos,portscan}/{main,classic,suricata}.conf
#
# EVIDENCE PER ASSIGNMENT — each measured in the tree, not inferred from a name:
#
#   *_classic.sh          -> classic
#       The dispatcher sources both modules unconditionally (nftban_ddos.sh:115-125)
#       but CALLS them only from mode-gated branches (`case "$mode" in classic)`
#       at nftban_ddos.sh:701-711 and :1039-1042). Sourcing is not execution.
#       Checked per enclosing function: nftban_ddos_list_banned has NO caller
#       anywhere in the repo besides its own definition and `export -f`, so no
#       suricata path reaches it; nftban_portscan_classic_record_connection is
#       called only from within nftban_portscan_classic.sh (:764, :810).
#
#   *_suricata.sh         -> suricata
#       Both dispatcher call sites into the suricata module sit inside
#       `case "$mode" in suricata)` branches (nftban_ddos.sh:713-726, :1043-1048).
#       MEASURED, because the risk here is real: a probe such as
#       nftban_ddos_suricata_is_available IS called during `auto` resolution and
#       therefore runs under BOTH modes — no registry row happens to live in one,
#       but the check is per enclosing function so that stays true if one appears.
#
#   dispatcher            -> shared
#       nftban_ddos.sh / nftban_portscan.sh RESOLVE the mode (`DDOS_MODE:-auto`
#       at :152/:199/:932, `PORTSCAN_MODE:-auto` at :144/:239/:963), so they are
#       entered before a mode exists and run under every value of it.
#
#   cli/cmd_{ddos,portscan}.sh  -> shared
#       Not in the declared execution population, but demonstrably mode-independent
#       rather than merely unclassified: the flagged sites are inside
#       _nftban_ddos_stats_json / _nftban_portscan_stats_json, which RENDER the
#       mode as data (cmd_ddos.sh:205 reads DDOS_MODE out of the config;
#       cmd_portscan.sh:321 emits `--arg mode "${PORTSCAN_MODE:-auto}"`), and are
#       reached from a `case "$subcommand" in stats)` verb branch (cmd_ddos.sh:413,
#       cmd_portscan.sh:451) — a verb dispatch, never a mode dispatch.
#
#   everything else       -> n/a
#       Including helpers/suricata_effective_config.sh, whose 5 sites (4 class A)
#       LOOK like a suricata-component row. MEASURED: its only caller in the tree
#       is core/nftban_watchdog.sh:171-172. Neither the DDoS nor the PortScan
#       dispatcher sources it, so "both modes reach it" is UNPROVEN and it is NOT
#       labelled shared. The note on those rows records the measured caller.
epipe_mode_for_file() {
    case "$1" in
        cli/lib/nftban/core/nftban_ddos_classic.sh|cli/lib/nftban/core/nftban_portscan_classic.sh)
            printf 'classic' ;;
        cli/lib/nftban/core/nftban_ddos_suricata.sh|cli/lib/nftban/core/nftban_portscan_suricata.sh)
            printf 'suricata' ;;
        cli/lib/nftban/core/nftban_ddos.sh|cli/lib/nftban/core/nftban_portscan.sh)
            printf 'shared' ;;
        cli/lib/nftban/cli/cmd_ddos.sh|cli/lib/nftban/cli/cmd_portscan.sh)
            printf 'shared' ;;
        *)  printf 'n/a' ;;
    esac
}

epipe_mode_note_for_file() {
    case "$1" in
        cli/lib/nftban/helpers/suricata_effective_config.sh)
            printf 'mode=n/a NOT shared: only in-tree caller is core/nftban_watchdog.sh:171-172; neither DDoS nor PortScan dispatcher sources it, so both-mode reach is UNPROVEN' ;;
        cli/lib/nftban/core/nftban_ddos_classic.sh)
            printf 'mode=classic: no caller in the repo outside its own definition and export -f; no suricata path reaches it' ;;
        cli/lib/nftban/cli/cmd_ddos.sh|cli/lib/nftban/cli/cmd_portscan.sh)
            printf 'mode=shared: reached from a subcommand branch, renders the mode as data; not mode-dispatched' ;;
        *)  printf '' ;;
    esac
}

# ---- reproduction_status seed ------------------------------------------------
# Seeded ONLY from what has actually been reproduced, keyed file:line at the
# 4654bb21 baseline the census was taken on. Everything not listed stays
# UNVERIFIED — which is a statement about the evidence, not about the site.
declare -A SEED_REPRO=(
    ["cli/lib/nftban/core/nftban_ddos_classic.sh:1092"]="PROVEN"
    ["cli/lib/nftban/core/nftban_ddos_classic.sh:1100"]="PROVEN"
    ["cli/lib/nftban/core/nftban_firewall_conflicts.sh:266"]="PROVEN"
    ["cli/lib/nftban/core/nftban_firewall_conflicts.sh:1397"]="DEBT"
    ["cli/lib/nftban/core/nftban_firewall_conflicts.sh:1398"]="DEBT"
    ["cli/lib/nftban/core/nftban_firewall_conflicts.sh:1399"]="DEBT"
    ["cli/lib/nftban/lib/nft_schema.sh:721"]="NOT_A_DEFECT"
)
declare -A SEED_REPRO_NOTE=(
    ["cli/lib/nftban/lib/nft_schema.sh:721"]="NOT_A_DEFECT: producer provably bounded, <=1 element, 79 B — cannot reach the pipe buffer"
)

# ---- census seed (optional, first run only) ---------------------------------
# EPIPE_CENSUS_TSV may point at the read-only classification census so a first
# generation is seeded with its A/B/C/D/E classes instead of UNCLASSIFIED. It is
# keyed by file:line, which only resolves against the tree the census was run on;
# after the first run the registry's own carried-forward classes are authority.
declare -A SEED_CLASS=() SEED_NOTE=()
if [[ -n "${EPIPE_CENSUS_TSV:-}" && -f "${EPIPE_CENSUS_TSV:-}" ]]; then
    while IFS=$'\t' read -r _f _l _c _fn _pf _ee _class _thr _sec _rest; do
        [[ -z "$_f" || "$_f" == "file" ]] && continue
        [[ -n "$_class" ]] || continue
        cur="${SEED_CLASS["$_f:$_l"]:-}"
        # most severe wins when a line carries more than one census row
        case "$cur" in A) continue ;; esac
        SEED_CLASS["$_f:$_l"]="$_class"
        if [[ "$_class" == "A" ]]; then
            SEED_NOTE["$_f:$_l"]="fn=${_fn:--}; security_or_count_surface=${_sec:--}; ${_thr:--}"
        elif [[ "$_class" == "E" ]]; then
            SEED_NOTE["$_f:$_l"]="fn=${_fn:--}; needs a producer-size probe on a representative host"
        fi
    done < "$EPIPE_CENSUS_TSV"
fi

emit_plane() {
    local plane="$1" require_pipefail="$2" popfn="$3"
    local f ln cons line fp key n
    local -a LINES=()
    declare -A SEEN=() CONS=() CLS=() NTE=() RPR=() RPR_NOTE=()
    while IFS= read -r p; do
        [[ -n "$p" ]] || continue
        [[ -f "$p" ]] || continue
        f="$p"
        if [[ "$require_pipefail" == "yes" ]]; then
            declares_pipefail "$f" || continue
        fi
        mapfile -t LINES < "$f" 2>/dev/null || continue
        while IFS=$'\t' read -r ln cons; do
            [[ -n "$ln" ]] || continue
            line="${LINES[$((ln - 1))]}"
            fp="$(epipe_fingerprint "$line")"
            key="$plane|$f|$fp"
            SEEN["$key"]=$(( ${SEEN["$key"]:-0} + 1 ))
            CONS["$key"]="$cons"
            if [[ "${CLS["$key"]:-}" != "A" ]]; then
                CLS["$key"]="${SEED_CLASS["$f:$ln"]:-}"
                NTE["$key"]="${SEED_NOTE["$f:$ln"]:-}"
            fi
            # A PROVEN/DEBT/NOT_A_DEFECT seed always wins over an UNVERIFIED one
            # when identical lines collapse into a single fingerprint row.
            if [[ -z "${RPR["$key"]:-}" || "${RPR["$key"]:-}" == "UNVERIFIED" ]]; then
                RPR["$key"]="${SEED_REPRO["$f:$ln"]:-UNVERIFIED}"
                RPR_NOTE["$key"]="${SEED_REPRO_NOTE["$f:$ln"]:-}"
            fi
        done < <(detect_sites "$f")
    done < <("$popfn")
    local class note mode repro kplane krest kfile kfp
    for key in "${!SEEN[@]}"; do
        n="${SEEN[$key]}"
        kplane="${key%%|*}"; krest="${key#*|}"; kfile="${krest%|*}"; kfp="${krest##*|}"
        class="${PRIOR_CLASS[$key]:-}"
        [[ -z "$class" ]] && class="${CLS[$key]:-}"
        [[ -z "$class" ]] && class="UNCLASSIFIED"
        # CARRY FORWARD, never recompute, once a value exists in the file. mode
        # and reproduction_status are measurements; regenerating must not quietly
        # replace a measurement with a default.
        mode="${PRIOR_MODE[$key]:-}"
        [[ -z "$mode" ]] && mode="$(epipe_mode_for_file "$kfile")"
        repro="${PRIOR_REPRO[$key]:-}"
        [[ -z "$repro" ]] && repro="${RPR[$key]:-UNVERIFIED}"
        note="${PRIOR_NOTE[$key]:-}"
        [[ -z "$note" || "$note" == "-" ]] && note="${NTE[$key]:-}"
        [[ -z "$note" ]] && note="$(epipe_mode_note_for_file "$kfile")"
        [[ -z "$note" ]] && note="-"
        # A reproduction ruling is APPENDED, never substituted. The census note on
        # cli/lib/nftban/lib/nft_schema.sh:721 records the THRESHOLD OF THE SHAPE
        # ("20/20 fail at 205291B"); the NOT_A_DEFECT ruling is about THIS site's
        # producer (<=1 element, 79 B). Replacing one with the other would lose a
        # true fact, and leaving the census note alone would let a NOT_A_DEFECT row
        # read as a measured failure. Both are true; both stay.
        if [[ -n "${RPR_NOTE[$key]:-}" && "$note" != *"${RPR_NOTE[$key]}"* ]]; then
            if [[ "$note" == "-" ]]; then note="${RPR_NOTE[$key]}"
            else note="$note | ${RPR_NOTE[$key]}"; fi
        fi
        printf '%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n' \
            "$kplane" "$kfile" "$kfp" "$n" "${CONS[$key]}" "$class" "$mode" "$repro" "$note"
    done
}

{
    cat <<'HDR'
# GENERATED by scripts/ci/gen-pipefail-epipe-inventory.sh — do not hand-edit
# except to improve the class/note columns, which regeneration carries forward.
#
# DECLARED EXPOSURE REGISTRY — every `producer | <short-circuiting consumer>`
# pipeline in the gate plane (CI-wired scripts/ci scripts) and the product plane
# (what packaging ships to /usr/lib/nftban + /usr/sbin and what systemd units
# ExecStart). Under `pipefail` such a pipeline can return 141 while its answer
# was correct; see the header of check-pipefail-epipe-shortcircuit.sh for the
# measured thresholds.
#
# ⛔ THIS IS A DEBT REGISTER, NOT AN ALLOWLIST. A row here means the exposure is
# KNOWN and OWED, not that it is safe. The class column is the disposition:
#
#   A             SIGPIPE-SENSITIVE — the producer can exceed the pipe buffer on
#                 a real host. Owed remediation. 39 of these sit on a security-
#                 or count-reporting surface.
#   B             structurally safe — producer bounded small by construction
#   C             already normalised — `|| true` / `|| echo` fallback, or a
#                 local/declare that masks the status
#   D             shipped but not on an automatic product execution path
#   E             UNKNOWN — producer size is host-dependent; needs a probe on a
#                 representative host before it can be classified
#   UNCLASSIFIED  detected but never classified; treat as E until measured
#
# mode — which operating mode of a TWO-MODE component the site belongs to:
#
#   classic   reached only on the Classic path of DDoS / PortScan
#   suricata  reached only on the Suricata path
#   shared    BOTH mode paths demonstrably reach it (a dispatcher, or a helper
#             proven reachable from both) — a CLAIM, assigned only with evidence
#   n/a       outside the two-mode components, OR inside one but with both-mode
#             reach UNPROVEN; the note then records what was measured instead
#
# ⛔ COVERAGE IS PER MODE. "DDoS is covered" and "PortScan is covered" are NOT
# statements this file can support and MUST NOT be said on the strength of it.
# DDoS and PortScan each have two operating modes, selected by DDOS_MODE /
# PORTSCAN_MODE; a finding in Classic says nothing about Suricata and vice versa.
# THE ABSENCE OF A ROW FOR A MODE MEANS UNVERIFIED, NEVER SAFE. The only claims
# this file supports are per (component, mode) and are bounded by the
# reproduction_status of the rows that carry that mode.
#
# reproduction_status — what has actually been reproduced, not what is suspected:
#
#   PROVEN        reproduced: the pipeline returns 141 on a realistic producer
#   DEBT          confirmed exposure, remediation owed, not yet reproduced
#   NOT_A_DEFECT  provably cannot fire (producer bounded below the pipe buffer)
#   UNVERIFIED    no reproduction attempted or none recorded — the DEFAULT, and a
#                 statement about the EVIDENCE, never a clearance for the site
#
# Identity is (plane, file, fingerprint) where fingerprint is the first 16 hex of
# the sha256 of the whitespace-normalised line. Line NUMBERS are deliberately not
# part of identity: they drift on any edit and would locate the subject by
# position. occurrences counts identical lines in the same file.
#
# class, mode, reproduction_status and note are CARRIED FORWARD across a
# regeneration whenever a row's identity survives. Each is a measurement; a
# regeneration that reset any of them to a default would erase the evidence the
# column exists to hold, and would do it invisibly.
#
# Ratchet, three directions — see the guard's ARM 1:
#   detected but not declared       -> FAIL (new exposure)
#   declared but no longer detected -> FAIL (reconcile; locks a real fix in and
#                                     makes a disappearance explainable)
#   declared, file no longer in the -> FAIL (rotting row; nothing consumes it)
#   population
#
# Regenerate: scripts/ci/gen-pipefail-epipe-inventory.sh
#
# plane	file	fingerprint	occurrences	consumers	class	mode	reproduction_status	note
HDR
    { emit_plane gate yes gate_population; emit_plane product no product_population; } | sort
} > "$OUT_REG"

{
    cat <<'HDR'
# GENERATED by scripts/ci/gen-pipefail-epipe-inventory.sh — do not hand-edit.
# Per-file count of `producer | <short-circuiting consumer>` sites in the
# BLOCKING shell-test corpus (test-authority-index gate = ci-bash|policy-gates).
#
# Counts, not content-anchored rows: a test's identity is not what is at stake
# here, its GROWTH is, and content-anchoring ~700 test lines would make every
# test edit a registry edit. The security-bearing sites live in the product
# plane, which IS content-anchored — see pipefail-epipe-exposure-registry.tsv.
#
# Ratchet: a count may only go DOWN, and a decrease must be recorded here.
HDR
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        declares_pipefail "$f" || continue
        n=0
        while IFS=$'\t' read -r _ln _cons; do
            [[ -n "$_ln" ]] || continue
            n=$((n + 1))
        done < <(detect_sites "$f")
        [[ "$n" -gt 0 ]] && printf '%s\t%s\n' "$f" "$n"
    done < <(test_corpus_population)
} > "$OUT_INV"

printf 'wrote %s (%d rows, %d sites)\n' "$OUT_REG" \
    "$(grep -vc '^#' "$OUT_REG" || true)" \
    "$(awk -F'\t' '!/^#/{s+=$4} END{print s+0}' "$OUT_REG")"
printf 'wrote %s (%d files, %d sites)\n' "$OUT_INV" \
    "$(grep -vc '^#' "$OUT_INV" || true)" \
    "$(awk -F'\t' '!/^#/{s+=$2} END{print s+0}' "$OUT_INV")"
