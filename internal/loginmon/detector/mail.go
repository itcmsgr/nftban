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
// - Dovecot native: "auth failed, rip=<ip>"
// - Dovecot PAM:    "pam_unix(dovecot:auth): authentication failure ... rhost=<ip>"
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
	// Dovecot native signals ("auth failed, rip=<ip>")
	sigDovecot    []byte
	sigAuthFailed []byte
	markerRip     []byte // "rip="

	// Dovecot PAM signals ("pam_unix(dovecot:auth): authentication failure ... rhost=<ip>")
	sigPamDovecot  []byte // "pam_unix(dovecot"
	sigAuthFailure []byte // "authentication failure"
	markerRhost    []byte // "rhost="

	// Postfix signals
	sigPostfix []byte
	sigSASL    []byte

	// Exim signals
	sigExim          []byte
	sigAuthenticator []byte
	sigFailed        []byte

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

		// Dovecot PAM
		sigPamDovecot:  []byte("pam_unix(dovecot"),
		sigAuthFailure: []byte("authentication failure"),
		markerRhost:    []byte("rhost="),

		// Postfix
		sigPostfix: []byte("postfix"),
		sigSASL:    []byte("SASL"),

		// Exim
		sigExim:          []byte("exim"),
		sigAuthenticator: []byte("authenticator"),
		sigFailed:        []byte("failed"),

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

	// Stage 2: Dovecot PAM detection (auth.log / secure)
	if bytes.Contains(line, d.sigPamDovecot) && bytes.Contains(lineLower, d.sigAuthFailure) {
		return d.detectDovecotPam(line)
	}

	// Stage 3: Postfix SASL detection
	if bytes.Contains(lineLower, d.sigPostfix) && bytes.Contains(line, d.sigSASL) {
		return d.detectPostfix(line)
	}

	// Stage 4: Exim detection
	// Match either "exim" + "authenticator" (syslog format) or
	// "authenticator" + "failed" (bare Exim mainlog without syslog prefix)
	if bytes.Contains(lineLower, d.sigAuthenticator) && bytes.Contains(lineLower, d.sigFailed) {
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
	// Bounds check: ensure ipStart is within line
	if ipStart >= len(line) {
		return Verdict{}, false
	}
	ipEnd := bytes.IndexAny(line[ipStart:], ", \n\r\t")
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
		Reason:     ReasonDovecotAuthFail,
		ScoreDelta: 15,
		Service:    "dovecot",
	}, true
}

// detectDovecotPam handles "pam_unix(dovecot:auth): authentication failure; ... rhost=<ip> user=<user>"
func (d *MailDetector) detectDovecotPam(line []byte) (Verdict, bool) {
	// Find "rhost=" marker
	rhostIdx := bytes.Index(line, d.markerRhost)
	if rhostIdx == -1 {
		return Verdict{}, false
	}

	// Extract IP after "rhost="
	ipStart := rhostIdx + len(d.markerRhost)
	if ipStart >= len(line) {
		return Verdict{}, false
	}
	ipEnd := bytes.IndexAny(line[ipStart:], " \t\n\r")
	if ipEnd == -1 {
		ipEnd = len(line) - ipStart
	}
	if ipEnd <= 0 || ipStart+ipEnd > len(line) {
		return Verdict{}, false
	}

	ipBytes := line[ipStart : ipStart+ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	// Try to extract user from "user=" or "ruser=" field
	var user string
	if idx := bytes.Index(line, []byte(" user=")); idx != -1 {
		uStart := idx + 6
		uEnd := bytes.IndexAny(line[uStart:], " \t\n\r")
		if uEnd == -1 {
			uEnd = len(line) - uStart
		}
		if uEnd > 0 && uStart+uEnd <= len(line) {
			user = string(line[uStart : uStart+uEnd])
		}
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonDovecotPamFail,
		ScoreDelta: 15,
		Service:    "dovecot",
		User:       user,
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

// detectExim handles "exim ... authenticator failed for ... [<ip>]:port"
// Exim log format has multiple bracket IPs:
//   [attacker]:port H=([claimed]) [attacker] I=[local]:port
// We extract the FIRST valid bracket IP, which is the remote peer.
func (d *MailDetector) detectExim(line []byte) (Verdict, bool) {
	// "authenticator" + "failed" already verified by Detect() prefilter

	// Find first valid bracket IP (forward scan — Exim puts attacker IP first)
	addr, ok := d.extractFirstBracketIP(line)
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

// extractFirstBracketIP extracts the first valid IP from [x.x.x.x] format (forward scan)
// Used by Exim where the remote peer IP appears before H= and I= fields
func (d *MailDetector) extractFirstBracketIP(line []byte) (netip.Addr, bool) {
	for i := 0; i < len(line); i++ {
		if line[i] == '[' {
			// Find matching ]
			for j := i + 1; j < len(line); j++ {
				if line[j] == ']' {
					ipBytes := line[i+1 : j]
					if addr, err := netip.ParseAddr(string(ipBytes)); err == nil {
						return addr, true
					}
					break
				}
			}
		}
	}
	return netip.Addr{}, false
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
