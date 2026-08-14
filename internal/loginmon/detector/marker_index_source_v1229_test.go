// SPDX-License-Identifier: MPL-2.0
//
// v1.229.1 TRACK 2 — detection-evasion regression + structural prohibition.
//
// PROVEN EVASION (runtime, through the public Detect(), before the fix):
//
//	corpus (synthetic)        lower delta   Plesk  cPanel  ProFTPD
//	ascii username             +0           yes    yes     yes
//	username with U+0130 (İ)   -1           NO     NO      NO
//	username with U+1E9E (ẞ)   -1           NO     NO      NO
//	username with U+212A (K)   -2           NO     NO      NO
//
// The correlation was exact: every delta != 0 evaded, every delta == 0 detected.
// One attacker-supplied character in a username suppressed the login-failure
// verdict entirely, because the marker offset was derived from a LOWERCASED copy
// and applied to the ORIGINAL line, and bytes.ToLower does not preserve byte length.
//
// INVARIANT ENFORCED HERE: INDEX_SOURCE == SLICE_SOURCE.
//
// The corpus is SYNTHETIC by construction — RFC 5737 IPv4, RFC 3849 IPv6, invented
// usernames. Log SHAPES were derived from documented formats by inspection; no live
// log values are reproduced here.
package detector

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// evasionCase is attacker-controlled text placed BEFORE the " from " marker.
type evasionCase struct {
	name      string
	user      string
	wantDelta bool // true if lowercasing this line changes its byte length
}

var evasionCorpus = []evasionCase{
	// POSITIVE CONTROL. If this ever fails the fixture stopped reaching the
	// detector and every other arm below is vacuous — that exact failure happened
	// while building this corpus (a fixture missing the signature gate returned
	// false for ALL cases, which looked like evasion but was blindness).
	{"ascii-control", "operator", false},

	{"latin-capital-I-with-dot", "operİtor", true}, // İ  2 bytes -> 1
	{"latin-capital-sharp-s", "operẞtor", true},    // ẞ  3 bytes -> 2
	{"kelvin-sign", "operKtor", true},              // K  3 bytes -> 1

	// Hostile literal that does NOT change length: the marker search must still
	// anchor on the LAST occurrence.
	{"username-containing-from", "oper from ator", false},

	{"trailing-space", "operator ", false},
	{"truncated", "op", false},
	{"empty-user", "", false},
}

func lowerChangesLength(s string) bool {
	return len(bytes.ToLower([]byte(s))) != len(s)
}

// runCorpus asserts EVERY case yields the expected IP, and that the fixture's
// delta expectation matches reality (so a corpus that stopped exercising the
// length-change condition fails loudly instead of passing quietly).
func runCorpus(t *testing.T, label string, build func(user string) string, want string, detect func([]byte) (Verdict, bool)) {
	t.Helper()
	sawDelta := false
	for _, c := range evasionCorpus {
		line := build(c.user)
		gotDelta := lowerChangesLength(line)
		if gotDelta != c.wantDelta {
			t.Fatalf("%s/%s: corpus drift — lowercase-length-change is %v, fixture expects %v; "+
				"the adversarial condition is no longer being exercised", label, c.name, gotDelta, c.wantDelta)
		}
		if gotDelta {
			sawDelta = true
		}
		v, ok := detect([]byte(line))
		if !ok {
			t.Errorf("%s/%s: DETECTION EVADED (lower delta=%v) — login failure suppressed by "+
				"attacker-controlled pre-marker text", label, c.name, gotDelta)
			continue
		}
		if v.IP.String() != want {
			t.Errorf("%s/%s: wrong IP extracted: got %q want %q", label, c.name, v.IP.String(), want)
		}
	}
	if !sawDelta {
		t.Fatalf("%s: no corpus case changed length under ToLower — the regression would be vacuous", label)
	}
}

func TestIndexSourceInvariant_PleskFallback(t *testing.T) {
	d := NewPanelDetector()
	runCorpus(t, "plesk",
		func(u string) string {
			// "plesk" satisfies the stage-3 signature; the generic " from " fallback
			// is the path under test. The documented "from IP " path indexes the
			// ORIGINAL line and is deliberately NOT touched by this fix.
			return fmt.Sprintf("plesk sw-engine: Authentication failed for user %s from %s", u, "192.0.2.10")
		}, "192.0.2.10", d.Detect)
}

func TestIndexSourceInvariant_CPanelFallback(t *testing.T) {
	d := NewPanelDetector()
	runCorpus(t, "cpanel",
		func(u string) string {
			return fmt.Sprintf("cpanel login: failed login for user %s from %s", u, "203.0.113.30")
		}, "203.0.113.30", d.Detect)
}

func TestIndexSourceInvariant_FTPFrom(t *testing.T) {
	d := NewFTPDetector()
	runCorpus(t, "proftpd",
		func(u string) string {
			return fmt.Sprintf("proftpd: USER %s no such user found from %s", u, "198.51.100.20")
		}, "198.51.100.20", d.Detect)
}

// The "ip=" marker path is the FOURTH site of this class. It was NOT in the
// original three-site report: a manual sweep found only the markerFrom sites, and
// the structural guard below is what surfaced it. Proven exploitable by the same
// corpus before the fix (delta != 0 -> evaded).
func TestIndexSourceInvariant_IpEqualsMarker(t *testing.T) {
	d := NewPanelDetector()
	runCorpus(t, "cpanel-ip=",
		func(u string) string {
			return fmt.Sprintf("cpanel: FAILED LOGIN user=%s ip=%s", u, "192.0.2.77")
		}, "192.0.2.77", d.Detect)
}

// IPv6 must survive the same treatment (RFC 3849 documentation range).
func TestIndexSourceInvariant_IPv6(t *testing.T) {
	d := NewFTPDetector()
	for _, c := range evasionCorpus {
		line := fmt.Sprintf("proftpd: USER %s no such user found from %s", c.user, "2001:db8::20")
		v, ok := d.Detect([]byte(line))
		if !ok {
			t.Errorf("ipv6/%s: DETECTION EVADED", c.name)
			continue
		}
		if v.IP.String() != "2001:db8::20" {
			t.Errorf("ipv6/%s: got %q", c.name, v.IP.String())
		}
	}
}

// lastIndexFoldASCII must behave as a case-insensitive LastIndex over the
// ORIGINAL bytes — including when non-ASCII bytes are present, which is the whole
// reason the previous implementation could not be trusted.
func TestLastIndexFoldASCII(t *testing.T) {
	cases := []struct {
		s, m string
		want int
	}{
		{"a from b", "from ", 2},
		{"a FROM b", "from ", 2},
		{"a FrOm b", "from ", 2},
		{"x from y from z", "from ", 9}, // LAST occurrence
		{"no marker here", "from ", -1},
		{"", "from ", -1},
		{"from ", "from ", 0},
		{"İ from x", "from ", 3}, // offset is valid for the ORIGINAL bytes
		{"abc", "", -1},
	}
	for _, c := range cases {
		if got := lastIndexFoldASCII([]byte(c.s), []byte(c.m)); got != c.want {
			t.Errorf("lastIndexFoldASCII(%q,%q) = %d, want %d", c.s, c.m, got, c.want)
		}
	}
	// The returned offset must always be sliceable on the input.
	s := []byte("K user from 192.0.2.1")
	if i := lastIndexFoldASCII(s, []byte("from ")); i >= 0 {
		if got := string(s[i+len("from "):]); got != "192.0.2.1" {
			t.Errorf("offset not valid for the original buffer: got %q", got)
		}
	} else {
		t.Fatal("marker not found in a line containing non-ASCII bytes")
	}
}

// STRUCTURAL PROHIBITION: the affected detectors must never again derive an
// extraction offset from a lowercased copy and apply it to the original line.
// A regression test says "this bug must not return"; this says "this entire
// representation crossing is no longer permitted here".
func TestStructural_NoIndexOnLowerThenSliceOriginal(t *testing.T) {
	// Any Index-family call whose HAYSTACK is a lowercased buffer produces an
	// offset that is only valid for that buffer. Locating a marker that way and
	// slicing `line` is the defect class.
	bad := regexp.MustCompile(`(?m)^[^/\n]*\b(?:bytes\.)?(?:Last)?Index(?:Any|Byte|Rune)?\(\s*(?:line|s)[Ll]ower\b`)

	for _, name := range []string{"panel.go", "ftp.go"} {
		p := filepath.Join(".", name)
		src, err := os.ReadFile(p)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if locs := bad.FindAllString(string(src), -1); len(locs) > 0 {
			t.Errorf("%s: extraction offset derived from a lowercased buffer (INDEX_SOURCE != SLICE_SOURCE): %s",
				name, strings.Join(locs, " | "))
		}
	}

	// Non-vacuity: the pattern must actually match the defective form.
	if !bad.MatchString("\tfromIdx := bytes.LastIndex(lineLower, d.markerFrom)\n") {
		t.Fatal("structural guard cannot recognise the defective form — it would never fire")
	}
	// ...and must NOT match the corrected form, or it would be unsatisfiable.
	if bad.MatchString("\tfromIdx := lastIndexFoldASCII(line, d.markerFrom)\n") {
		t.Fatal("structural guard rejects the corrected form")
	}
}
