// SPDX-License-Identifier: MPL-2.0
// meta:name="resolve_verdict_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth regression tests (MockExecutor + fixture profile): ResolveHealthResourceVerdict precedence — current>live>persisted>UNAVAILABLE, never a zero verdict. Covers BUG-REPAIR-HEALTH-VERDICT-EMPTY (repair-resume medium ACTIVE_MATCH must NOT false-DEGRADE) + real FALLBACK_UNDERSIZED must stay DEGRADED + persisted-fallback + explicit UNAVAILABLE."
package services

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/safety"
)

func setShow(m *executor.MockExecutor, high, max, tasks int64, dropins string) {
	m.RunResults[healthShowKey()] = executor.Result{Stdout: showOut(high, max, tasks, dropins)}
}

func nolog() *logging.Logger { return logging.New("/dev/null", false) }

// 1. current non-zero verdict → returned as-is; live systemd is NOT queried.
func TestResolveUsesCurrentWhenNonZero(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 * 1024 * miB) // medium
	cur := healthresource.Verdict{Profile: p, EffectiveState: healthresource.StateActiveMatch, CalculatedMax: p.MemoryMax}
	got := resolveWithProfile(m, &state.StateFile{}, nolog(), cur, verFixture, p)
	if got.EffectiveState != healthresource.StateActiveMatch {
		t.Fatalf("want current verdict preserved, got %s", got.EffectiveState)
	}
	for _, c := range m.Commands {
		if c.Name == "systemctl" {
			t.Fatal("resolver must NOT query live systemd when a current verdict is present")
		}
	}
}

//  2. REPAIR-RESUME regression: zero current, medium host, live drop-in ACTIVE_MATCH
//     → resolves ACTIVE_MATCH, acceptable, NO false DEGRADED, never a zero verdict.
func TestResolveZeroMediumLiveActiveMatch(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 * 1024 * miB) // medium 256/384
	setShow(m, p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)
	m.Files[healthresource.DropinFile] = healthresource.Render(p, verFixture)
	got := resolveWithProfile(m, &state.StateFile{}, nolog(), healthresource.Verdict{}, verFixture, p)
	if got.IsZero() {
		t.Fatal("resolver must NEVER return a zero verdict")
	}
	if got.EffectiveState != healthresource.StateActiveMatch {
		t.Fatalf("want ACTIVE_MATCH from live systemd, got %s", got.EffectiveState)
	}
	if !got.Acceptable() {
		t.Fatal("medium ACTIVE_MATCH must be acceptable — repair must NOT false-DEGRADE")
	}
}

//  3. A genuinely underprotected medium host (live effective < calc) must REMAIN
//     not-acceptable — the fix must not mask real underprotection.
func TestResolveZeroMediumLiveUndersizedStaysDegraded(t *testing.T) {
	m := executor.NewMockExecutor()
	p := profFor(6 * 1024 * miB) // medium calc 256/384
	setShow(m, 192*miB, 256*miB, 64, "")
	got := resolveWithProfile(m, &state.StateFile{}, nolog(), healthresource.Verdict{}, verFixture, p)
	if got.EffectiveState != healthresource.StateFallbackUnder {
		t.Fatalf("want FALLBACK_UNDERSIZED, got %s", got.EffectiveState)
	}
	if got.Acceptable() {
		t.Fatal("medium underprotected must NOT be acceptable (truthful DEGRADED)")
	}
}

// 4. live systemd unreadable + persisted evidence → cautious reconstruction.
func TestResolveShowFailsUsesPersisted(t *testing.T) {
	m := executor.NewMockExecutor()
	m.RunResults[healthShowKey()] = executor.Result{ExitCode: 1, Stderr: "boom"}
	p := profFor(6 * 1024 * miB)
	sf := &state.StateFile{
		HealthResourceState:      string(healthresource.StateActiveMatch),
		HealthResourceProfile:    string(safety.ResourceTierMedium),
		HealthResourceProtection: true,
		HealthMemMaxEffective:    402653184,
	}
	got := resolveWithProfile(m, sf, nolog(), healthresource.Verdict{}, verFixture, p)
	if got.EffectiveState != healthresource.StateActiveMatch {
		t.Fatalf("want persisted ACTIVE_MATCH reconstruction, got %s", got.EffectiveState)
	}
}

// 5. live systemd unreadable + NO persisted → explicit, MARKED UNAVAILABLE (never zero).
func TestResolveShowFailsNoPersistedUnavailable(t *testing.T) {
	m := executor.NewMockExecutor()
	m.RunResults[healthShowKey()] = executor.Result{ExitCode: 1, Stderr: "boom"}
	got := resolveWithProfile(m, &state.StateFile{}, nolog(), healthresource.Verdict{}, verFixture, profFor(6*1024*miB))
	if got.IsZero() {
		t.Fatal("unresolved verdict must be MARKED UNAVAILABLE, not a silent zero")
	}
	if got.EffectiveState != healthresource.StateUnavailable {
		t.Fatalf("want UNAVAILABLE, got %s", got.EffectiveState)
	}
}
