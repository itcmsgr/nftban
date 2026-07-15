// =============================================================================
// NFTBan v1.80 - DirectAdmin parser (Phase B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: directadmin
// Purpose: Parse DirectAdmin login.log failed-login lines into NormalizedEvents.
//
// meta:name="loginmon_pipeline_parser_directadmin"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="directadmin"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase B: DirectAdmin login.log parser for the v1.80 Go pipeline"
//
// meta:inventory.files="directadmin.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package directadmin implements a Parser for DirectAdmin's login.log format.
//
// Phase B scope: parse login.log only. security.log is empty on the production
// fleet as of 2026-04-09 (verified); it will be added when real security.log
// samples become available.
//
// DA login.log line format (a sanitized sample line):
//
//	2026:04:04-12:21:12: '192.0.2.122' 1 failed login attempts. Account 'admin'
//	2026:04:04-12:21:21: '192.0.2.122' successful login to 'reseller_admin'
//
// The parser matches lines containing "failed login" (case-insensitive) and
// extracts:
//
//   - IP: first single-quoted value
//   - Username: value inside "Account '<user>'"
//   - Timestamp: first 19 chars parsed as YYYY:MM:DD-HH:MM:SS
//
// Lines containing "successful login" are skipped. Lines that match "failed
// login" but fail field extraction are reported as ParseMalformed (data
// anomaly, not a parser bug).
//
// PARITY TARGET
//
// The legacy parser is internal/loginmon/detector/panel.go
// detectDANativeFormat() (lines 178–219). Parity is defined as: for every
// line where the legacy parser returns (Verdict, true), this parser returns
// (ParseMatched, NormalizedEvent) with:
//
//	legacy.IP                          == pipeline.SrcIP
//	legacy.ReasonNames[legacy.Reason]  == string(pipeline.Reason)
//	legacy.User                        == pipeline.Username
//
// The parity test in directadmin_test.go asserts this on the sanitized sample fixture.
package directadmin

import (
	"bytes"
	"net/netip"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// DA login.log timestamp layout. The first 19 characters of each line are
// the timestamp in this format.
const daTimestampLayout = "2006:01:02-15:04:05"

// Signals for quick rejection.
var (
	sigFailedLogin = []byte("failed login")
)

// Parser implements runtime.Parser for DirectAdmin login.log.
//
// The parser is stateless: same input, same output. No I/O, no DNS, no
// cross-line state. Thread-safe by construction (no mutable fields).
type Parser struct{}

// New constructs a DirectAdmin parser. It takes no configuration because
// the line format is fixed.
func New() *Parser { return &Parser{} }

// Name returns the source identifier this parser handles.
func (p *Parser) Name() string { return "directadmin" }

// Parse attempts to extract a NormalizedEvent from a DA login.log line.
//
// Returns ParseMatched for "failed login" lines with valid IP extraction.
// Returns ParseSkipped for "successful login" or non-matching lines.
// Returns ParseMalformed for "failed login" lines where the IP cannot be
// extracted (data anomaly in the log).
func (p *Parser) Parse(line event.RawLine) event.ParseResult {
	// Quick rejection: must contain "failed login" (case-insensitive).
	if !bytes.Contains(bytes.ToLower(line.Line), sigFailedLogin) {
		return event.ParseResult{Outcome: event.ParseSkipped}
	}

	// Extract IP from first single-quoted value: '192.0.2.122'
	qStart := bytes.IndexByte(line.Line, '\'')
	if qStart < 0 {
		return event.ParseResult{
			Outcome: event.ParseMalformed,
			Reason:  "failed login line but no single-quoted IP",
		}
	}
	rest := line.Line[qStart+1:]
	qEnd := bytes.IndexByte(rest, '\'')
	if qEnd <= 0 {
		return event.ParseResult{
			Outcome: event.ParseMalformed,
			Reason:  "failed login line but unclosed IP quote",
		}
	}
	ipStr := string(rest[:qEnd])
	addr, err := netip.ParseAddr(ipStr)
	if err != nil {
		return event.ParseResult{
			Outcome: event.ParseMalformed,
			Reason:  "failed login line but IP parse failed: " + ipStr,
		}
	}

	// Extract timestamp from the first 19 characters.
	ts := parseDATimestamp(line.Line)

	// Extract username from "Account 'USER'"
	user := extractAccount(line.Line)

	return event.ParseResult{
		Outcome: event.ParseMatched,
		Event: event.NormalizedEvent{
			Source:    "directadmin",
			Service:   "directadmin_login",
			Reason:    event.ReasonDirectAdminFail,
			SrcIP:     addr,
			Username:  user,
			Protocol:  "panel",
			Timestamp: ts,
			Path:      line.Path,
			RawLine:   append([]byte(nil), line.Line...),
		},
	}
}

// parseDATimestamp extracts the timestamp from the first 19 chars of a DA
// login.log line. Returns zero time on failure (the event still gets
// ingested; the aggregator handles zero timestamps gracefully).
func parseDATimestamp(line []byte) time.Time {
	if len(line) < 19 {
		return time.Time{}
	}
	t, err := time.Parse(daTimestampLayout, string(line[:19]))
	if err != nil {
		return time.Time{}
	}
	return t
}

// extractAccount extracts the username from "Account '<user>'" in a DA
// login.log line. Returns "" if not found.
func extractAccount(line []byte) string {
	marker := []byte("Account '")
	idx := bytes.Index(line, marker)
	if idx < 0 {
		return ""
	}
	uStart := idx + len(marker)
	if uStart >= len(line) {
		return ""
	}
	uEnd := bytes.IndexByte(line[uStart:], '\'')
	if uEnd <= 0 {
		return ""
	}
	return string(line[uStart : uStart+uEnd])
}
