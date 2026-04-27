// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore Panel→Firewall Mapping tests (PR-25 §20)
// =============================================================================
// meta:name="restore_panel_mapping_test"
// meta:type="test"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3A tests: §20 static-mapping behavior. Authoritative DirectAdmin→csf; all other panels unmapped → refuse; PanelNone refuses; output validates against §18.2 knownFirewallTypes; no default/best-effort/guessed path; map is intentionally sparse and pinned."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package restore

import (
	"errors"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
)

// =============================================================================
// 1. Authoritative entry: DirectAdmin → csf
// =============================================================================

func TestResolvePanelFirewall_DirectAdmin_MapsToCSF(t *testing.T) {
	got, err := ResolvePanelFirewall(detect.PanelDirectAdmin)
	if err != nil {
		t.Fatalf("ResolvePanelFirewall(DirectAdmin) returned error: %v", err)
	}
	if got != "csf" {
		t.Errorf("ResolvePanelFirewall(DirectAdmin) = %q; want %q", got, "csf")
	}
}

// =============================================================================
// 2. DirectAdmin output validates as a known firewall type (§18.2 set)
// =============================================================================

func TestResolvePanelFirewall_DirectAdmin_OutputIsKnownFirewallType(t *testing.T) {
	got, err := ResolvePanelFirewall(detect.PanelDirectAdmin)
	if err != nil {
		t.Fatalf("setup: %v", err)
	}
	if _, ok := knownFirewallTypes[got]; !ok {
		t.Errorf("DirectAdmin mapping output %q is not a member of knownFirewallTypes (§18.2 invariant)", got)
	}
	// Also: the output must be constructable as a TargetRecordedPrior
	// firewallType. This isn't strictly required by §20 (the panel-auto
	// branch produces a PanelNative target, not RecordedPrior), but if
	// the output validates against the same set, the §18.2 / §20.1
	// alignment is preserved and a future contract change won't desync.
	if _, err := TargetRecordedPrior(got); err != nil {
		t.Errorf("DirectAdmin mapping output %q is not constructable as TargetRecordedPrior firewallType: %v", got, err)
	}
}

// =============================================================================
// 3. All seven non-DirectAdmin panels currently refuse as unmapped
// =============================================================================

func TestResolvePanelFirewall_OtherPanels_RefuseAsUnmapped(t *testing.T) {
	// PR-25 commit 3A intentionally maps only DirectAdmin. All other
	// detect.PanelType values must refuse with ErrUnmappedPanel until
	// explicit operator-authority mappings are added in subsequent
	// commits.
	unmapped := []detect.PanelType{
		detect.PanelCPanel,
		detect.PanelPlesk,
		detect.PanelCyberPanel,
		detect.PanelHestia,
		detect.PanelVesta,
		detect.PanelCWP,
		detect.PanelInterWorx,
	}
	for _, p := range unmapped {
		t.Run(string(p), func(t *testing.T) {
			_, err := ResolvePanelFirewall(p)
			if err == nil {
				t.Fatalf("ResolvePanelFirewall(%q) accepted; want ErrUnmappedPanel", p)
			}
			if !errors.Is(err, ErrUnmappedPanel) {
				t.Errorf("ResolvePanelFirewall(%q) wrong error class: %v", p, err)
			}
		})
	}
}

// =============================================================================
// 4. PanelNone refuses
// =============================================================================

func TestResolvePanelFirewall_PanelNone_Refuses(t *testing.T) {
	_, err := ResolvePanelFirewall(detect.PanelNone)
	if err == nil {
		t.Fatalf("ResolvePanelFirewall(PanelNone) accepted; want error")
	}
	if !errors.Is(err, ErrPanelNoneNotMappable) {
		t.Errorf("ResolvePanelFirewall(PanelNone) wrong error class: %v", err)
	}
}

// =============================================================================
// 5. Unknown / future PanelType refuses (no default branch)
// =============================================================================

func TestResolvePanelFirewall_UnknownFuturePanel_Refuses(t *testing.T) {
	// Simulate a future detect.PanelType that doesn't exist yet. Casting
	// a string into PanelType bypasses the const enum but the resolver
	// has no exhaustive switch — it's a sparse map lookup, so any
	// non-key panel must refuse with ErrUnmappedPanel.
	cases := []detect.PanelType{
		detect.PanelType("zpanel"),       // hypothetical future panel
		detect.PanelType("ispconfig"),    // exists in the wild but not detected
		detect.PanelType("aapanel"),      // ditto
		detect.PanelType(""),             // already covered by PanelNone test, here as belt-and-braces
		detect.PanelType("DirectAdmin "), // typo with trailing space — must NOT accidentally match
		detect.PanelType("DIRECTADMIN"),  // wrong case — must NOT match
	}
	for _, p := range cases {
		t.Run(string(p), func(t *testing.T) {
			_, err := ResolvePanelFirewall(p)
			if err == nil {
				t.Fatalf("ResolvePanelFirewall(%q) accepted unknown panel; want refusal", p)
			}
			// PanelType("") is detect.PanelNone; the rest are unmapped.
			if p == detect.PanelType("") {
				if !errors.Is(err, ErrPanelNoneNotMappable) {
					t.Errorf("empty PanelType wrong error class: %v", err)
				}
			} else {
				if !errors.Is(err, ErrUnmappedPanel) {
					t.Errorf("unknown panel %q wrong error class: %v", p, err)
				}
			}
		})
	}
}

// =============================================================================
// 6. No default branch returns a firewall type by guess
// =============================================================================

func TestResolvePanelFirewall_NoGuessedDefault(t *testing.T) {
	// Walk every firewall type in the §18.2 known set. The resolver
	// must NEVER return one of them unless the panel argument is in
	// panelToFirewall. We verify by passing a clearly-unmapped panel
	// and confirming the return value is empty + error is non-nil.
	for fwt := range knownFirewallTypes {
		t.Run(fwt, func(t *testing.T) {
			got, err := ResolvePanelFirewall(detect.PanelType("guess-target-" + fwt))
			if err == nil {
				t.Fatalf("resolver returned no error for guess panel; would have leaked %q", fwt)
			}
			if got != "" {
				t.Errorf("resolver leaked firewall type %q on error path; want empty string", got)
			}
		})
	}
}

// =============================================================================
// 7. Map is intentionally sparse and pinned (commit 3A authoritative shape)
// =============================================================================

func TestPanelToFirewall_SparseMapPin(t *testing.T) {
	// PR-25 commit 3A: only DirectAdmin is mapped. This test pins that
	// shape — adding any panel without operator authority makes this
	// fail at PR review time.
	if len(panelToFirewall) != 1 {
		t.Errorf("panelToFirewall has %d entries; PR-25 commit 3A authorized exactly 1 (DirectAdmin→csf). New entries must arrive in their own commit with operator-authority citation.",
			len(panelToFirewall))
	}
	if got := panelToFirewall[detect.PanelDirectAdmin]; got != "csf" {
		t.Errorf("panelToFirewall[DirectAdmin] = %q; want %q (the only authorized entry)", got, "csf")
	}
	// Belt-and-braces: ensure none of the seven other panels have
	// somehow gained an entry.
	for _, p := range []detect.PanelType{
		detect.PanelCPanel,
		detect.PanelPlesk,
		detect.PanelCyberPanel,
		detect.PanelHestia,
		detect.PanelVesta,
		detect.PanelCWP,
		detect.PanelInterWorx,
	} {
		if _, present := panelToFirewall[p]; present {
			t.Errorf("panelToFirewall[%q] is mapped without authority — PR-25 commit 3A only authorized DirectAdmin", p)
		}
	}
}

// =============================================================================
// 8. Output-validation invariant: every entry in the map must validate
// against knownFirewallTypes (§18.2 / §20.1).
// =============================================================================

func TestPanelToFirewall_AllEntriesValidateAgainstKnownSet(t *testing.T) {
	for p, fwt := range panelToFirewall {
		if _, ok := knownFirewallTypes[fwt]; !ok {
			t.Errorf("panelToFirewall[%q] = %q is not a member of knownFirewallTypes (§18.2 / §20.1 violation)", p, fwt)
		}
	}
}

// =============================================================================
// 9. No mutation surface — file-scan
// =============================================================================

func TestPanelMapping_NoMutationSurface_FileScan(t *testing.T) {
	forbidden := []string{
		"os/exec",
		"exec.Command",
		"os.WriteFile",
		"os.Create",
		"os.Remove",
		"os.Rename",
		"syscall.",
		`"nft "`,
		`"systemctl `,
		"DetectPanel(", // resolver must not perform live detection
		"uninstall.Probe(",
		"uninstall.Classify(",
	}
	body, err := readSelf("panel_mapping.go")
	if err != nil {
		t.Fatalf("read panel_mapping.go: %v", err)
	}
	for _, pat := range forbidden {
		if strings.Contains(body, pat) {
			t.Errorf("panel_mapping.go references forbidden pattern %q (mutation/re-detection surface)", pat)
		}
	}
}
