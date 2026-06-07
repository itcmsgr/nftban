// =============================================================================
// NFTBan v1.156 PR-C — Installer [PHASE] boundary-marker tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-phase-markers-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-07"
// meta:description="Assert each installer phase emits greppable [PHASE] start/end markers and that the marker name set is 1:1 with the phase function set"
// meta:inventory.files="cmd/nftban-installer/phase_markers_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// PR-C is logging-string-only observability. These tests assert:
//
//   T-PM1  phaseStartMarker / phaseEndMarker emit the exact greppable
//          "[PHASE] <name> start" / "[PHASE] <name> end" strings.
//   T-PM2  every phase function emits its "start" marker at runtime (proven
//          by driving each phase with a cancelled context — the start marker
//          is at the top of each phase function, before the ctx guard, so it
//          always fires regardless of how the phase then returns).
//   T-PM3  PARITY — the phaseNames set is exactly 1:1 with the phase
//          functions defined in phases.go AND every phase function body
//          contains both a start and an end marker call for its own name.
//          This is the drift guard: a new phase added without markers (or a
//          phaseNames entry without a function, or vice-versa) fails here.
//
// =============================================================================
package main

import (
	"context"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

// newMarkerLogger returns a Logger writing to a tempfile + the path to read
// back. Mirrors newLoggingTestLogger in update_apply_logging_test.go.
func newMarkerLogger(t *testing.T) (*logging.Logger, string) {
	t.Helper()
	logPath := filepath.Join(t.TempDir(), "phase.log")
	return logging.New(logPath, true), logPath
}

func readMarkerLog(t *testing.T, logPath string) string {
	t.Helper()
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	return string(data)
}

// T-PM1 — the marker helpers emit the exact greppable strings.
func TestPhaseMarkerStrings(t *testing.T) {
	log, logPath := newMarkerLogger(t)
	for _, name := range phaseNames {
		phaseStartMarker(log, name)
		phaseEndMarker(log, name)
	}
	log.Close()

	content := readMarkerLog(t, logPath)
	for _, name := range phaseNames {
		if !strings.Contains(content, "[PHASE] "+name+" start") {
			t.Errorf("missing start marker for phase %q:\n%s", name, content)
		}
		if !strings.Contains(content, "[PHASE] "+name+" end") {
			t.Errorf("missing end marker for phase %q:\n%s", name, content)
		}
	}
}

// T-PM2 — every phase function emits its start marker at runtime. Driven with
// a cancelled context so each phase returns deterministically right after the
// entry guard; the start marker is above the guard so it always fires.
func TestPhaseFunctionsEmitStartMarker(t *testing.T) {
	type phaseEntry struct {
		marker string
		fn     func(context.Context, executor.Executor, *state.StateFile, *logging.Logger) error
	}
	phases := []phaseEntry{
		{"detect", phaseDetect},
		{"prepare", phasePrepare},
		{"switch", phaseSwitch},
		{"configure", phaseConfigure},
		{"validate", phaseValidate},
	}

	for _, p := range phases {
		p := p
		t.Run(p.marker, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			cancel() // pre-cancelled — phase returns right after the entry guard

			mock := executor.NewMockExecutor()
			sf := state.NewStateFile(t.TempDir())
			log, logPath := newMarkerLogger(t)
			_ = p.fn(ctx, mock, sf, log)
			log.Close()

			content := readMarkerLog(t, logPath)
			if !strings.Contains(content, "[PHASE] "+p.marker+" start") {
				t.Errorf("phase %q did not emit its start marker:\n%s", p.marker, content)
			}
		})
	}
}

// phasesGoSource returns the contents of phases.go, resolved relative to this
// test file (same runtime.Caller pattern as the timers parity test).
func phasesGoSource(t *testing.T) string {
	t.Helper()
	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed — cannot locate phases.go")
	}
	src := filepath.Join(filepath.Dir(filename), "phases.go")
	data, err := os.ReadFile(src)
	if err != nil {
		t.Fatalf("read phases.go: %v", err)
	}
	return string(data)
}

// T-PM3 — parity: phaseNames ≡ the phase functions defined in phases.go, AND
// every phase function carries both a start and end marker for its own name.
func TestPhaseMarkerParity(t *testing.T) {
	src := phasesGoSource(t)

	// Discover every phase function declared in phases.go. A phase function
	// is identified by its canonical signature (ctx context.Context, exec
	// executor.Executor, ...) — this deliberately excludes the marker helpers
	// phaseStartMarker/phaseEndMarker, which take (*logging.Logger, string).
	//   func phaseDetect(ctx context.Context, ... -> "detect"
	fnRe := regexp.MustCompile(`(?m)^func phase([A-Z][A-Za-z]*)\(ctx context\.Context,`)
	var fnNames []string
	for _, m := range fnRe.FindAllStringSubmatch(src, -1) {
		fnNames = append(fnNames, strings.ToLower(m[1]))
	}
	if len(fnNames) == 0 {
		t.Fatal("no phase functions discovered in phases.go — regex drift?")
	}

	// Set equality: phaseNames must equal the discovered function set.
	wantNames := append([]string{}, phaseNames...)
	sort.Strings(wantNames)
	gotNames := append([]string{}, fnNames...)
	sort.Strings(gotNames)

	nameSet := func(xs []string) map[string]bool {
		m := make(map[string]bool, len(xs))
		for _, x := range xs {
			m[x] = true
		}
		return m
	}
	wantSet := nameSet(wantNames)
	gotSet := nameSet(gotNames)

	for _, n := range gotNames {
		if !wantSet[n] {
			t.Errorf("phase function for %q has NO entry in phaseNames (add %q so it gets [PHASE] markers)", n, n)
		}
	}
	for _, n := range wantNames {
		if !gotSet[n] {
			t.Errorf("phaseNames lists %q but there is no matching phase function in phases.go", n)
		}
	}

	// Each phase must have BOTH a start and an end marker call for its name.
	for _, n := range phaseNames {
		if !strings.Contains(src, `phaseStartMarker(log, "`+n+`")`) {
			t.Errorf("phases.go is missing phaseStartMarker(log, %q) for phase %q", n, n)
		}
		if !strings.Contains(src, `phaseEndMarker(log, "`+n+`")`) {
			t.Errorf("phases.go is missing phaseEndMarker(log, %q) for phase %q", n, n)
		}
	}
}
