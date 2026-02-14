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
	"io"
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

	// Open file with O_RDWR|O_CREATE for locking and append
	f, err := os.OpenFile(targetFile, os.O_RDWR|os.O_CREATE, 0640)
	if err != nil {
		return "", "", fmt.Errorf("failed to open %s: %w", targetFile, err)
	}
	defer f.Close()

	// Acquire exclusive lock
	// G115: f.Fd() returns uintptr, but file descriptors are small positive ints (safe)
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil { //nolint:gosec // G115: fd always fits in int
		return "", "", fmt.Errorf("failed to lock %s: %w", targetFile, err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:gosec // G115: fd always fits in int

	// Check if IP already exists in this file
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Extract IP (before any comment)
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == ip {
			return AlreadyPresent, mapping.filename, nil
		}
	}
	if err := scanner.Err(); err != nil {
		return "", "", fmt.Errorf("failed to scan %s: %w", targetFile, err)
	}

	// Seek to end for append
	stat, err := f.Stat()
	if err != nil {
		return "", "", fmt.Errorf("failed to stat %s: %w", targetFile, err)
	}

	// Add header if file is empty
	if stat.Size() == 0 {
		if _, err := f.WriteString(mapping.header); err != nil {
			return "", "", fmt.Errorf("failed to write header: %w", err)
		}
	}

	// Seek to end (after potential header write or existing content)
	if _, err := f.Seek(0, io.SeekEnd); err != nil {
		return "", "", fmt.Errorf("failed to seek: %w", err)
	}

	// Write entry
	var entry string
	if reason != "" {
		entry = fmt.Sprintf("%s  # %s\n", ip, reason)
	} else {
		entry = fmt.Sprintf("%s\n", ip)
	}

	if _, err := f.WriteString(entry); err != nil {
		return "", "", fmt.Errorf("failed to write entry: %w", err)
	}

	// Sync to disk
	if err := f.Sync(); err != nil {
		return "", "", fmt.Errorf("failed to sync %s: %w", targetFile, err)
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
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil { //nolint:gosec // G115: fd always fits in int
		return false, fmt.Errorf("failed to lock: %w", err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:gosec // G115: fd always fits in int

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
	tmpFile, err := os.OpenFile(tempPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0640)
	if err != nil {
		return false, fmt.Errorf("failed to create temp file: %w", err)
	}

	for _, line := range lines {
		if _, err := tmpFile.WriteString(line + "\n"); err != nil {
			tmpFile.Close()
			os.Remove(tempPath)
			return false, err
		}
	}

	// Sync temp file to ensure data is on disk before rename
	if err := tmpFile.Sync(); err != nil {
		tmpFile.Close()
		os.Remove(tempPath)
		return false, err
	}
	tmpFile.Close()

	// Atomic rename (POSIX guarantees atomicity on same filesystem)
	if err := os.Rename(tempPath, filePath); err != nil {
		os.Remove(tempPath)
		return false, fmt.Errorf("failed to rename temp file: %w", err)
	}

	return true, nil
}
