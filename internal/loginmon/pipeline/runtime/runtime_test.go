// =============================================================================
// NFTBan v1.80 - pipeline runtime end-to-end tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: runtime
// Purpose: End-to-end test of the pipeline using fake source/watcher/parser.
//
// meta:name="loginmon_pipeline_runtime_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="runtime"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="End-to-end pipeline test: fake watcher + fake parser → aggregator"
//
// meta:inventory.files="runtime_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package runtime

import (
	"bytes"
	"context"
	"net/netip"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/source"
	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/watcher"
)

// fakeParser is a minimal Parser implementation for tests. It matches lines
// of the form "ATTACK <ip> <user>" and produces a NormalizedEvent.
type fakeParser struct {
	name string
}

func (p *fakeParser) Name() string { return p.name }

func (p *fakeParser) Parse(line event.RawLine) event.ParseResult {
	const prefix = "ATTACK "
	if !bytes.HasPrefix(line.Line, []byte(prefix)) {
		return event.ParseResult{Outcome: event.ParseSkipped}
	}
	rest := line.Line[len(prefix):]
	sp := bytes.IndexByte(rest, ' ')
	if sp < 0 {
		return event.ParseResult{Outcome: event.ParseMalformed}
	}
	ipStr := string(rest[:sp])
	user := string(rest[sp+1:])
	addr, err := netip.ParseAddr(ipStr)
	if err != nil {
		return event.ParseResult{Outcome: event.ParseMalformed}
	}
	return event.ParseResult{
		Outcome: event.ParseMatched,
		Event: event.NormalizedEvent{
			Source:    p.name,
			Reason:    event.ReasonDovecotAuthFail,
			SrcIP:     addr,
			Username:  user,
			Timestamp: line.ReceivedAt,
		},
	}
}

func TestPipeline_EndToEnd(t *testing.T) {
	src := source.NewMemorySource("dovecot", source.StateActive)
	w := watcher.NewMemoryWatcher("dovecot", 64)
	p := &fakeParser{name: "dovecot"}

	pipe := NewPipeline(PipelineOptions{})
	if err := pipe.Register(Registration{Source: src, Watcher: w, Parser: p}); err != nil {
		t.Fatalf("Register: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := pipe.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer pipe.Stop()

	// Push 10 attack lines: 8 distinct IPs, 1 victim user.
	for i := 0; i < 10; i++ {
		ipLast := i + 1
		if i >= 8 {
			ipLast = 1 // last 2 are duplicates of first IP
		}
		line := []byte("ATTACK 192.0.2." + intToStr(ipLast) + " info@victim.gr")
		if !w.Push(line) {
			t.Fatal("Push returned false")
		}
	}

	// Push some non-matching lines (must be silently skipped)
	for i := 0; i < 3; i++ {
		w.Push([]byte("noise line " + intToStr(i)))
	}

	// Allow the pipeline goroutine to drain.
	time.Sleep(200 * time.Millisecond)

	snap := pipe.Snapshot()
	src1, ok := snap.Sources["dovecot"]
	if !ok {
		t.Fatal("dovecot source missing from snapshot")
	}
	// Use the smallest window from DefaultWindows for the assertions.
	var w5 = 5 * time.Minute
	ws, ok := src1.Windows[w5]
	if !ok {
		t.Fatal("5-minute window missing")
	}

	// 8 distinct IPs * 1 user = 8 events admitted; the 2 duplicates of
	// 192.0.2.1 are suppressed by dedup (same Reason+IP+User+TimeBucket).
	if ws.EventCount != 8 {
		t.Errorf("EventCount: got %d, want 8 (10 pushed - 2 dedup duplicates)", ws.EventCount)
	}
	if ws.UniqueIPs != 8 {
		t.Errorf("UniqueIPs: got %d, want 8", ws.UniqueIPs)
	}
	if ws.UniqueAccounts != 1 {
		t.Errorf("UniqueAccounts: got %d, want 1", ws.UniqueAccounts)
	}
	if ws.MaxIPsPerAccount != 8 {
		t.Errorf("MaxIPsPerAccount: got %d, want 8 (distributed spray)", ws.MaxIPsPerAccount)
	}
}

func TestPipeline_RegisterStateMissingFails(t *testing.T) {
	src := source.NewMemorySource("test", source.StateMissing)
	w := watcher.NewMemoryWatcher("test", 8)
	p := &fakeParser{name: "test"}
	pipe := NewPipeline(PipelineOptions{})

	err := pipe.Register(Registration{Source: src, Watcher: w, Parser: p})
	if err != ErrSourceMissing {
		t.Errorf("got %v, want ErrSourceMissing", err)
	}
}

func TestPipeline_RegisterNameMismatchFails(t *testing.T) {
	src := source.NewMemorySource("dovecot", source.StateActive)
	w := watcher.NewMemoryWatcher("exim", 8) // wrong name
	p := &fakeParser{name: "dovecot"}
	pipe := NewPipeline(PipelineOptions{})

	if err := pipe.Register(Registration{Source: src, Watcher: w, Parser: p}); err == nil {
		t.Error("expected name-mismatch error")
	}
}

func TestPipeline_DoubleStartFails(t *testing.T) {
	pipe := NewPipeline(PipelineOptions{})
	ctx := context.Background()
	if err := pipe.Start(ctx); err != nil {
		t.Fatalf("first Start: %v", err)
	}
	defer pipe.Stop()
	if err := pipe.Start(ctx); err != ErrAlreadyStarted {
		t.Errorf("second Start: got %v, want ErrAlreadyStarted", err)
	}
}

func TestPipeline_StopIsIdempotent(t *testing.T) {
	pipe := NewPipeline(PipelineOptions{})
	if err := pipe.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := pipe.Stop(); err != nil {
		t.Fatalf("first Stop: %v", err)
	}
	if err := pipe.Stop(); err != nil {
		t.Fatalf("second Stop: %v", err)
	}
}

// intToStr — small int to decimal string, no fmt dep.
func intToStr(n int) string {
	if n == 0 {
		return "0"
	}
	negative := n < 0
	if negative {
		n = -n
	}
	var buf [16]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if negative {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
