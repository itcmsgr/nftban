# NFTBan Public API Boundary

## Product Identity

NFTBan is a **system-level nftables IPS firewall**. It is delivered as a daemon + CLI + shell framework, installed via deb/rpm packages. It is **not** a general-purpose Go library or embeddable SDK.

## Supported Public Go Packages

| Package | Import Path | Purpose |
|---------|-------------|---------|
| `pkg/ipc` | `github.com/itcmsgr/nftban/pkg/ipc` | IPC client for daemon communication |
| `pkg/version` | `github.com/itcmsgr/nftban/pkg/version` | Version information |

These are the only packages supported for external Go import. They use only the Go standard library, contain no panics, and provide a stable contract.

## Internal Packages

All packages under `internal/` are implementation details. They:

- May change without notice between releases
- Are compiler-enforced private (Go prevents external import of `internal/` packages)
- Include detection engines, kernel access, scoring algorithms, and runtime systems
- Were never intended for external consumption

## Why IPC Is the Integration Path

NFTBan uses a single-writer architecture: all nftables kernel operations go through the `nftband` daemon. The IPC client (`pkg/ipc`) communicates with the daemon over a Unix socket at `/run/nftban/nftband.sock`.

Direct import of engine packages (nftbackend, botguard, suricata, etc.) would bypass the daemon's mutex, safety checks, and audit logging, creating race conditions and potential firewall state corruption.

## Integration Options

1. **Go programs**: Use `pkg/ipc` to communicate with the daemon
2. **Shell scripts**: Use the `nftban` CLI commands
3. **HTTP clients**: Use the daemon's HTTP API at `127.0.0.1:8080/api/`
4. **Monitoring**: Use the Prometheus exporter or Zabbix integration

## Decision History

- **v1.36.0** (2026-03-23): Moved 48 packages from `pkg/` to `internal/`. Renamed `pkg/sync` to `internal/setsync` (stdlib collision avoidance). Renamed `pkg/config` to `internal/configloader` (existing `internal/config` conflict).
- **Rationale**: 50 packages under `pkg/` appeared on pkg.go.dev as importable Go packages, creating the false impression that NFTBan is a Go SDK. 48 of these were accidental public surface with no external consumers.
