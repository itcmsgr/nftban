// =============================================================================
// NFTBan v1.125 R-5 — disk preflight tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-preflight-disk-test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-22"
// meta:description="V125 R-5 regression tests: EnsureMinDiskFree pass/fail/bad-path + MinDiskFreeBytes env override truth table"
// meta:input="None (uses real syscall.Statfs against /tmp; env-var tests use t.Setenv for isolation)"
// meta:output="t.Fatal on preflight predicate drift or env-override regression"
// meta:depends="testing,os,strings"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_MIN_DISK_FREE_MB"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package preflight

import (
	"strings"
	"testing"
)

// TestEnsureMinDiskFree_PassesWhenSufficient asserts that requesting an
// easily-satisfiable amount (1 byte) against /tmp passes. Uses /tmp
// because every test environment has it; the test asserts the success
// path, not specific free-space values.
func TestEnsureMinDiskFree_PassesWhenSufficient(t *testing.T) {
	if err := EnsureMinDiskFree("/tmp", 1); err != nil {
		t.Fatalf("expected nil for 1-byte requirement on /tmp; got %v", err)
	}
}

// TestEnsureMinDiskFree_FailsWhenInsufficient asserts that requesting an
// impossibly-large amount (16 EB) against /tmp returns a refusal error
// citing "insufficient disk space". 16 EB exceeds any realistic
// filesystem capacity, so this case reliably triggers the refusal
// branch without needing a mock filesystem.
func TestEnsureMinDiskFree_FailsWhenInsufficient(t *testing.T) {
	// 16 EB minus 1 — exceeds any real-world filesystem.
	veryLarge := uint64(1<<63) - 1
	err := EnsureMinDiskFree("/tmp", veryLarge)
	if err == nil {
		t.Fatal("expected error for impossibly-large minBytes; got nil")
	}
	if !strings.Contains(err.Error(), "insufficient disk space") {
		t.Errorf("expected error message about insufficient disk space; got: %v", err)
	}
	if !strings.Contains(err.Error(), EnvMinDiskFreeMB) {
		t.Errorf("expected error message to reference %s for operator override hint; got: %v",
			EnvMinDiskFreeMB, err)
	}
}

// TestEnsureMinDiskFree_StatfsErrorOnBadPath asserts that statfs failures
// propagate as descriptive errors. /nonexistent/xyz cannot be statfs'd;
// the error should mention "statfs" so an operator log scrape can
// distinguish syscall failures from insufficient-space refusals.
func TestEnsureMinDiskFree_StatfsErrorOnBadPath(t *testing.T) {
	err := EnsureMinDiskFree("/nonexistent/path/v125-r5-xyz", DefaultMinDiskFreeBytes)
	if err == nil {
		t.Fatal("expected statfs error for nonexistent path; got nil")
	}
	if !strings.Contains(err.Error(), "statfs") {
		t.Errorf("expected error message to reference statfs; got: %v", err)
	}
}

// TestMinDiskFreeBytes_DefaultsWhenUnset asserts that with no env override,
// the default (500 MB) is returned.
func TestMinDiskFreeBytes_DefaultsWhenUnset(t *testing.T) {
	t.Setenv(EnvMinDiskFreeMB, "")
	if got := MinDiskFreeBytes(); got != DefaultMinDiskFreeBytes {
		t.Errorf("MinDiskFreeBytes() with unset env = %d; want default %d",
			got, DefaultMinDiskFreeBytes)
	}
}

// TestMinDiskFreeBytes_HonorsEnvOverride asserts that a valid positive
// integer in NFTBAN_MIN_DISK_FREE_MB is honored as the megabyte threshold.
func TestMinDiskFreeBytes_HonorsEnvOverride(t *testing.T) {
	cases := []struct {
		env      string
		wantMB   uint64 // multiplied by 1024*1024 to compare
	}{
		{"100", 100},
		{"1", 1},
		{"1024", 1024},
		{"5000", 5000},
	}
	for _, tc := range cases {
		t.Run(tc.env, func(t *testing.T) {
			t.Setenv(EnvMinDiskFreeMB, tc.env)
			want := tc.wantMB * 1024 * 1024
			if got := MinDiskFreeBytes(); got != want {
				t.Errorf("MinDiskFreeBytes() with env=%q = %d; want %d (=%d MB)",
					tc.env, got, want, tc.wantMB)
			}
		})
	}
}

// TestMinDiskFreeBytes_FallsBackOnInvalidEnv asserts that invalid env
// values do NOT silently weaken the gate. Each invalid case must return
// the default threshold, not zero or any partial value. This is the
// "preflight is a safety gate, not a parser" discipline: typos cannot
// be allowed to disable the protection.
func TestMinDiskFreeBytes_FallsBackOnInvalidEnv(t *testing.T) {
	cases := []struct {
		env  string
		why  string
	}{
		{"abc", "non-numeric"},
		{"-1", "negative (ParseUint rejects)"},
		{"0", "zero is treated as invalid (would disable the gate)"},
		{"99999999999999999999999", "uint64 overflow"},
		{"1.5", "float (ParseUint rejects)"},
		{"100MB", "trailing unit (ParseUint rejects)"},
		{" 100", "leading whitespace (ParseUint rejects strict)"},
		{"100 ", "trailing whitespace (ParseUint rejects strict)"},
	}
	for _, tc := range cases {
		t.Run(tc.env+"_"+tc.why, func(t *testing.T) {
			t.Setenv(EnvMinDiskFreeMB, tc.env)
			if got := MinDiskFreeBytes(); got != DefaultMinDiskFreeBytes {
				t.Errorf("invalid env %q (%s) = %d; want default %d (safety gate must not weaken on bad input)",
					tc.env, tc.why, got, DefaultMinDiskFreeBytes)
			}
		})
	}
}
