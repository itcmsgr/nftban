// =============================================================================
// NFTBan - nftband Daemon - Sync coordination (generation-aware joining)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Runs full/quick syncs off the IPC connection; joins requests by generation; reports execution + effect"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_TIMEOUT_IPC_SOCKET"
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network="/run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================
//
// v1.236 safety lane, Stage 1 part 2 (plan §11.1, owner corrections 1 and 2).
//
// Before: each "sync" IPC ran a full sync synchronously on the connection's goroutine
// behind syncMutex. A client that timed out left the sync running with nobody to
// read the answer, and every retry queued ANOTHER full sync behind it (installer:
// 3 x 15 s; shell: 3 x 30 s), so a slow sync produced a pile of redundant ones and
// the caller reported failure while the work was still converging.
//
// Now every sync request gets a GENERATION (the request's position in the daemon's
// request order). A run COVERS a request only if the run started reading its durable
// sources AFTER the request was registered: a run that began before the caller wrote
// its new configuration can never report that configuration as applied. Requests
// that arrive while a run is in progress are recorded ONCE as an owed follow-up (one
// flag per mode, not a queue), so N retries cost at most one more run. A full run
// covers quick requests; a quick run never covers a full one.
//
// The run executes on the coordinator's goroutine, not on the connection: a client
// that stops waiting does not stop or orphan anything, and it can ask again with
// "join": <generation> instead of submitting new work. Execution and effect are
// reported with the shared two-part result (pkg/ipc/operation.go).
//
// State is in memory only. A generation from an earlier daemon instance is answered
// "unknown", never "completed".

package main

import (
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/ipc"
)

// syncHistoryLimit bounds the completed runs kept for joining (memory only).
const syncHistoryLimit = 32

// syncWaitMargin keeps the daemon's answer inside the connection deadline.
const syncWaitMargin = 5 * time.Second

type syncRun struct {
	id       uint64
	covers   uint64 // every request with generation <= covers (and a compatible mode)
	full     bool
	started  time.Time
	finished time.Time
	done     chan struct{}
	resp     SocketResponse // valid once done is closed
}

type syncCoordinator struct {
	mu       sync.Mutex
	instance string
	seq      uint64 // last generation issued
	pendFull bool   // a full request is not covered by any started run
	pendAny  bool   // a request of either mode is not covered by any started run
	driving  bool   // the run loop goroutine is active
	running  *syncRun
	history  []*syncRun
	runs     uint64
	changed  chan struct{} // closed and replaced on every run start/finish
	exec     func(full bool) SocketResponse
	stop     <-chan struct{}
}

func newSyncCoordinator(exec func(full bool) SocketResponse, stop <-chan struct{}) *syncCoordinator {
	return &syncCoordinator{
		instance: strconv.FormatInt(time.Now().UnixNano(), 36),
		changed:  make(chan struct{}),
		exec:     exec,
		stop:     stop,
	}
}

// syncCoordinator returns the daemon's coordinator, created on first use.
func (d *Daemon) syncCoordinator() *syncCoordinator {
	d.syncCoordOnce.Do(func() {
		var stop <-chan struct{}
		if d.ctx != nil {
			stop = d.ctx.Done()
		}
		d.syncCoord = newSyncCoordinator(func(full bool) SocketResponse { return d.runSync(!full) }, stop)
	})
	return d.syncCoord
}

func (c *syncCoordinator) notifyLocked() {
	close(c.changed)
	c.changed = make(chan struct{})
}

func (c *syncCoordinator) generation(seq uint64, full bool) string {
	mode := "quick"
	if full {
		mode = "full"
	}
	return fmt.Sprintf("%s-%d-%s", c.instance, seq, mode)
}

// submit registers a request and makes sure a run will cover it.
func (c *syncCoordinator) submit(full bool) (uint64, string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.seq++
	s := c.seq
	c.pendAny = true
	if full {
		c.pendFull = true
	}
	if c.running != nil {
		log.Printf("[SYNC] request %s arrived during run %d (started before it): one follow-up run is owed", c.generation(s, full), c.running.id)
	}
	if !c.driving {
		c.driving = true
		go c.drive()
	}
	return s, c.generation(s, full)
}

// drive runs syncs until no request is left uncovered.
func (c *syncCoordinator) drive() {
	for {
		c.mu.Lock()
		if !c.pendAny {
			c.driving = false
			c.mu.Unlock()
			return
		}
		full := c.pendFull
		c.pendFull, c.pendAny = false, false
		c.runs++
		r := &syncRun{id: c.runs, covers: c.seq, full: full, started: time.Now(), done: make(chan struct{})}
		c.running = r
		c.notifyLocked()
		c.mu.Unlock()

		resp := c.execute(full)

		c.mu.Lock()
		r.resp = resp
		r.finished = time.Now()
		c.running = nil
		c.history = append(c.history, r)
		if len(c.history) > syncHistoryLimit {
			c.history = c.history[len(c.history)-syncHistoryLimit:]
		}
		close(r.done)
		c.notifyLocked()
		c.mu.Unlock()
	}
}

func (c *syncCoordinator) execute(full bool) (resp SocketResponse) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("[SYNC] run panicked: %v", p)
			resp = SocketResponse{Success: false, Error: fmt.Sprintf("sync run panicked: %v", p)}
		}
	}()
	return c.exec(full)
}

// coveringLocked returns the first run (finished or in progress) that covers request s.
func (c *syncCoordinator) coveringLocked(s uint64, full bool) *syncRun {
	for _, r := range c.history {
		if r.covers >= s && (r.full || !full) {
			return r
		}
	}
	if r := c.running; r != nil && r.covers >= s && (r.full || !full) {
		return r
	}
	return nil
}

// await waits until the run covering request s finishes, the deadline passes (zero =
// no deadline), or the daemon stops.
func (c *syncCoordinator) await(s uint64, full bool, gen string, deadline time.Time) SocketResponse {
	var timer <-chan time.Time
	if !deadline.IsZero() {
		t := time.NewTimer(time.Until(deadline))
		defer t.Stop()
		timer = t.C
	}
	for {
		c.mu.Lock()
		r := c.coveringLocked(s, full)
		if r != nil && !r.finished.IsZero() {
			c.mu.Unlock()
			return syncFinishedResponse(r, gen, s)
		}
		if r == nil && !c.pendAny {
			// Defensive: no held run covers the request and none is owed. (A request whose
			// own run left the bounded history is still covered by any later held run.)
			c.mu.Unlock()
			return syncUnknownResponse(gen, "the run covering this generation is no longer held by the daemon; completion unknown")
		}
		ch := c.changed
		c.mu.Unlock()
		select {
		case <-ch:
		case <-timer:
			return syncRunningResponse(gen)
		case <-c.stop:
			return syncUnknownResponse(gen, "daemon is shutting down; completion unknown")
		}
	}
}

// join reports the run covering an earlier generation without submitting work.
func (c *syncCoordinator) join(gen string, deadline time.Time) SocketResponse {
	parts := strings.Split(gen, "-")
	if len(parts) != 3 || (parts[2] != "full" && parts[2] != "quick") {
		return syncUnknownResponse(gen, "malformed generation")
	}
	s, err := strconv.ParseUint(parts[1], 10, 64)
	c.mu.Lock()
	instance, last := c.instance, c.seq
	c.mu.Unlock()
	if parts[0] != instance {
		return syncUnknownResponse(gen, "the daemon restarted after this generation was issued; completion unknown")
	}
	if err != nil || s == 0 || s > last {
		return syncUnknownResponse(gen, "generation not issued by this daemon")
	}
	return c.await(s, parts[2] == "full", gen, deadline)
}

func syncResultData(data any, exec ipc.Execution, eff ipc.Effect, gen string) map[string]any {
	m, _ := data.(map[string]any)
	out := make(map[string]any, len(m)+3)
	for k, v := range m {
		out[k] = v
	}
	out[ipc.KeyExecution] = string(exec)
	if eff != "" {
		out[ipc.KeyEffect] = string(eff)
	}
	out[ipc.KeyGeneration] = gen
	return out
}

func syncFinishedResponse(r *syncRun, gen string, s uint64) SocketResponse {
	resp := r.resp
	m, _ := resp.Data.(map[string]any)
	eff, _ := m[ipc.KeyEffect].(string)
	exec := ipc.ExecCompleted
	switch {
	case resp.Success && eff == "":
		eff = string(ipc.EffectApplied)
	case !resp.Success && eff == string(ipc.EffectRefused):
		// Completed with no effect: refused before any write.
	case !resp.Success:
		exec, eff = ipc.ExecFailed, ""
	}
	data := syncResultData(resp.Data, exec, ipc.Effect(eff), gen)
	data["run"] = r.id
	data["run_started"] = r.started.UTC().Format(time.RFC3339Nano)
	data["run_seconds"] = r.finished.Sub(r.started).Seconds()
	// joined = this request did not start the run; it was covered by it.
	data["joined"] = s < r.covers
	return SocketResponse{Success: resp.Success, Data: data, Error: resp.Error}
}

func syncRunningResponse(gen string) SocketResponse {
	return SocketResponse{
		Success: false,
		Error:   "sync still running; join generation " + gen,
		Data:    syncResultData(nil, ipc.ExecRunning, "", gen),
	}
}

func syncUnknownResponse(gen, why string) SocketResponse {
	return SocketResponse{
		Success: false,
		Error:   "sync completion unknown: " + why,
		Data:    syncResultData(nil, ipc.ExecUnknown, "", gen),
	}
}

// syncWaitDeadline: how long this connection may wait for its run. The answer must be
// written before the connection deadline (getIPCSocketTimeout), so the wait is capped
// just inside it; a smaller wait_seconds from the client is honoured.
func syncWaitDeadline(params map[string]any) time.Time {
	limit := getIPCSocketTimeout() - syncWaitMargin
	if limit < time.Second {
		limit = time.Second
	}
	wait := limit
	if v, ok := params[ipc.ParamWaitSeconds].(float64); ok && v > 0 {
		if w := time.Duration(v * float64(time.Second)); w < wait {
			wait = w
		}
	}
	return time.Now().Add(wait)
}

// handleSyncRequest is the "sync" IPC: submit (or join) and answer with the two-part result.
func (d *Daemon) handleSyncRequest(params map[string]any) SocketResponse {
	c := d.syncCoordinator()
	deadline := syncWaitDeadline(params)
	if gen, ok := params[ipc.ParamJoin].(string); ok && gen != "" {
		return c.join(gen, deadline)
	}
	quick, _ := params[ipc.ParamQuick].(bool)
	s, gen := c.submit(!quick)
	return c.await(s, !quick, gen, deadline)
}
