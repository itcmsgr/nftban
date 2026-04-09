// =============================================================================
// NFTBan v1.80 - pipeline event types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: event
// Purpose: Canonical data types for the detection pipeline (RawLine, NormalizedEvent).
//
// meta:name="loginmon_pipeline_event"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="event"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Pipeline event types — bottom of the import DAG, stdlib only"
//
// meta:inventory.files="event.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package event defines the canonical data types passed through the v1.80
// detection pipeline. It is the bottom of the import DAG: every other
// pipeline package depends on it, and it depends only on the standard library.
package event

import (
	"net/netip"
	"time"
)

// RawLine is a single log line emitted by a Watcher.
//
// It carries the raw bytes (not interpreted), the path the bytes were read
// from at read time (which may differ from the source's canonical path after
// rotation), the byte offset in the file, and the wall-clock time the
// watcher observed it.
//
// RawLine is the input to a Parser. Parsers MUST NOT mutate the Line field;
// the byte slice may be reused by the watcher.
type RawLine struct {
	Source     string    // source name, e.g. "directadmin", "exim", "dovecot"
	Path       string    // file path at the moment of read
	Line       []byte    // raw bytes of one log line, no trailing newline
	Offset     int64     // byte offset within Path
	ReceivedAt time.Time // wall-clock when the watcher emitted this line
}

// NormalizedEvent is the canonical event shape passed downstream from a
// Parser. Aggregation, dedup, and effective-axis logic key on these fields.
//
// All fields are immutable after the parser populates them. Downstream stages
// MAY enrich (e.g. ASN lookup) but MUST NOT change parser-set fields.
type NormalizedEvent struct {
	// Identity
	EventID string // monotonic, host-local: source + offset + ts
	Source  string // "directadmin", "exim", "dovecot", "postfix", ...
	Service string // free-form service identifier ("dovecot_imap", etc.)
	Reason  Reason // canonical reason taxonomy

	// Network
	SrcIP netip.Addr // canonical, IPv6 lowered, ::ffff:v4 stripped
	DstIP netip.Addr // local listener IP if known; zero value if not
	SrcASN int       // 0 if unknown; populated by normalize layer if available

	// Identity (auth)
	Username string // bare username or "user@domain" form; "" if absent
	Domain   string // RFC822 right-hand side or extracted from Username
	Protocol string // "imap", "pop3", "smtp", "panel", "ssh", ...

	// Provenance
	Panel      string    // from source descriptor; "directadmin", "cpanel", "plesk", ""
	Confidence int       // 0..100; 100 = parser-certain. Reserved for future use.
	Timestamp  time.Time // event timestamp from log line, NOT wall-clock
	Path       string    // file path at parse time

	// Forensic fallback (not used by aggregator)
	RawLine []byte // a copy of the raw line, for status/dump only
}

// Reason is the canonical taxonomy of detection reasons. New reasons are
// added by appending; existing values must not be renumbered or repurposed.
type Reason string

// Phase A defines only the reasons whose parsers will be migrated in
// Phases B-D (DirectAdmin, Exim, Dovecot, Postfix). SSH and FTP reasons
// are intentionally NOT defined here yet — they belong to later phases
// and would only collide with the existing detector package's reason
// constants if added prematurely. They will be introduced in the phase
// that wires an SSH or FTP parser through the Go pipeline.
const (
	ReasonUnknown         Reason = ""
	ReasonDovecotAuthFail Reason = "dovecot_auth_fail"
	ReasonDovecotPamFail  Reason = "dovecot_pam_fail"
	ReasonPostfixSASLFail Reason = "postfix_sasl_fail"
	ReasonEximAuthFail    Reason = "exim_auth_fail"
	ReasonDirectAdminFail Reason = "directadmin_login_fail"
	ReasonDirectAdminSec  Reason = "directadmin_security_fail"
)

// String satisfies fmt.Stringer.
func (r Reason) String() string { return string(r) }

// ParseOutcome discriminates Parser results so callers can distinguish
// "no match" (normal) from "parser bug" (error).
type ParseOutcome int

const (
	// ParseSkipped means the line did not match any pattern. This is normal
	// for the vast majority of lines and is not an error.
	ParseSkipped ParseOutcome = iota

	// ParseMatched means the line produced a NormalizedEvent.
	ParseMatched

	// ParseMalformed means the line matched a pattern but field extraction
	// failed (e.g. an IP that doesn't parse). This is a data anomaly the
	// parser should record but not crash on.
	ParseMalformed

	// ParseError means the parser hit an internal error (panic, regex
	// compile failure, etc.). This should never happen in production.
	ParseError
)

// String satisfies fmt.Stringer.
func (o ParseOutcome) String() string {
	switch o {
	case ParseSkipped:
		return "skipped"
	case ParseMatched:
		return "matched"
	case ParseMalformed:
		return "malformed"
	case ParseError:
		return "error"
	}
	return "unknown"
}

// ParseResult is what a Parser returns for one RawLine.
//
// We deliberately do NOT use (NormalizedEvent, error) where error means
// "no match" — that conflates parser bugs with normal "this line is
// uninteresting". The explicit ParseOutcome eliminates the ambiguity.
type ParseResult struct {
	Outcome ParseOutcome
	Event   NormalizedEvent // valid only when Outcome == ParseMatched
	Reason  string          // diagnostic for non-matched outcomes
}
