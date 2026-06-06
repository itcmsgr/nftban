// =============================================================================
// NFTBan v1.154.0 - Timer Hardening Drift-Parity Test
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-timers-post-install-parity-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-06"
// meta:description="Assert KnownTimers() covers exactly every install/systemd/*.timer (drift guard)"
// meta:inventory.files="internal/installer/services/timers_post_install_parity_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-*.timer"
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Mirrors the v1.137 B-12 LogInventory authority + drift-test pattern: the
// hardening's timer coverage (services.KnownTimers()) must equal EXACTLY the
// set of install/systemd/*.timer unit files shipped in the repo. If a new
// .timer is added (or one removed) without updating allKnownTimers in
// timers.go, this test fails — closing the future-drift risk where a freshly
// added timer would silently escape the D-INSTALL-TIMER-RELOAD wedge-recovery
// pass.
package services

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// installSystemdTimerBasenames returns the sorted basenames of every
// install/systemd/*.timer file in the repo, resolved relative to this test
// source file (same runtime.Caller pattern as the fhs paths-parity test).
func installSystemdTimerBasenames(t *testing.T) []string {
	t.Helper()

	_, filename, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller(0) failed — cannot locate repo root")
	}
	// internal/installer/services/<this file> -> repo root is three dirs up.
	repoRoot := filepath.Join(filepath.Dir(filename), "..", "..", "..")
	systemdDir := filepath.Join(repoRoot, "install", "systemd")

	matches, err := filepath.Glob(filepath.Join(systemdDir, "*.timer"))
	if err != nil {
		t.Fatalf("glob install/systemd/*.timer: %v", err)
	}
	if len(matches) == 0 {
		t.Fatalf("no *.timer files found under %s — repo layout changed?", systemdDir)
	}

	out := make([]string, 0, len(matches))
	for _, m := range matches {
		// Defensive: skip anything that is somehow a directory.
		if info, err := os.Stat(m); err == nil && info.IsDir() {
			continue
		}
		out = append(out, filepath.Base(m))
	}
	sort.Strings(out)
	return out
}

// TestKnownTimersMatchInstallSystemd asserts exact set equality between
// services.KnownTimers() and install/systemd/*.timer.
func TestKnownTimersMatchInstallSystemd(t *testing.T) {
	onDisk := installSystemdTimerBasenames(t)

	known := KnownTimers()
	sort.Strings(known)

	onDiskSet := make(map[string]bool, len(onDisk))
	for _, n := range onDisk {
		onDiskSet[n] = true
	}
	knownSet := make(map[string]bool, len(known))
	for _, n := range known {
		knownSet[n] = true
	}

	var missing []string // on disk but NOT in KnownTimers()
	for _, n := range onDisk {
		if !knownSet[n] {
			missing = append(missing, n)
		}
	}
	var extra []string // in KnownTimers() but NOT on disk
	for _, n := range known {
		if !onDiskSet[n] {
			extra = append(extra, n)
		}
	}

	if len(missing) > 0 {
		t.Errorf("install/systemd/*.timer units NOT covered by services.KnownTimers() "+
			"(add them to allKnownTimers in timers.go): %s", strings.Join(missing, ", "))
	}
	if len(extra) > 0 {
		t.Errorf("services.KnownTimers() lists units with NO install/systemd/*.timer file "+
			"(remove them from allKnownTimers in timers.go): %s", strings.Join(extra, ", "))
	}
}

// TestKnownTimersNoDuplicates guards against a copy-paste duplicate entry in
// allKnownTimers, which would make the hardening probe (and the parity set
// comparison) silently iterate a unit twice.
func TestKnownTimersNoDuplicates(t *testing.T) {
	seen := make(map[string]bool)
	for _, n := range KnownTimers() {
		if seen[n] {
			t.Errorf("duplicate timer in allKnownTimers: %s", n)
		}
		seen[n] = true
	}
}

// TestCoreAndOptionalTimersAreKnown asserts the reconcile-policy subsets
// (coreTimers, optionalTimers) are themselves members of the canonical
// KnownTimers() superset — i.e. KnownTimers() really is the superset it claims
// to be, so the hardening pass cannot miss a timer that the installer actively
// reconciles.
func TestCoreAndOptionalTimersAreKnown(t *testing.T) {
	knownSet := make(map[string]bool)
	for _, n := range KnownTimers() {
		knownSet[n] = true
	}
	for _, n := range coreTimers {
		if !knownSet[n] {
			t.Errorf("coreTimer %s missing from KnownTimers() superset", n)
		}
	}
	for _, n := range optionalTimers {
		if !knownSet[n] {
			t.Errorf("optionalTimer %s missing from KnownTimers() superset", n)
		}
	}
}
