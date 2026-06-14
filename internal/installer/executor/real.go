// =============================================================================
// NFTBan v1.73 - Installer Real Executor
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-executor-real"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Production executor using os/exec and syscalls"
// meta:inventory.files="internal/installer/executor/real.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package executor

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// defaultTimeout for commands without an explicit timeout.
const defaultTimeout = 30 * time.Second

// RealExecutor implements Executor using real system calls.
type RealExecutor struct{}

var _ Executor = (*RealExecutor)(nil)

func (r *RealExecutor) Run(name string, args ...string) Result {
	return r.RunTimeout(defaultTimeout, name, args...)
}

func (r *RealExecutor) RunContext(ctx context.Context, name string, args ...string) Result {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	exitCode := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			// Command not found, permission denied, etc.
			return Result{ExitCode: -1, Stdout: stdout.String(), Stderr: err.Error()}
		}
	}
	return Result{ExitCode: exitCode, Stdout: stdout.String(), Stderr: stderr.String()}
}

func (r *RealExecutor) RunTimeout(timeout time.Duration, name string, args ...string) Result {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return r.RunContext(ctx, name, args...)
}

func (r *RealExecutor) ReadFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

func (r *RealExecutor) WriteFileAtomic(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".nftban-installer-*.tmp")
	if err != nil {
		return fmt.Errorf("create temp for %s: %w", path, err)
	}
	tmpName := tmp.Name()

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return fmt.Errorf("write temp for %s: %w", path, err)
	}
	if err := tmp.Chmod(perm); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return fmt.Errorf("chmod temp for %s: %w", path, err)
	}
	// fsync the temp file before rename so a crash right after the rename
	// cannot leave a renamed-but-empty/partial file on the target path.
	// Directory fsync is intentionally omitted (an old-but-complete version
	// after a crash is acceptable here; see the F-3 DIR-FSYNC decision note).
	if err := tmp.Sync(); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
		return fmt.Errorf("sync temp for %s: %w", path, err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("close temp for %s: %w", path, err)
	}
	return os.Rename(tmpName, path)
}

func (r *RealExecutor) FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (r *RealExecutor) MkdirAll(path string, perm os.FileMode) error {
	return os.MkdirAll(path, perm)
}

func (r *RealExecutor) Chown(path string, uid, gid int) error {
	return os.Chown(path, uid, gid)
}

func (r *RealExecutor) Chmod(path string, perm os.FileMode) error {
	return os.Chmod(path, perm)
}

func (r *RealExecutor) Remove(path string) error {
	return os.Remove(path)
}

func (r *RealExecutor) Symlink(oldname, newname string) error {
	// Remove existing symlink first (idempotent)
	os.Remove(newname)
	return os.Symlink(oldname, newname)
}

// Rename atomically renames oldpath to newpath via os.Rename. Same-
// filesystem semantics; cross-filesystem renames will return an error
// per the os.Rename contract (the caller must ensure same-FS).
//
// Added in PR-26-code-B per §43.2: replaces the prior Run("mv", ...)
// indirection used by restore_deps_csf.go's A.3 step. Routing through
// os.Rename (rather than shelling to mv) avoids a process spawn and
// gives a typed error path consistent with WriteFileAtomic.
func (r *RealExecutor) Rename(oldpath, newpath string) error {
	return os.Rename(oldpath, newpath)
}

// Stat returns FileMeta (mode/uid/gid/size) via os.Stat +
// syscall.Stat_t. Read-only introspection. Added in PR-26-code-C
// for the CSF cron-backup manifest writer + reader.
//
// On non-POSIX hosts (Windows), uid/gid extraction would not work as
// written; the production target is Linux only, so this is acceptable.
func (r *RealExecutor) Stat(path string) (FileMeta, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return FileMeta{}, err
	}
	meta := FileMeta{
		Mode: fi.Mode().Perm(),
		Size: fi.Size(),
	}
	if sys, ok := fi.Sys().(*syscall.Stat_t); ok {
		meta.UID = int(sys.Uid)
		meta.GID = int(sys.Gid)
	}
	return meta, nil
}

// --- nftables ---

func (r *RealExecutor) NftTableExists(family, table string) bool {
	res := r.Run("nft", "list", "table", family, table)
	return res.ExitCode == 0
}

func (r *RealExecutor) NftListSet(family, table, set string) (string, error) {
	res := r.Run("nft", "list", "set", family, table, set)
	if res.ExitCode != 0 {
		return "", fmt.Errorf("nft list set %s %s %s: %s", family, table, set, strings.TrimSpace(res.Stderr))
	}
	return res.Stdout, nil
}

func (r *RealExecutor) NftAddElement(family, table, set string, element string) error {
	res := r.Run("nft", "add", "element", family, table, set, "{ "+element+" }")
	if res.ExitCode != 0 {
		return fmt.Errorf("nft add element: %s", strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) NftDeleteTable(family, table string) error {
	res := r.Run("nft", "delete", "table", family, table)
	if res.ExitCode != 0 {
		// Ignore "no such table" — expected for cleanup
		if strings.Contains(res.Stderr, "No such") || strings.Contains(res.Stderr, "does not exist") {
			return nil
		}
		return fmt.Errorf("nft delete table %s %s: %s", family, table, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) NftCheck(configContent string) error {
	// Write content to temp file, then nft -c -f
	tmp, err := os.CreateTemp("", "nftban-check-*.nft")
	if err != nil {
		return fmt.Errorf("create temp for nft check: %w", err)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.WriteString(configContent); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp for nft check: %w", err)
	}
	tmp.Close()

	res := r.RunTimeout(10*time.Second, "nft", "-c", "-f", tmp.Name())
	if res.ExitCode != 0 {
		return fmt.Errorf("nft syntax check failed: %s", strings.TrimSpace(res.Stderr))
	}
	return nil
}

// --- systemd ---

func (r *RealExecutor) ServiceActive(unit string) bool {
	res := r.Run("systemctl", "is-active", "--quiet", unit)
	return res.ExitCode == 0
}

func (r *RealExecutor) ServiceEnabled(unit string) bool {
	res := r.Run("systemctl", "is-enabled", "--quiet", unit)
	return res.ExitCode == 0
}

func (r *RealExecutor) ServiceEnable(unit string) error {
	res := r.Run("systemctl", "enable", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl enable %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) ServiceStart(unit string) error {
	res := r.RunTimeout(60*time.Second, "systemctl", "start", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl start %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) ServiceStop(unit string) error {
	res := r.RunTimeout(30*time.Second, "systemctl", "stop", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl stop %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

// ServiceTryRestart restarts the unit iff it is active (no-op if inactive).
// v1.185 INSTALL-UPGRADE-NO-DAEMON-RESTART: loads the newly-installed binary on an
// upgrade over a live daemon without forcing a start on a deliberately-stopped unit.
func (r *RealExecutor) ServiceTryRestart(unit string) error {
	res := r.RunTimeout(90*time.Second, "systemctl", "try-restart", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl try-restart %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) ServiceDisable(unit string) error {
	res := r.Run("systemctl", "disable", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl disable %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) ServiceMask(unit string) error {
	res := r.Run("systemctl", "mask", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl mask %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) ServiceUnmask(unit string) error {
	res := r.Run("systemctl", "unmask", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl unmask %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) ServiceResetFailed(unit string) error {
	res := r.Run("systemctl", "reset-failed", unit)
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl reset-failed %s: %s", unit, strings.TrimSpace(res.Stderr))
	}
	return nil
}

func (r *RealExecutor) DaemonReload() error {
	res := r.Run("systemctl", "daemon-reload")
	if res.ExitCode != 0 {
		return fmt.Errorf("systemctl daemon-reload: %s", strings.TrimSpace(res.Stderr))
	}
	return nil
}

// --- System ---

func (r *RealExecutor) CommandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func (r *RealExecutor) UserExists(name string) bool {
	_, err := user.Lookup(name)
	return err == nil
}

func (r *RealExecutor) GroupExists(name string) bool {
	_, err := user.LookupGroup(name)
	return err == nil
}

func (r *RealExecutor) Getenv(key string) string {
	return os.Getenv(key)
}
