// =============================================================================
// NFTBan v1.80 - Dovecot parser (Phase D)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: dovecot
// Purpose: Parse Dovecot imap/pop3-login auth-failed lines into NormalizedEvents.
//
// meta:name="loginmon_pipeline_parser_dovecot"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="dovecot"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase D: Dovecot auth-failure parser for the v1.80 Go pipeline"
//
// meta:inventory.files="dovecot.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package dovecot implements a Parser for Dovecot imap-login/pop3-login
// auth-failed lines.
//
// Dovecot log format (a sanitized sample line):
//
//	Apr  9 03:01:45 mail01 dovecot[1234]: imap-login: Login aborted: Connection closed (auth failed, 1 attempts in 3 secs) (auth_failed): user=<contact@example.test>, method=PLAIN, rip=203.0.113.178, lip=192.0.2.97, TLS, session=<synthetic-session>
//
// The parser matches lines containing "dovecot" + "auth failed" and extracts:
//
//   - IP: value after "rip=" up to comma/space/EOL
//   - DstIP: value after "lip=" (local IP — the listener)
//   - Username: value inside "user=<...>"
//   - Protocol: "imap" or "pop3" derived from "imap-login" / "pop3-login"
//
// PARITY TARGET
//
// Legacy: internal/loginmon/detector/mail.go detectDovecot() (lines 126-160).
// Legacy extracts IP from rip= only. This parser additionally extracts
// username, lip (DstIP), and protocol — improvements over parity.
package dovecot

import (
	"bytes"
	"net/netip"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

var (
	sigDovecot    = []byte("dovecot")
	sigAuthFailed = []byte("auth failed")
	markerRip     = []byte("rip=")
	markerLip     = []byte("lip=")
	markerUser    = []byte("user=<")
)

// Parser implements runtime.Parser for Dovecot auth-failure lines.
type Parser struct{}

// New constructs a Dovecot parser.
func New() *Parser { return &Parser{} }

// Name returns the source identifier.
func (p *Parser) Name() string { return "dovecot" }

// Parse attempts to extract a NormalizedEvent from a Dovecot log line.
func (p *Parser) Parse(line event.RawLine) event.ParseResult {
	lower := bytes.ToLower(line.Line)

	if !bytes.Contains(lower, sigDovecot) || !bytes.Contains(lower, sigAuthFailed) {
		return event.ParseResult{Outcome: event.ParseSkipped}
	}

	// Extract rip= (remote IP — the attacker)
	addr, ok := extractMarkerIP(line.Line, markerRip)
	if !ok {
		return event.ParseResult{
			Outcome: event.ParseMalformed,
			Reason:  "dovecot auth failed but no rip= found",
		}
	}

	// Extract lip= (local IP — the listener), optional
	dstIP, _ := extractMarkerIP(line.Line, markerLip)

	// Extract user=<...>
	user := extractUser(line.Line)

	// Derive protocol from "imap-login" or "pop3-login"
	proto := "imap"
	if bytes.Contains(lower, []byte("pop3-login")) {
		proto = "pop3"
	} else if bytes.Contains(lower, []byte("submission-login")) {
		proto = "smtp"
	}

	// Syslog timestamp (first 15 chars): "Apr  9 03:01:45"
	// Not year-aware — syslog doesn't include year. Use current year.
	ts := parseSyslogTimestamp(line.Line)

	return event.ParseResult{
		Outcome: event.ParseMatched,
		Event: event.NormalizedEvent{
			Source:    "dovecot",
			Service:   "dovecot_" + proto,
			Reason:    event.ReasonDovecotAuthFail,
			SrcIP:     addr,
			DstIP:     dstIP,
			Username:  user,
			Protocol:  proto,
			Timestamp: ts,
			Path:      line.Path,
			RawLine:   append([]byte(nil), line.Line...),
		},
	}
}

// extractMarkerIP extracts an IP after a "key=" marker up to the next
// comma, space, or EOL.
func extractMarkerIP(line, marker []byte) (netip.Addr, bool) {
	idx := bytes.Index(line, marker)
	if idx < 0 {
		return netip.Addr{}, false
	}
	start := idx + len(marker)
	if start >= len(line) {
		return netip.Addr{}, false
	}
	end := bytes.IndexAny(line[start:], ", \n\r\t")
	if end < 0 {
		end = len(line) - start
	}
	if end <= 0 || start+end > len(line) {
		return netip.Addr{}, false
	}
	addr, err := netip.ParseAddr(string(line[start : start+end]))
	if err != nil {
		return netip.Addr{}, false
	}
	return addr, true
}

// extractUser extracts the username from "user=<...>" in dovecot logs.
func extractUser(line []byte) string {
	idx := bytes.Index(line, markerUser)
	if idx < 0 {
		return ""
	}
	start := idx + len(markerUser)
	if start >= len(line) {
		return ""
	}
	end := bytes.IndexByte(line[start:], '>')
	if end <= 0 {
		return ""
	}
	return string(line[start : start+end])
}

// parseSyslogTimestamp parses the first 15 chars of a syslog line
// ("Apr  9 03:01:45") and returns a time in the current year.
// Returns zero time on failure.
func parseSyslogTimestamp(line []byte) time.Time {
	if len(line) < 15 {
		return time.Time{}
	}
	// Syslog format: "Jan  2 15:04:05" — Go reference time
	t, err := time.Parse("Jan  2 15:04:05", string(line[:15]))
	if err != nil {
		// Try single-digit day with one space: "Apr 9 ..." doesn't happen
		// in standard syslog, but handle "Apr  9" (two spaces before single digit)
		return time.Time{}
	}
	// Syslog doesn't include year — use current year
	now := time.Now()
	t = t.AddDate(now.Year(), 0, 0)
	return t
}
