// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/file_reader" meta:type="package" meta:version="1.1.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Secure file reading for OpQueue replace_set"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"

package opqueue

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"syscall"
)

const (
	maxFileSize  = 100 * 1024 * 1024 // 100MB max
	maxLineCount = 1_000_000         // 1M elements max
	maxLineLen   = 64 * 1024         // 64KB per line (bufio default)
)

// allowedPrefixes defines safe directories for file reading
var allowedPrefixes = []string{
	"/var/cache/nftban/",
	"/var/lib/nftban/",
	"/tmp/nftban-",
}

// FileReadResult contains the result of reading a file
type FileReadResult struct {
	Elements []string
	Count    int
}

// SecureReadElementsFile reads elements from a file with security checks
// Security measures:
// 1. Path prefix validation
// 2. Symlink rejection (O_NOFOLLOW + Lstat)
// 3. Regular file check
// 4. Size limit
// 5. Ownership check (root or nftban)
// 6. World-writable check
// 7. TOCTOU protection (inode verification)
// 8. Line count limit
func SecureReadElementsFile(path string) (*FileReadResult, error) {
	// 1. Validate path prefix
	allowed := false
	for _, prefix := range allowedPrefixes {
		if strings.HasPrefix(path, prefix) {
			allowed = true
			break
		}
	}
	if !allowed {
		return nil, fmt.Errorf("path not in allowed directories: %s", path)
	}

	// 2. Lstat to check for symlinks BEFORE opening
	info, err := os.Lstat(path)
	if err != nil {
		return nil, fmt.Errorf("lstat failed: %w", err)
	}

	// Reject symlinks
	if info.Mode()&os.ModeSymlink != 0 {
		return nil, fmt.Errorf("symlinks not allowed: %s", path)
	}

	// 3. Must be regular file
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("not a regular file: %s", path)
	}

	// 4. Check size
	if info.Size() > maxFileSize {
		return nil, fmt.Errorf("file too large: %d > %d", info.Size(), maxFileSize)
	}

	// 5-6. Check ownership and permissions
	stat, ok := info.Sys().(*syscall.Stat_t)
	if ok {
		// UID must be 0 (root) or nftban user (typically 995 or similar)
		// We allow root and any UID < 1000 (system users)
		if stat.Uid >= 1000 {
			return nil, fmt.Errorf("file owner not trusted: uid=%d", stat.Uid)
		}
		// Must not be world-writable
		if stat.Mode&0002 != 0 {
			return nil, fmt.Errorf("file is world-writable")
		}
	}

	// 7. Open with O_NOFOLLOW for TOCTOU protection
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open failed: %w", err)
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()

	// Verify inode matches (TOCTOU protection)
	if stat != nil {
		var fdStat syscall.Stat_t
		if err := syscall.Fstat(fd, &fdStat); err != nil {
			return nil, fmt.Errorf("fstat failed: %w", err)
		}
		if fdStat.Ino != stat.Ino || fdStat.Dev != stat.Dev {
			return nil, fmt.Errorf("file changed between lstat and open (TOCTOU)")
		}
	}

	// 8. Read with limits
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, maxLineLen), maxLineLen)

	var elements []string
	lineCount := 0

	for scanner.Scan() {
		lineCount++
		if lineCount > maxLineCount {
			return nil, fmt.Errorf("too many lines: > %d", maxLineCount)
		}

		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		elements = append(elements, line)
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan error: %w", err)
	}

	return &FileReadResult{
		Elements: elements,
		Count:    len(elements),
	}, nil
}

// IsAllowedPath checks if a path is in allowed directories
func IsAllowedPath(path string) bool {
	for _, prefix := range allowedPrefixes {
		if strings.HasPrefix(path, prefix) {
			return true
		}
	}
	return false
}
