# NFTBan Install-Mirror Layout (Canonical Source)

This directory is the **canonical source** for the Bash CLI runtime files and is
intentionally structured to mirror the final install location:

```
/usr/lib/nftban/
```

## Install Mapping

During packaging/installation, this tree is copied directly:

| Repo Path                  | Install Path              |
|----------------------------|---------------------------|
| `cli/lib/nftban/cli/`      | `/usr/lib/nftban/cli/`    |
| `cli/lib/nftban/lib/`      | `/usr/lib/nftban/lib/`    |
| `cli/lib/nftban/core/`     | `/usr/lib/nftban/core/`   |
| `cli/lib/nftban/exporters/`| `/usr/lib/nftban/exporters/` |
| `cli/lib/nftban/helpers/`  | `/usr/lib/nftban/helpers/` |
| `cli/lib/nftban/setup/`    | `/usr/lib/nftban/setup/`  |
| `cli/lib/nftban/cron/`     | `/usr/lib/nftban/cron/`   |
| `cli/lib/nftban/tests/`    | `/usr/lib/nftban/tests/`  |

## Subdirectory Purposes

| Directory    | Purpose                                      |
|--------------|----------------------------------------------|
| `cli/`       | CLI command modules (`cmd_*.sh`)             |
| `lib/`       | Shared Bash libraries sourced by commands    |
| `core/`      | Core functionality (health, stats, output)   |
| `exporters/` | Metrics exporters (unified, prometheus, etc) |
| `helpers/`   | Helper scripts and utilities                 |
| `setup/`     | Installation and configuration scripts       |
| `cron/`      | Scheduled task scripts                       |
| `tests/`     | Test suites and validation scripts           |

## Why Paths Look "Redundant"

You may notice path repetition like:
- `cli/lib/nftban/cli/` ("cli" twice)
- `cli/lib/nftban/lib/` ("lib" twice)

This is **cosmetic, not redundancy**. Each occurrence has a different meaning:

```
cli/              <- Repo organization: "Bash CLI component" (vs pkg/ for Go)
  lib/nftban/     <- Install-mirror root: mirrors /usr/lib/nftban/
    cli/          <- Runtime: "CLI command modules"
    lib/          <- Runtime: "shared library functions"
```

## Important Notes

1. **Single Source of Truth**: This is the canonical source, not a staging copy.
   There is no separate `lib/` at repo root that this duplicates.

2. **No Drift Risk**: Install scripts copy directly from here. No generation
   step exists that could cause source/staging drift.

3. **Do Not "Fix" This Layout**: The structure is intentional and matches FHS
   conventions for the installed product.

## Install Script Reference

From `install_binaries.sh`:
```bash
cp -r "$SCRIPT_DIR/cli/lib/nftban/lib/"* "$LIB_DIR/lib/"
cp -r "$SCRIPT_DIR/cli/lib/nftban/cli/"* "$LIB_DIR/cli/"
cp -r "$SCRIPT_DIR/cli/lib/nftban/core/"* "$LIB_DIR/core/"
# ... etc
```

Where `$LIB_DIR=/usr/lib/nftban`
