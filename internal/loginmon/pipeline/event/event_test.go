// =============================================================================
// NFTBan v1.80 - pipeline event types tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: event
// Purpose: Tests for canonical event types.
//
// meta:name="loginmon_pipeline_event_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="event"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Tests for pipeline event types"
//
// meta:inventory.files="event_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package event

import "testing"

func TestReasonString(t *testing.T) {
	if ReasonDovecotAuthFail.String() != "dovecot_auth_fail" {
		t.Errorf("Reason.String: got %q", ReasonDovecotAuthFail.String())
	}
	if ReasonUnknown.String() != "" {
		t.Errorf("ReasonUnknown.String: expected empty, got %q", ReasonUnknown.String())
	}
}

func TestParseOutcomeString(t *testing.T) {
	cases := map[ParseOutcome]string{
		ParseSkipped:   "skipped",
		ParseMatched:   "matched",
		ParseMalformed: "malformed",
		ParseError:     "error",
	}
	for in, want := range cases {
		if in.String() != want {
			t.Errorf("ParseOutcome(%d).String: got %q, want %q", in, in.String(), want)
		}
	}
}

func TestParseResultZeroValue(t *testing.T) {
	// Default-constructed ParseResult is ParseSkipped with empty event.
	// This is important for parsers that return early on no-match.
	var r ParseResult
	if r.Outcome != ParseSkipped {
		t.Errorf("zero ParseResult.Outcome: got %v, want ParseSkipped", r.Outcome)
	}
	if r.Event.Source != "" {
		t.Errorf("zero ParseResult.Event.Source: got %q, want empty", r.Event.Source)
	}
}
