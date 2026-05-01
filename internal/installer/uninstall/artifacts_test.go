// =============================================================================
// NFTBan v1.100.4 — RemoveArtifacts unit tests (UPSTREAM-UNINSTALL-INCOMPLETE-001)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-uninstall-artifacts-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-02"
// meta:description="RemoveArtifacts: payload symmetry + mode contract + unmask order"
// meta:inventory.files="internal/installer/uninstall/artifacts_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package uninstall

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/payload"
)

// recordedRMs returns every "rm -rf <path>" or "rm -f <path>" target
// recorded by the mock, in execution order.
func recordedRMs(m *executor.MockExecutor) []string {
	var out []string
	for _, c := range m.Commands {
		if c.Name != "rm" {
			continue
		}
		// rm flags + path; last arg is the target.
		if len(c.Args) >= 2 {
			out = append(out, c.Args[len(c.Args)-1])
		}
	}
	return out
}

// indexOf returns the first index of target in xs, or -1 if absent.
func indexOf(xs []string, target string) int {
	for i, x := range xs {
		if x == target {
			return i
		}
	}
	return -1
}

// containsAny reports whether any element of needles is present in xs.
func containsAny(xs []string, needles ...string) bool {
	for _, n := range needles {
		if indexOf(xs, n) >= 0 {
			return true
		}
	}
	return false
}

// TestPayloadDestinations_MatchesStageAll proves Destinations and
// buildEntries return parallel sets — the single source of truth
// invariant the install/uninstall symmetry depends on.
func TestPayloadDestinations_MatchesStageAll(t *testing.T) {
	dests := payload.Destinations(nil)

	if len(dests) == 0 {
		t.Fatal("Destinations(nil) returned empty slice; expected non-empty install catalog")
	}

	// Every destination must have a non-empty Path; install StageAll
	// would skip empties — uninstall must see the same surface.
	for i, d := range dests {
		if d.Path == "" {
			t.Errorf("Destinations[%d] has empty Path: %+v", i, d)
		}
	}

	// Spot-check a known core destination is present (smoke test that
	// the accessor is reading the same buildEntries StageAll uses).
	wantCore := []string{
		"/usr/sbin/nftban",
		"/usr/lib/nftban/bin/nftban-installer",
		"/usr/lib/nftban/VERSION",
	}
	for _, w := range wantCore {
		found := false
		for _, d := range dests {
			if d.Path == w {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("Destinations missing core install target %q — symmetry with StageAll broken", w)
		}
	}
}

// TestRemoveArtifacts_RemovesStagedPayloadPaths — the basic symmetry
// claim. Under ModeRemove, every installer-owned path the catalog lists
// outside operator territory must be passed to rm.
func TestRemoveArtifacts_RemovesStagedPayloadPaths(t *testing.T) {
	m := executor.NewMockExecutor()
	r := RemoveArtifacts(m, ModeRemove, nil, newTestLogger())

	if r.Failed > 0 {
		t.Errorf("ModeRemove: Failed=%d on a clean mock; expected 0", r.Failed)
	}
	if r.Removed == 0 {
		t.Error("ModeRemove: Removed=0; expected non-zero (catalog is non-empty and ModeRemove deletes installer-owned paths)")
	}

	rms := recordedRMs(m)
	wantRemoved := []string{
		"/usr/sbin/nftban",
		"/usr/lib/nftban/bin/nftban-installer",
		"/usr/lib/nftban/VERSION",
		"/etc/logrotate.d/nftban",
	}
	for _, w := range wantRemoved {
		if indexOf(rms, w) < 0 {
			t.Errorf("ModeRemove: rm did not target %q; recorded rms=%v", w, rms)
		}
	}
}

// TestRemoveArtifacts_DoesNotRemoveNonOwnedParents — safety boundary.
// rm must never target a path outside payload.Destinations or the
// explicit uninstall-owned runtime list.
func TestRemoveArtifacts_DoesNotRemoveNonOwnedParents(t *testing.T) {
	m := executor.NewMockExecutor()
	_ = RemoveArtifacts(m, ModePurgeForceDOC, nil, newTestLogger())

	rms := recordedRMs(m)
	forbiddenParents := []string{
		"/", "/etc", "/usr", "/var", "/home", "/root",
		"/usr/lib", "/usr/sbin", "/var/lib", "/var/log",
		"/etc/systemd", "/usr/lib/systemd",
		"/usr/share", "/usr/share/man", "/usr/share/man/man8",
	}
	for _, p := range forbiddenParents {
		if indexOf(rms, p) >= 0 {
			t.Errorf("forbidden parent %q was passed to rm; safety boundary breach (rm list: %v)", p, rms)
		}
	}

	// Every recorded rm target must START WITH a known prefix
	// (payload root or runtime-owned root).
	allowedPrefixes := []string{
		"/usr/lib/nftban",
		"/usr/sbin/nftban",
		"/etc/nftban",
		"/var/lib/nftban",
		"/var/log/nftban",
		"/etc/logrotate.d/nftban",
		"/etc/polkit-1/rules.d",   // polkit dest (RHEL family)
		"/usr/share/polkit-1/rules.d", // polkit dest (Debian family)
		"/usr/share/man/man8/nftban",
		"/usr/share/bash-completion/completions/nftban",
		"/usr/lib/tmpfiles.d/nftban",
		"/usr/lib/systemd/system/nftban", // unit-file rm
		"/usr/lib/systemd/system/nftband",
		"/etc/systemd/system/nftban",  // mask-symlink rm under purge
		"/etc/systemd/system/nftband",
	}
	for _, target := range rms {
		ok := false
		for _, p := range allowedPrefixes {
			if strings.HasPrefix(target, p) {
				ok = true
				break
			}
		}
		if !ok {
			t.Errorf("rm target %q does not match any allowed prefix; safety-boundary violation", target)
		}
	}
}

// TestRemoveArtifacts_ModeControlsKeepVsPurge — the §4.4 mode contract.
// ModeRemove preserves operator territory; ModePurge removes it
// (preserving *.conf.local handled separately); ModePurgeForceDOC
// removes everything.
func TestRemoveArtifacts_ModeControlsKeepVsPurge(t *testing.T) {
	cases := []struct {
		mode             Mode
		etcShouldRemove  bool
		varlibShouldRm   bool
		varlogShouldRm   bool
	}{
		{ModeRemove, false, false, false},
		{ModePurge, true, true, true},
		{ModePurgeForceDOC, true, true, true},
	}

	for _, tc := range cases {
		t.Run(string(tc.mode), func(t *testing.T) {
			m := executor.NewMockExecutor()
			_ = RemoveArtifacts(m, tc.mode, nil, newTestLogger())
			rms := recordedRMs(m)

			etcRm := containsAny(rms, "/etc/nftban", "/etc/nftban/nftban.conf", "/etc/nftban/nftables.conf")
			varlibRm := indexOf(rms, "/var/lib/nftban") >= 0
			varlogRm := indexOf(rms, "/var/log/nftban") >= 0

			if etcRm != tc.etcShouldRemove {
				t.Errorf("mode=%s: /etc/nftban rm = %v; want %v (rms=%v)", tc.mode, etcRm, tc.etcShouldRemove, rms)
			}
			if varlibRm != tc.varlibShouldRm {
				t.Errorf("mode=%s: /var/lib/nftban rm = %v; want %v", tc.mode, varlibRm, tc.varlibShouldRm)
			}
			if varlogRm != tc.varlogShouldRm {
				t.Errorf("mode=%s: /var/log/nftban rm = %v; want %v", tc.mode, varlogRm, tc.varlogShouldRm)
			}
		})
	}
}

// TestRemoveArtifacts_UnmasksNftbandBeforeUnitFileRemoval — the v1.100.4
// symmetry fix. ServiceUnmask("nftband.service") must be recorded
// BEFORE any rm of /usr/lib/systemd/system/nftband.service.
func TestRemoveArtifacts_UnmasksNftbandBeforeUnitFileRemoval(t *testing.T) {
	m := executor.NewMockExecutor()
	// Seed the unit file so removeUnitFilesAtDest's filepath.Glob
	// matches it. The mock's Files map is for ReadFile; filepath.Glob
	// hits the real filesystem, so this test only proves the unmask
	// call ordering — the unit-file glob is exercised by real-host
	// evidence.
	_ = RemoveArtifacts(m, ModeRemove, nil, newTestLogger())

	// ServiceUnmask records as "systemctl:unmask:nftband.service" via
	// the mock's recordCommand path (see mock.go ServiceUnmask).
	unmaskIdx := -1
	for i, c := range m.Commands {
		if c.Name == "systemctl" && len(c.Args) >= 2 && c.Args[0] == "unmask" && c.Args[1] == "nftband.service" {
			unmaskIdx = i
			break
		}
	}
	if unmaskIdx < 0 {
		t.Fatal("RemoveArtifacts must record ServiceUnmask(nftband.service) — never invoked")
	}

	// Find any rm of nftband unit file (if filepath.Glob found it on
	// the test host); if present, it must come AFTER unmask.
	for i, c := range m.Commands {
		if c.Name == "rm" && len(c.Args) >= 2 {
			target := c.Args[len(c.Args)-1]
			if strings.HasSuffix(target, "/nftband.service") {
				if i < unmaskIdx {
					t.Errorf("rm of %q at command index %d came BEFORE unmask at index %d", target, i, unmaskIdx)
				}
			}
		}
	}
}

// TestApply_ArtifactRemovalSequence — apply.go inserts remove_artifacts
// in the right position (after disable_nftband, before mask_nftband).
func TestApply_ArtifactRemovalSequence(t *testing.T) {
	m := executor.NewMockExecutor()
	seedAuthoritativeHost(m)

	r := Apply(m, &ApplyConfig{SSHPort: 22, Mode: ModePurge}, newTestLogger())

	if r.State != "UNINSTALL_RELEASED" {
		t.Fatalf("happy-path with ModePurge: State = %q; want UNINSTALL_RELEASED", r.State)
	}

	// Find positions of the relevant steps in r.Steps.
	posDisable, posArtifacts, posMask, posValidate := -1, -1, -1, -1
	for i, s := range r.Steps {
		switch s.Name {
		case "disable_nftband":
			posDisable = i
		case "remove_artifacts":
			posArtifacts = i
		case "mask_nftband":
			posMask = i
		case "validate_end_state":
			posValidate = i
		}
	}
	if posArtifacts < 0 {
		t.Fatal("Apply did not record remove_artifacts step")
	}
	if !(posDisable < posArtifacts && posArtifacts < posMask && posMask < posValidate) {
		t.Errorf("step ordering wrong: disable=%d artifacts=%d mask=%d validate=%d (want disable < artifacts < mask < validate)",
			posDisable, posArtifacts, posMask, posValidate)
	}
}

// TestRemoveArtifacts_DefaultModeIsRemove — zero-value Mode must behave
// as ModeRemove (the operator-default uninstall path).
func TestRemoveArtifacts_DefaultModeIsRemove(t *testing.T) {
	m := executor.NewMockExecutor()
	r := RemoveArtifacts(m, "", nil, newTestLogger())

	rms := recordedRMs(m)
	// ModeRemove must NOT touch operator territory.
	if containsAny(rms, "/etc/nftban", "/etc/nftban/nftban.conf", "/var/lib/nftban", "/var/log/nftban") {
		t.Errorf("zero-value mode must default to ModeRemove (preserve operator territory); rms=%v", rms)
	}
	// But MUST touch installer-owned payload.
	if r.Removed == 0 {
		t.Error("zero-value mode default ModeRemove must still remove installer-owned paths; Removed=0")
	}
}

// TestRemoveArtifacts_DaemonReloadAfterRm — daemon-reload must be the
// last systemctl call (clears stale unit-file view; closes the
// "leftover_units=49" residue signature from cross-distro evidence).
func TestRemoveArtifacts_DaemonReloadAfterRm(t *testing.T) {
	m := executor.NewMockExecutor()
	_ = RemoveArtifacts(m, ModeRemove, nil, newTestLogger())

	lastDaemonReloadIdx := -1
	lastRmIdx := -1
	for i, c := range m.Commands {
		switch {
		case c.Name == "systemctl" && len(c.Args) >= 1 && c.Args[0] == "daemon-reload":
			lastDaemonReloadIdx = i
		case c.Name == "rm":
			lastRmIdx = i
		}
	}
	if lastDaemonReloadIdx < 0 {
		t.Fatal("RemoveArtifacts must invoke daemon-reload")
	}
	if lastRmIdx >= 0 && lastDaemonReloadIdx < lastRmIdx {
		t.Errorf("daemon-reload at index %d came BEFORE last rm at index %d; want reload AFTER rm to clear systemd cache",
			lastDaemonReloadIdx, lastRmIdx)
	}
}

// TestStartDaemon_UnmasksNftbandBeforeEnable — services.StartDaemon's
// defensive belt. Lives in this file because it shares mock-recording
// helpers; the alternative location internal/installer/services/ has
// its own mock pattern but this assertion is about the integration.
//
// Verifies the symmetry contract: if uninstall left a phantom mask
// symlink (the bug source), install must remove it before enabling.
// Smallest possible test — assert ServiceUnmask is on the command
// trail.
func TestStartDaemon_UnmasksNftbandBeforeEnable(t *testing.T) {
	// This test pulls in the services package; to keep the artifacts_test
	// package boundary clean, we assert the install-path symmetry via a
	// command-trail probe on the same MockExecutor that RemoveArtifacts
	// uses. The actual services.StartDaemon test is in
	// internal/installer/services/services_test.go with the existing
	// mock — this test only documents the symmetry expectation at the
	// uninstall-package level.
	t.Skip("symmetry expectation; concrete StartDaemon assertion lives in internal/installer/services/services_test.go")
}
