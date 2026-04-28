// =============================================================================
// NFTBan v1.73 - Installer Executor Interface
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-executor"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Executor interface abstracting system commands for testability"
// meta:inventory.files="internal/installer/executor/executor.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package executor

import (
	"context"
	"os"
	"time"
)

// Result holds the output of an executed command.
type Result struct {
	ExitCode int
	Stdout   string
	Stderr   string
}

// Executor contract (frozen):
//
// Command execution:
//   - Run: execute a command, return exit code + output
//   - RunContext: execute with context (for timeout/cancellation)
//
// File operations:
//   - ReadFile / WriteFileAtomic / FileExists / MkdirAll
//   - Chown / Chmod / Remove / Symlink
//
// nftables queries:
//   - NftTableExists / NftListSet / NftAddElement / NftDeleteTable / NftCheck
//
// systemd:
//   - ServiceActive / ServiceEnable / ServiceStart / ServiceStop
//   - ServiceDisable / ServiceMask / ServiceUnmask / DaemonReload
//
// File operations (atomic):
//   - Rename — atomic same-filesystem rename via os.Rename
//
// System:
//   - CommandExists / UserExists / GroupExists / Getenv
type Executor interface {
	// Run executes a command and returns the result. Timeout defaults to 30s.
	Run(name string, args ...string) Result

	// RunContext executes a command with the given context for cancellation/timeout.
	RunContext(ctx context.Context, name string, args ...string) Result

	// RunTimeout is a convenience wrapper: creates a context with the given timeout.
	RunTimeout(timeout time.Duration, name string, args ...string) Result

	// ReadFile reads the contents of a file.
	ReadFile(path string) ([]byte, error)

	// WriteFileAtomic writes data to a temp file then renames to path (atomic on same FS).
	WriteFileAtomic(path string, data []byte, perm os.FileMode) error

	// FileExists returns true if path exists (file or directory).
	FileExists(path string) bool

	// MkdirAll creates a directory tree (like os.MkdirAll).
	MkdirAll(path string, perm os.FileMode) error

	// Chown changes file ownership.
	Chown(path string, uid, gid int) error

	// Chmod changes file permissions.
	Chmod(path string, perm os.FileMode) error

	// Remove deletes a file or empty directory.
	Remove(path string) error

	// Symlink creates a symbolic link (newname -> oldname).
	Symlink(oldname, newname string) error

	// Rename atomically renames oldpath to newpath. Same-filesystem
	// semantics equivalent to syscall.Rename. Implementations route
	// through whatever primitive their host abstraction provides
	// (RealExecutor uses os.Rename; MockExecutor records the call and
	// updates its in-memory file map).
	//
	// Added in PR-26-code-B per §43.2 lock to replace the previous
	// Run("mv", ...) indirection used by restore_deps_csf.go's A.3
	// binary-restore step. Mutation surface is bounded by
	// INV-PR26-NEW-MUTATION-SURFACES-BOUNDED (§44 row 2).
	Rename(oldpath, newpath string) error

	// NftTableExists returns true if the given nft table exists in the kernel.
	// family: "ip", "ip6", or "inet". table: e.g. "nftban".
	NftTableExists(family, table string) bool

	// NftListSet returns the elements of an nft set as a raw string.
	// Returns ("", error) if the set does not exist.
	NftListSet(family, table, set string) (string, error)

	// NftAddElement adds an element to an nft set.
	NftAddElement(family, table, set string, element string) error

	// NftDeleteTable deletes an nft table. Ignores "not found" errors.
	NftDeleteTable(family, table string) error

	// NftCheck runs nft -c -f on the given config content (syntax validation).
	// Returns nil if valid, error with details if invalid.
	NftCheck(configContent string) error

	// ServiceActive returns true if the systemd unit is active.
	ServiceActive(unit string) bool

	// ServiceEnable enables a systemd unit.
	ServiceEnable(unit string) error

	// ServiceStart starts a systemd unit.
	ServiceStart(unit string) error

	// ServiceStop stops a systemd unit.
	ServiceStop(unit string) error

	// ServiceDisable disables a systemd unit.
	ServiceDisable(unit string) error

	// ServiceMask masks a systemd unit (prevents start by any means).
	ServiceMask(unit string) error

	// ServiceUnmask unmasks a systemd unit (inverse of ServiceMask).
	// Used by the CSF restore A.1 step. Added in PR-26-code-B per
	// §43.2 lock to replace the previous
	// Run("systemctl", "unmask", ...) indirection. Mutation surface
	// is bounded by INV-PR26-NEW-MUTATION-SURFACES-BOUNDED (§44 row 2).
	ServiceUnmask(unit string) error

	// DaemonReload runs systemctl daemon-reload.
	DaemonReload() error

	// CommandExists returns true if the named command is in PATH.
	CommandExists(name string) bool

	// UserExists returns true if the named system user exists.
	UserExists(name string) bool

	// GroupExists returns true if the named system group exists.
	GroupExists(name string) bool

	// Getenv returns the value of an environment variable.
	Getenv(key string) string
}
