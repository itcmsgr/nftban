// =============================================================================
// NFTBan v1.125 — Installer Disk-Space Preflight (V125 R-5)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-preflight-disk"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-22"
// meta:description="syscall.Statfs-based disk-space preflight; refuses installer runs that would ENOSPC mid-phase"
// meta:inventory.files="internal/installer/preflight/disk.go,internal/installer/preflight/disk_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_MIN_DISK_FREE_MB"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// V125 R-5 — closes the ENOSPC-mid-install class identified in the V125
// install-robustness audit (AUDIT_190_LIFECYCLE/V125_INSTALL_ROBUSTNESS_SCOPE.md
// §3.1 R-5). Without a preflight, an installer run on a host already at
// 95%+ disk utilization could partially complete phasePrepare (mkdir, FHS
// setup) then ENOSPC mid-write to install_state, mid-render of
// nftables.conf, or mid-fhs.SetPermissions — leaving the host in an
// inconsistent state that's harder to recover than a clean refusal.
//
// Mechanism
// ─────────
// EnsureMinDiskFree uses syscall.Statfs on the target path's filesystem
// and compares the non-root-available bytes (Bavail * Bsize) against the
// caller-supplied minimum. The "non-root available" calculation (Bavail)
// matches what the installer's writes can actually consume, NOT total
// free space (Bfree, which includes the root-reserved tail).
//
// MinDiskFreeBytes returns the operator-tunable threshold, defaulting to
// 500 MB and honoring NFTBAN_MIN_DISK_FREE_MB. Invalid env values fall
// back to default — this is a safety gate, not a parser; a typo'd env
// var must not silently weaken protection.
//
// Scope boundaries
// ────────────────
// - Linux-only (uses syscall.Statfs). The installer is already Linux-only,
//   so no cross-platform conditional compilation is needed.
// - Read-only: Statfs makes no filesystem mutation. Safe to call during
//   any dry-run gate that reaches phaseDetect (though install --dry-run
//   is refused at flag-parse and update/uninstall --dry-run forks before
//   phases, so this is defense in depth).
// - No daemon, schema, metrics, packaging, systemd, polkit, or
//   release-process surface touched.
// =============================================================================

package preflight

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

// DefaultMinDiskFreeBytes is the V125 R-5 default minimum free space
// (500 MB) required on the state directory's filesystem before the
// installer proceeds with phasePrepare's potential dnf/apt installs and
// file writes. Chosen as a conservative envelope covering:
//   - dnf/apt cache + downloaded packages on a typical install (~150 MB)
//   - FHS payload staging in /usr/lib/nftban (~50 MB)
//   - nftables.conf renders (~1 MB)
//   - install_state + update-history.json + lock file (<1 MB)
//   - GeoIP database (~250 MB on full updates; rarer)
//   - headroom for unforeseen growth
const DefaultMinDiskFreeBytes uint64 = 500 * 1024 * 1024

// EnvMinDiskFreeMB is the environment variable name operators can use to
// override the default minimum free space. Value is interpreted as
// megabytes. Invalid values (non-numeric, zero, parse error) fall back
// to default.
const EnvMinDiskFreeMB = "NFTBAN_MIN_DISK_FREE_MB"

// EnsureMinDiskFree returns nil if the filesystem containing path has at
// least minBytes of free space available to non-root processes. Returns
// a descriptive error otherwise.
//
// Uses syscall.Statfs (Linux-only; the installer is Linux-only). The
// "free" calculation uses Bavail (blocks available to non-root) rather
// than Bfree (total free blocks including root-reserved space), since
// the installer's writes consume non-root-reserved space.
//
// Path is filepath.Clean()-sanitized at the call site. While syscall.Statfs
// isn't on gosec's G304 fixed-list (it doesn't open or read file content),
// applying Clean is consistent with the project convention and defensive
// against future scanner additions.
func EnsureMinDiskFree(path string, minBytes uint64) error {
	cleanPath := filepath.Clean(path)
	var s syscall.Statfs_t
	if err := syscall.Statfs(cleanPath, &s); err != nil {
		return fmt.Errorf("preflight: statfs %s: %w", cleanPath, err)
	}
	// Bavail = blocks available to non-root; Bsize = fundamental block size.
	// Multiplication is bounds-safe for any realistic filesystem
	// (uint64 * positive-int-32-as-uint64 fits in uint64 until total
	// would exceed 16 EB, well beyond any real-world filesystem).
	avail := uint64(s.Bavail) * uint64(s.Bsize)
	if avail < minBytes {
		return fmt.Errorf("preflight: insufficient disk space at %s: %d bytes available, %d bytes required (set %s to override)",
			cleanPath, avail, minBytes, EnvMinDiskFreeMB)
	}
	return nil
}

// MinDiskFreeBytes returns the minimum free-space threshold to enforce,
// honoring the NFTBAN_MIN_DISK_FREE_MB environment variable when set and
// parsable as a positive integer megabyte count, and falling back to
// DefaultMinDiskFreeBytes otherwise.
//
// Invalid env values (non-numeric, zero, negative, overflow, parse error)
// fall back to default — this is a preflight safety gate, not a parser;
// we don't want a typo'd env var to silently weaken protection.
func MinDiskFreeBytes() uint64 {
	s := os.Getenv(EnvMinDiskFreeMB)
	if s == "" {
		return DefaultMinDiskFreeBytes
	}
	mb, err := strconv.ParseUint(s, 10, 64)
	if err != nil || mb == 0 {
		return DefaultMinDiskFreeBytes
	}
	// Overflow check: mb * 1MB must fit in uint64. Practically impossible
	// to hit (mb would need to exceed 16 EB / 1MB = 16 PB), but explicit
	// safe-math is cheap and prevents wraparound.
	const maxMB = ^uint64(0) / (1024 * 1024)
	if mb > maxMB {
		return DefaultMinDiskFreeBytes
	}
	return mb * 1024 * 1024
}
