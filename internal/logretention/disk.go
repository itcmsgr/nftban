// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-disk"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Reads /var/log filesystem capacity + non-root-available bytes via syscall.Statfs (Linux). This is the ONE side-effecting input; it is deliberately separate from the pure Calculate() so the calculator stays deterministic. Mirrors the installer preflight statfs convention (Bavail for non-root available, Blocks for capacity, safeconv for the block-size conversion)."
// meta:depends="syscall,github.com/itcmsgr/nftban/internal/safeconv"
// meta:inventory.files="internal/logretention/disk.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package logretention

import (
	"fmt"
	"path/filepath"
	"syscall"

	"github.com/itcmsgr/nftban/internal/safeconv"
)

// DefaultLogDir is the filesystem whose capacity backs the retention budget.
const DefaultLogDir = "/var/log"

// DetectDiskFacts returns the capacity and non-root-available bytes of the
// filesystem containing path. It reads the filesystem (side effect) and is
// therefore kept out of Calculate, which takes DiskFacts as a pure input.
//
// TotalBytes uses Blocks (fundamental block count) — the stable capacity basis.
// AvailBytes uses Bavail (blocks available to non-root) — surfaced only as
// headroom/health, never as the permanent budget basis.
func DetectDiskFacts(path string) (DiskFacts, error) {
	clean := filepath.Clean(path)
	var s syscall.Statfs_t
	if err := syscall.Statfs(clean, &s); err != nil {
		return DiskFacts{}, fmt.Errorf("logretention: statfs %s: %w", clean, err)
	}
	bsize := safeconv.Int64ToUint64OrZero(s.Bsize)
	return DiskFacts{
		Path:       clean,
		TotalBytes: s.Blocks * bsize,
		AvailBytes: s.Bavail * bsize,
	}, nil
}
