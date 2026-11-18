// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband_cleanup_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 cleanup repair, transaction level (fake kernel, tempdir config + tracking file): an IP with two automatic reasons loses only the selected reason and keeps its kernel element; protection or a new reason added between selection and execution survives; an interrupted removal (after the intent marker, or after the durable step) is finished consistently by the retry; a kernel failure leaves the marker so the retry finishes; an unmarked tracking-only entry is never acted on. RFC 5737 documentation addresses; no traffic, no firewall."
// meta:inventory.privileges="none"

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/persistence"
	"github.com/itcmsgr/nftban/internal/safety"
)

type fakeKernel struct {
	mu     sync.Mutex
	banned map[string]bool
	fail   bool
	calls  int
}

func (k *fakeKernel) Unban(ip string) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	k.calls++
	if k.fail {
		return errors.New("simulated kernel failure")
	}
	delete(k.banned, ip)
	return nil
}

type cleanupFixture struct {
	t    *testing.T
	dir  string
	now  time.Time
	kern *fakeKernel
}

func newCleanupFixture(t *testing.T) *cleanupFixture {
	t.Helper()
	dir := t.TempDir()
	t.Cleanup(safety.SetPermanentBansPathForTest(filepath.Join(dir, "state", "permanent_bans.json")))
	// v1.237 state boundary: the trust marker exists before any tracked entry (as on a host after nftband start).
	if _, err := safety.EstablishTrackingTrust(); err != nil {
		t.Fatal(err)
	}
	return &cleanupFixture{t: t, dir: dir, now: time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC), kern: &fakeKernel{banned: map[string]bool{}}}
}

func (f *cleanupFixture) reason(source string, ips ...string) {
	f.t.Helper()
	name, _ := persistence.FileForSource(source)
	p := filepath.Join(f.dir, "blacklist.d", name)
	_ = os.MkdirAll(filepath.Dir(p), 0o750)
	b, _ := os.ReadFile(p)
	s := string(b)
	for _, ip := range ips {
		s += ip + "  # fixture\n"
		f.kern.banned[ip] = true
	}
	if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
		f.t.Fatal(err)
	}
}

// track writes a tracking entry with an established ban-time age old enough to qualify.
func (f *cleanupFixture) track(ip, source string, mut func(*safety.PermanentBan)) {
	f.t.Helper()
	st, _ := safety.LoadPermanentBans()
	b := &safety.PermanentBan{IP: ip, Source: source, AgeSource: safety.AgeSourceBanTime,
		AddedAt: f.now.AddDate(0, 0, -(safety.BanAgeThresholdDays + 10))}
	if mut != nil {
		mut(b)
	}
	st.Bans[ip] = b
	if err := safety.SavePermanentBans(st); err != nil {
		f.t.Fatal(err)
	}
}

func (f *cleanupFixture) reasons(ip string) []string {
	r, _ := persistence.ReasonsForIP(f.dir, ip)
	return r
}

func (f *cleanupFixture) tracked(ip string) *safety.PermanentBan {
	st, _ := safety.LoadPermanentBans()
	return st.Bans[ip]
}

func TestCleanup_TwoReasonsOnlySelectedReasonRemovedKernelKept(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.70"
	f.reason("persistent", ip)
	f.reason("login", ip)
	f.track(ip, "persistent", nil) // only the persistent reason matches the tracked source
	r, err := cleanupExecute(f.dir, f.now, 0, f.kern, cleanupHooks{})
	if err != nil {
		t.Fatal(err)
	}
	if got := f.reasons(ip); len(got) != 1 || got[0] != "login" {
		t.Fatalf("remaining reasons = %v, want [login]", got)
	}
	if !f.kern.banned[ip] || f.kern.calls != 0 {
		t.Fatalf("kernel element must stay while another reason remains (calls=%d)", f.kern.calls)
	}
	if tr := f.tracked(ip); tr == nil || tr.CleanupPending != "" {
		t.Fatalf("tracking must stay without a pending marker: %+v", tr)
	}
	if r.Removed != 1 || r.Excluded[safety.ExclSourceMismatch] != 1 {
		t.Fatalf("report removed=%d excluded=%v", r.Removed, r.Excluded)
	}
}

func TestCleanup_ProtectBetweenSelectionAndExecutionSurvives(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.71"
	f.reason("portscan", ip)
	f.track(ip, "portscan", nil)
	h := cleanupHooks{beforeLock: func(x string) {
		if err := cleanupProtect(f.dir, x, true); err != nil {
			t.Errorf("protect: %v", err)
		}
	}}
	r, err := cleanupExecute(f.dir, f.now, 0, f.kern, h)
	if err != nil {
		t.Fatal(err)
	}
	if len(f.reasons(ip)) != 1 || !f.kern.banned[ip] || !f.tracked(ip).Protected {
		t.Fatalf("protected-in-between ban was touched: reasons=%v kernel=%v", f.reasons(ip), f.kern.banned[ip])
	}
	if r.Removed != 0 || !strings.HasPrefix(r.Items[len(r.Items)-1].Result, "skipped:"+safety.ExclProtected) {
		t.Fatalf("want skipped:protected, got %+v", r.Items)
	}
}

func TestCleanup_NewReasonBetweenSelectionAndExecutionSurvives(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.72"
	f.reason("ddos", ip)
	f.track(ip, "ddos", nil)
	h := cleanupHooks{beforeLock: func(x string) { f.reason("manual", x) }}
	if _, err := cleanupExecute(f.dir, f.now, 0, f.kern, h); err != nil {
		t.Fatal(err)
	}
	if got := f.reasons(ip); len(got) != 2 || !f.kern.banned[ip] {
		t.Fatalf("a reason added in between must make the IP ineligible: reasons=%v kernel=%v", got, f.kern.banned[ip])
	}
}

func TestCleanup_InterruptedAfterDurableIsFinishedByRetry(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.73"
	f.reason("login", ip)
	f.track(ip, "login", nil)
	crash := cleanupHooks{afterDurable: func(string) error { return errors.New("simulated crash") }}
	if _, err := cleanupExecute(f.dir, f.now, 0, f.kern, crash); err != nil {
		t.Fatal(err)
	}
	if len(f.reasons(ip)) != 0 || !f.kern.banned[ip] || f.tracked(ip).CleanupPending != "login" {
		t.Fatalf("crash state wrong: reasons=%v kernel=%v tracked=%+v", f.reasons(ip), f.kern.banned[ip], f.tracked(ip))
	}
	r, err := cleanupExecute(f.dir, f.now, 0, f.kern, cleanupHooks{})
	if err != nil {
		t.Fatal(err)
	}
	if f.kern.banned[ip] || f.tracked(ip) != nil || r.Finished != 1 {
		t.Fatalf("retry did not converge: kernel=%v tracked=%+v finished=%d", f.kern.banned[ip], f.tracked(ip), r.Finished)
	}
}

func TestCleanup_InterruptedAfterMarkIsCompletedByRetry(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.74"
	f.reason("persistent", ip)
	f.track(ip, "persistent", nil)
	crash := cleanupHooks{afterMark: func(string) error { return errors.New("simulated crash") }}
	_, _ = cleanupExecute(f.dir, f.now, 0, f.kern, crash)
	if len(f.reasons(ip)) != 1 || f.tracked(ip).CleanupPending != "persistent" {
		t.Fatalf("crash-after-mark state wrong: reasons=%v tracked=%+v", f.reasons(ip), f.tracked(ip))
	}
	if _, err := cleanupExecute(f.dir, f.now, 0, f.kern, cleanupHooks{}); err != nil {
		t.Fatal(err)
	}
	if len(f.reasons(ip)) != 0 || f.kern.banned[ip] || f.tracked(ip) != nil {
		t.Fatalf("retry did not complete: reasons=%v kernel=%v tracked=%+v", f.reasons(ip), f.kern.banned[ip], f.tracked(ip))
	}
}

func TestCleanup_KernelFailureKeepsMarkerAndRetryFinishes(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.75"
	f.reason("portscan", ip)
	f.track(ip, "portscan", nil)
	f.kern.fail = true
	r, _ := cleanupExecute(f.dir, f.now, 0, f.kern, cleanupHooks{})
	if r.Failed != 1 || f.tracked(ip).CleanupPending != "portscan" || len(f.reasons(ip)) != 0 {
		t.Fatalf("kernel failure state wrong: failed=%d tracked=%+v", r.Failed, f.tracked(ip))
	}
	f.kern.fail = false
	r, _ = cleanupExecute(f.dir, f.now, 0, f.kern, cleanupHooks{})
	if r.Finished != 1 || f.kern.banned[ip] || f.tracked(ip) != nil {
		t.Fatalf("retry after kernel failure did not finish: %+v", r)
	}
}

// An unmarked tracking-only entry (e.g. a kernel-only ban whose persist failed) is reported, never acted on.
func TestCleanup_UnmarkedTrackingOnlyEntryUntouched(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.76"
	f.kern.banned[ip] = true
	f.track(ip, "login", nil)
	r, _ := cleanupExecute(f.dir, f.now, 0, f.kern, cleanupHooks{})
	if !f.kern.banned[ip] || f.tracked(ip) == nil || f.kern.calls != 0 || r.Excluded[safety.ExclNoReasonFile] != 1 {
		t.Fatalf("unmarked tracking-only entry was acted on: calls=%d report=%+v", f.kern.calls, r)
	}
}

// Dry-run (summarize) and execute select from the same calculation.
func TestCleanup_DryRunMatchesExecute(t *testing.T) {
	f := newCleanupFixture(t)
	f.reason("login", "198.51.100.77", "198.51.100.78")
	f.track("198.51.100.77", "login", nil)
	f.reason("manual", "198.51.100.79")
	decs, st, err := cleanupEvaluate(f.dir, f.now)
	if err != nil {
		t.Fatal(err)
	}
	dry := cleanupSummarize(decs, st, 0)
	r, _ := cleanupExecute(f.dir, f.now, 0, f.kern, cleanupHooks{})
	if strings.Join(dry.Selected, ",") != strings.Join(r.Selected, ",") || dry.Selected[0] != "198.51.100.77" {
		t.Fatalf("dry-run %v != execute %v", dry.Selected, r.Selected)
	}
}

// v1.237 state boundary: when the daemon started before the boundary held (no valid trust marker), the
// cleanup path itself establishes it under the lock set, sanitizing records written before it.
func TestCleanup_EstablishesTrustWhenStartWasTooEarly(t *testing.T) {
	f := newCleanupFixture(t)
	ip := "198.51.100.90"
	f.reason("login", ip)
	f.track(ip, "login", nil) // carries ban-time provenance, as a forged pre-boundary record would
	st, _ := safety.LoadPermanentBans()
	if st.Bans[ip].AgeSource != safety.AgeSourceBanTime {
		t.Fatal("fixture precondition")
	}
	marker := filepath.Join(f.dir, "state", "permanent_bans.json"+safety.PermanentBansTrustSuffix)
	// A look-alike marker planted while state/ was writable: right content, wrong mode. It must never
	// establish trust, whatever its owner becomes later.
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(marker, []byte("nftban tracking trust boundary v1237\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	decs, st, err := cleanupEvaluate(f.dir, f.now)
	if err != nil {
		t.Fatalf("cleanup must establish trust itself once the boundary holds: %v", err)
	}
	if fi, err := os.Stat(marker); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatal("the planted marker must be replaced by a root-only one")
	}
	if st.Bans[ip].AgeSource != "" {
		t.Fatal("a record present before the marker must be sanitized (age_source cleared)")
	}
	for _, d := range decs {
		if d.Eligible {
			t.Fatalf("a pre-marker record became eligible: %+v", d)
		}
	}
}
