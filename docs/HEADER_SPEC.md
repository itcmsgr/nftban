# NFTBan Header & Inventory Specification

**Version:** 1.3.0
**Last Updated:** 2026-01-22
**Status:** Normative

## Overview

All NFTBan source files (Bash scripts, Go files, systemd units, config templates) MUST include standardized metadata headers. This enables:

- Automated dependency tracking
- Pre-commit validation
- Documentation generation
- Security auditing
- Installation verification

## Required Headers

### 1. License (SPDX)

Every file MUST contain exactly one SPDX license identifier:

```bash
# SPDX-License-Identifier: MPL-2.0
```

```go
// SPDX-License-Identifier: MPL-2.0
```

### 2. Core Metadata

All files SHOULD include these metadata fields:

| Field | Required | Description |
|-------|----------|-------------|
| `meta:name` | Yes | Short identifier (lowercase, hyphens) |
| `meta:type` | Yes | File type: `core`, `module`, `cli`, `cron`, `tool`, `helper`, `systemd` |
| `meta:version` | Yes | Semantic version (e.g., `1.3.0`) |
| `meta:owner` | Yes | Maintainer with email |
| `meta:description` | Yes | One-line description (quoted) |
| `meta:created_date` | No | ISO date: `YYYY-MM-DD` |
| `meta:depends` | No | Runtime dependencies (comma-separated) |

### 3. Inventory Keys (REQUIRED)

Every `.sh`, `.go`, `.service`, `.timer` file MUST include all 7 inventory keys:

```bash
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
```

**Empty values are acceptable** - they indicate the file has no dependencies in that category.

## Inventory Key Specifications

### `meta:inventory.files`

Data files, databases, state files created or modified by this component.

```bash
# meta:inventory.files="/var/lib/nftban/metrics/metrics.db,/var/lib/nftban/snapshots/*.json"
```

**Format:** Absolute paths, comma-separated. Globs allowed.

### `meta:inventory.binaries`

External executables required at runtime.

```bash
# meta:inventory.binaries="nft,jq,curl,systemctl"
```

**Format:** Binary names (no paths), comma-separated.

**Special Values:**
- `none` - No external binaries required
- `optional:NAME` - Binary is optional (graceful degradation)

### `meta:inventory.env_vars`

Environment variables read by this component.

```bash
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LOG_DIR,NFTBAN_DATA_DIR"
```

**Format:** Variable names (no `$`), comma-separated.

### `meta:inventory.config_files`

Configuration files read by this component.

```bash
# meta:inventory.config_files="/etc/nftban/nftban.conf,/etc/nftban/conf.d/*.conf"
```

**Format:** Absolute paths, comma-separated. Globs allowed.

### `meta:inventory.systemd_units`

Systemd units this component depends on or interacts with.

```bash
# meta:inventory.systemd_units="nftban-core.service,nftban-maintenance.timer"
```

**Format:** Unit names with suffix (`.service`, `.timer`, etc.), comma-separated.

**Special Values:**
- `none` - No systemd dependencies

### `meta:inventory.network`

Network endpoints, ports, or protocols used.

```bash
# meta:inventory.network="outbound:443/tcp,listen:9090/tcp"
```

**Format:** `direction:port/protocol` or descriptive (e.g., `outbound`, `none`)

**Direction Values:**
- `outbound` - Makes outgoing connections
- `listen` - Opens listening port
- `none` - No network access

### `meta:inventory.privileges`

Required privilege level to execute this component.

```bash
# meta:inventory.privileges="root"
```

**Standard Values:**
| Value | Description |
|-------|-------------|
| `none` | No special privileges |
| `nftban` | Requires nftban user/group |
| `root` | Requires root access |
| `root:cap_net_admin` | Root with specific capability |
| `root:read-nftables` | Root for nft read operations |
| `root:write-nftables` | Root for nft write operations |

## Complete Example

### Bash Script

```bash
#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Example Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="example-module"
# meta:type="module"
# meta:version="1.3.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-01-22"
# meta:description="Example module demonstrating header spec"
# meta:depends="bash,nft_schema.sh"
# meta:inventory.files="/var/lib/nftban/example.db"
# meta:inventory.binaries="nft,jq"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-core.service"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-nftables"
# =============================================================================

set -Eeuo pipefail
```

### Go File

```go
// =============================================================================
// NFTBan v1.3.0 - Example Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="example-pkg"
// meta:type="package"
// meta:version="1.3.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Example Go package demonstrating header spec"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network="outbound:443/tcp"
// meta:inventory.privileges="nftban"
// =============================================================================

package example
```

### Systemd Unit

```ini
# =============================================================================
# NFTBan v1.3.0 - Example Service
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban-example.service"
# meta:type="systemd"
# meta:version="1.3.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Example systemd service"
# meta:inventory.files=""
# meta:inventory.binaries="/usr/lib/nftban/bin/nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-example.timer"
# meta:inventory.network="none"
# meta:inventory.privileges="nftban"
# =============================================================================

[Unit]
Description=NFTBan Example Service
```

## Validation

### Pre-commit Hook

The `tools/validate-headers.sh` script enforces this specification:

```bash
# Run validation
./tools/validate-headers.sh

# Checks performed:
# 1. Exactly one SPDX-License-Identifier line
# 2. License is MPL-2.0
# 3. All meta: lines are properly quoted
# 4. All 7 inventory keys present
# 5. No free-text headers (From:, Called by:)
# 6. Bash files have set -Eeuo pipefail
```

### Inventory Aggregation

The `tools/inventory-aggregate.sh` script aggregates all inventory metadata:

```bash
# Quick overview
./tools/inventory-aggregate.sh

# Validate all dependencies exist
./tools/inventory-aggregate.sh validate

# Export to JSON
./tools/inventory-aggregate.sh json > inventory.json

# Find files missing headers
./tools/inventory-aggregate.sh coverage
```

## Rationale

### Why 7 Inventory Keys?

Each key serves a specific purpose in the NFTBan ecosystem:

| Key | Purpose |
|-----|---------|
| `files` | Tracks data file dependencies for backup/migration |
| `binaries` | Installation verification, dependency checking |
| `env_vars` | Configuration audit, environment setup |
| `config_files` | Configuration management, upgrade safety |
| `systemd_units` | Service orchestration, dependency ordering |
| `network` | Security audit, firewall configuration |
| `privileges` | Security classification, RBAC enforcement |

### Why Require Empty Values?

Explicit empty values (`=""`) indicate:
1. The developer considered this category
2. The file genuinely has no dependencies in this area
3. Future audits can distinguish "no dependencies" from "not checked"

## Migration Guide

### Adding Headers to Existing Files

1. Run coverage check: `./tools/inventory-aggregate.sh coverage`
2. Add header block at file top (after shebang)
3. Fill in known dependencies
4. Use empty string for unknown/none: `meta:inventory.binaries=""`
5. Run validation: `./tools/validate-headers.sh`

### Updating Outdated Headers

1. Run aggregation: `./tools/inventory-aggregate.sh report`
2. Compare file's headers against actual usage
3. Update values as needed
4. Re-run validation

## See Also

- `tools/validate-headers.sh` - Pre-commit validation hook
- `tools/inventory-aggregate.sh` - Inventory aggregation tool
- `commands.registry.yml` - Command registry (different purpose)
- `CONTRIBUTING.md` - Contributor guidelines
