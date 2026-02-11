// =============================================================================
// NFTBan v1.0.30 - High-Performance SSH Detector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: detector
// Purpose: Signal-based SSH authentication failure detection
//
// meta:name="ssh_detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="Signal-based SSH authentication failure detection"
//
// Detection Patterns (from production Bash patterns):
// - "Failed password for <user> from <ip>"
// - "Failed password for invalid user <user> from <ip>"
// - "Invalid user <user> from <ip>"
// - "Disconnected from <ip> ... preauth"
// - "Too many authentication failures for <user> from <ip>"
//
// Performance:
// - bytes.Contains prefilter skips 99%+ of lines instantly
// - Zero-copy []byte slicing for IP extraction
// - netip.ParseAddr for validated IPv4/IPv6 parsing
//
// meta:inventory.files="ssh.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package detector

import (
	"bytes"
	"net/netip"
)

// SSHDetector detects SSH authentication failures
type SSHDetector struct {
	// Prefilter signals (cheap checks)
	sigFailed      []byte // "Failed password"
	sigInvalid     []byte // "Invalid user"
	sigDisconnect  []byte // "Disconnected from"
	sigTooMany     []byte // "Too many authentication"
	sigSshd        []byte // "sshd"

	// Extraction markers
	markerFrom     []byte // "from "
	markerPort     []byte // " port"
	markerFor      []byte // "for "
	markerPreauth  []byte // "preauth"
	markerRoot     []byte // "root"
	markerInvalid  []byte // "invalid user "
}

// NewSSHDetector creates a new SSH detector with precomputed signals
func NewSSHDetector() *SSHDetector {
	return &SSHDetector{
		sigFailed:     []byte("Failed password"),
		sigInvalid:    []byte("Invalid user"),
		sigDisconnect: []byte("Disconnected from"),
		sigTooMany:    []byte("Too many authentication"),
		sigSshd:       []byte("sshd"),
		markerFrom:    []byte("from "),
		markerPort:    []byte(" port"),
		markerFor:     []byte("for "),
		markerPreauth: []byte("preauth"),
		markerRoot:    []byte("root"),
		markerInvalid: []byte("invalid user "),
	}
}

// Name returns the detector identifier
func (d *SSHDetector) Name() string {
	return "ssh"
}

// Detect checks if a log line is an SSH authentication failure
func (d *SSHDetector) Detect(line []byte) (Verdict, bool) {
	// Stage 0: Quick check for sshd (optional but helps on mixed logs)
	// Skip this check if using journalctl with -u sshd filter
	// hasSshd := bytes.Contains(line, d.sigSshd)

	// Stage 1: Check for "Failed password" signal
	if bytes.Contains(line, d.sigFailed) {
		return d.detectFailedPassword(line)
	}

	// Stage 2: Check for "Invalid user" signal
	if bytes.Contains(line, d.sigInvalid) {
		return d.detectInvalidUser(line)
	}

	// Stage 3: Check for "Disconnected from ... preauth" signal
	if bytes.Contains(line, d.sigDisconnect) && bytes.Contains(line, d.markerPreauth) {
		return d.detectPreauth(line)
	}

	// Stage 4: Check for "Too many authentication" signal
	if bytes.Contains(line, d.sigTooMany) {
		return d.detectTooMany(line)
	}

	return Verdict{}, false
}

// detectFailedPassword handles "Failed password for [invalid user] <user> from <ip>"
func (d *SSHDetector) detectFailedPassword(line []byte) (Verdict, bool) {
	// Find "from " marker
	fromIdx := bytes.Index(line, d.markerFrom)
	if fromIdx == -1 {
		return Verdict{}, false
	}

	// Extract IP: starts after "from ", ends at " port" or end
	ipStart := fromIdx + len(d.markerFrom)
	ipEnd := bytes.Index(line[ipStart:], d.markerPort)
	if ipEnd == -1 {
		// No " port" found, try to find end of IP by space or newline
		ipEnd = bytes.IndexAny(line[ipStart:], " \n\r\t")
		if ipEnd == -1 {
			ipEnd = len(line) - ipStart
		}
	}

	// Parse IP address (only allocation point)
	ipBytes := line[ipStart : ipStart+ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	// Extract username (between "for " and "from ")
	user := d.extractUser(line, fromIdx)

	// Determine score based on context
	scoreDelta := int16(10) // Base score for failed password
	reason := ReasonSSHFailedPassword

	// Check if this was an invalid user attempt (higher risk)
	if bytes.Contains(line[:fromIdx], d.markerInvalid) {
		scoreDelta = 15
		reason = ReasonSSHInvalidUser
	}

	// Root attempt bonus
	if bytes.Contains(line[:fromIdx], d.markerRoot) {
		scoreDelta += 10
		reason = ReasonSSHRootAttempt
	}

	return Verdict{
		IP:         addr,
		Reason:     reason,
		ScoreDelta: scoreDelta,
		User:       user,
		Service:    "ssh",
	}, true
}

// detectInvalidUser handles "Invalid user <user> from <ip>"
func (d *SSHDetector) detectInvalidUser(line []byte) (Verdict, bool) {
	// Find "from " marker
	fromIdx := bytes.Index(line, d.markerFrom)
	if fromIdx == -1 {
		return Verdict{}, false
	}

	// Extract IP
	ipStart := fromIdx + len(d.markerFrom)
	ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t")
	if ipEnd == -1 {
		ipEnd = len(line) - ipStart
	}

	ipBytes := line[ipStart : ipStart+ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	// Extract username (between "Invalid user " and "from ")
	user := ""
	invIdx := bytes.Index(line, d.sigInvalid)
	if invIdx != -1 {
		userStart := invIdx + len(d.sigInvalid)
		userEnd := fromIdx - 1 // -1 for the space before "from"
		if userEnd > userStart && userEnd < len(line) {
			user = string(bytes.TrimSpace(line[userStart:userEnd]))
		}
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonSSHInvalidUser,
		ScoreDelta: 15, // Higher score for unknown users
		User:       user,
		Service:    "ssh",
	}, true
}

// detectPreauth handles "Disconnected from <ip> ... preauth"
func (d *SSHDetector) detectPreauth(line []byte) (Verdict, bool) {
	// Find "Disconnected from " or "from "
	fromIdx := bytes.Index(line, d.markerFrom)
	if fromIdx == -1 {
		return Verdict{}, false
	}

	// Extract IP
	ipStart := fromIdx + len(d.markerFrom)

	// Handle optional "authenticating user" before IP
	// Format: "Disconnected from authenticating user root 1.2.3.4 port..."
	// or: "Disconnected from 1.2.3.4 port..."
	segment := line[ipStart:]

	// Skip "authenticating user <user> " if present
	if bytes.HasPrefix(segment, []byte("authenticating user ")) {
		// Find the IP after "authenticating user <user> "
		space1 := bytes.IndexByte(segment[20:], ' ')
		if space1 != -1 {
			ipStart = ipStart + 20 + space1 + 1
			segment = line[ipStart:]
		}
	}

	// Find end of IP (space before "port" or other delimiter)
	ipEnd := bytes.IndexAny(segment, " \n\r\t")
	if ipEnd == -1 {
		ipEnd = len(segment)
	}

	ipBytes := segment[:ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonSSHPreauth,
		ScoreDelta: 20, // High score for scanner behavior
		Service:    "ssh",
	}, true
}

// detectTooMany handles "Too many authentication failures for <user> from <ip>"
func (d *SSHDetector) detectTooMany(line []byte) (Verdict, bool) {
	// Find "from " marker
	fromIdx := bytes.Index(line, d.markerFrom)
	if fromIdx == -1 {
		return Verdict{}, false
	}

	// Extract IP
	ipStart := fromIdx + len(d.markerFrom)
	ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t")
	if ipEnd == -1 {
		ipEnd = len(line) - ipStart
	}

	ipBytes := line[ipStart : ipStart+ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	user := d.extractUser(line, fromIdx)

	return Verdict{
		IP:         addr,
		Reason:     ReasonSSHTooManyFailures,
		ScoreDelta: 30, // Very high score for repeated failures
		User:       user,
		Service:    "ssh",
	}, true
}

// extractUser extracts username from "for <user> from" pattern
func (d *SSHDetector) extractUser(line []byte, fromIdx int) string {
	forIdx := bytes.Index(line[:fromIdx], d.markerFor)
	if forIdx == -1 {
		return ""
	}

	userStart := forIdx + len(d.markerFor)
	userEnd := fromIdx - 1 // -1 for the space before "from"

	if userEnd <= userStart {
		return ""
	}

	// Handle "invalid user <user>" case
	userBytes := bytes.TrimPrefix(line[userStart:userEnd], d.markerInvalid)

	return string(bytes.TrimSpace(userBytes))
}
