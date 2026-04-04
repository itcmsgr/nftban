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

func TestRebuild_Failure(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild"] = executor.Result{ExitCode: 1, Stderr: "rebuild failed"}

	err := Rebuild(mock, newTestLogger())
	if err == nil {
		t.Fatal("expected error, got nil")
	}

	// Verify install-failed marker was written
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("expected install_failed marker to be written")
	}
}
