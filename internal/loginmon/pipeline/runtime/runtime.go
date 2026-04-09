// =============================================================================
// NFTBan v1.80 - pipeline runtime (composition root)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: runtime
// Purpose: Pipeline composition root, Parser interface, lifecycle management.
//
// meta:name="loginmon_pipeline_runtime"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="runtime"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Pipeline composition root: wires source, watcher, parser, dedup, aggregate"
//
// meta:inventory.files="runtime.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package runtime is the composition root of the v1.80 pipeline.
//
// It defines the Parser interface (the per-source plug-in point) and the
// Pipeline type that wires together sources, watchers, parsers, the dedup
// sieve, and the aggregator. The Pipeline owns the lifecycle: Start spawns
// goroutines per registered source, Stop cancels them and drains.
//
// Phase A ships the runtime with no real parsers wired in. Tests use
// MemoryWatcher + a fake parser to exercise the end-to-end flow. Phase B
// will add the first real parser (DirectAdmin) and register it via the
// same RegisterSource call shown in this package's tests.
package runtime

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/aggregate"
	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/dedup"
	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/normalize"
	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/source"
	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/watcher"
)

// Parser is the per-source plug-in contract.
//
// A Parser is a pure function: same input, same output. No I/O, no state
// across calls, no DNS lookups. The parser owns its match patterns and
// field extraction; it does NOT own path discovery (that is the source's
// job) or rate limiting (that is the scorer's job).
//
// Parser is the only interface a parser author needs to implement to plug
// into the pipeline. Phase B's DirectAdmin parser will satisfy this
// interface.
type Parser interface {
	// Name returns the source identifier this parser handles. Used by the
	// runtime for logging and registry lookup.
	Name() string

	// Parse attempts to extract a NormalizedEvent from a raw log line.
	// Returns ParseSkipped if the line does not match any pattern (the
	// common case for the vast majority of log lines).
	Parse(line event.RawLine) event.ParseResult
}

// ErrAlreadyStarted is returned by Pipeline.Start if Start was called twice.
var ErrAlreadyStarted = errors.New("pipeline: already started")

// ErrSourceMissing is returned by RegisterSource if the source descriptor
// is in StateMissing — the runtime refuses to register a source whose path
// did not resolve.
var ErrSourceMissing = errors.New("pipeline: source state is MISSING")

// Registration binds one source to one watcher to one parser.
//
// All three must be non-nil. The source's name must equal the watcher's
// source name AND the parser's name (the runtime checks this at register
// time).
type Registration struct {
	Source  source.Source
	Watcher watcher.Watcher
	Parser  Parser
}

// PipelineOptions configures NewPipeline.
type PipelineOptions struct {
	Sieve      *dedup.Sieve      // dedup sieve; if nil, a default sieve is created
	Aggregator *aggregate.Aggregator // aggregator; if nil, a default is created
}

// Pipeline is the composition root.
//
// Lifecycle:
//
//	p := runtime.NewPipeline(runtime.PipelineOptions{})
//	p.Register(reg1)
//	p.Register(reg2)
//	if err := p.Start(ctx); err != nil { ... }
//	defer p.Stop()
//	// ... use p.Snapshot() to read aggregated state ...
//
// Pipeline is safe for concurrent registration before Start. After Start,
// Register returns an error.
type Pipeline struct {
	mu      sync.Mutex
	regs    []Registration
	sieve   *dedup.Sieve
	agg     *aggregate.Aggregator
	started bool
	cancel  context.CancelFunc
	wg      sync.WaitGroup
}

// NewPipeline constructs a Pipeline with the given options.
func NewPipeline(opts PipelineOptions) *Pipeline {
	if opts.Sieve == nil {
		opts.Sieve = dedup.NewSieve(dedup.SieveOptions{})
	}
	if opts.Aggregator == nil {
		opts.Aggregator = aggregate.NewAggregator(aggregate.AggregatorOptions{})
	}
	return &Pipeline{
		sieve: opts.Sieve,
		agg:   opts.Aggregator,
	}
}

// Register binds a source/watcher/parser triple to the pipeline.
//
// All three must share the same name. The source descriptor must NOT be
// in StateMissing — callers should check before registering and emit a
// doctor warning if the source cannot be bound.
//
// Register MUST be called before Start. After Start, returns an error.
func (p *Pipeline) Register(reg Registration) error {
	if reg.Source == nil || reg.Watcher == nil || reg.Parser == nil {
		return errors.New("pipeline: Registration fields must all be non-nil")
	}
	if reg.Source.Name() != reg.Watcher.Source() || reg.Source.Name() != reg.Parser.Name() {
		return errors.New("pipeline: source/watcher/parser names must match")
	}
	if reg.Source.Descriptor().State == source.StateMissing {
		return ErrSourceMissing
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.started {
		return errors.New("pipeline: Register after Start")
	}
	p.regs = append(p.regs, reg)
	return nil
}

// Start spawns one goroutine per registered source. Each goroutine reads
// from its watcher's Lines channel, runs the parser, normalizes, dedups,
// and ingests into the aggregator.
//
// Start returns immediately after the goroutines are running. Errors from
// individual watchers (e.g. failing to open a file) are not propagated; the
// affected source's channel will simply be closed.
func (p *Pipeline) Start(ctx context.Context) error {
	p.mu.Lock()
	if p.started {
		p.mu.Unlock()
		return ErrAlreadyStarted
	}
	p.started = true
	pctx, cancel := context.WithCancel(ctx)
	p.cancel = cancel
	regs := append([]Registration(nil), p.regs...)
	p.mu.Unlock()

	for _, reg := range regs {
		if err := reg.Source.Open(); err != nil {
			// Source failed to open: skip its goroutine. The source will
			// remain unregistered from the dataflow but the descriptor is
			// still observable via the (future) status surface.
			continue
		}
		if err := reg.Watcher.Start(pctx); err != nil {
			_ = reg.Source.Close()
			continue
		}
		p.wg.Add(1)
		go p.runSource(pctx, reg)
	}
	return nil
}

// Stop cancels all running source goroutines and waits for them to drain.
// Idempotent.
func (p *Pipeline) Stop() error {
	p.mu.Lock()
	if !p.started {
		p.mu.Unlock()
		return nil
	}
	p.started = false
	cancel := p.cancel
	p.cancel = nil
	p.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	for _, reg := range p.regs {
		_ = reg.Watcher.Stop()
	}
	p.wg.Wait()
	for _, reg := range p.regs {
		_ = reg.Source.Close()
	}
	return nil
}

// Snapshot returns the current aggregator snapshot. Safe to call from any
// goroutine. Cheap; downstream consumers should still cache for ~60s.
func (p *Pipeline) Snapshot() aggregate.Snapshot {
	return p.agg.Snapshot()
}

// RecordBan records a ban observed by the legacy scorer. This bridges the
// existing ban path into the pipeline aggregator so the Effective-axis
// ratio (bans/events) is computed against real data, not always 1.0.
//
// Phase E: called from module.go's EventBan subscriber when the pipeline
// is enabled. The pipeline does NOT issue bans itself.
func (p *Pipeline) RecordBan(source string, at time.Time) {
	p.agg.RecordBan(source, at)
}

// EffectiveHealth evaluates the Effective-axis state machine against the
// current aggregator snapshot and returns the host-level summary.
func (p *Pipeline) EffectiveHealth() aggregate.HostEffective {
	return aggregate.EvaluateHost(p.agg.Snapshot())
}

// runSource is the per-source goroutine. Reads lines from the watcher,
// parses, normalizes, dedups, ingests.
func (p *Pipeline) runSource(ctx context.Context, reg Registration) {
	defer p.wg.Done()
	lines := reg.Watcher.Lines()
	for {
		select {
		case <-ctx.Done():
			return
		case rl, ok := <-lines:
			if !ok {
				return
			}
			res := reg.Parser.Parse(rl)
			if res.Outcome != event.ParseMatched {
				continue
			}
			ne := normalize.Canonicalize(res.Event)
			if !p.sieve.Admit(ne) {
				continue
			}
			p.agg.Ingest(ne)
		}
	}
}
