// =============================================================================
// NFTBan v1.229.11 lane 6A — installer rebuild interruption semantics
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-rebuild-interruption-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-25"
// meta:description="Proves that an INTERRUPTED firewall rebuild fails the install instead of being reported as a degraded-but-acceptable outcome. Before v1.229.11 the rebuild ran under a fixed 60s deadline; a host whose rebuild legitimately took longer (srv3: 453s) was killed, surfaced as ExitCode -1, matched neither the ==1 nor the >=2 branch, and fell through to a log line claiming the rebuild 'finished DEGRADED ... (recovery expected)' while Rebuild returned nil. The install therefore SUCCEEDED over a convergence that never completed. These tests pin the four result classes apart: SUCCESS, DEGRADED_COMPLETE, FAILED, and TIMED_OUT/INTERRUPTED."
// meta:inventory.files="internal/installer/switchop/rebuild_interruption_v1229_11_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

const rebuildKey = "/usr/sbin/nftban:firewall:rebuild:--install-context"

// A TIMEOUT IS NOT AN EXIT CODE. IT IS THE ABSENCE OF ONE.
func TestRebuild_TimedOut_IsFatalToTheInstall(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	// The shape a killed rebuild actually produces: no chosen exit code, and the
	// context reporting the deadline.
	mock.RunResults[rebuildKey] = executor.Result{ExitCode: -1, TimedOut: true}

	err := Rebuild(mock, newTestLogger())
	if err == nil {
		t.Fatal("an INTERRUPTED rebuild must fail the install — convergence did not complete")
	}
	if !strings.Contains(err.Error(), "INTERRUPTED") {
		t.Errorf("the error must name interruption, not a generic failure; got: %v", err)
	}
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("an interrupted convergence must write the install-failed marker")
	}
}

// The pre-fix regression, pinned: a timeout must never be narrated as DEGRADED.
func TestRebuild_TimedOut_IsNotReportedAsDegraded(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	mock.RunResults[rebuildKey] = executor.Result{ExitCode: -1, TimedOut: true}

	log, dump := readLog(t)
	_ = Rebuild(mock, log)
	out := dump()

	for _, forbidden := range []string{
		"finished DEGRADED",
		"recovery expected",
		"module chains deferred to daemon start",
	} {
		if strings.Contains(out, forbidden) {
			t.Errorf("an interrupted rebuild must not be narrated as recoverable; log contained %q\n%s", forbidden, out)
		}
	}
}

// A process that died without choosing an exit code is equally incomplete, even
// when no deadline was involved (SIGKILL, OOM, or a missing binary).
func TestRebuild_NoExitStatus_IsFatal(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	mock.RunResults[rebuildKey] = executor.Result{ExitCode: -1, Stderr: "signal: killed"}

	err := Rebuild(mock, newTestLogger())
	if err == nil {
		t.Fatal("a rebuild that produced no exit status must fail the install")
	}
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("expected the install-failed marker")
	}
}

// ⛔ NON-VACUITY. The three classes that must still behave as before — otherwise
// the tests above would pass on a Rebuild that simply fails everything.
func TestRebuild_SurvivingClassesUnchanged(t *testing.T) {
	cases := []struct {
		name    string
		res     executor.Result
		wantErr bool
		marker  bool
	}{
		{"SUCCESS", executor.Result{ExitCode: 0}, false, false},
		{"DEGRADED_COMPLETE", executor.Result{ExitCode: 1, Stderr: "modules deferred"}, false, false},
		{"FAILED", executor.Result{ExitCode: 2, Stderr: "rollback"}, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mock := executor.NewMockExecutor()
			mock.StrictUnregistered = true
			mock.RunResults[rebuildKey] = tc.res

			err := Rebuild(mock, newTestLogger())
			if tc.wantErr && err == nil {
				t.Fatalf("%s must return an error", tc.name)
			}
			if !tc.wantErr && err != nil {
				t.Fatalf("%s must not return an error, got: %v", tc.name, err)
			}
			if got := mock.FileExists("/run/nftban/install_failed"); got != tc.marker {
				t.Errorf("%s marker = %v, want %v", tc.name, got, tc.marker)
			}
		})
	}
}
