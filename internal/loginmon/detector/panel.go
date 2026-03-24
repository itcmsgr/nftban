// =============================================================================
// NFTBan v1.0.30 - High-Performance Panel Detector (DirectAdmin/cPanel/Plesk)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: detector
// Purpose: Signal-based control panel authentication failure detection
//
// meta:name="panel_detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="Signal-based control panel authentication failure detection"
//
// Detection Patterns:
// - DirectAdmin: "FAILED LOGIN ... IP=<ip>"
// - cPanel: "FAILED LOGIN ... ip=<ip>"
// - Plesk: "Authentication failed for ... from <ip>"
//
// meta:inventory.files="panel.go"
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

// PanelDetector detects control panel authentication failures
type PanelDetector struct {
	// DirectAdmin signals
	sigDirectAdmin []byte
	sigFailedLogin []byte
	markerIP       []byte // "IP=" or "ip="

	// cPanel signals
	sigCPanel     []byte
	sigCPHulk     []byte
	markerIpLower []byte // "ip="

	// Plesk signals
	sigPlesk      []byte
	sigPsaFailed  []byte

	// Common
	markerFrom []byte
}

// NewPanelDetector creates a new panel detector
func NewPanelDetector() *PanelDetector {
	return &PanelDetector{
		sigDirectAdmin: []byte("directadmin"),
		sigFailedLogin: []byte("FAILED LOGIN"),
		markerIP:       []byte("IP="),
		sigCPanel:      []byte("cpanel"),
		sigCPHulk:      []byte("cphulkd"),
		markerIpLower:  []byte("ip="),
		sigPlesk:       []byte("plesk"),
		sigPsaFailed:   []byte("sw-cp-server"),
		markerFrom:     []byte("from "),
	}
}

// Name returns the detector identifier
func (d *PanelDetector) Name() string {
	return "panel"
}

// Detect checks if a log line is a panel authentication failure
func (d *PanelDetector) Detect(line []byte) (Verdict, bool) {
	lineLower := bytes.ToLower(line)

	// Stage 1: DirectAdmin detection
	if bytes.Contains(lineLower, d.sigDirectAdmin) {
		if v, ok := d.detectDirectAdmin(line); ok {
			return v, true
		}
	}

	// Stage 2: cPanel detection (including cPHulk)
	if bytes.Contains(lineLower, d.sigCPanel) || bytes.Contains(lineLower, d.sigCPHulk) {
		if v, ok := d.detectCPanel(line, lineLower); ok {
			return v, true
		}
	}

	// Stage 3: Plesk detection
	if bytes.Contains(lineLower, d.sigPlesk) || bytes.Contains(lineLower, d.sigPsaFailed) {
		if v, ok := d.detectPlesk(line, lineLower); ok {
			return v, true
		}
	}

	return Verdict{}, false
}

// detectDirectAdmin handles "directadmin: FAILED LOGIN ... IP=<ip>"
func (d *PanelDetector) detectDirectAdmin(line []byte) (Verdict, bool) {
	if !bytes.Contains(line, d.sigFailedLogin) {
		return Verdict{}, false
	}

	// Find "IP=" marker (case-sensitive first, then insensitive)
	ipIdx := bytes.Index(line, d.markerIP)
	if ipIdx == -1 {
		ipIdx = bytes.Index(bytes.ToLower(line), d.markerIpLower)
		if ipIdx == -1 {
			return Verdict{}, false
		}
	}

	// Extract IP after "IP="
	ipStart := ipIdx + 3 // len("IP=")
	// Bounds check: ensure ipStart is within line
	if ipStart >= len(line) {
		return Verdict{}, false
	}
	ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t,;")
	if ipEnd == -1 {
		ipEnd = len(line) - ipStart
	}
	// Bounds check: ensure we have valid slice
	if ipEnd <= 0 || ipStart+ipEnd > len(line) {
		return Verdict{}, false
	}

	ipBytes := line[ipStart : ipStart+ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonDirectAdminLogin,
		ScoreDelta: 20,
		Service:    "directadmin",
	}, true
}

// detectCPanel handles cPanel/WHM and cPHulk login failures
func (d *PanelDetector) detectCPanel(line, lineLower []byte) (Verdict, bool) {
	// Must contain failure indicator
	hasFailure := bytes.Contains(lineLower, []byte("failed")) ||
		bytes.Contains(lineLower, []byte("invalid")) ||
		bytes.Contains(lineLower, []byte("blocked"))

	if !hasFailure {
		return Verdict{}, false
	}

	// Try "ip=" marker
	ipIdx := bytes.Index(lineLower, d.markerIpLower)
	if ipIdx != -1 {
		ipStart := ipIdx + 3
		// Bounds check: ensure ipStart is within line
		if ipStart >= len(line) {
			return Verdict{}, false
		}
		ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t,;\"'")
		if ipEnd == -1 {
			ipEnd = len(line) - ipStart
		}
		// Bounds check: ensure we have valid slice
		if ipEnd <= 0 || ipStart+ipEnd > len(line) {
			return Verdict{}, false
		}

		ipBytes := line[ipStart : ipStart+ipEnd]
		if addr, err := netip.ParseAddr(string(ipBytes)); err == nil {
			return Verdict{
				IP:         addr,
				Reason:     ReasonCPanelLogin,
				ScoreDelta: 20,
				Service:    "cpanel",
			}, true
		}
	}

	// Try "from " marker
	fromIdx := bytes.LastIndex(lineLower, d.markerFrom)
	if fromIdx != -1 {
		ipStart := fromIdx + len(d.markerFrom)
		// Bounds check: ensure ipStart is within line
		if ipStart >= len(line) {
			return Verdict{}, false
		}
		ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t,;\"'[]")
		if ipEnd == -1 {
			ipEnd = len(line) - ipStart
		}
		// Bounds check: ensure we have valid slice
		if ipEnd <= 0 || ipStart+ipEnd > len(line) {
			return Verdict{}, false
		}

		ipBytes := line[ipStart : ipStart+ipEnd]
		if addr, err := netip.ParseAddr(string(ipBytes)); err == nil {
			return Verdict{
				IP:         addr,
				Reason:     ReasonCPanelLogin,
				ScoreDelta: 20,
				Service:    "cpanel",
			}, true
		}
	}

	return Verdict{}, false
}

// detectPlesk handles Plesk authentication failures
func (d *PanelDetector) detectPlesk(line, lineLower []byte) (Verdict, bool) {
	// Must contain failure indicator
	hasFailure := bytes.Contains(lineLower, []byte("failed")) ||
		bytes.Contains(lineLower, []byte("authentication")) ||
		bytes.Contains(lineLower, []byte("invalid"))

	if !hasFailure {
		return Verdict{}, false
	}

	// Try "from " marker
	fromIdx := bytes.LastIndex(lineLower, d.markerFrom)
	if fromIdx != -1 {
		ipStart := fromIdx + len(d.markerFrom)
		// Bounds check: ensure ipStart is within line
		if ipStart >= len(line) {
			return Verdict{}, false
		}
		ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t,;\"'[]")
		if ipEnd == -1 {
			ipEnd = len(line) - ipStart
		}
		// Bounds check: ensure we have valid slice
		if ipEnd <= 0 || ipStart+ipEnd > len(line) {
			return Verdict{}, false
		}

		ipBytes := line[ipStart : ipStart+ipEnd]
		if addr, err := netip.ParseAddr(string(ipBytes)); err == nil {
			return Verdict{
				IP:         addr,
				Reason:     ReasonPleskLogin,
				ScoreDelta: 20,
				Service:    "plesk",
			}, true
		}
	}

	// Try bracket IP [x.x.x.x]
	for i := len(line) - 1; i >= 0; i-- {
		if line[i] == ']' {
			for j := i - 1; j >= 0; j-- {
				if line[j] == '[' {
					ipBytes := line[j+1 : i]
					if addr, err := netip.ParseAddr(string(ipBytes)); err == nil {
						return Verdict{
							IP:         addr,
							Reason:     ReasonPleskLogin,
							ScoreDelta: 20,
							Service:    "plesk",
						}, true
					}
					break
				}
			}
		}
	}

	return Verdict{}, false
}
