#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Config Schema Expander
# =============================================================================
# meta:name="expand-config-schema"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Transforms registry-skeleton.json into full config-schema.json"
# meta:inventory.files=""
# meta:inventory.binaries="jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# H-03: skeleton path has no public default — caller must pass it. Output
# defaults to the canonical repo-relative location, resolved from this
# script's own directory so the tool works on any clone.
_self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
INPUT_SKELETON="${1:?usage: $0 <skeleton.json> [output-schema.json]}"
OUTPUT_SCHEMA="${2:-${_self_dir}/../cli/lib/nftban/data/config-schema.json}"

echo "Expanding config schema from: $INPUT_SKELETON"
echo "Output to: $OUTPUT_SCHEMA"

# Use jq to transform the skeleton into schema format
jq --arg timestamp "$(date -Iseconds)" '
# Type mapping function
def map_type:
  if . == "boolish" then "boolean_string"
  elif . == "int" then "positive_integer"
  elif . == "path" then "path"
  else "string"
  end;

# Category from file path
def get_category:
  if . | test("banner\\.conf") then "system"
  elif . | test("mail\\.conf") then "notifications"
  elif . | test("stats\\.conf") then "system"
  elif . | test("rbl/") then "features"
  elif . | test("portscan/") then "modules"
  elif . | test("ddos/") then "modules"
  elif . | test("login/") then "modules"
  elif . | test("panels/") then "panels"
  elif . | test("feeds\\.conf") then "features"
  else "system"
  end;

# Activation from key prefix and file path
def get_activation($path):
  if . | test("^PORTSCAN_CLASSIC_") then "portscan_classic"
  elif . | test("^PORTSCAN_SURICATA_") then "portscan_suricata"
  elif . | test("^DDOS_CLASSIC_") then "ddos_classic"
  elif . | test("^DDOS_SURICATA_") then "ddos_suricata"
  elif . | test("^LOGIN_CLASSIC_") then "login_classic"
  elif . | test("^LOGIN_SURICATA_") then "login_suricata"
  elif . | test("^PANEL_") then "panel_detected"
  elif $path | test("classic\\.conf") then "mode_classic"
  elif $path | test("suricata\\.conf") then "mode_suricata"
  else "always"
  end;

# Generate description from key name
def make_description:
  if (.description_seed // "") != "" then .description_seed
  else
    .key
    | gsub("_"; " ")
    | ascii_downcase
    | split(" ")
    | map(if length > 0 then .[0:1] | ascii_upcase + .[1:] else . end)
    | join(" ")
  end;

# Build all properties
[.files[] | .path as $path | .keys[] | {
  key: .key,
  value: {
    type: "string",
    "$ref": ("#/definitions/" + (.type | map_type)),
    default: (.default // ""),
    description: (. | make_description),
    introduced_in: "1.0.0",
    category: ($path | get_category),
    config_file: $path,
    active_when: (.key | get_activation($path))
  }
}] | from_entries as $props |

# Final schema structure
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://nftban.com/schemas/config-v1.json",
  title: "NFTBan Configuration Schema",
  description: "Schema for NFTBan configuration validation and audit",
  version: "1.0.28",
  type: "object",

  metadata: {
    schema_version: 1,
    min_nftban_version: "1.0.0",
    documentation_url: "https://nftban.com/docs/config",
    generated_at: $timestamp,
    key_count: ($props | length)
  },

  definitions: {
    boolean_string: {
      type: "string",
      enum: ["true", "false", "yes", "no", "1", "0", "on", "off"],
      description: "Boolean value as string (shell-compatible)"
    },
    positive_integer: {
      type: "string",
      pattern: "^[0-9]+$",
      description: "Positive integer as string"
    },
    duration_seconds: {
      type: "string",
      pattern: "^[0-9]+$",
      description: "Duration in seconds"
    },
    path: {
      type: "string",
      description: "Filesystem path"
    },
    ip_address: {
      type: "string",
      pattern: "^([0-9]{1,3}\\.){3}[0-9]{1,3}$|^([0-9a-fA-F:]+)$"
    },
    cidr: {
      type: "string",
      pattern: "^([0-9]{1,3}\\.){3}[0-9]{1,3}/[0-9]{1,2}$|^([0-9a-fA-F:]+)/[0-9]{1,3}$"
    },
    email: {
      type: "string",
      description: "Email address"
    },
    log_level: {
      type: "string",
      enum: ["debug", "info", "warn", "error", "none"],
      description: "Logging level"
    },
    mode: {
      type: "string",
      enum: ["auto", "classic", "suricata", "hybrid"],
      description: "Detection mode"
    }
  },

  activation_rules: {
    always: "File/key is always active",
    portscan_classic: "PORTSCAN_MODE in [classic, hybrid] OR (PORTSCAN_MODE=auto AND !suricata_detected)",
    portscan_suricata: "PORTSCAN_MODE in [suricata, hybrid] OR (PORTSCAN_MODE=auto AND suricata_detected)",
    ddos_classic: "DDOS_MODE in [classic, hybrid] OR (DDOS_MODE=auto AND !suricata_detected)",
    ddos_suricata: "DDOS_MODE in [suricata, hybrid] OR (DDOS_MODE=auto AND suricata_detected)",
    login_classic: "LOGIN_MODE in [classic, hybrid] OR (LOGIN_MODE=auto AND !suricata_detected)",
    login_suricata: "LOGIN_MODE in [suricata, hybrid] OR (LOGIN_MODE=auto AND suricata_detected)",
    mode_classic: "Active when mode-specific config file is in classic mode",
    mode_suricata: "Active when mode-specific config file is in suricata mode",
    panel_detected: "Panel auto-detected or explicitly configured"
  },

  properties: (
    {
      "_config_version": {
        type: "integer",
        description: "Schema version this config was created with",
        default: 1,
        minimum: 1
      }
    } + $props
  ),

  deprecated: {
    NFTBAN_FAIL2BAN_ENABLED: {
      deprecated_in: "1.0.0",
      removed_in: null,
      replaced_by: null,
      message: "Fail2ban integration removed in v1.0; use Suricata mode instead"
    }
  },

  renamed: {
    PORTSCAN_THRESHOLD: {
      renamed_to: "PORTSCAN_BAN_THRESHOLD",
      renamed_in: "1.0.0"
    }
  },

  categories: {
    system: "Core system settings",
    paths: "Filesystem paths",
    features: "Feature toggles",
    banning: "Ban behavior settings",
    modules: "Module-specific settings",
    notifications: "Alert and notification settings",
    panels: "Hosting panel integration",
    detection: "Detection thresholds and tuning"
  }
}
' "$INPUT_SKELETON" > "$OUTPUT_SCHEMA"

key_count=$(jq '.metadata.key_count' "$OUTPUT_SCHEMA")
echo "Schema expanded: $key_count keys written to $OUTPUT_SCHEMA"
