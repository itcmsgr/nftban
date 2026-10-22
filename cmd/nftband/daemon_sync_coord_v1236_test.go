// =============================================================================
// NFTBan v1.236 - sync coordination: generation-aware joining + two-part result
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband-sync-coord-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="Hermetic tests of daemon_sync_coord.go: coverage by generation, one follow-up per mode, bounded waits, join, unknown, effect mapping"
// meta:inventory.files="cmd/nftband/daemon_sync_coord_v1236_test.go"
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/pkg/ipc"
)

// gatedRuns is a sync executor whose runs block until released.
type gatedRuns struct {
	mu      sync.Mutex
	modes   []bool // full?
	started chan bool
	release chan struct{}
	resp    func(n int, full bool) SocketResponse
}

func newGatedRuns() *gatedRuns {
	return &gatedRuns{started: make(chan bool, 16), release: make(chan struct{}, 16)}
}

func (g *gatedRuns) exec(full bool) SocketResponse {
	g.mu.Lock()
	g.modes = append(g.modes, full)
	n := len(g.modes)
	g.mu.Unlock()
	g.started <- full
	<-g.release
	if g.resp != nil {
		return g.resp(n, full)
	}
	return SocketResponse{Success: true, Data: map[string]any{ipc.KeyEffect: string(ipc.EffectApplied)}}
}

func (g *gatedRuns) runs() []bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]bool(nil), g.modes...)
}

func waitStarted(t *testing.T, g *gatedRuns) bool {
	t.Helper()
	select {
	case full := <-g.started:
		return full
	case <-time.After(5 * time.Second):
		t.Fatal("run did not start")
		return false
	}
}

func dataOf(t *testing.T, r SocketResponse) map[string]any {
	t.Helper()
	m, ok := r.Data.(map[string]any)
	if !ok {
		t.Fatalf("response without data map: %+v", r)
	}
	return m
}

func soon() time.Time { return time.Now().Add(5 * time.Second) }

// A request registered while a run is in progress is NOT covered by that run (the run
// may have read the sources before the caller wrote them). All such requests share
// ONE follow-up run.
func TestSyncCoordRequestsDuringRunShareOneFollowUp(t *testing.T) {
	g := newGatedRuns()
	c := newSyncCoordinator(g.exec, nil)

	sA, gA := c.submit(true)
	waitStarted(t, g)
	sB, gB := c.submit(true)
	sC, gC := c.submit(true)

	res := make([]SocketResponse, 3)
	var wg sync.WaitGroup
	for i, req := range []struct {
		s   uint64
		gen string
	}{{sA, gA}, {sB, gB}, {sC, gC}} {
		wg.Add(1)
		go func(i int, s uint64, gen string) {
			defer wg.Done()
			res[i] = c.await(s, true, gen, soon())
		}(i, req.s, req.gen)
	}

	g.release <- struct{}{} // finish run 1
	waitStarted(t, g)       // run 2 = the one follow-up
	g.release <- struct{}{}
	wg.Wait()

	if n := len(g.runs()); n != 2 {
		t.Fatalf("want exactly 2 runs (original + one follow-up), got %d", n)
	}
	wantRun := []float64{1, 2, 2}
	for i, r := range res {
		d := dataOf(t, r)
		if d[ipc.KeyExecution] != string(ipc.ExecCompleted) || !r.Success {
			t.Fatalf("request %d: want completed, got %+v", i, r)
		}
		if run, _ := d["run"].(uint64); float64(run) != wantRun[i] {
			t.Fatalf("request %d covered by run %v, want %v (a newer request must not inherit an older run)", i, d["run"], wantRun[i])
		}
	}
	if j := dataOf(t, res[1])["joined"]; j != true {
		t.Fatalf("request B shares run 2 with C: joined want true, got %v", j)
	}
}

// The wait is bounded: the answer is "running" with the generation, and joining that
// generation later reports the same run without starting another.
func TestSyncCoordBoundedWaitThenJoin(t *testing.T) {
	g := newGatedRuns()
	c := newSyncCoordinator(g.exec, nil)

	s, gen := c.submit(true)
	waitStarted(t, g)
	r := c.await(s, true, gen, time.Now().Add(50*time.Millisecond))
	if d := dataOf(t, r); d[ipc.KeyExecution] != string(ipc.ExecRunning) || d[ipc.KeyGeneration] != gen || r.Success {
		t.Fatalf("want running + generation %s, got %+v", gen, r)
	}

	done := make(chan SocketResponse, 1)
	go func() { done <- c.join(gen, soon()) }()
	g.release <- struct{}{}
	r = <-done
	if d := dataOf(t, r); d[ipc.KeyExecution] != string(ipc.ExecCompleted) || !r.Success {
		t.Fatalf("join after completion: want completed, got %+v", r)
	}
	if n := len(g.runs()); n != 1 {
		t.Fatalf("join must not start work: want 1 run, got %d", n)
	}
	// A late join of a finished generation answers from history, immediately.
	if r := c.join(gen, time.Now().Add(10*time.Millisecond)); dataOf(t, r)[ipc.KeyExecution] != string(ipc.ExecCompleted) {
		t.Fatalf("late join: want completed from history, got %+v", r)
	}
}

func TestSyncCoordUnknownGenerations(t *testing.T) {
	g := newGatedRuns()
	c := newSyncCoordinator(g.exec, nil)
	for _, gen := range []string{
		"",
		"garbage",
		"otherinstance-1-full",     // issued by an earlier daemon
		c.instance + "-99-full",    // never issued
		c.instance + "-0-full",     // never issued
		c.instance + "-1-sideways", // malformed mode
	} {
		r := c.join(gen, time.Now().Add(10*time.Millisecond))
		if d := dataOf(t, r); d[ipc.KeyExecution] != string(ipc.ExecUnknown) || r.Success {
			t.Fatalf("join(%q): want unknown, got %+v", gen, r)
		}
	}
	if n := len(g.runs()); n != 0 {
		t.Fatalf("unknown joins must start nothing, got %d runs", n)
	}
}

// A quick run never covers a full request; a full run covers quick requests.
func TestSyncCoordModeCoverage(t *testing.T) {
	g := newGatedRuns()
	c := newSyncCoordinator(g.exec, nil)

	sQ, gQ := c.submit(false)
	if full := waitStarted(t, g); full {
		t.Fatal("first run must be quick")
	}
	sF, gF := c.submit(true)    // not covered by the running quick run
	sQ2, gQ2 := c.submit(false) // folded into the full follow-up

	out := make(chan [3]SocketResponse, 1)
	go func() {
		out <- [3]SocketResponse{c.await(sQ, false, gQ, soon()), c.await(sF, true, gF, soon()), c.await(sQ2, false, gQ2, soon())}
	}()
	g.release <- struct{}{}
	if full := waitStarted(t, g); !full {
		t.Fatal("follow-up must be FULL (a full request is owed)")
	}
	g.release <- struct{}{}
	res := <-out

	if got := g.runs(); len(got) != 2 || got[0] || !got[1] {
		t.Fatalf("want runs [quick full], got %v", got)
	}
	for i, want := range []uint64{1, 2, 2} {
		if run, _ := dataOf(t, res[i])["run"].(uint64); run != want {
			t.Fatalf("request %d: covered by run %v, want %d", i, run, want)
		}
	}
}

func TestSyncCoordEffectMapping(t *testing.T) {
	cases := []struct {
		name    string
		resp    SocketResponse
		exec    ipc.Execution
		effect  any
		success bool
	}{
		{"applied", SocketResponse{Success: true, Data: map[string]any{ipc.KeyEffect: "applied"}}, ipc.ExecCompleted, "applied", true},
		{"no effect key from success", SocketResponse{Success: true}, ipc.ExecCompleted, "applied", true},
		{"partial", SocketResponse{Success: true, Data: map[string]any{ipc.KeyEffect: "partial"}}, ipc.ExecCompleted, "partial", true},
		{"refused", SocketResponse{Success: false, Error: "refused: no authority", Data: map[string]any{ipc.KeyEffect: "refused"}}, ipc.ExecCompleted, "refused", false},
		{"failed", SocketResponse{Success: false, Error: "sync failed: x"}, ipc.ExecFailed, nil, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := newSyncCoordinator(func(bool) SocketResponse { return tc.resp }, nil)
			s, gen := c.submit(true)
			r := c.await(s, true, gen, soon())
			d := dataOf(t, r)
			if d[ipc.KeyExecution] != string(tc.exec) || d[ipc.KeyEffect] != tc.effect || r.Success != tc.success {
				t.Fatalf("got execution=%v effect=%v success=%v, want %v/%v/%v", d[ipc.KeyExecution], d[ipc.KeyEffect], r.Success, tc.exec, tc.effect, tc.success)
			}
		})
	}
}

func TestSyncCoordPanicIsFailedAndLoopSurvives(t *testing.T) {
	n := 0
	c := newSyncCoordinator(func(bool) SocketResponse {
		n++
		if n == 1 {
			panic("boom")
		}
		return SocketResponse{Success: true}
	}, nil)
	s, gen := c.submit(true)
	if d := dataOf(t, c.await(s, true, gen, soon())); d[ipc.KeyExecution] != string(ipc.ExecFailed) {
		t.Fatalf("panicking run: want failed, got %v", d)
	}
	s, gen = c.submit(true)
	if d := dataOf(t, c.await(s, true, gen, soon())); d[ipc.KeyExecution] != string(ipc.ExecCompleted) {
		t.Fatalf("next run after a panic: want completed, got %v", d)
	}
}

func TestSyncCoordShutdownIsUnknown(t *testing.T) {
	g := newGatedRuns()
	stop := make(chan struct{})
	c := newSyncCoordinator(g.exec, stop)
	s, gen := c.submit(true)
	waitStarted(t, g)
	close(stop)
	if d := dataOf(t, c.await(s, true, gen, soon())); d[ipc.KeyExecution] != string(ipc.ExecUnknown) {
		t.Fatalf("shutdown while waiting: want unknown, got %v", d)
	}
	g.release <- struct{}{}
}

// A generation whose own run fell out of the bounded history is answered by the oldest
// held run that started after it: that run also read the sources after the request, so
// it covers it. It is never answered by the evicted run or anything older.
func TestSyncCoordEvictedGenerationAnsweredByLaterCoveringRun(t *testing.T) {
	c := newSyncCoordinator(func(bool) SocketResponse { return SocketResponse{Success: true} }, nil)
	first, firstGen := c.submit(true)
	c.await(first, true, firstGen, soon())
	for i := 0; i < syncHistoryLimit+2; i++ {
		s, gen := c.submit(true)
		c.await(s, true, gen, soon())
	}
	d := dataOf(t, c.join(firstGen, time.Now().Add(10*time.Millisecond)))
	if d[ipc.KeyExecution] != string(ipc.ExecCompleted) {
		t.Fatalf("evicted generation: want completed by a later covering run, got %v", d)
	}
	if run, _ := d["run"].(uint64); run <= 1 {
		t.Fatalf("evicted generation answered by run %v; want a run held in history (> 1)", d["run"])
	}
}

func TestSyncWaitDeadlineCappedInsideConnectionDeadline(t *testing.T) {
	t.Setenv("NFTBAN_TIMEOUT_IPC_SOCKET", "30")
	within := func(d time.Time, want time.Duration) bool {
		got := time.Until(d)
		return got > want-time.Second && got <= want
	}
	if d := syncWaitDeadline(nil); !within(d, 25*time.Second) {
		t.Fatalf("default wait: want ~25s (30s - margin), got %v", time.Until(d))
	}
	if d := syncWaitDeadline(map[string]any{ipc.ParamWaitSeconds: float64(3)}); !within(d, 3*time.Second) {
		t.Fatalf("client wait 3s: got %v", time.Until(d))
	}
	if d := syncWaitDeadline(map[string]any{ipc.ParamWaitSeconds: float64(999)}); !within(d, 25*time.Second) {
		t.Fatalf("client wait above the cap: want ~25s, got %v", time.Until(d))
	}
	t.Setenv("NFTBAN_TIMEOUT_IPC_SOCKET", strconv.Itoa(2))
	if d := syncWaitDeadline(nil); !within(d, time.Second) {
		t.Fatalf("tiny socket timeout: want the 1s floor, got %v", time.Until(d))
	}
}
