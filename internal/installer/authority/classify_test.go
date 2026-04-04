// =============================================================================
// NFTBan v1.73 - Installer Authority Classification Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-authority-classify-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for authority decision tree"
// meta:inventory.files="internal/installer/authority/classify_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package authority

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

func TestClassify_Update(t *testing.T) {
	mock := executor.NewMockExecutor()
	// NFTBan table + chain exist
	mock.NftTables["ip:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}

	decision := Classify(mock, nil, detect.PanelNone, false, newTestLogger())
	if decision != Update {
		t.Errorf("decision = %s, want UPDATE", decision)
	}
}

func TestClassify_Update_WithConflicts(t *testing.T) {
	// UPDATE takes priority even if conflicts exist
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}

	conflicts := []detect.Conflict{{Name: "firewalld", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, false, newTestLogger())
	if decision != Update {
		t.Errorf("decision = %s, want UPDATE (table+chain exist, ignoring conflicts)", decision)
	}
}

func TestClassify_Fresh(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No NFTBan table, no conflicts
	decision := Classify(mock, nil, detect.PanelNone, false, newTestLogger())
	if decision != Fresh {
		t.Errorf("decision = %s, want FRESH", decision)
	}
}

func TestClassify_Takeover_EnvVar(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Env["NFTBAN_TAKEOVER"] = "1"

	conflicts := []detect.Conflict{{Name: "CSF", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, false, newTestLogger())
	if decision != Takeover {
		t.Errorf("decision = %s, want TAKEOVER (env var)", decision)
	}
}

func TestClassify_Takeover_Flag(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{{Name: "UFW", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, true, newTestLogger())
	if decision != Takeover {
		t.Errorf("decision = %s, want TAKEOVER (--takeover flag)", decision)
	}
}

func TestClassify_Takeover_PanelAutoApprove(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{{Name: "firewalld", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelCPanel, false, newTestLogger())
	if decision != Takeover {
		t.Errorf("decision = %s, want TAKEOVER (cPanel auto-approve)", decision)
	}
}

func TestClassify_Abort(t *testing.T) {
	mock := executor.NewMockExecutor()

	conflicts := []detect.Conflict{{Name: "CSF", Active: true}}
	decision := Classify(mock, conflicts, detect.PanelNone, false, newTestLogger())
	if decision != Abort {
		t.Errorf("decision = %s, want ABORT (conflicts, no approval)", decision)
	}
}

func TestClassify_TableWithoutChain(t *testing.T) {
	// Table exists but chain doesn't → not authoritative → check conflicts
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 1, Stderr: "no such chain"}

	decision := Classify(mock, nil, detect.PanelNone, false, newTestLogger())
	if decision != Fresh {
		t.Errorf("decision = %s, want FRESH (table without chain = not authoritative)", decision)
	}
}

func TestClassify_Priority_UpdateOverConflicts(t *testing.T) {
	// Even with every conflict active, UPDATE wins if NFTBan owns the firewall
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}

	conflicts := []detect.Conflict{
		{Name: "CSF", Active: true},
		{Name: "UFW", Active: true},
		{Name: "firewalld", Active: true},
	}
	decision := Classify(mock, conflicts, detect.PanelCPanel, true, newTestLogger())
	if decision != Update {
		t.Errorf("decision = %s, want UPDATE (overrides everything)", decision)
	}
}
