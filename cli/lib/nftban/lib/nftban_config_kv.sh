#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="nftban_config_kv"
# meta:type="lib"
# meta:version="1.230.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.230.0 PR-5c-A. Single set-or-append authority for shell KEY=\"value\" configuration files. Replaces the `sed -i \"s|^KEY=.*|...|\"` idiom, which substitutes ONLY when the key already exists and otherwise changes nothing while still exiting 0 — so the caller reports success for a request that was never written (CONFIG-MUTATION-SILENT-DROP-WHEN-KEY-ABSENT). Enforces exactly-once cardinality, validates the candidate before publishing, publishes atomically, and VERIFIES the persisted value before returning success. SCOPE: persistence only. It does NOT prove the value wins at runtime — that is PR-5c-B (CONFIG-SHELL-CENTRAL-OVERRIDE-OVERWRITTEN-BY-LATE-BASE)."
# meta:inventory.files=""
# meta:inventory.binaries="mktemp,grep,chmod,chown,mv"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

[[ -n "${_NFTBAN_CONFIG_KV_LOADED:-}" ]] && return 0
_NFTBAN_CONFIG_KV_LOADED=1

# Result vocabulary — a caller must be able to tell WHY a mutation did not happen.
: "${NFTBAN_KV_OK:=0}"
: "${NFTBAN_KV_BAD_KEY:=2}"
: "${NFTBAN_KV_NO_TARGET:=3}"
: "${NFTBAN_KV_AMBIGUOUS:=4}"
: "${NFTBAN_KV_IO_ERROR:=5}"
: "${NFTBAN_KV_CANDIDATE_INVALID:=6}"
: "${NFTBAN_KV_VERIFY_FAILED:=7}"

# nftban_config_kv_set <file> <KEY> <value>
#
#   key present exactly once -> replaced exactly once
#   key absent               -> appended exactly once
#   key present >1 time      -> REFUSED (ambiguous authority; normalising silently could
#                               drop an operator's line)
#   any failure              -> non-zero, and the target is left untouched
#
# ⛔ Returns success ONLY after re-reading the file and confirming BOTH that the key now
#    appears exactly once AND that its value equals the request. rc=0 from mv is not proof.
nftban_config_kv_set() {
    local file="${1:-}" key="${2:-}" value="${3-}"

    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
        printf 'nftban: config-kv: refusing malformed key %q\n' "$key" >&2
        return "$NFTBAN_KV_BAD_KEY"; }
    [[ -n "$file" && -f "$file" ]] || {
        printf 'nftban: config-kv: target is not a regular file: %s\n' "$file" >&2
        return "$NFTBAN_KV_NO_TARGET"; }

    local before
    before=$(grep -cE "^[[:space:]]*${key}=" "$file" 2>/dev/null || true)
    if [[ "$before" -gt 1 ]]; then
        printf 'nftban: config-kv: REFUSING mutation — %s declares %s %s times; ambiguous authority, resolve by hand\n' \
            "$file" "$key" "$before" >&2
        return "$NFTBAN_KV_AMBIGUOUS"
    fi

    local tmp
    tmp=$(mktemp "${file}.nftban-kv.XXXXXX" 2>/dev/null) || return "$NFTBAN_KV_IO_ERROR"
    # Publish must not change the subject's metadata; mirror the original.
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0640 "$tmp" 2>/dev/null || true
    chown --reference="$file" "$tmp" 2>/dev/null || true

    local line replaced=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$replaced" -eq 0 && "$line" =~ ^[[:space:]]*${key}= ]]; then
            printf '%s="%s"\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return "$NFTBAN_KV_IO_ERROR"; }
            replaced=1
        else
            printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return "$NFTBAN_KV_IO_ERROR"; }
        fi
    done < "$file"
    if [[ "$replaced" -eq 0 ]]; then
        printf '%s="%s"\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return "$NFTBAN_KV_IO_ERROR"; }
    fi

    # VALIDATE BEFORE PUBLISH. A candidate that cannot be parsed must never replace a
    # working file — same discipline as _source_local's bash -n gate (env.sh:55).
    if ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        printf 'nftban: config-kv: candidate for %s failed syntax check; target left unchanged\n' "$file" >&2
        return "$NFTBAN_KV_CANDIDATE_INVALID"
    fi

    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return "$NFTBAN_KV_IO_ERROR"; }

    # POST-WRITE VERIFICATION — cardinality AND value. Never trust the write.
    local after_n after_v
    after_n=$(grep -cE "^[[:space:]]*${key}=" "$file" 2>/dev/null || true)
    if [[ "$after_n" -ne 1 ]]; then
        printf 'nftban: config-kv: post-write cardinality for %s in %s is %s, expected exactly 1\n' \
            "$key" "$file" "$after_n" >&2
        return "$NFTBAN_KV_VERIFY_FAILED"
    fi
    after_v=$(sed -n "s/^[[:space:]]*${key}=\"\([^\"]*\)\".*$/\1/p; s/^[[:space:]]*${key}=\([^\"]*\)$/\1/p" "$file" | head -1)
    if [[ "$after_v" != "$value" ]]; then
        printf 'nftban: config-kv: post-write value for %s is %q, requested %q\n' "$key" "$after_v" "$value" >&2
        return "$NFTBAN_KV_VERIFY_FAILED"
    fi
    return "$NFTBAN_KV_OK"
}
