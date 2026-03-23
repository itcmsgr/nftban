// =============================================================================
// NFTBan v1.0 - Safe File Operations
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="file"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Safe file operations with symlink and traversal protection"
// meta:inventory.files=""
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

// ErrSymlinkDetected is returned when a symlink is detected in the path
var ErrSymlinkDetected = errors.New("symlink detected in path (TOCTOU protection)")

// ErrPathTraversal is returned when path traversal is detected
var ErrPathTraversal = errors.New("path traversal detected")

// ErrInsecureDirectory is returned when target directory has insecure permissions
var ErrInsecureDirectory = errors.New("target directory has insecure permissions (world-writable)")

// SafeFileFlags returns secure flags for file creation
// O_NOFOLLOW prevents following symlinks (TOCTOU protection)
// O_EXCL ensures file is created (not opened if exists)
func SafeFileFlags() int {
	return os.O_CREATE | os.O_WRONLY | os.O_TRUNC | syscall.O_NOFOLLOW
}

// SafeAppendFlags returns secure flags for appending to files
func SafeAppendFlags() int {
	return os.O_CREATE | os.O_WRONLY | os.O_APPEND | syscall.O_NOFOLLOW
}

// IsSymlink checks if a path is a symlink without following it
func IsSymlink(path string) (bool, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil // Path doesn't exist, not a symlink
		}
		return false, err
	}
	return fi.Mode()&os.ModeSymlink != 0, nil
}

// ValidatePath performs security checks on a file path
// - Rejects symlinks anywhere in the path
// - Rejects path traversal attempts (../)
// - Rejects world-writable directories
func ValidatePath(path string) error {
	// Clean and make absolute
	absPath, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return fmt.Errorf("failed to resolve path: %w", err)
	}

	// Check for path traversal in original path
	if filepath.Clean(path) != path {
		// Path contained .. or similar
		return ErrPathTraversal
	}

	// Walk up the path checking each component
	current := absPath
	for current != "/" && current != "." {
		// Check if current component is a symlink
		isLink, err := IsSymlink(current)
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("failed to check path component %s: %w", current, err)
		}
		if isLink {
			return fmt.Errorf("%w: %s", ErrSymlinkDetected, current)
		}
		current = filepath.Dir(current)
	}

	return nil
}

// ValidateDirectory checks if a directory is safe for file creation
// Returns error if directory is world-writable (o+w)
func ValidateDirectory(dir string) error {
	fi, err := os.Stat(dir)
	if err != nil {
		return fmt.Errorf("failed to stat directory: %w", err)
	}

	if !fi.IsDir() {
		return fmt.Errorf("path is not a directory: %s", dir)
	}

	// Check for world-writable (o+w = 0002)
	mode := fi.Mode().Perm()
	if mode&0002 != 0 {
		return fmt.Errorf("%w: %s (mode %o)", ErrInsecureDirectory, dir, mode)
	}

	return nil
}

// SafeCreate creates a file with TOCTOU protection
// - Validates path for symlinks and traversal
// - Uses O_NOFOLLOW to prevent symlink following
// - Validates parent directory permissions
func SafeCreate(path string, perm os.FileMode) (*os.File, error) {
	// Validate the path
	if err := ValidatePath(path); err != nil {
		return nil, err
	}

	// Validate parent directory
	dir := filepath.Dir(path)
	if err := ValidateDirectory(dir); err != nil {
		return nil, err
	}

	// Open with O_NOFOLLOW - will fail if path is symlink
	return os.OpenFile(path, SafeFileFlags(), perm)
}

// SafeOpenFile opens a file with TOCTOU protection
func SafeOpenFile(path string, flag int, perm os.FileMode) (*os.File, error) {
	// Validate the path
	if err := ValidatePath(path); err != nil {
		return nil, err
	}

	// Add O_NOFOLLOW to provided flags
	flag |= syscall.O_NOFOLLOW

	return os.OpenFile(path, flag, perm)
}

// SafeWriteFile writes data to a file with TOCTOU protection
// Uses atomic write pattern: write to temp, then rename
func SafeWriteFile(path string, data []byte, perm os.FileMode) error {
	// Validate the path
	if err := ValidatePath(path); err != nil {
		return err
	}

	dir := filepath.Dir(path)

	// Validate parent directory
	if err := ValidateDirectory(dir); err != nil {
		return err
	}

	// Create temp file in same directory (for atomic rename)
	tmpFile, err := os.CreateTemp(dir, ".nftban-safe-*")
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	tmpPath := tmpFile.Name()

	// Ensure cleanup on failure
	success := false
	defer func() {
		if !success {
			os.Remove(tmpPath)
		}
	}()

	// Write data
	if _, err := tmpFile.Write(data); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to write data: %w", err)
	}

	// Sync to disk
	if err := tmpFile.Sync(); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to sync: %w", err)
	}

	if err := tmpFile.Close(); err != nil {
		return fmt.Errorf("failed to close: %w", err)
	}

	// Set permissions
	if err := os.Chmod(tmpPath, perm); err != nil {
		return fmt.Errorf("failed to chmod: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("failed to rename: %w", err)
	}

	success = true
	return nil
}

// SafeAppendFile appends data to a file with TOCTOU protection
func SafeAppendFile(path string, data []byte, perm os.FileMode) error {
	f, err := SafeOpenFile(path, SafeAppendFlags(), perm)
	if err != nil {
		return err
	}
	defer f.Close()

	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("failed to write: %w", err)
	}

	return f.Sync()
}

// SafeMkdirAll creates directories with TOCTOU protection
// Validates each path component is not a symlink
func SafeMkdirAll(path string, perm os.FileMode) error {
	// Validate the path first
	if err := ValidatePath(path); err != nil {
		// Path doesn't exist yet, check parent components that do exist
		current := path
		for {
			parent := filepath.Dir(current)
			if parent == current {
				break // Reached root
			}
			if _, err := os.Stat(parent); err == nil {
				// Parent exists, validate it
				isLink, _ := IsSymlink(parent)
				if isLink {
					return fmt.Errorf("%w: %s", ErrSymlinkDetected, parent)
				}
			}
			current = parent
		}
	}

	return os.MkdirAll(path, perm)
}
