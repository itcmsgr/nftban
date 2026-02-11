// =============================================================================
// NFTBan - Efficient File Line Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="fileloader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Streaming file loader with atomic write operations"
// meta:input="File paths"
// meta:output="Parsed lines"
// meta:depends="bufio,os"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package util

import (
	"bufio"
	"fmt"
	"os"
)

// LoadLines reads a file line-by-line and calls the handler for each line.
// Designed for efficient processing of large files (threat feeds, logs, configs).
//
// Key optimizations:
// - Preallocated 64KB buffer prevents allocations for typical lines
// - 1MB max line length handles pathological cases safely
// - Single pass, streaming design for memory efficiency
// - Early error returns prevent partial processing
//
// The handler function receives each line as a string and can:
// - Return nil to continue processing
// - Return error to stop and propagate error
//
// Use cases in nftban v1.0:
// - Whitelist/blacklist file loading
// - Threat feed parsing
// - Suricata eve.json tailing
// - Mail/panel log parsing
// - Any line-oriented file processing
//
// Example usage:
//
//	err := util.LoadLines("/etc/nftban/whitelist.conf", func(line string) error {
//	    line = strings.TrimSpace(line)
//	    if line == "" || strings.HasPrefix(line, "#") {
//	        return nil // skip empty lines and comments
//	    }
//	    // process line...
//	    return nil
//	})
func LoadLines(path string, handle func(line string) error) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)

	// Prevent allocation on long lines
	// - Initial buffer: 64KB (typical case, no allocation needed)
	// - Max buffer: 1MB (handles pathological cases like base64 blobs)
	// This is critical for threat feeds which may have long comment lines
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		if err := handle(scanner.Text()); err != nil {
			return err
		}
	}

	return scanner.Err()
}

// RemoveLineFromFile removes lines from a file that match the given predicate.
// The predicate function receives each line and returns true if the line should be removed.
// Returns whether any lines were removed.
//
// This is used by both whitelist and blacklist packages to remove IPs from config files.
// The atomic write pattern (write to tmp, then rename) ensures file integrity.
//
// Example usage:
//
//	removed, err := util.RemoveLineFromFile("/etc/nftban/blacklist.d/99-manual.conf",
//	    func(line string) bool {
//	        ip := strings.Fields(strings.TrimSpace(line))[0]
//	        return ip == "192.168.1.100"
//	    })
func RemoveLineFromFile(filePath string, shouldRemove func(line string) bool) (bool, error) {
	file, err := os.Open(filePath)
	if err != nil {
		return false, err
	}
	defer file.Close()

	var lines []string
	found := false
	scanner := bufio.NewScanner(file)

	// Use same buffer settings as LoadLines for consistency
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		if shouldRemove(line) {
			found = true
			continue // Skip this line
		}
		lines = append(lines, line)
	}

	if err := scanner.Err(); err != nil {
		return false, err
	}

	if !found {
		return false, nil
	}

	// Atomic write: create temp file, write, then rename
	tmpFile := filePath + ".tmp"
	f, err := os.Create(tmpFile)
	if err != nil {
		return false, err
	}

	for _, line := range lines {
		if _, err := fmt.Fprintln(f, line); err != nil {
			f.Close()
			os.Remove(tmpFile)
			return false, err
		}
	}

	if err := f.Close(); err != nil {
		os.Remove(tmpFile)
		return false, err
	}

	// Replace original file atomically
	if err := os.Rename(tmpFile, filePath); err != nil {
		os.Remove(tmpFile)
		return false, err
	}

	return true, nil
}
