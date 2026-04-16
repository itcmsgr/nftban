// =============================================================================
// NFTBan v1.73 - Installer Rebuild Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-rebuild-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for nftban firewall rebuild operations"
// meta:inventory.files="internal/installer/switchop/rebuild_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

func TestRebuild_Success(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild"] = executor.Result{ExitCode: 0}

	err := Rebuild(mock, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestRebuild_Degraded(t *testing.T) {
	// Exit 1 = DEGRADED: firewall operational but module checks failed.
	// This is expected during upgrade and must NOT return an error.
	mock := executor.NewMockExecutor()
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild"] = executor.Result{ExitCode: 1, Stderr: "DEGRADED"}

	err := Rebuild(mock, newTestLogger())
	if err != nil {
		t.Fatalf("exit 1 (DEGRADED) should not return error, got: %v", err)
	}

	// Verify install-failed marker was NOT written for degraded
	if mock.FileExists("/run/nftban/install_failed") {
		t.Error("install_failed marker should not be written for DEGRADED")
	}
}

func TestRebuild_Failure(t *testing.T) {
	// Exit 2 = FAILED: rebuild failed, rollback happened.
	mock := executor.NewMockExecutor()
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild"] = executor.Result{ExitCode: 2, Stderr: "rebuild failed"}

	err := Rebuild(mock, newTestLogger())
	if err == nil {
		t.Fatal("exit 2 (FAILED) should return error, got nil")
	}

	// Verify install-failed marker was written
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("expected install_failed marker to be written")
	}
}
