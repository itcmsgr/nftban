#!/usr/bin/env bash
# =============================================================================
# NFTBan — config local (read-only .conf.local diagnostics) — IMPL-2
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2024-2026 Antonios Voulvoulis
#
# meta:name="nftban_config_local.sh"
# meta:type="core"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Read-only diagnostics for operator *.conf.local overrides: list/validate/doctor. Enumerates the .local inventory, bash -n syntax-checks (never sources/executes), and lints KEY=VALUE assignments against config-schema.json (single source of truth). STRICTLY READ-ONLY — no writes, no quarantine, no mutation (CONFIG_LOCAL_RECOVERY IMPL-2)."
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq,sha256sum,stat,grep,sed"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="conf.d/*.conf.local,whitelist.d/*.conf.local,blacklist.d/*.conf.local,nftban.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
[[ -n "${NFTBAN_CONFIG_LOCAL_LOADED:-}" ]] && return 0
readonly NFTBAN_CONFIG_LOCAL_LOADED=1

# Enumerate every operator *.conf.local across the standard inventory globs.
# Read-only; prints existing files only, one per line.
_config_local_inventory() {
    local cd="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local f
    shopt -s nullglob
    for f in "$cd"/nftban.conf.local \
             "$cd"/conf.d/*.conf.local \
             "$cd"/whitelist.d/*.conf.local \
             "$cd"/blacklist.d/*.conf.local; do
        if [[ -f "$f" ]]; then printf '%s\n' "$f"; fi
    done
    shopt -u nullglob
    return 0
}

# bash -n syntax gate (the SAME check _source_local uses). Read-only.
# echoes "OK" / "MALFORMED:<msg>"; returns 0 if clean, 1 if malformed.
_config_local_bashn() {
    local f="$1" err
    if err=$(bash -n "$f" 2>&1); then printf 'OK'; return 0; fi
    printf 'MALFORMED:%s' "$(printf '%s' "$err" | head -1)"
    return 1
}

# nftban config local list [--json]
nftban_cmd_config_local_list() {
    local json=0 a
    for a in "$@"; do if [[ "$a" == "--json" ]]; then json=1; fi; done
    local files; files=$(_config_local_inventory)
    if [[ $json -eq 1 ]]; then
        local arr="[]" f base sha size mtime st
        while IFS= read -r f; do
            if [[ -z "$f" ]]; then continue; fi
            base="${f%.local}"
            sha=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1) || true
            size=$(stat -c '%s' "$f" 2>/dev/null) || true
            mtime=$(stat -c '%Y' "$f" 2>/dev/null) || true
            st=$(_config_local_bashn "$f") || true; st="${st%%:*}"
            arr=$(jq -c --arg p "$f" --arg b "$base" --arg s "$sha" \
                --argjson z "${size:-0}" --argjson m "${mtime:-0}" --arg st "$st" \
                '. + [{path:$p,overrides:$b,sha256:$s,size:$z,mtime:$m,syntax:$st}]' <<<"$arr")
        done <<<"$files"
        printf '%s\n' "$arr" | jq .
        return 0
    fi
    if [[ -z "$files" ]]; then
        echo "No operator *.conf.local overrides found under ${NFTBAN_CONFIG_DIR:-/etc/nftban}."
        return 0
    fi
    printf '%-48s %-9s %-7s %s\n' "FILE" "SYNTAX" "SIZE" "SHA256(12)"
    local f base sha size st
    while IFS= read -r f; do
        if [[ -z "$f" ]]; then continue; fi
        base="${f%.local}"
        sha=$(sha256sum "$f" 2>/dev/null | cut -c1-12) || true
        size=$(stat -c '%s' "$f" 2>/dev/null) || true
        st=$(_config_local_bashn "$f") || true; st="${st%%:*}"
        printf '%-48s %-9s %-7s %s\n' "$f" "$st" "${size:-?}" "$sha"
        printf '    overrides: %s\n' "$base"
    done <<<"$files"
    return 0
}

# nftban config local validate [--json]  — bash -n only; rc≠0 if any SYNTAX_ERROR.
nftban_cmd_config_local_validate() {
    local json=0 a; for a in "$@"; do if [[ "$a" == "--json" ]]; then json=1; fi; done
    local files; files=$(_config_local_inventory)
    local rc=0 f res status msg arr="[]"
    while IFS= read -r f; do
        if [[ -z "$f" ]]; then continue; fi
        if res=$(_config_local_bashn "$f"); then status="OK"; msg=""
        else status="SYNTAX_ERROR"; msg="${res#MALFORMED:}"; rc=1; fi
        if [[ $json -eq 1 ]]; then
            arr=$(jq -c --arg p "$f" --arg s "$status" --arg m "$msg" \
                '. + [{path:$p,status:$s,message:$m}]' <<<"$arr")
        elif [[ "$status" == "OK" ]]; then
            printf '  OK            %s\n' "$f"
        else
            printf '  SYNTAX_ERROR  %s — %s\n' "$f" "$msg"
        fi
    done <<<"$files"
    if [[ $json -eq 1 ]]; then printf '%s\n' "$arr" | jq .
    elif [[ -z "$files" ]]; then echo "No *.conf.local overrides to validate."; fi
    return $rc
}

# Classify one KEY=VALUE against config-schema.json via the canonical validator.
# echoes "OK|UNKNOWN_KEY|DEPRECATED_KEY|BAD_VALUE<TAB>message"; always returns 0.
_config_local_classify_kv() {
    local key="$1" val="$2" msg rc cls prop dep
    # Honor a property-level deprecated:true flag — the canonical validator only
    # checks the .deprecated map for keys ABSENT from .properties, so a still-present
    # deprecated property (e.g. the v1.201.3 recovery keys) would otherwise read OK.
    prop=$(nftban_schema_get_property "$key" 2>/dev/null) || true
    if [[ -n "$prop" ]]; then
        dep=$(printf '%s' "$prop" | jq -r '.deprecated // false' 2>/dev/null) || true
        if [[ "$dep" == "true" ]]; then printf 'DEPRECATED_KEY\t%s' "deprecated in schema"; return 0; fi
    fi
    msg=$(nftban_config_validate_value "$key" "$val" 2>/dev/null) && rc=0 || rc=$?
    if [[ $rc -eq 0 ]]; then cls="OK"; msg=""
    elif [[ "$msg" == DEPRECATED* || "$msg" == RENAMED* ]]; then cls="DEPRECATED_KEY"
    elif [[ "$msg" == UNKNOWN* ]]; then cls="UNKNOWN_KEY"
    else cls="BAD_VALUE"; fi
    printf '%s\t%s' "$cls" "$msg"
    return 0
}

# nftban config local doctor [--dry-run] [--json]
# Read-only by design (no mutating mode exists). validate + schema-derived KEY=VALUE lint.
nftban_cmd_config_local_doctor() {
    local json=0 a; for a in "$@"; do case "$a" in --json) json=1;; --dry-run) :;; esac; done
    local files; files=$(_config_local_inventory)
    local rc=0 f line key val cls msg arr="[]" farr synstat
    while IFS= read -r f; do
        if [[ -z "$f" ]]; then continue; fi
        if _config_local_bashn "$f" >/dev/null; then synstat="OK"; else synstat="SYNTAX_ERROR"; rc=1; fi
        if [[ $json -eq 0 ]]; then printf '  %s  [syntax:%s]\n' "$f" "$synstat"; fi
        farr="[]"
        # parse ONLY simple KEY=VALUE assignments — never source/execute
        while IFS= read -r line; do
            if [[ ! "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then continue; fi
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}"   # strip trailing comment/space
            val="${val#[\"\']}"; val="${val%[\"\']}"                 # strip one layer of quotes
            IFS=$'\t' read -r cls msg <<<"$(_config_local_classify_kv "$key" "$val")"
            if [[ "$cls" != "OK" ]]; then rc=1; fi
            if [[ $json -eq 1 ]]; then
                farr=$(jq -c --arg k "$key" --arg c "$cls" --arg m "$msg" \
                    '. + [{key:$k,class:$c,message:$m}]' <<<"$farr")
            else
                printf '    %-14s %s%s\n' "$cls" "$key" "${msg:+  ($msg)}"
            fi
        done < "$f"
        if [[ $json -eq 1 ]]; then
            arr=$(jq -c --arg p "$f" --arg s "$synstat" --argjson keys "$farr" \
                '. + [{path:$p,syntax:$s,keys:$keys}]' <<<"$arr")
        fi
    done <<<"$files"
    if [[ $json -eq 1 ]]; then printf '%s\n' "$arr" | jq .
    elif [[ -z "$files" ]]; then echo "No *.conf.local overrides to check."; fi
    return $rc
}

# Dispatch: nftban config local <list|validate|doctor> [opts]
nftban_cmd_config_local() {
    local sub="${1:-help}"; shift || true
    case "$sub" in
        list)
            case "${1:-}" in -h|--help|help)
                echo "nftban config local list [--json] — enumerate operator *.conf.local overrides (read-only)"
                echo "    Per file: path · base .conf it overrides · sha256 · size · mtime · bash -n syntax status"; return 0;; esac
            nftban_cmd_config_local_list "$@" ;;
        validate)
            case "${1:-}" in -h|--help|help)
                echo "nftban config local validate [--json] — bash -n syntax-check each *.conf.local (read-only; never sources)"
                echo "    rc=0 if all OK; rc≠0 if any SYNTAX_ERROR"; return 0;; esac
            nftban_cmd_config_local_validate "$@" ;;
        doctor)
            case "${1:-}" in -h|--help|help)
                echo "nftban config local doctor [--json] — syntax + schema lint of each *.conf.local (READ-ONLY by design)"
                echo "    Per KEY=VALUE: OK | UNKNOWN_KEY | DEPRECATED_KEY | BAD_VALUE (validated against config-schema.json)"
                echo "    This command never modifies, quarantines, or disables any file. rc≠0 if any issue is found."; return 0;; esac
            nftban_cmd_config_local_doctor "$@" ;;
        help|-h|--help|"")
            echo "nftban config local <subcommand> — read-only diagnostics for operator *.conf.local overrides"
            echo ""
            echo "Subcommands:"
            echo "    list      [--json]   Enumerate *.conf.local (path/base/sha256/size/mtime/syntax)"
            echo "    validate  [--json]   bash -n syntax-check each (never sources/executes)"
            echo "    doctor    [--json]   Syntax + schema KEY=VALUE lint (READ-ONLY by design)"
            echo ""
            echo "All subcommands are READ-ONLY: no writes, no quarantine, no disable/reset/restore."
            return 0 ;;
        *)
            echo "ERROR: Unknown 'config local' subcommand: $sub" >&2
            echo "Valid: list, validate, doctor" >&2
            return 1 ;;
    esac
}

export -f nftban_cmd_config_local
export -f nftban_cmd_config_local_list nftban_cmd_config_local_validate nftban_cmd_config_local_doctor
