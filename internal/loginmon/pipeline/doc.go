// =============================================================================
// NFTBan v1.80 - Detection pipeline (Phase A foundation)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: pipeline
// Purpose: Top-level documentation for the v1.80 Go detection pipeline.
//
// meta:name="loginmon_pipeline"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="pipeline"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="v1.80 Phase A: Go pipeline foundation (framework only)"
//
// meta:inventory.files="doc.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package pipeline contains the v1.80 Go detection pipeline foundation.
//
// PHASE A SCOPE
//
// Phase A is the structural skeleton only. It provides the abstractions and
// composition root that future phases will populate with real parser
// implementations. Phase A must NOT:
//
//   - migrate any existing parser (mail, panel, ssh, etc.)
//   - change scoring or banning logic
//   - touch the nftables write path
//   - introduce runtime coupling with the existing loginmon detector
//
// Phase A MUST:
//
//   - compile cleanly with stdlib-only dependencies
//   - be testable in isolation (no external services, no real files in tests)
//   - reuse the v1.79.2 distroconf truth surface (no path discovery duplication)
//   - support incremental per-parser migration (Phase B onward)
//
// PIPELINE FLOW
//
//	source -> watcher -> RawLine -> parser -> NormalizedEvent -> normalize ->
//	dedup -> aggregate -> Snapshot
//
// Each stage is a one-way pipe. No stage reads downstream state. The
// aggregator publishes a snapshot; downstream consumers (CLI, validator,
// future scoring) read the snapshot but do not call back.
//
// IMPORT DAG (enforced by package layout, no cycles)
//
//	event       (stdlib only)
//	normalize -> event
//	dedup     -> event
//	aggregate -> event
//	watcher   -> event
//	source    -> event + internal/loginmon/distroconf
//	runtime   -> all of the above
//
// MIGRATION READINESS
//
// Phase B (DirectAdmin parser) plugs in by:
//
//  1. Implementing runtime.Parser for the DA log line format
//  2. Constructing a source.Descriptor via distroconf.Resolve("directadmin_login_log")
//  3. Constructing a watcher.PollingWatcher for the resolved path
//  4. Calling pipeline.Register(source, watcher, parser)
//
// No changes to existing internal/loginmon/detector/panel.go are required.
// The two paths coexist until the legacy parser is retired (see DEC-1..9 in
// MASTER_TODO.md).
//
// NON-GOALS (Phase A explicitly does NOT include)
//
//   - HTTP / wp-login parser
//   - FTP / pure-ftpd parser
//   - Roundcube parser
//   - scoring or ban decisions
//   - CLI integration
//   - IPC plumbing
//   - persistent cursor storage
//   - cross-host correlation
//   - external message bus
package pipeline
