// =============================================================================
// NFTBan v1.0.30 - High-Performance FTP Detector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: detector
// Purpose: Signal-based FTP authentication failure detection
//
// meta:name="ftp_detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="Signal-based FTP authentication failure detection"
//
// Detection Patterns:
// - Pure-FTPd: "Authentication failed for user ... [<ip>]"
// - vsftpd: "FAIL LOGIN: Client \"<ip>\""
// - ProFTPD: "USER ... no such user found from <ip>"
//
// meta:inventory.files="ftp.go"
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

// FTPDetector detects FTP authentication failures
type FTPDetector struct {
	// Pure-FTPd signals
	sigPureFTPd []byte
	sigAuthFail []byte

	// vsftpd signals
	sigVsftpd    []byte
	sigFailLogin []byte

	// ProFTPD signals
	sigProFTPD    []byte
	sigNoSuchUser []byte

	// Common markers
	markerFrom         []byte
	markerClient       []byte
	markerBracketOpen  []byte
	markerBracketClose []byte
	markerQuote        []byte
}

// NewFTPDetector creates a new FTP detector
func NewFTPDetector() *FTPDetector {
	return &FTPDetector{
		sigPureFTPd:        []byte("pure-ftpd"),
		sigAuthFail:        []byte("Authentication failed"),
		sigVsftpd:          []byte("vsftpd"),
		sigFailLogin:       []byte("FAIL LOGIN"),
		sigProFTPD:         []byte("proftpd"),
		sigNoSuchUser:      []byte("no such user"),
		markerFrom:         []byte("from "),
		markerClient:       []byte("Client \""),
		markerBracketOpen:  []byte("["),
		markerBracketClose: []byte("]"),
		markerQuote:        []byte("\""),
	}
}

// Name returns the detector identifier
func (d *FTPDetector) Name() string {
	return "ftp"
}

// Detect checks if a log line is an FTP authentication failure
func (d *FTPDetector) Detect(line []byte) (Verdict, bool) {
	lineLower := bytes.ToLower(line)

	// Stage 1: Pure-FTPd detection
	if bytes.Contains(lineLower, d.sigPureFTPd) {
		if v, ok := d.detectPureFTPd(line); ok {
			return v, true
		}
	}

	// Stage 2: vsftpd detection.
	// vsftpd's own log file (/var/log/vsftpd.log) does NOT contain the daemon
	// name "vsftpd" on each line — only the distinctive `FAIL LOGIN: Client "<ip>"`.
	// The "vsftpd" substring only appears when vsftpd logs via syslog. Gate on the
	// daemon name OR the distinctive failure phrase so the file source is covered.
	if bytes.Contains(lineLower, d.sigVsftpd) || bytes.Contains(line, d.sigFailLogin) {
		if v, ok := d.detectVsftpd(line); ok {
			return v, true
		}
	}

	// Stage 3: ProFTPD detection
	if bytes.Contains(lineLower, d.sigProFTPD) {
		if v, ok := d.detectProFTPD(line, lineLower); ok {
			return v, true
		}
	}

	return Verdict{}, false
}

// detectPureFTPd handles "pure-ftpd: ... Authentication failed for user ... [<ip>]"
func (d *FTPDetector) detectPureFTPd(line []byte) (Verdict, bool) {
	if !bytes.Contains(line, d.sigAuthFail) {
		return Verdict{}, false
	}

	// pure-ftpd's real syslog format carries the client IP in the connection
	// prefix "(<logname>@<ip>)" (logname is "?" on a failed login), e.g.
	//   pure-ftpd: (?@203.0.113.7) [WARNING] Authentication failed for user [bob]
	// The bracketed fields are [WARNING] and the *username*, NOT the IP, so try
	// the paren-at form first and fall back to a bracketed IP (some configs append
	// a trailing "[<ip>]"). Validated against sample traffic.
	addr, ok := d.extractParenAtIP(line)
	if !ok {
		addr, ok = d.extractBracketIP(line)
	}
	if !ok {
		return Verdict{}, false
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonFTPAuthFail,
		ScoreDelta: 15,
		Service:    "pure-ftpd",
	}, true
}

// extractParenAtIP extracts the IP from pure-ftpd's "(<logname>@<ip>)" connection
// prefix: the bytes between the first '@' and the following ')'. Handles IPv4 and
// IPv6. Returns false if no parseable address is present.
func (d *FTPDetector) extractParenAtIP(line []byte) (netip.Addr, bool) {
	at := bytes.IndexByte(line, '@')
	if at == -1 || at+1 >= len(line) {
		return netip.Addr{}, false
	}
	rest := line[at+1:]
	end := bytes.IndexByte(rest, ')')
	if end <= 0 {
		return netip.Addr{}, false
	}
	if addr, err := netip.ParseAddr(string(rest[:end])); err == nil {
		return addr, true
	}
	return netip.Addr{}, false
}

// detectVsftpd handles "vsftpd: ... FAIL LOGIN: Client \"<ip>\""
func (d *FTPDetector) detectVsftpd(line []byte) (Verdict, bool) {
	if !bytes.Contains(line, d.sigFailLogin) {
		return Verdict{}, false
	}

	// Find "Client \""
	clientIdx := bytes.Index(line, d.markerClient)
	if clientIdx == -1 {
		return Verdict{}, false
	}

	// Extract IP between quotes
	ipStart := clientIdx + len(d.markerClient)
	// Bounds check: ensure ipStart is within line
	if ipStart >= len(line) {
		return Verdict{}, false
	}
	ipEnd := bytes.Index(line[ipStart:], d.markerQuote)
	if ipEnd == -1 || ipEnd <= 0 {
		return Verdict{}, false
	}
	// Bounds check: ensure we have valid slice
	if ipStart+ipEnd > len(line) {
		return Verdict{}, false
	}

	ipBytes := line[ipStart : ipStart+ipEnd]
	addr, err := netip.ParseAddr(string(ipBytes))
	if err != nil {
		return Verdict{}, false
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonFTPAuthFail,
		ScoreDelta: 15,
		Service:    "vsftpd",
	}, true
}

// detectProFTPD handles "proftpd[...]: ... no such user found from <ip>"
func (d *FTPDetector) detectProFTPD(line, lineLower []byte) (Verdict, bool) {
	// Check for auth failure indicators
	hasFailure := bytes.Contains(lineLower, d.sigNoSuchUser) ||
		bytes.Contains(lineLower, []byte("login failed")) ||
		bytes.Contains(lineLower, []byte("authentication failed"))

	if !hasFailure {
		return Verdict{}, false
	}

	// Try to find IP after "from "
	fromIdx := bytes.LastIndex(lineLower, d.markerFrom)
	if fromIdx != -1 {
		ipStart := fromIdx + len(d.markerFrom)
		// Bounds check: ensure ipStart is within line
		if ipStart >= len(line) {
			return Verdict{}, false
		}
		ipEnd := bytes.IndexAny(line[ipStart:], " \n\r\t[]")
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
				Reason:     ReasonFTPAuthFail,
				ScoreDelta: 15,
				Service:    "proftpd",
			}, true
		}
	}

	// Fallback: try bracket IP
	if addr, ok := d.extractBracketIP(line); ok {
		return Verdict{
			IP:         addr,
			Reason:     ReasonFTPAuthFail,
			ScoreDelta: 15,
			Service:    "proftpd",
		}, true
	}

	return Verdict{}, false
}

// extractBracketIP extracts an IP address from [x.x.x.x] format
func (d *FTPDetector) extractBracketIP(line []byte) (netip.Addr, bool) {
	for i := len(line) - 1; i >= 0; i-- {
		if line[i] == ']' {
			for j := i - 1; j >= 0; j-- {
				if line[j] == '[' {
					ipBytes := line[j+1 : i]
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
