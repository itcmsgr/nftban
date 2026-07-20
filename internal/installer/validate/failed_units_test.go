// meta:name="failed_units_test.go"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 4 tests for NormalizeFailedUnits: health/botscan/arbitrary nftban units, dedup, deterministic order, injection rejection (whitespace/shell-metachars/path/prose), pre-existing vs in-window attribution buckets, empty input."
package validate

import (
	"reflect"
	"testing"
)

func fu(unit, class string) FailedUnitPostInstall {
	return FailedUnitPostInstall{Unit: unit, Classification: class}
}

func TestNormalizeFailedUnitsCanonicalDedupSort(t *testing.T) {
	in := []FailedUnitPostInstall{
		fu("nftban-health.service", "PRE_EXISTING_FATAL"),
		fu("nftban-botscan.service", "IN_WINDOW"),
		fu("nftban-health.service", "PRE_EXISTING_FATAL"), // dup
		fu("nftban-watchdog.service", "IN_WINDOW"),
	}
	all, pre, inw := NormalizeFailedUnits(in)
	wantAll := []string{"nftban-botscan.service", "nftban-health.service", "nftban-watchdog.service"}
	if !reflect.DeepEqual(all, wantAll) {
		t.Errorf("all=%v want %v (canonical, deduped, sorted)", all, wantAll)
	}
	if !reflect.DeepEqual(pre, []string{"nftban-health.service"}) {
		t.Errorf("preexisting=%v want [nftban-health.service]", pre)
	}
	if !reflect.DeepEqual(inw, []string{"nftban-botscan.service", "nftban-watchdog.service"}) {
		t.Errorf("in-window=%v", inw)
	}
}

func TestNormalizeFailedUnitsRejectsUnsafe(t *testing.T) {
	in := []FailedUnitPostInstall{
		fu("nftban-health.service; rm -rf /", "IN_WINDOW"),          // shell injection
		fu("../../etc/passwd", "IN_WINDOW"),                          // path traversal
		fu("nftban health.service", "IN_WINDOW"),                    // whitespace
		fu("sshd.service", "IN_WINDOW"),                             // not nftban-owned
		fu("$(reboot)", "IN_WINDOW"),                                // command subst
		fu("nftban-health.service\nMemoryMax=0", "IN_WINDOW"),       // newline
		fu("nftban-real.service", "IN_WINDOW"),                      // valid → survives
	}
	all, _, _ := NormalizeFailedUnits(in)
	if !reflect.DeepEqual(all, []string{"nftban-real.service"}) {
		t.Errorf("only the safe nftban unit must survive, got %v", all)
	}
}

func TestNormalizeFailedUnitsEmpty(t *testing.T) {
	all, pre, inw := NormalizeFailedUnits(nil)
	if len(all) != 0 || len(pre) != 0 || len(inw) != 0 {
		t.Errorf("empty input must yield empty output, got %v/%v/%v", all, pre, inw)
	}
}

func TestSafeNftbanUnitName(t *testing.T) {
	good := []string{"nftban-health.service", "nftband.service", "nftban-alert@nftband.service"}
	bad := []string{"", "sshd.service", "nftban health.service", "nftban-health.service;x", "a" + string(make([]byte, 200))}
	for _, g := range good {
		if !SafeNftbanUnitName(g) {
			t.Errorf("%q should be safe", g)
		}
	}
	for _, b := range bad {
		if SafeNftbanUnitName(b) {
			t.Errorf("%q should be rejected", b)
		}
	}
}

func TestAttributionFor(t *testing.T) {
	pre := []string{"nftban-health.service"}
	if AttributionFor("nftban-health.service", pre) != AttrPreexistingFailed {
		t.Error("health should be PREEXISTING_STILL_FAILED")
	}
	if AttributionFor("nftban-botscan.service", pre) != AttrNewFailed {
		t.Error("botscan (not in pre set) should be NEW_FAILED_UNIT")
	}
}
