// =============================================================================
// NFTBan v1.0.30 - High-Performance Mail Detector (Dovecot/Postfix/Exim)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: detector
// Purpose: Signal-based mail authentication failure detection
//
// meta:name="mail_detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="Signal-based mail authentication failure detection"
//
// Detection Patterns:
// - Dovecot: "auth failed, rip=<ip>"
// - Postfix: "SASL LOGIN authentication failed.*[<ip>]"
// - Exim: "authenticator failed for.*[<ip>]"
//
// meta:inventory.files="mail.go"
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

// MailDetector detects mail authentication failures (Dovecot, Postfix, Exim)
type MailDetector struct {
	// Dovecot signals
	sigDovecot    []byte
	sigAuthFailed []byte
	markerRip     []byte // "rip="

	// Postfix signals
	sigPostfix    []byte
	sigSASL       []byte

	// Exim signals
	sigExim          []byte
	sigAuthenticator []byte

	// Common markers
	markerBracketOpen  []byte
	markerBracketClose []byte
}

// NewMailDetector creates a new mail detector
func NewMailDetector() *MailDetector {
	return &MailDetector{
		// Dovecot
		sigDovecot:    []byte("dovecot"),
		sigAuthFailed: []byte("auth failed"),
		markerRip:     []byte("rip="),

		// Postfix
		sigPostfix: []byte("postfix"),
		sigSASL:    []byte("SASL"),

		// Exim
		sigExim:          []byte("exim"),
		sigAuthenticator: []byte("authenticator"),

		// Common
		markerBracketOpen:  []byte("["),
		markerBracketClose: []byte("]"),
	}
}

// Name returns the detector identifier
func (d *MailDetector) Name() string {
	return "mail"
}

// Detect checks if a log line is a mail authentication failure
func (d *MailDetector) Detect(line []byte) (Verdict, bool) {
	lineLower := bytes.ToLower(line)

	// Stage 1: Dovecot detection
	if bytes.Contains(lineLower, d.sigDovecot) && bytes.Contains(lineLower, d.sigAuthFailed) {
		return d.detectDovecot(line)
	}

	// Stage 2: Postfix SASL detection
	if bytes.Contains(lineLower, d.sigPostfix) && bytes.Contains(line, d.sigSASL) {
		return d.detectPostfix(line)
	}

	// Stage 3: Exim detection
	if bytes.Contains(lineLower, d.sigExim) && bytes.Contains(lineLower, d.sigAuthenticator) {
		return d.detectExim(line)
	}

	return Verdict{}, false
}

// detectDovecot handles "dovecot: ... auth failed, rip=<ip>"
func (d *MailDetector) detectDovecot(line []byte) (Verdict, bool) {
	// Find "rip=" marker
	ripIdx := bytes.Index(line, d.markerRip)
	if ripIdx == -1 {
		return Verdict{}, false
	}

	// Extract IP after "rip="
	ipStart := ripIdx + len(d.markerRip)
	ipEnd := bytes.IndexAny(line[ipStart:], ", \n\r\t")
	if ipEnd == -1 {
		ipEnd = len(line) - ipStart
	}

	ipBytes := line[ipStart : ipStart+ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonDovecotAuthFail,
		ScoreDelta: 15,
		Service:    "dovecot",
	}, true
}

// detectPostfix handles "postfix/smtpd[...]: ... SASL LOGIN authentication failed: ... [<ip>]"
func (d *MailDetector) detectPostfix(line []byte) (Verdict, bool) {
	// Must contain "authentication failed"
	if !bytes.Contains(bytes.ToLower(line), []byte("authentication failed")) {
		return Verdict{}, false
	}

	// Find IP in brackets [x.x.x.x]
	addr, ok := d.extractBracketIP(line)
	if !ok {
		return Verdict{}, false
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonPostfixSASL,
		ScoreDelta: 15,
		Service:    "postfix",
	}, true
}

// detectExim handles "exim ... authenticator failed for ... [<ip>]"
func (d *MailDetector) detectExim(line []byte) (Verdict, bool) {
	// Must contain "failed"
	if !bytes.Contains(bytes.ToLower(line), []byte("failed")) {
		return Verdict{}, false
	}

	// Find IP in brackets [x.x.x.x]
	addr, ok := d.extractBracketIP(line)
	if !ok {
		return Verdict{}, false
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonEximAuthFail,
		ScoreDelta: 15,
		Service:    "exim",
	}, true
}

// extractBracketIP extracts an IP address from [x.x.x.x] format
func (d *MailDetector) extractBracketIP(line []byte) (netip.Addr, bool) {
	// Search from end of line (IP usually at end)
	for i := len(line) - 1; i >= 0; i-- {
		if line[i] == ']' {
			// Find matching [
			for j := i - 1; j >= 0; j-- {
				if line[j] == '[' {
					ipBytes := line[j+1 : i]
					// Try to parse as IP
					if addr, err := netip.ParseAddr(string(ipBytes)); err == nil {
						return addr, true
					}
					// Not an IP, continue searching
					break
				}
			}
		}
	}
	return netip.Addr{}, false
}
