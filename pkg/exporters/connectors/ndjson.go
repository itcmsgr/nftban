// =============================================================================
// NFTBan v1.0 - NDJSON File Connector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ndjson"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="NDJSON file connector with rotation and compression"
// meta:inventory.files="/var/log/nftban/metrics/*.ndjson"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package connectors

import (
	"bufio"
	"compress/gzip"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// =============================================================================
// NDJSON Connector
// =============================================================================

// NDJSONConnector writes records to NDJSON files
type NDJSONConnector struct {
	*BaseConnector
	config NDJSONConfig

	// File state
	file       *os.File
	writer     *bufio.Writer
	gzWriter   *gzip.Writer
	currentDay string
	bytesWritten int64
	mu         sync.Mutex
}

// NDJSONConfig holds NDJSON connector configuration
type NDJSONConfig struct {
	// Output directory
	Directory string `json:"directory"`

	// File prefix (default: "nftban")
	Prefix string `json:"prefix"`

	// Rotation settings
	RotateDaily    bool  `json:"rotate_daily"`
	RotateSize     int64 `json:"rotate_size"`      // Max file size in bytes
	RetentionDays  int   `json:"retention_days"`   // Days to keep files
	RetentionCount int   `json:"retention_count"`  // Max files to keep

	// Compression
	Compress bool `json:"compress"` // Gzip compression

	// Buffer settings
	BufferSize int `json:"buffer_size"` // Write buffer size

	// Sync settings
	SyncAfterWrite bool `json:"sync_after_write"` // fsync after each write
}

// DefaultNDJSONConfig returns default configuration
func DefaultNDJSONConfig() NDJSONConfig {
	return NDJSONConfig{
		Directory:      "/var/log/nftban/metrics",
		Prefix:         "nftban",
		RotateDaily:    true,
		RotateSize:     100 * 1024 * 1024, // 100MB
		RetentionDays:  30,
		RetentionCount: 100,
		Compress:       true,
		BufferSize:     64 * 1024, // 64KB
		SyncAfterWrite: false,
	}
}

// NewNDJSONConnector creates a new NDJSON connector
func NewNDJSONConnector(name string, config NDJSONConfig) *NDJSONConnector {
	return &NDJSONConnector{
		BaseConnector: NewBaseConnector(name, ConnectorTypeNDJSON),
		config:        config,
	}
}

// Connect opens the output file
func (c *NDJSONConnector) Connect(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Create directory if needed
	if err := os.MkdirAll(c.config.Directory, 0755); err != nil {
		return fmt.Errorf("failed to create directory: %w", err)
	}

	// Open file
	if err := c.openFile(); err != nil {
		return err
	}

	c.SetConnected(true)
	return nil
}

// Disconnect closes the file
func (c *NDJSONConnector) Disconnect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	err := c.closeFile()
	c.SetConnected(false)
	return err
}

// Send writes records to the file
func (c *NDJSONConnector) Send(ctx context.Context, records []Record) error {
	if len(records) == 0 {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	start := time.Now()

	// Check if rotation needed
	if err := c.checkRotation(); err != nil {
		c.RecordError(err)
		return err
	}

	// Write records
	var bytesWritten int64
	for _, record := range records {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		data, err := record.ToNDJSON()
		if err != nil {
			c.RecordError(err)
			return fmt.Errorf("failed to marshal record: %w", err)
		}

		var n int
		if c.gzWriter != nil {
			n, err = c.gzWriter.Write(data)
		} else {
			n, err = c.writer.Write(data)
		}

		if err != nil {
			c.RecordError(err)
			return fmt.Errorf("failed to write record: %w", err)
		}

		bytesWritten += int64(n)
		c.bytesWritten += int64(n)
	}

	// Flush
	if c.gzWriter != nil {
		if err := c.gzWriter.Flush(); err != nil {
			c.RecordError(err)
			return err
		}
	}
	if err := c.writer.Flush(); err != nil {
		c.RecordError(err)
		return err
	}

	// Sync if configured
	if c.config.SyncAfterWrite && c.file != nil {
		if err := c.file.Sync(); err != nil {
			c.RecordError(err)
			return err
		}
	}

	c.RecordSend(len(records), bytesWritten, time.Since(start))
	return nil
}

// =============================================================================
// File Operations
// =============================================================================

// openFile opens a new output file
func (c *NDJSONConnector) openFile() error {
	filename := c.generateFilename()
	path := filepath.Join(c.config.Directory, filename)

	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open file: %w", err)
	}

	c.file = file
	c.bytesWritten = 0

	// Get current file size
	if info, err := file.Stat(); err == nil {
		c.bytesWritten = info.Size()
	}

	// Setup buffered writer
	bufSize := c.config.BufferSize
	if bufSize <= 0 {
		bufSize = 64 * 1024
	}
	c.writer = bufio.NewWriterSize(file, bufSize)

	// Setup gzip if enabled
	if c.config.Compress {
		c.gzWriter = gzip.NewWriter(c.writer)
	}

	c.currentDay = time.Now().Format("2006-01-02")

	return nil
}

// closeFile closes the current file
func (c *NDJSONConnector) closeFile() error {
	var errs []error

	if c.gzWriter != nil {
		if err := c.gzWriter.Close(); err != nil {
			errs = append(errs, err)
		}
		c.gzWriter = nil
	}

	if c.writer != nil {
		if err := c.writer.Flush(); err != nil {
			errs = append(errs, err)
		}
		c.writer = nil
	}

	if c.file != nil {
		if err := c.file.Close(); err != nil {
			errs = append(errs, err)
		}
		c.file = nil
	}

	if len(errs) > 0 {
		return fmt.Errorf("errors closing file: %v", errs)
	}

	return nil
}

// checkRotation checks if rotation is needed and performs it
func (c *NDJSONConnector) checkRotation() error {
	needsRotation := false

	// Check daily rotation
	if c.config.RotateDaily {
		today := time.Now().Format("2006-01-02")
		if today != c.currentDay {
			needsRotation = true
		}
	}

	// Check size rotation
	if c.config.RotateSize > 0 && c.bytesWritten >= c.config.RotateSize {
		needsRotation = true
	}

	if !needsRotation {
		return nil
	}

	// Close current file
	if err := c.closeFile(); err != nil {
		return err
	}

	// Open new file
	if err := c.openFile(); err != nil {
		return err
	}

	// Cleanup old files
	go c.cleanup()

	return nil
}

// generateFilename generates a filename based on current time
func (c *NDJSONConnector) generateFilename() string {
	prefix := c.config.Prefix
	if prefix == "" {
		prefix = "nftban"
	}

	timestamp := time.Now().Format("2006-01-02")
	ext := ".ndjson"
	if c.config.Compress {
		ext = ".ndjson.gz"
	}

	// If file exists, add sequence number
	base := fmt.Sprintf("%s-%s", prefix, timestamp)
	filename := base + ext
	path := filepath.Join(c.config.Directory, filename)

	seq := 1
	for {
		if _, err := os.Stat(path); os.IsNotExist(err) {
			break
		}
		filename = fmt.Sprintf("%s-%d%s", base, seq, ext)
		path = filepath.Join(c.config.Directory, filename)
		seq++
	}

	return filename
}

// cleanup removes old files based on retention settings
func (c *NDJSONConnector) cleanup() {
	prefix := c.config.Prefix
	if prefix == "" {
		prefix = "nftban"
	}

	pattern := filepath.Join(c.config.Directory, prefix+"*.ndjson*")
	files, err := filepath.Glob(pattern)
	if err != nil {
		return
	}

	if len(files) == 0 {
		return
	}

	// Sort by modification time (oldest first)
	type fileInfo struct {
		path    string
		modTime time.Time
	}

	var fileInfos []fileInfo
	for _, f := range files {
		info, err := os.Stat(f)
		if err != nil {
			continue
		}
		fileInfos = append(fileInfos, fileInfo{path: f, modTime: info.ModTime()})
	}

	sort.Slice(fileInfos, func(i, j int) bool {
		return fileInfos[i].modTime.Before(fileInfos[j].modTime)
	})

	// Apply retention by count
	if c.config.RetentionCount > 0 && len(fileInfos) > c.config.RetentionCount {
		toDelete := len(fileInfos) - c.config.RetentionCount
		for i := 0; i < toDelete; i++ {
			os.Remove(fileInfos[i].path)
		}
		fileInfos = fileInfos[toDelete:]
	}

	// Apply retention by age
	if c.config.RetentionDays > 0 {
		cutoff := time.Now().AddDate(0, 0, -c.config.RetentionDays)
		for _, fi := range fileInfos {
			if fi.modTime.Before(cutoff) {
				os.Remove(fi.path)
			}
		}
	}
}

// =============================================================================
// Status
// =============================================================================

// Status returns connector status with file info
func (c *NDJSONConnector) Status() ConnectorStatus {
	status := c.BaseConnector.Status()

	c.mu.Lock()
	if c.file != nil {
		status.BytesSent = c.bytesWritten
	}
	c.mu.Unlock()

	return status
}

// =============================================================================
// Utility Functions
// =============================================================================

// CurrentFile returns the current output file path
func (c *NDJSONConnector) CurrentFile() string {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.file == nil {
		return ""
	}
	return c.file.Name()
}

// ForceRotate forces a file rotation
func (c *NDJSONConnector) ForceRotate() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.closeFile(); err != nil {
		return err
	}
	return c.openFile()
}

// BytesWritten returns bytes written to current file
func (c *NDJSONConnector) BytesWritten() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.bytesWritten
}
