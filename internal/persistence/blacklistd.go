// =============================================================================
// NFTBan v1.0 - Persistence Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="blacklistd"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Persistent ban storage in /etc/nftban/blacklist.d/"
// meta:inventory.files="/etc/nftban/blacklist.d"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package persistence

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// Result indicates the outcome of a persistence operation
type Result string

const (
	Created        Result = "created"
	AlreadyPresent Result = "already_present"
)

// fileMapping maps source to filename and header
var fileMapping = map[string]struct {
	filename string
	header   string
}{
	"login": {
		filename: "login-auto.conf",
		header:   "# Login Monitor Auto-Ban Entries\n# Added automatically by nftban-login-monitor\n# Format: IP  # reason\n\n",
	},
	"portscan": {
		filename: "portscan-auto.conf",
		header:   "# Port Scan Auto-Ban Entries\n# Added automatically by nftban-portscan\n# Format: IP  # reason\n\n",
	},
	"ddos": {
		filename: "ddos-auto.conf",
		header:   "# DDoS Auto-Ban Entries\n# Added automatically by nftban-ddos\n# Format: IP  # reason\n\n",
	},
	"persistent": {
		filename: "30-persistent-offenders.conf",
		header:   "# Persistent Offenders - Permanent Bans\n# IPs that exceeded ban thresholds and were escalated\n# Format: IP  # reason\n\n",
	},
	"manual": {
		filename: "99-manual.conf",
		header:   "# Manual Blacklist Entries\n# Added via nftban ban command\n# Format: IP  # reason\n\n",
	},
}

// PersistBan adds an IP to the persistent blacklist files.
// Uses flock for safe concurrent access.
//
// Parameters:
//   - configDir: base config directory (e.g., /etc/nftban)
//   - ip: normalized IP address (must be valid)
//   - reason: ban reason (optional)
//   - source: determines target file (login/portscan/ddos/persistent/manual)
//
// Returns:
//   - Result: Created or AlreadyPresent
//   - string: filename that was written to
//   - error: on I/O failure or invalid input
func PersistBan(configDir, ip, reason, source string) (Result, string, error) {
	// Validate IP format (basic check - daemon should pass normalized IP)
	if net.ParseIP(ip) == nil {
		// Check CIDR
		_, _, err := net.ParseCIDR(ip)
		if err != nil {
			return "", "", fmt.Errorf("invalid IP address: %s", ip)
		}
	}

	// Determine target file
	mapping, ok := fileMapping[source]
	if !ok {
		mapping = fileMapping["manual"]
	}

	blacklistDir := filepath.Join(configDir, "blacklist.d")
	targetFile := filepath.Join(blacklistDir, mapping.filename)

	// Ensure directory exists (should already exist, but be safe)
	if err := os.MkdirAll(blacklistDir, 0750); err != nil {
		return "", "", fmt.Errorf("failed to create blacklist.d: %w", err)
	}

	// D-UXV-17: serialize the entire read-modify-rename on a STABLE sibling
	// lockfile that is NEVER renamed. Flocking targetFile's own fd is unsafe
	// here because the atomic rename below replaces the inode — a concurrent
	// writer that opens+flocks the new inode is not excluded and can clobber
	// this write (e.g. the old unlocked AddToPersistentOffenders append, now
	// also routed through PersistBan). The ".lock" suffix is not "*.conf" so
	// the blacklist loaders (internal/blacklist/loader.go, shell *.conf globs)
	// never parse it as IPs.
	lockPath := targetFile + ".lock"
	lockF, err := os.OpenFile(lockPath, os.O_RDWR|os.O_CREATE, 0640) // #nosec G304 -- path derived from validated mapping
	if err != nil {
		return "", "", fmt.Errorf("failed to open lock %s: %w", lockPath, err)
	}
	defer lockF.Close()
	// G115: Fd() returns uintptr, but a file descriptor always fits in int.
	if err := syscall.Flock(int(lockF.Fd()), syscall.LOCK_EX); err != nil { // #nosec G115
		return "", "", fmt.Errorf("failed to lock %s: %w", lockPath, err)
	}
	defer func() { _ = syscall.Flock(int(lockF.Fd()), syscall.LOCK_UN) }() // #nosec G115

	// Open the target read-only for the dedup scan (create if missing). The
	// lockfile above — not this fd — provides mutual exclusion across the rename.
	f, err := os.OpenFile(targetFile, os.O_RDONLY|os.O_CREATE, 0640) // #nosec G304 -- path derived from validated mapping
	if err != nil {
		return "", "", fmt.Errorf("failed to open %s: %w", targetFile, err)
	}
	defer f.Close()

	// Read all existing lines, checking for duplicate IP
	var lines []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		lines = append(lines, line)
		trimmed := strings.TrimSpace(line)
		// Skip empty lines and comments
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		// Extract IP (before any comment)
		fields := strings.Fields(trimmed)
		if len(fields) > 0 && fields[0] == ip {
			return AlreadyPresent, mapping.filename, nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", "", fmt.Errorf("failed to scan %s: %w", targetFile, err)
	}

	// Build new entry
	var entry string
	if reason != "" {
		entry = fmt.Sprintf("%s  # %s", ip, reason)
	} else {
		entry = ip
	}

	// Write to temp file in same directory (required for atomic rename)
	tempPath := targetFile + ".tmp"
	tmpFile, err := os.OpenFile(tempPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600) // #nosec G304 -- path validated via configMappings
	if err != nil {
		return "", "", fmt.Errorf("failed to create temp file: %w", err)
	}

	// Write header if file was empty (no existing lines)
	if len(lines) == 0 {
		if _, err := tmpFile.WriteString(mapping.header); err != nil {
			_ = tmpFile.Close()
			_ = os.Remove(tempPath)
			return "", "", fmt.Errorf("failed to write header: %w", err)
		}
	} else {
		// Write existing lines
		for _, line := range lines {
			if _, err := tmpFile.WriteString(line + "\n"); err != nil {
				_ = tmpFile.Close()
				_ = os.Remove(tempPath)
				return "", "", fmt.Errorf("failed to write existing content: %w", err)
			}
		}
	}

	// Append new entry
	if _, err := tmpFile.WriteString(entry + "\n"); err != nil {
		_ = tmpFile.Close()
		_ = os.Remove(tempPath)
		return "", "", fmt.Errorf("failed to write entry: %w", err)
	}

	// Sync temp file to ensure data is on disk before rename
	if err := tmpFile.Sync(); err != nil {
		_ = tmpFile.Close()
		_ = os.Remove(tempPath)
		return "", "", fmt.Errorf("failed to sync temp file: %w", err)
	}
	_ = tmpFile.Close()

	// Atomic rename (POSIX guarantees atomicity on same filesystem)
	if err := os.Rename(tempPath, targetFile); err != nil {
		_ = os.Remove(tempPath) // Best effort cleanup; ignore error
		return "", "", fmt.Errorf("failed to rename temp file: %w", err)
	}

	return Created, mapping.filename, nil
}

// UnpersistBan removes an IP from all blacklist files.
// Uses flock for safe concurrent access.
//
// Returns the number of files modified and any error.
func UnpersistBan(configDir, ip string) (int, error) {
	// Validate IP format
	if net.ParseIP(ip) == nil {
		_, _, err := net.ParseCIDR(ip)
		if err != nil {
			return 0, fmt.Errorf("invalid IP address: %s", ip)
		}
	}

	blacklistDir := filepath.Join(configDir, "blacklist.d")

	// Find all .conf files
	entries, err := os.ReadDir(blacklistDir)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil // No blacklist.d = nothing to remove
		}
		return 0, fmt.Errorf("failed to read blacklist.d: %w", err)
	}

	modified := 0
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}

		filePath := filepath.Join(blacklistDir, entry.Name())
		removed, err := removeIPFromFile(filePath, ip)
		if err != nil {
			return modified, fmt.Errorf("failed to process %s: %w", entry.Name(), err)
		}
		if removed {
			modified++
		}
	}

	return modified, nil
}

// removeIPFromFile removes an IP from a single file using atomic rewrite.
// Uses flock for concurrency + temp+rename for crash safety.
func removeIPFromFile(filePath, ip string) (bool, error) {
	// Open original file for locking and reading
	f, err := os.OpenFile(filePath, os.O_RDONLY, 0640)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	defer f.Close()

	// Acquire exclusive lock on original file
	// This serializes concurrent access even across processes
	// G115: f.Fd() returns uintptr, but file descriptors are small positive ints (safe)
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil { // #nosec G115 -: fd always fits in int
		return false, fmt.Errorf("failed to lock: %w", err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) // #nosec G115 -: fd always fits in int

	// Read all lines, filtering out the target IP
	var lines []string
	found := false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)

		// Check if this line contains the IP
		if trimmed != "" && !strings.HasPrefix(trimmed, "#") {
			fields := strings.Fields(trimmed)
			if len(fields) > 0 && fields[0] == ip {
				found = true
				continue // Skip this line
			}
		}
		lines = append(lines, line)
	}
	if err := scanner.Err(); err != nil {
		return false, err
	}

	if !found {
		return false, nil
	}

	// Write to temp file in same directory (required for atomic rename)
	tempPath := filePath + ".tmp"
	tmpFile, err := os.OpenFile(tempPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600) // #nosec G304 -- path validated
	if err != nil {
		return false, fmt.Errorf("failed to create temp file: %w", err)
	}

	for _, line := range lines {
		if _, err := tmpFile.WriteString(line + "\n"); err != nil {
			_ = tmpFile.Close()
			_ = os.Remove(tempPath)
			return false, err
		}
	}

	// Sync temp file to ensure data is on disk before rename
	if err := tmpFile.Sync(); err != nil {
		_ = tmpFile.Close()
		_ = os.Remove(tempPath)
		return false, err
	}
	_ = tmpFile.Close()

	// Atomic rename (POSIX guarantees atomicity on same filesystem)
	if err := os.Rename(tempPath, filePath); err != nil {
		_ = os.Remove(tempPath)
		return false, fmt.Errorf("failed to rename temp file: %w", err)
	}

	return true, nil
}
