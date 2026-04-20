// =============================================================================
// NFTBan v1.100 PR-P2-2 — Cross-caller consistency proof
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-extfw-consistency-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="Proof that install and uninstall lifecycle paths see the same external-firewall truth"
// meta:inventory.files="internal/installer/extfw/consistency_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// PR-P2-2 hard rule: same mocked host → same external-firewall result
// across all lifecycle callers. This test file is the falsifiable
// regression guard for that invariant.
//
// The test uses an external _test package (extfw_test) so it can import
// both detect/conflicts.go and uninstall/authority.go — the two
// historically-divergent surfaces that PR-P2-2 unifies.
//
// =============================================================================
package extfw_test

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/extfw"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

func newTestLogger() *logging.Logger { return logging.New("/dev/null", false) }

// hostFixture describes a mocked host and the single external-firewall
// truth that every lifecycle caller MUST agree on for that host.
type hostFixture struct {
	name   string
	setup  func(*executor.MockExecutor)
	wantFW extfw.Name // the firewall every caller must see, or NameNone
	// wantAmbiguous is true when the host has multiple active firewalls
	// and every caller must surface the ambiguity rather than pick one.
	wantAmbiguous bool
}

var cleanBase = func(m *executor.MockExecutor) {
	m.ExistingCommands["nft"] = true
	m.RunResults["nft:list:tables"] = executor.Result{ExitCode: 0, Stdout: ""}
	m.RunResults["iptables-save"] = executor.Result{
		ExitCode: 0,
		Stdout:   "# Generated\n*filter\n:INPUT ACCEPT\nCOMMIT\n",
	}
}

func fixtures() []hostFixture {
	return []hostFixture{
		{
			name: "clean host — no firewalls",
			setup: func(m *executor.MockExecutor) {
				cleanBase(m)
			},
			wantFW: extfw.NameNone,
		},
		{
			name: "ufw service only",
			setup: func(m *executor.MockExecutor) {
				cleanBase(m)
				m.Services["ufw.service"] = true
			},
			wantFW: extfw.NameUFW,
		},
		{
			name: "firewalld service only",
			setup: func(m *executor.MockExecutor) {
				cleanBase(m)
				m.Services["firewalld.service"] = true
			},
			wantFW: extfw.NameFirewalld,
		},
		{
			name: "iptables-save rules present",
			setup: func(m *executor.MockExecutor) {
				cleanBase(m)
				m.RunResults["iptables-save"] = executor.Result{
					ExitCode: 0,
					Stdout:   "# Generated\n*filter\n:INPUT ACCEPT\n-A INPUT -j ACCEPT\n-A INPUT -p tcp --dport 22 -j ACCEPT\n-A INPUT -p tcp --dport 80 -j ACCEPT\nCOMMIT\n",
				}
			},
			wantFW: extfw.NameIptables,
		},
		{
			name: "csf services only",
			setup: func(m *executor.MockExecutor) {
				cleanBase(m)
				m.Services["csf.service"] = true
				m.Services["lfd.service"] = true
			},
			wantFW: extfw.NameCSF,
		},
		{
			// Option A locked resolution: config-file-only CSF remnant
			// MUST be detected consistently across all lifecycle callers.
			name: "csf config file only (Option A resolution)",
			setup: func(m *executor.MockExecutor) {
				cleanBase(m)
				m.Files["/etc/csf/csf.conf"] = []byte("# csf stub\n")
			},
			wantFW: extfw.NameCSF,
		},
		{
			// Multi-active: every caller must see Ambiguous — never
			// silently collapse via precedence.
			name:          "ufw + csf both active — ambiguous",
			wantAmbiguous: true,
			setup: func(m *executor.MockExecutor) {
				cleanBase(m)
				m.Services["ufw.service"] = true
				m.Services["csf.service"] = true
			},
		},
	}
}

// TestConsistency_InstallAndUninstallAgree is the PR-P2-2 regression
// guard. For every fixture, we verify that extfw.Detect (the canonical
// source) and every legacy caller return the same external-firewall
// truth.
func TestConsistency_InstallAndUninstallAgree(t *testing.T) {
	for _, fx := range fixtures() {
		t.Run(fx.name, func(t *testing.T) {
			// Shared mock — both callers use the same fixture.
			m := executor.NewMockExecutor()
			fx.setup(m)
			log := newTestLogger()

			// Ground truth from the canonical detector.
			gold := extfw.Detect(m, log)

			// ── Install-side: detect.DetectConflicts
			conflicts := detect.DetectConflicts(m, log)
			var installSeesFW bool
			for _, c := range conflicts {
				if c.Active {
					// Map display name back to extfw.Name
					var n extfw.Name
					switch c.Name {
					case "UFW":
						n = extfw.NameUFW
					case "firewalld":
						n = extfw.NameFirewalld
					case "iptables", "iptables-nft":
						n = extfw.NameIptables
					case "CSF":
						n = extfw.NameCSF
					}
					if fx.wantFW != extfw.NameNone && n == fx.wantFW {
						installSeesFW = true
					}
					if fx.wantAmbiguous {
						installSeesFW = true // any match during ambiguous is fine
					}
				}
			}
			switch {
			case fx.wantFW == extfw.NameNone && !fx.wantAmbiguous:
				if len(conflicts) != 0 {
					t.Errorf("[install] DetectConflicts returned %d conflicts on clean host; extfw.Detect correctly returned none", len(conflicts))
				}
			case fx.wantFW != extfw.NameNone && !installSeesFW:
				t.Errorf("[install] DetectConflicts did not surface %q; extfw.Detect reported Authoritative=%q", fx.wantFW, gold.Authoritative)
			case fx.wantAmbiguous && len(conflicts) < 2:
				t.Errorf("[install] DetectConflicts returned %d conflicts for an ambiguous host; expected ≥2", len(conflicts))
			}

			// ── Uninstall-side: uninstall.Classify
			uRes := uninstall.Classify(m, log)
			switch {
			case fx.wantFW == extfw.NameNone && !fx.wantAmbiguous:
				if uRes.External != "" {
					t.Errorf("[uninstall] External = %q on clean host; extfw.Detect correctly returned none", uRes.External)
				}
			case fx.wantFW != extfw.NameNone && !fx.wantAmbiguous:
				if uRes.External != string(fx.wantFW) {
					t.Errorf("[uninstall] External = %q; want %q (extfw.Detect Authoritative=%q)", uRes.External, fx.wantFW, gold.Authoritative)
				}
			case fx.wantAmbiguous:
				if uRes.State != uninstall.AuthorityAmbiguous {
					t.Errorf("[uninstall] State = %q on ambiguous host; want AuthorityAmbiguous (extfw.Detect Ambiguous=%v)", uRes.State, gold.Ambiguous)
				}
			}
		})
	}
}

// TestConsistency_OptionA_CSFConfigFileOnly is the explicit regression
// guard for the PR-P2-2 Option A resolution: a host whose only CSF
// signal is /etc/csf/csf.conf must be seen as having CSF by every
// lifecycle caller. Before PR-P2-2 the install side ignored this
// signal; after PR-P2-2 it must agree with the uninstall side.
func TestConsistency_OptionA_CSFConfigFileOnly(t *testing.T) {
	m := executor.NewMockExecutor()
	cleanBase(m)
	m.Files["/etc/csf/csf.conf"] = []byte("# csf stub\n")
	log := newTestLogger()

	// Canonical answer.
	gold := extfw.Detect(m, log)
	if gold.Authoritative != extfw.NameCSF {
		t.Fatalf("canonical: Authoritative = %q; want csf", gold.Authoritative)
	}

	// Install side must now agree.
	conflicts := detect.DetectConflicts(m, log)
	var sawCSF bool
	for _, c := range conflicts {
		if c.Name == "CSF" && c.Active {
			sawCSF = true
		}
	}
	if !sawCSF {
		t.Errorf("install-side detect.DetectConflicts missed CSF (config-file-only); PR-P2-2 Option A regression — install and uninstall must agree")
	}

	// Uninstall side must still see it (it did before PR-P2-2 as well).
	uRes := uninstall.Classify(m, log)
	if uRes.External != string(extfw.NameCSF) {
		t.Errorf("uninstall-side: External = %q; want csf", uRes.External)
	}
}
