// =============================================================================
// NFTBan v1.160 - lifecycle JSON routing tests (PR-B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle_routing_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-07"
// meta:description="v1.160 PR-B: verifies lifecycle JSON routing — default goes to the structured log file not the console; opt-in (NFTBAN_LIFECYCLE_JSON/NFTBAN_DEBUG) also reaches the console; no-file+no-opt-in discards with a Debug note. Writers injected for testability."
// meta:input="lifecycleWriter()/lifecycleConsoleOptIn() with injected writers + env"
// meta:output="t.Error on mis-routed bytes"
// meta:depends="testing,bytes,io,os"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_LIFECYCLE_JSON,NFTBAN_DEBUG"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/lifecycle"
)

// emitOne drives a single lifecycle event through a logger bound to w so the
// test can assert which sink received the JSON.
func emitOne(w *bytes.Buffer) {
	lg := lifecycle.NewLogger(w, lifecycle.ModeInstall, false)
	lg.LogResult(lifecycle.RunResult{
		SchemaVersion: lifecycle.OutputSchemaVersion,
		Mode:          lifecycle.ModeInstall,
		Outcome:       lifecycle.OutcomeSuccess,
		Stage:         lifecycle.StageFinal,
	})
}

func TestLifecycleWriterDefaultGoesToFileNotConsole(t *testing.T) {
	var file, console bytes.Buffer

	w := lifecycleWriter(&file, false /*consoleOptIn*/, &console, nil)

	// The returned writer must be the file buffer (or route to it) and must
	// NOT write to the console buffer.
	if buf, ok := w.(*bytes.Buffer); !ok || buf != &file {
		t.Fatalf("default routing must select the file writer; got %T", w)
	}

	// Drive a real event through a logger bound to the chosen writer.
	emitOne(&file)
	if file.Len() == 0 {
		t.Errorf("expected lifecycle JSON in file, got empty")
	}
	if console.Len() != 0 {
		t.Errorf("default routing must not write to console; got %q", console.String())
	}
}

func TestLifecycleWriterOptInAlsoGoesToConsole(t *testing.T) {
	var file, console bytes.Buffer

	w := lifecycleWriter(&file, true /*consoleOptIn*/, &console, nil)

	lg := lifecycle.NewLogger(w, lifecycle.ModeInstall, false)
	lg.LogResult(lifecycle.RunResult{
		SchemaVersion: lifecycle.OutputSchemaVersion,
		Mode:          lifecycle.ModeInstall,
		Outcome:       lifecycle.OutcomeSuccess,
		Stage:         lifecycle.StageFinal,
	})

	if file.Len() == 0 {
		t.Errorf("opt-in routing must still write to file; got empty")
	}
	if console.Len() == 0 {
		t.Errorf("opt-in routing must also write to console; got empty")
	}
	if !strings.Contains(console.String(), `"event":"result"`) {
		t.Errorf("console output missing expected event JSON: %q", console.String())
	}
}

func TestLifecycleWriterOptInNoFileGoesToConsoleOnly(t *testing.T) {
	var console bytes.Buffer

	w := lifecycleWriter(nil /*file*/, true /*consoleOptIn*/, &console, nil)
	if buf, ok := w.(*bytes.Buffer); !ok || buf != &console {
		t.Fatalf("opt-in with no file must select console; got %T", w)
	}
}

func TestLifecycleWriterNoFileNoOptInDiscards(t *testing.T) {
	var console bytes.Buffer

	// log is nil here only to keep the test free of a real Logger; the routing
	// must still resolve to io.Discard (not the console).
	w := lifecycleWriter(nil /*file*/, false /*consoleOptIn*/, &console, nil)

	emitInto(w)
	if console.Len() != 0 {
		t.Errorf("discard routing must not write to console; got %q", console.String())
	}
}

// emitInto drives a lifecycle event through an arbitrary writer (used for the
// discard case where we only care that nothing reaches the console).
func emitInto(w interface {
	Write([]byte) (int, error)
}) {
	lg := lifecycle.NewLogger(w, lifecycle.ModeInstall, false)
	lg.LogResult(lifecycle.RunResult{
		SchemaVersion: lifecycle.OutputSchemaVersion,
		Mode:          lifecycle.ModeInstall,
		Outcome:       lifecycle.OutcomeSuccess,
		Stage:         lifecycle.StageFinal,
	})
}
