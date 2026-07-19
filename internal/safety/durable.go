// =============================================================================
// NFTBan v1.222 - Durable (power-loss-safe) file primitives
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="durable"
// meta:type="lib"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-20"
// meta:description="Power-loss-durable file primitives shared by the durability idioms. A file rename is only durable across a crash once the PARENT DIRECTORY has itself been fsync'd — otherwise the new directory entry may be lost even though the file data was flushed. FsyncDir flushes a directory; WriteFileDurable is SafeWriteFile plus that directory fsync (so the atomic rename survives power loss); DurableRename is os.Rename plus a destination-directory fsync; StageFile writes a candidate into a trusted staging directory (file fsync + directory fsync) without activating any final target. These are the guard-exempt low-level ops the logretention two-file activation transaction routes through so it holds no raw temp+rename writer of its own."
// meta:depends="os,path/filepath"
// meta:inventory.files="internal/safety/durable.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// FsyncDir flushes a directory's own metadata (its entries) to stable storage so
// that a file created or renamed inside it survives a power loss. Without this,
// an atomic rename can be lost after a crash even though the file's data was
// fsync'd — the directory entry pointing at it was never flushed.
//
// Some filesystems (and every non-directory target) reject fsync on a directory
// with EINVAL; that is not a durability failure on those filesystems, so it is
// reported as success. All other open/sync errors are propagated.
func FsyncDir(dir string) error {
	d, err := os.Open(dir) // #nosec G304 -- caller-owned directory path; opened read-only solely to fsync its entries
	if err != nil {
		return fmt.Errorf("fsync dir: open %s: %w", dir, err)
	}
	syncErr := d.Sync()
	closeErr := d.Close()
	if syncErr != nil {
		// Filesystems that do not implement fsync on a directory return EINVAL —
		// treat that as a no-op rather than a durability failure.
		if errors.Is(syncErr, syscall.EINVAL) {
			return closeErr
		}
		return fmt.Errorf("fsync dir: sync %s: %w", dir, syncErr)
	}
	return closeErr
}

// WriteFileDurable writes data to path atomically AND durably: it inherits every
// guarantee of SafeWriteFile (symlink/traversal validation, temp-in-dir, file
// fsync, chmod, atomic rename, cleanup on failure) and ADDS a fsync of the
// target's parent directory after the rename, so the replacement survives a power
// loss. This is the primitive every atomic state writer should use; SafeWriteFile
// delegates to it so the whole repo gets the directory-fsync fix.
func WriteFileDurable(path string, data []byte, perm os.FileMode) error {
	if err := ValidatePath(path); err != nil {
		return err
	}

	dir := filepath.Dir(path)
	if err := ValidateDirectory(dir); err != nil {
		return err
	}

	tmpFile, err := os.CreateTemp(dir, ".nftban-safe-*") // #nosec G304 -- temp created inside the caller-validated destination directory
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	success := false
	defer func() {
		if !success {
			_ = os.Remove(tmpPath)
		}
	}()

	if _, err := tmpFile.Write(data); err != nil {
		_ = tmpFile.Close()
		return fmt.Errorf("failed to write data: %w", err)
	}
	if err := tmpFile.Sync(); err != nil {
		_ = tmpFile.Close()
		return fmt.Errorf("failed to sync: %w", err)
	}
	if err := tmpFile.Close(); err != nil {
		return fmt.Errorf("failed to close: %w", err)
	}
	if err := os.Chmod(tmpPath, perm); err != nil {
		return fmt.Errorf("failed to chmod: %w", err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("failed to rename: %w", err)
	}
	// Durability: the rename created a new directory entry; flush the directory so
	// that entry survives a crash. Best-effort on filesystems without dir fsync.
	if err := FsyncDir(dir); err != nil {
		return fmt.Errorf("failed to fsync dir after rename: %w", err)
	}

	success = true
	return nil
}

// DurableRename renames oldpath to newpath and fsyncs the destination directory
// so the rename survives a power loss. Both paths must be on the same filesystem
// (rename is atomic only within a filesystem). Used by the logretention
// activation/rollback/recovery so every target and staging mutation is durable.
func DurableRename(oldpath, newpath string) error {
	if err := os.Rename(oldpath, newpath); err != nil {
		return fmt.Errorf("durable rename %s -> %s: %w", oldpath, newpath, err)
	}
	if err := FsyncDir(filepath.Dir(newpath)); err != nil {
		return fmt.Errorf("durable rename: fsync dest dir: %w", err)
	}
	return nil
}

// StageFile writes data as a fresh candidate file inside dir (a trusted staging
// directory) and returns its path. The candidate's contents are fsync'd and the
// staging directory itself is fsync'd, so the staged file's directory entry is
// durable before it is later activated by a rename. It never touches or activates
// any final target. pattern follows os.CreateTemp semantics (a trailing '*' is
// replaced by a random string).
func StageFile(dir, pattern string, data []byte, perm os.FileMode) (string, error) {
	if err := ValidateDirectory(dir); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(dir, pattern) // #nosec G304 -- staged file created inside the caller-validated staging directory
	if err != nil {
		return "", fmt.Errorf("stage file in %s: %w", dir, err)
	}
	name := f.Name()
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		_ = os.Remove(name)
		return "", fmt.Errorf("stage file write: %w", err)
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(name)
		return "", fmt.Errorf("stage file sync: %w", err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(name)
		return "", fmt.Errorf("stage file close: %w", err)
	}
	if err := os.Chmod(name, perm); err != nil {
		_ = os.Remove(name)
		return "", fmt.Errorf("stage file chmod: %w", err)
	}
	// Make the staged file's directory entry durable before it becomes an
	// activation source.
	if err := FsyncDir(dir); err != nil {
		_ = os.Remove(name)
		return "", fmt.Errorf("stage file fsync dir: %w", err)
	}
	return name, nil
}
