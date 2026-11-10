// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="validator_boot_content_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 BUG-STATUS-PROTECTED-DURING-BOOT-SET-LOAD-WINDOW: after a failed or refused boot-content load of the CURRENT boot, the validator reports VAL-BOOT-001 (DEGRADED) until every durable ban element is in the kernel; zero expected bans never degrades; a loaded, skipped, absent or stale state is not a finding; a render or kernel-read failure is VAL-BOOT-002 (never assumed restored)."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.privileges="none"

package validator

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type bootFixture struct {
	state    string // file content; "" = no file
	bootTime time.Time
	expected map[string][]string
	expErr   error
	kernel   map[string][]string // "fam/set" -> keys
	kerErr   error
}

func (f bootFixture) run(t *testing.T) *Finding {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "boot-content.state")
	if f.state != "" {
		if err := os.WriteFile(p, []byte(f.state), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	savedP, savedB, savedE, savedK := bootContentStatePath, bootTimeFn, bootExpectFn, bootKernelFn
	t.Cleanup(func() { bootContentStatePath, bootTimeFn, bootExpectFn, bootKernelFn = savedP, savedB, savedE, savedK })
	bootContentStatePath = p
	bt := f.bootTime
	if bt.IsZero() {
		bt = time.Date(2026, 11, 10, 16, 0, 0, 0, time.UTC)
	}
	bootTimeFn = func() (time.Time, bool) { return bt, true }
	bootExpectFn = func() (map[string][]string, error) { return f.expected, f.expErr }
	bootKernelFn = func(fam, set string) ([]string, error) {
		if f.kerErr != nil {
			return nil, f.kerErr
		}
		return f.kernel[fam+"/"+set], nil
	}
	return bootContentFinding()
}

// An unregistered verifier (a binary that was not wired) must fail closed after a failed load.
func TestBootContent_UnregisteredVerifierIsUnverifiable(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "boot-content.state")
	if err := os.WriteFile(p, []byte(failedState), 0o644); err != nil {
		t.Fatal(err)
	}
	savedP, savedB, savedV := bootContentStatePath, bootTimeFn, bootVerifier
	t.Cleanup(func() { bootContentStatePath, bootTimeFn, bootVerifier = savedP, savedB, savedV })
	bootContentStatePath, bootVerifier = p, nil
	bootTimeFn = func() (time.Time, bool) { return time.Date(2026, 11, 10, 16, 0, 0, 0, time.UTC), true }
	f := bootContentFinding()
	if f == nil || f.Code != CodeBootContentUnverifiable || !strings.Contains(f.Message, "no boot-content verifier") {
		t.Fatalf("unregistered verifier must be VAL-BOOT-002, got %+v", f)
	}
}

const failedState = "outcome=content-failed\nat=2026-11-10T16:00:12Z\nmonotonic_us=12000000\ndetail=nft -f refused the contents: x; sets stay empty until the daemon's sync\n"
const refusedState = "outcome=content-refused\nat=2026-11-10T16:00:12Z\ndetail=renderer rc=3: refused before any change\n"

var durable = map[string][]string{
	"ip/blacklist_manual_ipv4":  {"23.129.97.211", "5.188.0.1"},
	"ip6/blacklist_manual_ipv6": {"2001:db8::1"},
	"ip/blacklist_ipv4":         {"198.51.100.0/24", "203.0.113.7"},
	"ip/whitelist_ipv4":         {"192.0.2.10"}, // not a ban set: never required
}

func TestBootContent_NoStateNoClaim(t *testing.T) {
	if f := (bootFixture{expected: durable}).run(t); f != nil {
		t.Fatalf("no state file must not produce a finding, got %+v", f)
	}
}

func TestBootContent_LoadedAndSkippedAreNotFindings(t *testing.T) {
	for _, s := range []string{
		"outcome=content-loaded\nat=2026-11-10T16:00:12Z\ndetail=RULESET_CONTENT elements=0\n",
		"outcome=content-skipped\nat=2026-11-10T16:00:12Z\ndetail=NFTBan is not enabled\n",
	} {
		if f := (bootFixture{state: s, expected: durable}).run(t); f != nil {
			t.Errorf("state %q: unexpected finding %+v", strings.SplitN(s, "\n", 2)[0], f)
		}
	}
}

func TestBootContent_FailedAndNotRestored_Degrades(t *testing.T) {
	for _, s := range []string{failedState, refusedState} {
		f := (bootFixture{state: s, expected: durable, kernel: map[string][]string{}}).run(t)
		if f == nil || f.Code != CodeBootContentNotRestored || f.Severity != SeverityError {
			t.Fatalf("empty kernel after a failed load must be VAL-BOOT-001/error, got %+v", f)
		}
		if !strings.Contains(f.Message, "5 of 5") {
			t.Errorf("message must count the 5 required ban elements (whitelist excluded): %s", f.Message)
		}
	}
}

func TestBootContent_PartialRestoreStillDegrades(t *testing.T) {
	// The daemon has started and a sync is under way: some, not all, elements present.
	f := (bootFixture{state: failedState, expected: durable, kernel: map[string][]string{
		"ip/blacklist_manual_ipv4": {"23.129.97.211"},
		"ip/blacklist_ipv4":        {"198.51.100.0/24", "203.0.113.7"},
	}}).run(t)
	if f == nil || f.Code != CodeBootContentNotRestored || !strings.Contains(f.Message, "2 of 5") {
		t.Fatalf("partial restore must stay VAL-BOOT-001 with 2 of 5 missing, got %+v", f)
	}
}

func TestBootContent_FullRestoreIsPositiveEvidence(t *testing.T) {
	f := (bootFixture{state: failedState, expected: durable, kernel: map[string][]string{
		"ip/blacklist_manual_ipv4":  {"5.188.0.1", "23.129.97.211", "9.9.9.9"}, // extra elements are fine
		"ip6/blacklist_manual_ipv6": {"2001:0db8:0000::0001"},                  // non-canonical spelling
		// auto-merged interval: one range covers both expected entries
		"ip/blacklist_ipv4": {"198.51.100.0-203.0.113.255"},
	}}).run(t)
	if f != nil {
		t.Fatalf("every durable ban element present must clear the finding, got %+v", f)
	}
}

func TestBootContent_ZeroExpectedBansNeverDegrades(t *testing.T) {
	f := (bootFixture{state: failedState, expected: map[string][]string{"ip/whitelist_ipv4": {"192.0.2.10"}},
		kernel: map[string][]string{}}).run(t)
	if f != nil {
		t.Fatalf("zero expected durable bans + empty sets must not degrade, got %+v", f)
	}
}

func TestBootContent_StaleStateIgnored(t *testing.T) {
	// "at" long before this boot: not the current boot's outcome.
	f := (bootFixture{state: failedState, bootTime: time.Date(2026, 11, 11, 0, 0, 0, 0, time.UTC),
		expected: durable}).run(t)
	if f != nil {
		t.Fatalf("a state from before this boot must be ignored, got %+v", f)
	}
}

func TestBootContent_UnverifiableIsNotRestored(t *testing.T) {
	f := (bootFixture{state: failedState, expErr: errors.New("load blacklists: permission denied")}).run(t)
	if f == nil || f.Code != CodeBootContentUnverifiable || f.Severity != SeverityError {
		t.Fatalf("render failure must be VAL-BOOT-002/error, got %+v", f)
	}
	f = (bootFixture{state: failedState, expected: durable, kerErr: errors.New("nft: no such file")}).run(t)
	if f == nil || f.Code != CodeBootContentUnverifiable {
		t.Fatalf("kernel read failure must be VAL-BOOT-002, got %+v", f)
	}
	f = (bootFixture{state: "garbage without outcome\n", expected: durable}).run(t)
	if f == nil || f.Code != CodeBootContentUnverifiable {
		t.Fatalf("unparseable state must be VAL-BOOT-002, got %+v", f)
	}
}

func TestBootContent_IntervalContainment(t *testing.T) {
	kernel := []string{"10.0.0.0/8", "10.1.0.0/24", "192.0.2.0-192.0.2.127"}
	cases := map[string]bool{ // key -> covered
		"10.200.3.0/24":   true,
		"10.1.0.5":        true,
		"192.0.2.64/26":   true,
		"192.0.2.128/25":  false, // crosses the end of the range
		"11.0.0.0/8":      false,
		"172.16.0.1":      false,
		"not-an-address":  false,
		"192.0.2.0 timeout 3600s": true, // carried suffix ignored
	}
	for k, want := range cases {
		got := countMissing([]string{k}, kernel, false) == 0
		if got != want {
			t.Errorf("%s: covered=%v, want %v", k, got, want)
		}
	}
}
