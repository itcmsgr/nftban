// =============================================================================
// NFTBan v1.100 Amendment 2 — Evidence reader unit tests (§56.5)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-restore-decide-evidence-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Per-row coverage for gatherOrphanEvidence + dispatcher integration"
// meta:inventory.files="cmd/nftban-installer/restore_decide_evidence_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// happyExec returns a MockExecutor pre-seeded so every §54.1 row holds.
func happyExec() *executor.MockExecutor {
	exec := executor.NewMockExecutor()
	// E.6: csf.service exists, not active, is-enabled=masked.
	exec.Services["csf.service"] = false // inactive
	exec.RunResults["systemctl:status:--no-pager:--lines=0:csf.service"] = executor.Result{
		ExitCode: 0,
		Stdout:   "● csf.service\n     Loaded: masked (Reason: Unit csf.service is masked.)\n     Active: inactive (dead)\n",
	}
	exec.RunResults["systemctl:is-enabled:csf.service"] = executor.Result{
		ExitCode: 0,
		Stdout:   "masked\n",
	}
	// E.7: /usr/sbin/csf.disabled exists.
	exec.Files["/usr/sbin/csf.disabled"] = []byte("dummy-binary")
	// E.8: /usr/sbin/csf absent — ensured by not putting it in Files.
	// E.9, E.10: nft tables present.
	exec.NftTables["ip:nftban"] = true
	exec.NftTables["ip6:nftban"] = true
	// E.11: nftband.service active.
	exec.Services["nftband.service"] = true
	return exec
}

func happyAuth() *uninstall.ClassifyResult {
	return &uninstall.ClassifyResult{
		State:     uninstall.AuthorityNFTBan,
		Ambiguity: uninstall.AmbiguityNone,
	}
}

func happyProbe() *uninstall.ProbeResult {
	return &uninstall.ProbeResult{State: uninstall.PriorNoRecord}
}

func happyCfg() *config {
	return &config{
		mode:               "restore",
		panelAutoTakeover:  true,
		acceptOrphanNFTBan: true,
	}
}

// TestGatherOrphanEvidence_AllTrue confirms the happy-path returns
// every row true.
func TestGatherOrphanEvidence_AllTrue(t *testing.T) {
	log := logging.New("/dev/null", false)
	ev := gatherOrphanEvidence(happyExec(), log, detect.PanelDirectAdmin, happyAuth(), happyProbe(), happyCfg())
	if !ev.AllTrue() {
		t.Errorf("AllTrue=false; failed row=%s", ev.FailedRowID())
	}
}

// TestGatherOrphanEvidence_PerRowFailure confirms each row fails
// independently when its precondition is removed. This is §56.5 row
// coverage.
func TestGatherOrphanEvidence_PerRowFailure(t *testing.T) {
	tests := []struct {
		name     string
		mutate   func(*executor.MockExecutor, *uninstall.ClassifyResult, *uninstall.ProbeResult, *config, *detect.PanelType)
		wantFail string
	}{
		{
			name: "E1_panel_not_directadmin",
			mutate: func(_ *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, p *detect.PanelType) {
				*p = detect.PanelCPanel
			},
			wantFail: "AMD2-E.1",
		},
		{
			name: "E2_authority_not_nftban",
			mutate: func(_ *executor.MockExecutor, a *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				a.State = uninstall.AuthorityNone
			},
			wantFail: "AMD2-E.2",
		},
		{
			name: "E3_prior_not_norecord",
			mutate: func(_ *executor.MockExecutor, _ *uninstall.ClassifyResult, p *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				p.State = uninstall.PriorRecordIncomplete
			},
			wantFail: "AMD2-E.3",
		},
		{
			name: "E4_panel_auto_off",
			mutate: func(_ *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, c *config, _ *detect.PanelType) {
				c.panelAutoTakeover = false
			},
			wantFail: "AMD2-E.4",
		},
		{
			name: "E5_orphan_flag_off",
			mutate: func(_ *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, c *config, _ *detect.PanelType) {
				c.acceptOrphanNFTBan = false
			},
			wantFail: "AMD2-E.5",
		},
		{
			name: "E6_csf_active",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.Services["csf.service"] = true
			},
			wantFail: "AMD2-E.6",
		},
		{
			name: "E6_csf_not_found",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.RunResults["systemctl:status:--no-pager:--lines=0:csf.service"] = executor.Result{
					ExitCode: 4,
					Stderr:   "Unit csf.service could not be found.\n",
				}
			},
			wantFail: "AMD2-E.6",
		},
		{
			name: "E6_csf_enabled_forbidden",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.RunResults["systemctl:is-enabled:csf.service"] = executor.Result{
					ExitCode: 0,
					Stdout:   "enabled\n",
				}
			},
			wantFail: "AMD2-E.6",
		},
		{
			name: "E6_csf_static_forbidden",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.RunResults["systemctl:is-enabled:csf.service"] = executor.Result{
					ExitCode: 0,
					Stdout:   "static\n",
				}
			},
			wantFail: "AMD2-E.6",
		},
		{
			name: "E6_csf_disabled_acceptable_fallback",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.RunResults["systemctl:is-enabled:csf.service"] = executor.Result{
					ExitCode: 1, // systemctl exits non-zero for "disabled" but we only read stdout
					Stdout:   "disabled\n",
				}
			},
			wantFail: "", // disabled is acceptable fallback per AMD2-E.6
		},
		{
			name: "E7_csf_disabled_absent",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				delete(e.Files, "/usr/sbin/csf.disabled")
			},
			wantFail: "AMD2-E.7",
		},
		{
			name: "E8_csf_present",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.Files["/usr/sbin/csf"] = []byte("dummy")
			},
			wantFail: "AMD2-E.8",
		},
		{
			name: "E9_ip_nftban_absent",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.NftTables["ip:nftban"] = false
			},
			wantFail: "AMD2-E.9",
		},
		{
			name: "E10_ip6_nftban_absent",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.NftTables["ip6:nftban"] = false
			},
			wantFail: "AMD2-E.10",
		},
		{
			name: "E11_nftband_inactive",
			mutate: func(e *executor.MockExecutor, _ *uninstall.ClassifyResult, _ *uninstall.ProbeResult, _ *config, _ *detect.PanelType) {
				e.Services["nftband.service"] = false
			},
			wantFail: "AMD2-E.11",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			exec := happyExec()
			auth := happyAuth()
			probe := happyProbe()
			cfg := happyCfg()
			panel := detect.PanelDirectAdmin
			tc.mutate(exec, auth, probe, cfg, &panel)
			log := logging.New("/dev/null", false)
			ev := gatherOrphanEvidence(exec, log, panel, auth, probe, cfg)
			got := ev.FailedRowID()
			if got != tc.wantFail {
				t.Errorf("FailedRowID = %q, want %q (AllTrue=%v)", got, tc.wantFail, ev.AllTrue())
			}
		})
	}
}

// TestAcceptOrphanNFTBan_NoEnvVarFallback (Amendment 2 §55, §56.1 row 20):
// the dispatcher uses cfg.acceptOrphanNFTBan exclusively. Even if the
// env var NFTBAN_ACCEPT_ORPHAN is set, the engine sees
// AcceptOrphanNFTBan=false unless the CLI parser explicitly set it.
//
// This test is structural: it asserts that the flags.go source does
// NOT contain any os.Getenv path that mirrors NFTBAN_ACCEPT_ORPHAN
// onto cfg.acceptOrphanNFTBan.
func TestAcceptOrphanNFTBan_NoEnvVarFallback(t *testing.T) {
	const forbidden = "NFTBAN_ACCEPT_ORPHAN"
	data, err := readFileBytes("flags.go")
	if err != nil {
		t.Fatalf("read flags.go: %v", err)
	}
	if contains(data, forbidden) {
		t.Errorf("Amendment 2 §55: flags.go contains forbidden env-var %q (CLI argv only)", forbidden)
	}
	// Defensive: also assert no env-var path in restore_decide.go.
	data2, err := readFileBytes("restore_decide.go")
	if err == nil {
		if contains(data2, forbidden) {
			t.Errorf("Amendment 2 §55: restore_decide.go contains forbidden env-var %q", forbidden)
		}
	}
}

// readFileBytes is a tiny helper kept inline to avoid pulling in
// os/ioutil at top of file.
func readFileBytes(path string) ([]byte, error) {
	return readFileImpl(path)
}

// contains is a substring check. Plain bytes.Contains-like behavior.
func contains(haystack []byte, needle string) bool {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		match := true
		for j := 0; j < len(needle); j++ {
			if haystack[i+j] != needle[j] {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
