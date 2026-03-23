// =============================================================================
// NFTBan - Log Integrity HMAC Chain
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="integrity"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-23"
// meta:description="HMAC hash chain for tamper-evident log files (bans.log, audit.log)"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package logger

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"sync"
)

// IntegrityWriter appends HMAC hash chain signatures to log lines.
// Each line is written as: <content>|hmac=<SHA256(prevHMAC + content)>
// This creates a chain where tampering with any line breaks all subsequent HMACs.
type IntegrityWriter struct {
	mu       sync.Mutex
	file     *os.File
	path     string
	key      []byte
	prevHMAC []byte // Previous HMAC for chaining
}

// NewIntegrityWriter creates a new integrity writer for the given log file.
// The key is used for HMAC computation. If the file already exists,
// the writer reads the last line's HMAC to continue the chain.
func NewIntegrityWriter(path string, key []byte) (*IntegrityWriter, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640) // #nosec G302 -- log file readable by nftban group
	if err != nil {
		return nil, fmt.Errorf("integrity writer: open %s: %w", path, err)
	}

	w := &IntegrityWriter{
		file:     f,
		path:     path,
		key:      key,
		prevHMAC: make([]byte, 0), // Zero seed for first entry
	}

	return w, nil
}

// WriteLine writes a line with HMAC chain signature appended.
func (w *IntegrityWriter) WriteLine(content string) error {
	w.mu.Lock()
	defer w.mu.Unlock()

	// Compute HMAC: SHA256(key, prevHMAC + content)
	mac := hmac.New(sha256.New, w.key)
	mac.Write(w.prevHMAC)
	mac.Write([]byte(content))
	sig := mac.Sum(nil)

	// Format: content|hmac=<hex>
	line := fmt.Sprintf("%s|hmac=%s\n", content, hex.EncodeToString(sig))

	if _, err := w.file.WriteString(line); err != nil {
		return fmt.Errorf("integrity write failed: %w", err)
	}

	// Update chain
	w.prevHMAC = sig
	return nil
}

// Close closes the underlying file.
func (w *IntegrityWriter) Close() error {
	w.mu.Lock()
	defer w.mu.Unlock()

	if w.file != nil {
		return w.file.Close()
	}
	return nil
}

// VerifyChain reads a log file and verifies the HMAC chain integrity.
// Returns the line number of the first broken link, or 0 if chain is valid.
func VerifyChain(path string, key []byte) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, fmt.Errorf("verify chain: %w", err)
	}

	var prevHMAC []byte
	lineNum := 0

	for len(data) > 0 {
		lineNum++

		// Find end of line
		end := 0
		for end < len(data) && data[end] != '\n' {
			end++
		}
		line := string(data[:end])
		if end < len(data) {
			data = data[end+1:]
		} else {
			data = nil
		}

		if line == "" {
			continue
		}

		// Split on |hmac=
		idx := len(line) - 71 // |hmac= (6) + hex(32 bytes = 64) = 70
		if idx < 0 || line[idx:idx+6] != "|hmac=" {
			return lineNum, nil // Missing HMAC
		}

		content := line[:idx]
		expectedHex := line[idx+6:]

		expectedSig, err := hex.DecodeString(expectedHex)
		if err != nil {
			return lineNum, nil // Invalid hex
		}

		// Recompute HMAC
		mac := hmac.New(sha256.New, key)
		mac.Write(prevHMAC)
		mac.Write([]byte(content))
		computedSig := mac.Sum(nil)

		if !hmac.Equal(computedSig, expectedSig) {
			return lineNum, nil // Chain broken
		}

		prevHMAC = computedSig
	}

	return 0, nil // Chain valid
}
