// =============================================================================
// NFTBan v1.80 - Exim parser (Phase C)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: exim
// Purpose: Parse Exim mainlog authenticator-failed lines into NormalizedEvents.
//
// meta:name="loginmon_pipeline_parser_exim"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="exim"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase C: Exim mainlog parser for the v1.80 Go pipeline"
//
// meta:inventory.files="exim.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package exim implements a Parser for Exim mainlog auth-failure lines.
//
// Exim mainlog format (from real srv2/srv3 fixtures):
//
//	2026-04-09 04:28:42 login authenticator failed for H=([92.118.39.211]) [92.118.39.211]: 535 Incorrect authentication data (set_id=admin@kostaskorakas.gr)
//
// The parser matches lines containing "authenticator" + "failed" and
// extracts:
//
//   - IP: first valid bracket-enclosed IP using forward scan ([92.118.39.211])
//   - Username: value inside "(set_id=...)" if present
//   - Timestamp: first 19 chars as YYYY-MM-DD HH:MM:SS
//
// PARITY TARGET
//
// The legacy parser is internal/loginmon/detector/mail.go detectExim()
// (lines 233-252) + extractFirstBracketIP() (lines 254-272). Parity:
//
//	legacy.IP == pipeline.SrcIP  (same forward-scan bracket extraction)
//
// The Go parser additionally extracts set_id (username), which the legacy
// parser does not. This is an improvement, not a deviation — parity on IP
// is the gate; username is a bonus.
package exim

import (
	"bytes"
	"net/netip"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// Exim timestamp layout (first 19 chars of mainlog line).
const eximTimestampLayout = "2006-01-02 15:04:05"

// Signals for quick rejection.
var (
	sigAuthenticator = []byte("authenticator")
	sigFailed        = []byte("failed")
)

// Parser implements runtime.Parser for Exim mainlog.
type Parser struct{}

// New constructs an Exim parser.
func New() *Parser { return &Parser{} }

// Name returns the source identifier.
func (p *Parser) Name() string { return "exim" }

// Parse attempts to extract a NormalizedEvent from an Exim mainlog line.
func (p *Parser) Parse(line event.RawLine) event.ParseResult {
	lower := bytes.ToLower(line.Line)

	// Quick rejection: must contain both "authenticator" and "failed".
	if !bytes.Contains(lower, sigAuthenticator) || !bytes.Contains(lower, sigFailed) {
		return event.ParseResult{Outcome: event.ParseSkipped}
	}

	// Extract first valid bracket IP using forward scan.
	// Exim puts the remote peer IP first: [attacker]:port H=(...) [attacker] I=[local]:port
	addr, ok := extractFirstBracketIP(line.Line)
	if !ok {
		return event.ParseResult{
			Outcome: event.ParseMalformed,
			Reason:  "authenticator failed but no valid bracket IP found",
		}
	}

	ts := parseEximTimestamp(line.Line)
	user := extractSetID(line.Line)

	return event.ParseResult{
		Outcome: event.ParseMatched,
		Event: event.NormalizedEvent{
			Source:    "exim",
			Service:   "exim_smtp",
			Reason:    event.ReasonEximAuthFail,
			SrcIP:     addr,
			Username:  user,
			Protocol:  "smtp",
			Timestamp: ts,
			Path:      line.Path,
			RawLine:   append([]byte(nil), line.Line...),
		},
	}
}

// extractFirstBracketIP finds the first valid IP inside [...] using a
// forward scan. This is the exact same algorithm as the legacy
// extractFirstBracketIP in detector/mail.go (lines 254-272).
func extractFirstBracketIP(line []byte) (netip.Addr, bool) {
	for i := 0; i < len(line); i++ {
		if line[i] != '[' {
			continue
		}
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
	return netip.Addr{}, false
}

// parseEximTimestamp extracts the timestamp from the first 19 chars.
func parseEximTimestamp(line []byte) time.Time {
	if len(line) < 19 {
		return time.Time{}
	}
	t, err := time.Parse(eximTimestampLayout, string(line[:19]))
	if err != nil {
		return time.Time{}
	}
	return t
}

// extractSetID extracts the username from "(set_id=user@domain)" if present.
// Returns "" if not found. This is an improvement over the legacy parser
// which does not extract set_id.
func extractSetID(line []byte) string {
	marker := []byte("(set_id=")
	idx := bytes.Index(line, marker)
	if idx < 0 {
		return ""
	}
	start := idx + len(marker)
	if start >= len(line) {
		return ""
	}
	end := bytes.IndexByte(line[start:], ')')
	if end <= 0 {
		return ""
	}
	return string(line[start : start+end])
}
