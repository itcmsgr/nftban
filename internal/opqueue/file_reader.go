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

	"github.com/itcmsgr/nftban/internal/safeconv"
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
	file := os.NewFile(safeconv.IntToUintptrOrZero(fd), path)
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

// StreamingBatchConfig configures the streaming file reader
type StreamingBatchConfig struct {
	BatchSize int // Elements per batch (default: 10000)
}

// DefaultStreamingBatchConfig returns sensible defaults
func DefaultStreamingBatchConfig() StreamingBatchConfig {
	return StreamingBatchConfig{
		BatchSize: 10000,
	}
}

// BatchCallback is called for each batch of elements
// Return error to abort streaming
type BatchCallback func(batch []string, batchNum int) error

// StreamingFileReader provides streaming access to element files
// It maintains an open file handle and reads elements in batches
type StreamingFileReader struct {
	file    *os.File
	scanner *bufio.Scanner
	config  StreamingBatchConfig

	// Stats
	lineCount    int
	elementCount int
}

// SecureOpenElementsFile opens a file with security checks for streaming
// Returns a reader that must be closed after use
// Security measures are identical to SecureReadElementsFile
func SecureOpenElementsFile(path string, config StreamingBatchConfig) (*StreamingFileReader, error) {
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
		if stat.Uid >= 1000 {
			return nil, fmt.Errorf("file owner not trusted: uid=%d", stat.Uid)
		}
		if stat.Mode&0002 != 0 {
			return nil, fmt.Errorf("file is world-writable")
		}
	}

	// 7. Open with O_NOFOLLOW for TOCTOU protection
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, fmt.Errorf("open failed: %w", err)
	}
	file := os.NewFile(safeconv.IntToUintptrOrZero(fd), path)

	// Verify inode matches (TOCTOU protection)
	if stat != nil {
		var fdStat syscall.Stat_t
		if err := syscall.Fstat(fd, &fdStat); err != nil {
			file.Close()
			return nil, fmt.Errorf("fstat failed: %w", err)
		}
		if fdStat.Ino != stat.Ino || fdStat.Dev != stat.Dev {
			file.Close()
			return nil, fmt.Errorf("file changed between lstat and open (TOCTOU)")
		}
	}

	// Set up scanner with limits
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, maxLineLen), maxLineLen)

	if config.BatchSize <= 0 {
		config.BatchSize = 10000
	}

	return &StreamingFileReader{
		file:    file,
		scanner: scanner,
		config:  config,
	}, nil
}

// Close closes the underlying file
func (r *StreamingFileReader) Close() error {
	if r.file != nil {
		return r.file.Close()
	}
	return nil
}

// Stats returns reading statistics
func (r *StreamingFileReader) Stats() (lineCount, elementCount int) {
	return r.lineCount, r.elementCount
}

// ReadNextBatch reads the next batch of elements
// Returns the batch (may be smaller than BatchSize at end of file)
// Returns nil, nil when EOF is reached
// Returns nil, error on read error or limit exceeded
func (r *StreamingFileReader) ReadNextBatch() ([]string, error) {
	batch := make([]string, 0, r.config.BatchSize)

	for len(batch) < r.config.BatchSize && r.scanner.Scan() {
		r.lineCount++
		if r.lineCount > maxLineCount {
			return nil, fmt.Errorf("too many lines: > %d", maxLineCount)
		}

		line := strings.TrimSpace(r.scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		batch = append(batch, line)
		r.elementCount++
	}

	if err := r.scanner.Err(); err != nil {
		return nil, fmt.Errorf("scan error: %w", err)
	}

	if len(batch) == 0 {
		return nil, nil // EOF
	}

	return batch, nil
}

// StreamElements reads elements in batches and calls the callback for each
// This is the main streaming API - memory stays O(batch_size)
func (r *StreamingFileReader) StreamElements(callback BatchCallback) error {
	batchNum := 0
	for {
		batch, err := r.ReadNextBatch()
		if err != nil {
			return err
		}
		if batch == nil {
			break // EOF
		}

		batchNum++
		if err := callback(batch, batchNum); err != nil {
			return fmt.Errorf("callback error on batch %d: %w", batchNum, err)
		}
	}
	return nil
}

// SecureStreamElementsFile opens a file, streams elements in batches via callback, and closes
// This is a convenience function that handles the full lifecycle
// Memory usage is O(batch_size) instead of O(n)
func SecureStreamElementsFile(path string, config StreamingBatchConfig, callback BatchCallback) (elementCount int, err error) {
	reader, err := SecureOpenElementsFile(path, config)
	if err != nil {
		return 0, err
	}
	defer reader.Close()

	if err := reader.StreamElements(callback); err != nil {
		return reader.elementCount, err
	}

	return reader.elementCount, nil
}
