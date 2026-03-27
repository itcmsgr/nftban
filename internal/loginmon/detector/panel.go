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
	sigDirectAdmin    []byte
	sigFailedLogin    []byte
	sigFailedLoginLow []byte // v1.48.0: DA format "'IP' N failed login attempts"
	markerIP          []byte // "IP=" or "ip="

	// cPanel signals
	sigCPanel     []byte
	sigCPHulk     []byte
	markerIpLower []byte // "ip="

	// Plesk signals
	sigPlesk     []byte
	sigPsaFailed []byte
	sigPleskPanel []byte // v1.48.0: "[panel]" in panel.log
	markerFromIP []byte  // v1.48.0: "from IP " (Plesk uses "from IP x.x.x.x")

	// cPanel access_log signals
	sigPostLogin []byte // v1.48.0: "POST /login/" for cPanel access_log 401

	// Common
	markerFrom []byte
}

// NewPanelDetector creates a new panel detector
func NewPanelDetector() *PanelDetector {
	return &PanelDetector{
		sigDirectAdmin:    []byte("directadmin"),
		sigFailedLogin:    []byte("FAILED LOGIN"),
		sigFailedLoginLow: []byte("failed login"),
		markerIP:          []byte("IP="),
		sigCPanel:         []byte("cpanel"),
		sigCPHulk:         []byte("cphulkd"),
		markerIpLower:     []byte("ip="),
		sigPlesk:          []byte("plesk"),
		sigPsaFailed:      []byte("sw-cp-server"),
		sigPleskPanel:     []byte("[panel]"),
		markerFromIP:      []byte("from IP "),
		sigPostLogin:      []byte("POST /login/"),
		markerFrom:        []byte("from "),
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
	// v1.48.0: Also detect DA's native log format "'IP' N failed login attempts"
	// which does NOT contain "directadmin" keyword — triggered by "failed login"
	if bytes.Contains(lineLower, d.sigDirectAdmin) || bytes.Contains(lineLower, d.sigFailedLoginLow) {
		if v, ok := d.detectDirectAdmin(line); ok {
			return v, true
		}
	}

	// Stage 2: cPanel detection (including cPHulk + access_log 401)
	// v1.48.0: Also trigger on "POST /login/" for access_log format
	if bytes.Contains(lineLower, d.sigCPanel) || bytes.Contains(lineLower, d.sigCPHulk) ||
		bytes.Contains(line, d.sigPostLogin) {
		if v, ok := d.detectCPanel(line, lineLower); ok {
			return v, true
		}
	}

	// Stage 3: Plesk detection
	// v1.48.0: Also trigger on "[panel]" — Plesk panel.log uses this, not "plesk"
	if bytes.Contains(lineLower, d.sigPlesk) || bytes.Contains(lineLower, d.sigPsaFailed) ||
		bytes.Contains(line, d.sigPleskPanel) {
		if v, ok := d.detectPlesk(line, lineLower); ok {
			return v, true
		}
	}

	return Verdict{}, false
}

// detectDirectAdmin handles DirectAdmin login failures
// Supports two formats:
//   - Legacy/syslog: "directadmin: FAILED LOGIN ... IP=<ip>"
//   - Native DA log: "'<ip>' N failed login attempts. Account '<user>'"
func (d *PanelDetector) detectDirectAdmin(line []byte) (Verdict, bool) {
	lineLower := bytes.ToLower(line)

	// v1.48.0: Try native DA log format first: "'IP' N failed login attempts"
	if bytes.Contains(lineLower, d.sigFailedLoginLow) {
		if v, ok := d.detectDANativeFormat(line); ok {
			return v, true
		}
	}

	// Legacy format: "FAILED LOGIN ... IP=<ip>"
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

// detectDANativeFormat handles DA's native login.log format:
// "'192.0.2.122' 1 failed login attempts. Account 'admin'"
func (d *PanelDetector) detectDANativeFormat(line []byte) (Verdict, bool) {
	// Look for pattern: '<ip>' ... failed login
	// Find first single quote
	qStart := bytes.IndexByte(line, '\'')
	if qStart == -1 {
		return Verdict{}, false
	}
	// Find closing quote
	rest := line[qStart+1:]
	qEnd := bytes.IndexByte(rest, '\'')
	if qEnd == -1 || qEnd == 0 {
		return Verdict{}, false
	}

	ipBytes := rest[:qEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	// Extract username from "Account '<user>'" if present
	user := ""
	accountMarker := []byte("Account '")
	if idx := bytes.Index(line, accountMarker); idx != -1 {
		uStart := idx + len(accountMarker)
		if uStart < len(line) {
			uEnd := bytes.IndexByte(line[uStart:], '\'')
			if uEnd > 0 {
				user = string(line[uStart : uStart+uEnd])
			}
		}
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonDirectAdminLogin,
		ScoreDelta: 20,
		User:       user,
		Service:    "directadmin",
	}, true
}

// detectCPanel handles cPanel/WHM and cPHulk login failures
// Supports:
//   - Legacy: "FAILED LOGIN user=admin ip=1.2.3.4"
//   - access_log: "IP - user [date] "POST /login/?login_only=1" 401"
func (d *PanelDetector) detectCPanel(line, lineLower []byte) (Verdict, bool) {
	// v1.48.0: Try access_log 401 format first: "IP - user [...] POST /login/ ... 401"
	if bytes.Contains(line, d.sigPostLogin) && bytes.Contains(line, []byte(" 401 ")) {
		// IP is at start of line, ends at first space
		spIdx := bytes.IndexByte(line, ' ')
		if spIdx > 0 {
			if addr, err := netip.ParseAddr(string(line[:spIdx])); err == nil {
				return Verdict{
					IP:         addr,
					Reason:     ReasonCPanelLogin,
					ScoreDelta: 20,
					Service:    "cpanel",
				}, true
			}
		}
	}

	// Must contain failure indicator for legacy formats
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
// Real format: "[Action Log] Failed login attempt with login 'user' from IP 192.0.2.122"
func (d *PanelDetector) detectPlesk(line, lineLower []byte) (Verdict, bool) {
	// Must contain failure indicator
	hasFailure := bytes.Contains(lineLower, []byte("failed")) ||
		bytes.Contains(lineLower, []byte("authentication")) ||
		bytes.Contains(lineLower, []byte("invalid")) ||
		bytes.Contains(lineLower, []byte("incorrect"))

	if !hasFailure {
		return Verdict{}, false
	}

	// v1.48.0: Try "from IP " marker first (Plesk panel.log real format)
	fromIPIdx := bytes.LastIndex(line, d.markerFromIP)
	if fromIPIdx != -1 {
		ipStart := fromIPIdx + len(d.markerFromIP)
		if ipStart < len(line) {
			ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t,;\"'[]")
			if ipEnd == -1 {
				ipEnd = len(line) - ipStart
			}
			if ipEnd > 0 && ipStart+ipEnd <= len(line) {
				ipBytes := line[ipStart : ipStart+ipEnd]
				if addr, err := netip.ParseAddr(string(ipBytes)); err == nil {
					// Extract username from "login 'user'" if present
					user := ""
					loginMarker := []byte("login '")
					if idx := bytes.Index(line, loginMarker); idx != -1 {
						uStart := idx + len(loginMarker)
						if uStart < len(line) {
							uEnd := bytes.IndexByte(line[uStart:], '\'')
							if uEnd > 0 {
								user = string(line[uStart : uStart+uEnd])
							}
						}
					}
					return Verdict{
						IP:         addr,
						Reason:     ReasonPleskLogin,
						ScoreDelta: 20,
						User:       user,
						Service:    "plesk",
					}, true
				}
			}
		}
	}

	// Try "from " marker (generic)
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
