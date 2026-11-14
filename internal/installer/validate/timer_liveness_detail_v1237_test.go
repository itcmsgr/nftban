// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="timer_liveness_detail_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 BUG-INSTALLER-TIMER-LIVENESS-DETAIL-NAMES-ONE-TIMER: when no nftban timer is active after Configure, the timer_liveness_ok detail keeps its VAL-TIMER-001 text and names every timer the installer reconciles (core + optional) that is not active; one active timer still passes."
// meta:inventory.privileges="none"

package validate

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/services"
)

func TestTimerLiveness_DetailNamesEveryInactiveReconciledTimer(t *testing.T) {
	m := executor.NewMockExecutor() // no service active; no nftban.conf -> reconcile default true
	r := assertTimerLiveness(m, nolog())
	if r.Passed {
		t.Fatalf("no active timer must fail timer_liveness_ok")
	}
	if !strings.HasPrefix(r.Detail, TimerLivenessCode+": no active nftban timers after Configure") {
		t.Errorf("VAL-TIMER-001 text must be kept for parsers, got %q", r.Detail)
	}
	want := services.ReconciledTimers()
	if len(want) != 11 {
		t.Fatalf("reconciled timer set changed (%d); update this test with the new count", len(want))
	}
	for _, timer := range want {
		if !strings.Contains(r.Detail, timer) {
			t.Errorf("detail does not name inactive timer %s: %q", timer, r.Detail)
		}
	}
}

func TestTimerLiveness_OneActiveTimerPasses(t *testing.T) {
	m := executor.NewMockExecutor()
	m.Services["nftban-watchdog.timer"] = true
	if r := assertTimerLiveness(m, nolog()); !r.Passed || r.Detail != "" {
		t.Fatalf("one active timer must pass with no detail, got passed=%v detail=%q", r.Passed, r.Detail)
	}
}
