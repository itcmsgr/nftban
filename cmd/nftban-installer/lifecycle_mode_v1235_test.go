// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/services"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/internal/installer/validate"
	"github.com/itcmsgr/nftban/pkg/version"
)

// v1.235 row 486 (owner U1 / R-DEC / D4): while NFTBan is DISABLED (stored
// choice) or the per-boot EMERGENCY BYPASS is active, the installer updates
// files but loads no rules, starts/enables no NFTBan unit and never touches
// nftables.service. The three boot guards are enabled in every mode. A
// correctly disabled host ends COMMITTED on its disabled invariants.

const servicesConfLocal = "/etc/nftban/conf.d/services.conf.local"

type lmMode int

const (
	lmNormal lmMode = iota
	lmDisabled
	lmBypass
	lmInvalid // v1.235 K2: NFTBAN_ENABLED declared with a value that is neither on nor off
	lmUnknown // v1.235 K2-c: services.conf.local present but unreadable (here: a directory)
)

func lmMock(mode lmMode) *executor.MockExecutor {
	m := executor.NewMockExecutor()
	switch mode {
	case lmDisabled:
		m.Files[servicesConfLocal] = []byte("NFTBAN_ENABLED=\"false\"\n")
	case lmBypass:
		m.Files[services.ProcCmdlinePath] = []byte("BOOT_IMAGE=/vmlinuz root=/dev/vda1 nftban=disabled\n")
	case lmInvalid:
		m.Files[servicesConfLocal] = []byte("NFTBAN_ENABLED=maybe\n")
	case lmUnknown:
		// present (FileExists) but ReadFile fails; services.conf itself says ON, which must NOT win.
		m.Files["/etc/nftban/conf.d/services.conf"] = []byte("NFTBAN_ENABLED=true\n")
		m.Dirs[servicesConfLocal] = true
	}
	for _, u := range services.BootGuardUnits {
		m.Files["/usr/lib/systemd/system/"+u] = []byte("[Unit]\n")
	}
	return m
}

func lmState(t *testing.T, st state.InstallState) (*state.StateFile, *logging.Logger) {
	t.Helper()
	dir := t.TempDir()
	sf := state.NewStateFile(dir)
	sf.State = st
	sf.Version = version.Version
	sf.SSHPort = 22
	return sf, logging.New(dir+"/installer.log", false)
}

// mutatingCommands returns recorded commands that would load rules, start or
// enable NFTBan units, or change nftables.service.
func mutatingCommands(m *executor.MockExecutor) []string {
	var out []string
	for _, c := range m.Commands {
		line := c.Name + " " + strings.Join(c.Args, " ")
		switch {
		case strings.Contains(line, "firewall rebuild"),
			strings.Contains(line, "render-boot") && !strings.Contains(line, "--inert"),
			strings.Contains(line, "nftables.service") && (strings.Contains(line, "enable") || strings.Contains(line, "start")),
			c.Name == "nft" && len(c.Args) > 0 && (c.Args[0] == "add" || c.Args[0] == "-f" || c.Args[0] == "delete"):
			out = append(out, line)
		}
		if c.Name == "systemctl" && len(c.Args) >= 2 && (c.Args[0] == "enable" || c.Args[0] == "start" || c.Args[0] == "restart") {
			guard := false
			for _, g := range services.BootGuardUnits {
				if c.Args[len(c.Args)-1] == g {
					guard = true
				}
			}
			if !guard {
				out = append(out, line)
			}
		}
	}
	return out
}

func TestPhaseSwitch_DisabledAndBypass_NoMutation(t *testing.T) {
	for _, mode := range []lmMode{lmDisabled, lmBypass} {
		m := lmMock(mode)
		sf, log := lmState(t, state.StatePrepareComplete)
		globalPhaseData = phaseData{sshPort: 22, sshPorts: []int{22}, decision: authority.Fresh}
		if err := phaseSwitch(context.Background(), m, sf, log); err != nil {
			t.Fatalf("mode %d: phaseSwitch returned %v", mode, err)
		}
		if sf.State != state.StateSwitchComplete {
			t.Fatalf("mode %d: state = %s, want SWITCH_COMPLETE", mode, sf.State)
		}
		if got := mutatingCommands(m); len(got) > 0 {
			t.Fatalf("mode %d: phaseSwitch mutated the firewall/units while disabled/bypassed: %v", mode, got)
		}
		if len(m.Commands) > 0 && strings.Contains(m.Commands[0].Name+strings.Join(m.Commands[0].Args, " "), "nftban_install_emergency") {
			t.Fatalf("mode %d: an emergency SSH table was injected although nothing is switched", mode)
		}
		if sf.ConvergenceVerified != "" {
			t.Fatalf("mode %d: convergence must be NOT evaluated in Switch, got %q", mode, sf.ConvergenceVerified)
		}
		if m.ServicesEnabled["nftables.service"] || m.ServicesEnabled["nftables"] {
			t.Fatalf("mode %d: nftables.service enablement changed (owner D4)", mode)
		}
	}
}

func TestPhaseConfigure_DisabledAndBypass_OnlyBootGuards(t *testing.T) {
	for _, mode := range []lmMode{lmDisabled, lmBypass} {
		m := lmMock(mode)
		sf, log := lmState(t, state.StateSwitchComplete)
		globalPhaseData = phaseData{sshPort: 22}
		if err := phaseConfigure(context.Background(), m, sf, log); err != nil {
			t.Fatalf("mode %d: phaseConfigure returned %v", mode, err)
		}
		for _, u := range services.BootGuardUnits {
			if !m.ServicesEnabled[u] {
				t.Fatalf("mode %d: boot guard %s must be enabled in every mode", mode, u)
			}
		}
		for _, u := range []string{"nftband.service", "nftband.socket", "nftban-maintenance.timer", "nftban-watchdog.timer"} {
			if m.ServicesEnabled[u] || m.Services[u] {
				t.Fatalf("mode %d: %s was enabled/started while disabled/bypassed", mode, u)
			}
		}
		if sf.WhitelistConvergence != "" {
			t.Fatalf("mode %d: whitelist convergence must be NOT evaluated, got %q", mode, sf.WhitelistConvergence)
		}
	}
}

func TestPhaseConfigure_Normal_StartsDaemonAndGuards(t *testing.T) {
	m := lmMock(lmNormal)
	sf, log := lmState(t, state.StateSwitchComplete)
	globalPhaseData = phaseData{sshPort: 22}
	_ = phaseConfigure(context.Background(), m, sf, log)
	if !m.ServicesEnabled["nftband.service"] {
		t.Fatal("normal mode: the daemon must still be enabled (no regression)")
	}
	for _, u := range services.BootGuardUnits {
		if !m.ServicesEnabled[u] {
			t.Fatalf("normal mode: boot guard %s must be enabled", u)
		}
	}
}

// disabledPassMock: the all-assertions-pass fixture plus the disabled invariants.
func disabledPassMock(t *testing.T, mode lmMode) (*assertionTestInjection, *executor.MockExecutor) {
	inj, m, _ := newAllAssertionsPassFixture(t)
	base := lmMock(mode)
	for k, v := range base.Files {
		m.Files[k] = v
	}
	for k, v := range base.Dirs { // lmUnknown: the unreadable switch file is a directory
		m.Dirs[k] = v
	}
	for _, u := range services.BootGuardUnits {
		m.ServicesEnabled[u] = true
	}
	m.Files[switchop.BootProjectionPath] = []byte("#!/usr/sbin/nft -f\n" + validate.BootProjectionInertMarker + "\n")
	m.RunResults["systemctl:list-unit-files:--no-legend:--plain:nftban*:nftband*"] = executor.Result{
		Stdout: "nftband.service disabled enabled\nnftban-boot-bypass.service enabled enabled\n",
	}
	// a disabled host has no daemon and (bypass) no NFTBan tables
	m.Services["nftband.service"] = false
	delete(m.NftTables, "ip:nftban")
	delete(m.NftTables, "ip6:nftban")
	return inj, m
}

func TestPhaseValidate_Disabled_CommitsOnDisabledInvariants(t *testing.T) {
	for _, mode := range []lmMode{lmDisabled, lmBypass} {
		inj, m := disabledPassMock(t, mode)
		sf, log := lmState(t, state.StateServicesComplete)
		globalPhaseData = phaseData{sshPort: 22, inject: inj}
		_ = phaseValidate(context.Background(), m, sf, log)
		if sf.State != state.StateCommitted {
			t.Fatalf("mode %d: a correctly disabled host must end COMMITTED, got %s (%s)", mode, sf.State, sf.FailureReason)
		}
		if sf.ConvergenceVerified != string(switchop.ConvergenceNotApplicableDisabled) {
			t.Fatalf("mode %d: verdict = %q, want NOT_APPLICABLE_DISABLED (never VERIFIED)", mode, sf.ConvergenceVerified)
		}
		for _, c := range m.Commands {
			if c.Name == "systemctl" && len(c.Args) > 0 && c.Args[0] == "restart" {
				t.Fatalf("mode %d: wedged-timer hardening restarted a unit while disabled: %v", mode, c.Args)
			}
		}
	}
}

func TestPhaseValidate_Disabled_ActiveProjectionDegrades(t *testing.T) {
	inj, m := disabledPassMock(t, lmDisabled)
	m.Files[switchop.BootProjectionPath] = []byte("#!/usr/sbin/nft -f\ntable ip nftban {\n}\n")
	sf, log := lmState(t, state.StateServicesComplete)
	globalPhaseData = phaseData{sshPort: 22, inject: inj}
	_ = phaseValidate(context.Background(), m, sf, log)
	if sf.State != state.StateDegraded {
		t.Fatalf("an ACTIVE projection on a disabled host must DEGRADE, got %s", sf.State)
	}
	if !strings.Contains(sf.FailureReason, "boot_projection_inert") {
		t.Fatalf("the reason must name the failed invariant, got %q", sf.FailureReason)
	}
}

func TestPhaseValidate_Bypass_LoadedTablesDegrade(t *testing.T) {
	inj, m := disabledPassMock(t, lmBypass)
	m.NftTables["ip:nftban"] = true
	sf, log := lmState(t, state.StateServicesComplete)
	globalPhaseData = phaseData{sshPort: 22, inject: inj}
	_ = phaseValidate(context.Background(), m, sf, log)
	if sf.State != state.StateDegraded {
		t.Fatalf("NFTBan tables loaded during a bypass boot must DEGRADE, got %s", sf.State)
	}
}

func TestStateAllowsNotApplicableDisabledCommit(t *testing.T) {
	if !state.ConvergenceVerdictPermitsCommit(string(switchop.ConvergenceNotApplicableDisabled)) {
		t.Fatal("NOT_APPLICABLE_DISABLED must be commit-eligible (with the disabled invariants)")
	}
	if state.ConvergenceVerdictPermitsCommit("") {
		t.Fatal("the empty verdict must still be refused")
	}
}

// v1.235 K2 (owner 2026-10-08): an INVALID NFTBAN_ENABLED is neither enabled nor disabled. The
// installer changes nothing switch-dependent (no rule load, no unit change, no boot projection
// publish of ANY kind, inert included) and never ends COMMITTED.
// K2-c (owner 2026-10-08): an UNREADABLE choice is UNKNOWN and takes the same path ("could not
// read the setting" never means "the operator chose ON").
var lmUnusable = []struct {
	name string
	mode lmMode
	want string // the operator text the reason must carry
}{
	{"invalid", lmInvalid, "master switch is INVALID (NFTBAN_ENABLED=maybe in " + servicesConfLocal + ": set it to true or false)"},
	{"unknown", lmUnknown, "master switch is UNKNOWN (" + servicesConfLocal + " exists but could not be read"},
}

func TestLifecycleMode_InvalidSwitch_Resolved(t *testing.T) {
	for _, c := range lmUnusable {
		m := lmMock(c.mode)
		var pd phaseData
		_, log := lmState(t, state.StatePrepareComplete)
		resolveLifecycleMode(m, &pd, log)
		if !pd.switchInvalid || pd.nftbanDisabled || pd.bypassActive {
			t.Fatalf("%s: switchInvalid=%v disabled=%v bypass=%v, want the unusable-switch path only", c.name, pd.switchInvalid, pd.nftbanDisabled, pd.bypassActive)
		}
		if !pd.enforcementSkipped() {
			t.Fatalf("%s: an unusable choice must skip enforcement (never 'proceeding as ENABLED')", c.name)
		}
		if r := pd.skipReason(); !strings.Contains(r, c.want) {
			t.Fatalf("%s: skip reason must carry %q, got %q", c.name, c.want, r)
		}
	}
}

// Owner 2026-10-08 (item 5): "no boot rules written" = the EXISTING boot projection and the
// distro include file are BYTE-IDENTICAL afterwards (not merely "no new file").
const lmOldProjection = "#!/usr/sbin/nft -f\n# last published ACTIVE projection\ntable ip nftban {\n}\n"
const lmDistroConf = "/etc/nftables.conf"
const lmOldDistroConf = "#!/usr/sbin/nft -f\ninclude \"/etc/nftban/generated/nftban-boot.nft\"\n"

func lmAssertBootUnchanged(t *testing.T, name string, m *executor.MockExecutor) {
	t.Helper()
	if got := m.Files[switchop.BootProjectionPath]; !bytes.Equal(got, []byte(lmOldProjection)) {
		t.Fatalf("%s: the existing boot projection changed (%d bytes):\n%s", name, len(got), got)
	}
	if got := m.Files[lmDistroConf]; !bytes.Equal(got, []byte(lmOldDistroConf)) {
		t.Fatalf("%s: the distro boot include changed:\n%s", name, got)
	}
	for _, c := range m.Commands {
		if line := c.Name + " " + strings.Join(c.Args, " "); strings.Contains(line, "render-boot") {
			t.Fatalf("%s: a boot projection was rendered (inert included): %s", name, line)
		}
	}
}

func TestPhaseSwitch_InvalidSwitch_NoMutationNoRender(t *testing.T) {
	for _, c := range lmUnusable {
		m := lmMock(c.mode)
		m.Files[switchop.BootProjectionPath] = []byte(lmOldProjection)
		m.Files[lmDistroConf] = []byte(lmOldDistroConf)
		sf, log := lmState(t, state.StatePrepareComplete)
		globalPhaseData = phaseData{sshPort: 22, sshPorts: []int{22}, decision: authority.Fresh}
		_ = phaseSwitch(context.Background(), m, sf, log)
		if got := mutatingCommands(m); len(got) > 0 {
			t.Fatalf("%s: phaseSwitch mutated the firewall/units: %v", c.name, got)
		}
		lmAssertBootUnchanged(t, c.name, m)
	}
}

// The phasePrepare gap (code-read only until now): the render branch publishes nothing and
// the include integration refuses, so the existing projection and include stay byte-identical.
// Non-vacuous: the phase must reach PREPARE_COMPLETE (it ran past the render branch).
func TestPhasePrepare_InvalidSwitch_BootUnchanged(t *testing.T) {
	for _, c := range lmUnusable {
		m := lmMock(c.mode)
		m.Files[switchop.BootProjectionPath] = []byte(lmOldProjection)
		m.Files[lmDistroConf] = []byte(lmOldDistroConf)
		for _, c := range []string{"jq", "curl", "socat", "bc", "gawk", "getfacl", "tar"} {
			m.ExistingCommands[c] = true // dependencies present: the phase must reach the render branch
		}
		sf, log := lmState(t, state.StateDetectComplete)
		globalPhaseData = phaseData{sshPort: 22, sshPorts: []int{22}, decision: authority.Fresh,
			distro: &detect.DistroInfo{NftConfPath: lmDistroConf}}
		_ = phasePrepare(context.Background(), m, sf, log)
		if sf.State != state.StatePrepareComplete {
			t.Fatalf("%s: phasePrepare did not run to the end (state %s: %s) — the check would be vacuous", c.name, sf.State, sf.FailureReason)
		}
		lmAssertBootUnchanged(t, c.name, m)
	}
}

// K2 / K2-c (owner 2026-10-08): DEGRADED reads as "completed with warnings"; an install that
// applied no firewall because the switch is unusable ends FAILED (exit 2), never COMMITTED or
// DEGRADED, and the reason names the cause.
func TestPhaseValidate_InvalidSwitch_Fails(t *testing.T) {
	for _, c := range lmUnusable {
		inj, m := disabledPassMock(t, c.mode)
		sf, log := lmState(t, state.StateServicesComplete)
		globalPhaseData = phaseData{sshPort: 22, inject: inj}
		_ = phaseValidate(context.Background(), m, sf, log)
		if sf.State != state.StateFailedNoFirewall || sf.State.ExitCode() != state.ExitFailed {
			t.Fatalf("%s: want FAILED_NO_FIREWALL / exit %d, got %s / exit %d", c.name, state.ExitFailed, sf.State, sf.State.ExitCode())
		}
		if !strings.Contains(sf.FailureReason, c.want) {
			t.Fatalf("%s: the reason must carry %q, got %q", c.name, c.want, sf.FailureReason)
		}
	}
}
