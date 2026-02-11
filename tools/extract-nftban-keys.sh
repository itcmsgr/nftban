#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Config Key Extractor
# =============================================================================
# meta:name="extract-nftban-keys"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Scans config tree, extracts keys, infers types, emits registry skeleton"
# meta:inventory.files=""
# meta:inventory.binaries="find,awk,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Usage:
#   ./extract-nftban-keys.sh /path/to/install/config /tmp/nftban-registry
#
# Outputs:
#   <outdir>/extracted-keys.json
#   <outdir>/registry-skeleton.json
#
# What it does:
#   - Recursively scans a config tree (e.g. install/config/ or /etc/nftban/)
#   - Extracts lines that look like UPPERCASE_KEY=...
#   - Captures: file path, key name, default value, inferred type, inline comment
#   - Emits:
#     * extracted-keys.json (flat list, easy for further processing)
#     * registry-skeleton.json (grouped by file -> keys, suitable for config-registry.json)
#
# This is deliberately "starter data": it will not infer active_when, required_when,
# introduced_in, etc. Those are the higher-value fields you add after coverage.
# =============================================================================

set -Eeuo pipefail

ROOT_DIR="${1:-}"
OUT_DIR="${2:-}"

if [[ -z "${ROOT_DIR}" || -z "${OUT_DIR}" ]]; then
  echo "Usage: $0 <config_root_dir> <out_dir>" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 ./install/config /tmp/nftban-config-registry" >&2
  echo "  $0 /etc/nftban /tmp/nftban-config-registry" >&2
  exit 2
fi

if [[ ! -d "${ROOT_DIR}" ]]; then
  echo "ERROR: root dir not found: ${ROOT_DIR}" >&2
  exit 2
fi

mkdir -p "${OUT_DIR}"

# Check for required tools
for cmd in find awk jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
done

# Regex notes:
# - Keys are assumed to be uppercase + digits + underscore
# - Accepts KEY=value and KEY="value"
# - Captures trailing comment after value: ... # comment
#
# Excludes:
# - commented lines starting with #
# - export KEY=... (supported by allowing optional "export " prefix)
#
# Type inference is intentionally conservative.

tmp_jsonl="$(mktemp)"
trap 'rm -f "${tmp_jsonl}"' EXIT

# Collect *.conf plus top-level *.conf.local, and any .conf under conf.d-like layouts.
mapfile -t files < <(find "${ROOT_DIR}" -type f \( -name "*.conf" -o -name "*.conf.local" \) | sort)

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "ERROR: no .conf files found under ${ROOT_DIR}" >&2
  exit 1
fi

echo "Scanning ${#files[@]} config files in ${ROOT_DIR}..."

# AWK to parse KEY=VALUE lines robustly.
# Outputs JSON Lines (one object per key occurrence).
awk -v root="${ROOT_DIR}" '
function ltrim(s){ sub(/^[ \t\r\n]+/, "", s); return s }
function rtrim(s){ sub(/[ \t\r\n]+$/, "", s); return s }
function trim(s){ return rtrim(ltrim(s)) }

# Basic type inference from VALUE string (post-unquote)
function infer_type(v,   low) {
  low = v
  for (i=1; i<=length(low); i++) {
    c = substr(low,i,1)
    if (c >= "A" && c <= "Z") low = substr(low,1,i-1) tolower(c) substr(low,i+1)
  }

  if (low == "true" || low == "false" || low == "yes" || low == "no" || low == "1" || low == "0") return "boolish"
  if (v ~ /^[0-9]+$/) return "int"
  if (v ~ /^[0-9]+\.[0-9]+$/) return "float"
  if (v ~ /^([0-9]+)(s|m|h|d)$/) return "duration"
  if (v ~ /^([0-9]+)(ms|sec|secs|mins|hours|days)$/) return "duration"
  if (v ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$/) return "cidr"
  if (v ~ /^\//) return "path"
  return "string"
}

# Strip surrounding single/double quotes if present
function unquote(v) {
  v = trim(v)
  if ((substr(v,1,1)=="\"" && substr(v,length(v),1)=="\"") || (substr(v,1,1)=="\047" && substr(v,length(v),1)=="\047")) {
    return substr(v,2,length(v)-2)
  }
  return v
}

BEGIN { }
{
  line = $0

  # skip full-line comments and empty
  if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) next

  # match: optional "export", KEY=VALUE, optional comment
  # We do not attempt to parse complex bash expansions.
  # We also tolerate spaces around "=".
  if (match(line, /^[ \t]*(export[ \t]+)?([A-Z0-9_]+)[ \t]*=[ \t]*([^#]*)(#.*)?$/, m)) {
    key = m[2]
    raw_value = trim(m[3])
    comment = m[4]
    if (comment ~ /^#/) comment = substr(comment,2)
    comment = trim(comment)

    value = unquote(raw_value)
    t = infer_type(value)

    # file path comes from FILENAME; normalize to relative under root
    rel = FILENAME
    sub("^" root "/?", "", rel)

    # Emit JSON line (jq can slurp later)
    gsub(/\\/,"\\\\", value)
    gsub(/"/,"\\\"", value)
    gsub(/\\/,"\\\\", comment)
    gsub(/"/,"\\\"", comment)
    gsub(/\\/,"\\\\", raw_value)
    gsub(/"/,"\\\"", raw_value)

    printf("{\"file\":\"%s\",\"key\":\"%s\",\"raw_value\":\"%s\",\"value\":\"%s\",\"type\":\"%s\",\"comment\":\"%s\"}\n",
           rel, key, raw_value, value, t, comment)
  }
}
' "${files[@]}" > "${tmp_jsonl}"

# Count extracted keys
key_count=$(wc -l < "${tmp_jsonl}")
echo "Extracted ${key_count} key definitions"

# Build extracted-keys.json (flat list)
jq -s --arg root "${ROOT_DIR}" '
  {
    generated_at: (now | todate),
    root: $root,
    count: length,
    items: .
  }
' "${tmp_jsonl}" > "${OUT_DIR}/extracted-keys.json"

# Build registry-skeleton.json grouped by file
jq -s --arg root "${ROOT_DIR}" '
  def file_group:
    group_by(.file)
    | map({
        path: .[0].file,
        keys: (
          group_by(.key)
          | map({
              key: .[0].key,
              type: (.[0].type),
              default: (.[0].value),
              raw_default: (.[0].raw_value),
              description_seed: (.[0].comment // ""),
              occurrences: length
            })
        )
      });

  {
    generated_at: (now | todate),
    root: $root,
    files: file_group
  }
' "${tmp_jsonl}" > "${OUT_DIR}/registry-skeleton.json"

echo ""
echo "Wrote:"
echo "  ${OUT_DIR}/extracted-keys.json"
echo "  ${OUT_DIR}/registry-skeleton.json"
echo ""
echo "Next suggested steps:"
echo "  1) Review keys with occurrences>1 (possible duplicates or repeated defaults)."
echo "  2) Add mode activation metadata (active_when) for classic/suricata files."
echo "  3) Promote from skeleton -> config-registry.json (add validators, required_when, introduced_in)."
