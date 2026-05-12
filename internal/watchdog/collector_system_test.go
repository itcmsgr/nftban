// =============================================================================
// NFTBan - Tests for SystemCollector host-vitals extensions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_collector_system_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-12"
// meta:description="Tests for PR-M2b-w1 host-vitals collection (collectOOMEvents, collectMultiMountDisks, hostDiskMountAllowlist)"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_HOST_DISK_MOUNT_ALLOWLIST"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Covers schema doc 17 §F4 host-vitals additions: mount allowlist policy
// (§F4.3.1), OOM events from /proc/vmstat (§F4.2). The collectMultiMountDisks
// fixture tests use real /proc/self/mountinfo + syscall.Statfs against
// standard mounts (/ always exists), since stubbing the syscall layer would
// add abstraction beyond what this fix warrants.
// =============================================================================

package watchdog

import (
	"context"
	"os"
	"testing"
)

// =============================================================================
// hostDiskMountAllowlist — env policy
// =============================================================================

func TestHostDiskMountAllowlist_DefaultWhenEnvUnset(t *testing.T) {
	t.Setenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST", "")
	got := hostDiskMountAllowlist()
	want := defaultHostDiskMounts
	if len(got) != len(want) {
		t.Fatalf("len(got)=%d len(want)=%d", len(got), len(want))
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("[%d] got=%q want=%q", i, got[i], want[i])
		}
	}
}

func TestHostDiskMountAllowlist_DefaultWhenEnvAllWhitespace(t *testing.T) {
	t.Setenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST", "  ,  ,  ")
	got := hostDiskMountAllowlist()
	if len(got) != len(defaultHostDiskMounts) {
		t.Errorf("expected default fallback on all-whitespace env, got %v", got)
	}
}

func TestHostDiskMountAllowlist_EnvOverride(t *testing.T) {
	t.Setenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST", "/, /data , /mnt/storage")
	got := hostDiskMountAllowlist()
	want := []string{"/", "/data", "/mnt/storage"}
	if len(got) != len(want) {
		t.Fatalf("len(got)=%d len(want)=%d (got=%v)", len(got), len(want), got)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("[%d] got=%q want=%q", i, got[i], want[i])
		}
	}
}

func TestHostDiskMountAllowlist_DefaultDocPolicyPlusNftbanStateDir(t *testing.T) {
	// Schema doc 17 §F4.3.1 defaults: /, /var, /var/log.
	// Plus /var/lib/nftban (nftban-specific FHS addition).
	expected := map[string]bool{
		"/":               true,
		"/var":            true,
		"/var/log":        true,
		"/var/lib/nftban": true,
	}
	for _, m := range defaultHostDiskMounts {
		if !expected[m] {
			t.Errorf("unexpected default mount: %q", m)
		}
		delete(expected, m)
	}
	if len(expected) > 0 {
		t.Errorf("missing default mounts: %v", expected)
	}
}

// =============================================================================
// collectMultiMountDisks — populates snapshot.System.Disks
// =============================================================================

func TestCollectMultiMountDisks_RootMountAlwaysPresent(t *testing.T) {
	t.Setenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST", "/")
	c := NewSystemCollector("/")
	snapshot := &Snapshot{}
	c.collectMultiMountDisks(snapshot)

	if len(snapshot.System.Disks) != 1 {
		t.Fatalf("expected 1 disk entry for root mount, got %d (disks=%+v)", len(snapshot.System.Disks), snapshot.System.Disks)
	}
	d := snapshot.System.Disks[0]
	if d.Mount != "/" {
		t.Errorf("Mount = %q, want %q", d.Mount, "/")
	}
	if d.Ratio < 0 || d.Ratio > 1 {
		t.Errorf("Ratio = %v, want 0..1", d.Ratio)
	}
	// Device + FSType come from /proc/self/mountinfo on Linux; should resolve
	// to non-"unknown" on a working test host, but we accept "unknown" as
	// the documented fallback for parse failure.
	if d.Device == "" {
		t.Error("Device should be non-empty")
	}
	if d.FSType == "" {
		t.Error("FSType should be non-empty")
	}
}

func TestCollectMultiMountDisks_NonexistentMountSkipped(t *testing.T) {
	t.Setenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST", "/this/path/does/not/exist/anywhere,/")
	c := NewSystemCollector("/")
	snapshot := &Snapshot{}
	c.collectMultiMountDisks(snapshot)

	// The bogus mount must be silently skipped; "/" should still appear.
	rootSeen := false
	for _, d := range snapshot.System.Disks {
		if d.Mount == "/this/path/does/not/exist/anywhere" {
			t.Error("nonexistent mount should be skipped, but appeared in snapshot")
		}
		if d.Mount == "/" {
			rootSeen = true
		}
	}
	if !rootSeen {
		t.Error("expected root mount in snapshot after skipping bogus mount")
	}
}

func TestCollectMultiMountDisks_CardinalityBoundDefault(t *testing.T) {
	t.Setenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST", "")
	c := NewSystemCollector("/")
	snapshot := &Snapshot{}
	c.collectMultiMountDisks(snapshot)

	// Default policy is 4 mounts; not all may exist on the test host.
	if len(snapshot.System.Disks) > len(defaultHostDiskMounts) {
		t.Errorf("default-policy emission produced %d series, want ≤ %d", len(snapshot.System.Disks), len(defaultHostDiskMounts))
	}
}

// =============================================================================
// collectOOMEvents — reads /proc/vmstat oom_kill
// =============================================================================

func TestCollectOOMEvents_LinuxHost(t *testing.T) {
	if _, err := os.Stat("/proc/vmstat"); err != nil {
		t.Skip("/proc/vmstat not available (non-Linux test host)")
	}
	c := NewSystemCollector("/")
	snapshot := &Snapshot{}
	c.collectOOMEvents(snapshot)

	// Modern kernels (≥4.7) have oom_kill; the value is a counter,
	// usually 0 on healthy hosts but may be > 0 if OOM events occurred.
	// Either way, the field must be set (or unchanged from zero) without
	// panic. We just verify the field is reachable.
	_ = snapshot.System.OOMEvents
}

// =============================================================================
// SystemCollector.Collect — integration: host-vitals collectors wired into Collect()
// =============================================================================

func TestSystemCollector_CollectIncludesHostVitals(t *testing.T) {
	t.Setenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST", "/")
	c := NewSystemCollector("/var/log")
	snapshot := &Snapshot{}
	if err := c.Collect(context.Background(), snapshot); err != nil {
		t.Fatalf("Collect() error: %v", err)
	}

	// Pre-existing fields populated.
	if snapshot.System.NumCPU == 0 {
		t.Error("NumCPU should be populated")
	}
	if snapshot.System.MemTotal == 0 {
		t.Skip("MemTotal not populated — likely non-Linux test host without /proc/meminfo")
	}

	// PR-M2b-w1 additions populated.
	if len(snapshot.System.Disks) == 0 {
		t.Error("Disks should contain at least the root mount")
	}
	// OOMEvents is a cumulative counter (≥0); just verify field reachable.
	_ = snapshot.System.OOMEvents
}

// =============================================================================
// readMountInfo — best-effort /proc/self/mountinfo parser
// =============================================================================

func TestReadMountInfo_LinuxHostFindsRoot(t *testing.T) {
	if _, err := os.Stat("/proc/self/mountinfo"); err != nil {
		t.Skip("/proc/self/mountinfo not available (non-Linux test host)")
	}
	info := readMountInfo()
	if info == nil {
		t.Fatal("readMountInfo returned nil map (contract is non-nil)")
	}
	root, ok := info["/"]
	if !ok {
		t.Skip("/ not in mountinfo on this host — unusual but acceptable")
	}
	if root.device == "" {
		t.Error("root device should be non-empty")
	}
	if root.fstype == "" {
		t.Error("root fstype should be non-empty")
	}
}

func TestReadMountInfo_NeverReturnsNilMap(t *testing.T) {
	// Even if /proc/self/mountinfo is unreadable, readMountInfo() must
	// return a non-nil (empty) map so callers can range without nil check.
	info := readMountInfo()
	if info == nil {
		t.Fatal("readMountInfo must never return nil map")
	}
}
