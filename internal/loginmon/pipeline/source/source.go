// =============================================================================
// NFTBan v1.80 - pipeline source abstraction
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: source
// Purpose: Source interface wrapping distroconf for the v1.80 pipeline.
//
// meta:name="loginmon_pipeline_source"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="source"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Source interface and Descriptor wrapping distroconf"
//
// meta:inventory.files="source.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/distros/*.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package source defines the Source abstraction for the v1.80 pipeline.
//
// A Source represents one parser input (exim, dovecot, directadmin, etc.)
// and provides a stable identity, a descriptor (where its log file lives,
// who said so), and Open/Close lifecycle methods. The descriptor reuses
// the v1.79.2 distroconf truth surface — Source does NOT duplicate path
// discovery logic.
//
// MIGRATION READINESS
//
// To migrate a parser from the legacy detector layer to the pipeline:
//
//  1. Construct a Source via NewFileSource(loader, key, name) — the source
//     resolves its path through distroconf and records the resolution origin.
//  2. Pass it to runtime.Pipeline.Register along with a watcher and parser.
//  3. Leave the legacy parser in detector/ untouched until parity is proven.
package source

import (
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/distroconf"
)

// State is the lifecycle state of a Source.
//
// These mirror the v1.79.2 truth foundation plan Section C states. UNKNOWN
// is intentionally NOT a valid value: any code path that would emit it is a
// bug. UNKNOWN was eliminated from the validator in v1.79.1 and the pipeline
// must not reintroduce it.
type State int

const (
	// StateActive: descriptor resolved, file exists, watcher can attach.
	StateActive State = iota

	// StateStale: descriptor resolved, file exists, but mtime is older than
	// the freshness threshold. The parser may still tail it, but the doctor
	// surfaces an advisory.
	StateStale

	// StateMissing: descriptor required (service detected) but no candidate
	// path resolved through distroconf, authority probe, or fallback.
	StateMissing

	// StateDisabled: operator opt-out, OR distroconf returned NotApplicable
	// (n/a literal). Parser intentionally does not start.
	StateDisabled
)

// String satisfies fmt.Stringer.
func (s State) String() string {
	switch s {
	case StateActive:
		return "ACTIVE"
	case StateStale:
		return "STALE"
	case StateMissing:
		return "MISSING"
	case StateDisabled:
		return "DISABLED"
	}
	return "INVALID"
}

// Descriptor describes one Source after path resolution.
//
// It wraps a distroconf.Resolution (the canonical truth-surface result) and
// adds runtime fields the pipeline needs: state, freshness, and whether the
// file exists at the resolved path.
//
// Descriptor is the unit of truth that the CLI, validator, and doctor will
// consume in later phases. The pipeline emits one of these per registered
// source at startup, and one updated copy per rotation event.
type Descriptor struct {
	Name       string                 // source identifier ("exim", "directadmin", ...)
	Service    string                 // free-form service label
	DistroKey  string                 // the distroconf [paths] key consulted
	Resolution distroconf.Resolution  // raw resolution result from distroconf
	Path       string                 // chosen path (may differ from Resolution.Path
	                                  // when authority/fallback layers win)
	ResolvedBy string                 // "distroconf" | "authority" | "fallback" | ""
	State      State
	Reason     string                 // human-readable explanation for State
	Mtime      time.Time              // freshness check result; zero value if unknown
	Discovered time.Time              // when the descriptor was built
}

// Source is the abstraction the pipeline registers.
//
// A Source has stable identity (Name) and produces a current Descriptor.
// Open/Close are lifecycle hooks for sources that need setup/teardown
// (most file-based sources do not, but the interface keeps the door open).
type Source interface {
	// Name returns the canonical identifier of this source.
	Name() string

	// Descriptor returns the current truth-surface descriptor for this
	// source. Callers MUST treat the returned value as immutable.
	Descriptor() Descriptor

	// Open prepares the source for use. For file sources this is typically
	// a no-op (the watcher opens the file). It exists so future sources
	// (e.g. journald, IPC) can do setup.
	Open() error

	// Close releases any resources held by the source. Idempotent.
	Close() error
}

// FileSource is a Source backed by a regular file on disk, resolved through
// distroconf. It is the canonical Source implementation for v1.80 Phase A.
//
// FileSource does NOT tail the file itself — that is the watcher's job.
// FileSource only owns the descriptor and resolves the path at construction
// time. If the operator wants to re-resolve (e.g. after a config reload),
// they construct a new FileSource.
type FileSource struct {
	mu         sync.RWMutex
	descriptor Descriptor
}

// FileSourceOptions configures NewFileSource.
//
// Loader is REQUIRED. If nil, the resolver always returns LoaderUnavailable
// and the source falls through to the AuthorityFn / Fallback layers.
//
// AuthorityFn is OPTIONAL. When set, it is called if distroconf does not
// resolve the key (Absent or LoaderUnavailable). It should return the
// authoritative path discovered via a service-specific tool (e.g.
// `exim -bP log_file_path`). Empty string + nil error means "tool not
// installed; not an error" — caller falls through to Fallback.
//
// Fallback is OPTIONAL. When set, it is the ordered list of hard-coded
// candidate paths tried in order if both distroconf and AuthorityFn fail.
//
// FreshnessMax controls when StateActive degrades to StateStale. Default
// is 24 hours.
type FileSourceOptions struct {
	Name         string
	Service      string
	DistroKey    string
	Loader       *distroconf.Loader
	AuthorityFn  func() (string, error)
	AuthorityName string
	Fallback     []string
	FreshnessMax time.Duration
}

// DefaultFreshnessMax is the default StateActive→StateStale threshold.
const DefaultFreshnessMax = 24 * time.Hour

// NewFileSource constructs a FileSource by running the layered resolution
// against distroconf, then the authoritative tool, then the fallback list.
//
// The returned source's Descriptor reflects the resolution outcome. If no
// layer resolves a path, the descriptor's State is StateMissing and the
// caller should NOT register a watcher for it (the runtime will skip it).
func NewFileSource(opts FileSourceOptions) *FileSource {
	if opts.FreshnessMax == 0 {
		opts.FreshnessMax = DefaultFreshnessMax
	}

	d := Descriptor{
		Name:       opts.Name,
		Service:    opts.Service,
		DistroKey:  opts.DistroKey,
		Discovered: time.Now(),
	}

	// Layer 1: distroconf
	r := opts.Loader.Resolve(opts.DistroKey) // safe on nil receiver
	d.Resolution = r

	switch r.Outcome {
	case distroconf.Resolved:
		if mt, ok := statMtime(r.Path); ok {
			d.Path = r.Path
			d.ResolvedBy = "distroconf"
			d.Mtime = mt
			d.State = freshnessState(mt, opts.FreshnessMax)
			d.Reason = fmt.Sprintf("distroconf:%s", r.DistroID)
			return &FileSource{descriptor: d}
		}
		// Path resolved but not on disk: fall through to next layer.
	case distroconf.NotApplicable:
		d.State = StateDisabled
		d.Reason = r.Reason
		return &FileSource{descriptor: d}
	case distroconf.Absent, distroconf.LoaderUnavailable:
		// fall through to layer 2
	}

	// Layer 2: authoritative tool
	if opts.AuthorityFn != nil {
		if path, err := opts.AuthorityFn(); err == nil && path != "" {
			if mt, ok := statMtime(path); ok {
				d.Path = path
				d.ResolvedBy = "authority"
				d.Mtime = mt
				d.State = freshnessState(mt, opts.FreshnessMax)
				d.Reason = "authority:" + opts.AuthorityName
				return &FileSource{descriptor: d}
			}
		}
	}

	// Layer 3: hard-coded fallback list
	for _, p := range opts.Fallback {
		if mt, ok := statMtime(p); ok {
			d.Path = p
			d.ResolvedBy = "fallback"
			d.Mtime = mt
			d.State = freshnessState(mt, opts.FreshnessMax)
			d.Reason = "fallback:hardcoded_probe"
			return &FileSource{descriptor: d}
		}
	}

	// Layer 4: MISSING
	d.State = StateMissing
	d.Reason = "no candidate path resolved (distroconf, authority, fallback all failed)"
	return &FileSource{descriptor: d}
}

// Name returns the source identifier.
func (s *FileSource) Name() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.descriptor.Name
}

// Descriptor returns a snapshot of the current source descriptor.
func (s *FileSource) Descriptor() Descriptor {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.descriptor
}

// Open is a no-op for FileSource. The watcher opens the file.
func (s *FileSource) Open() error { return nil }

// Close is a no-op for FileSource. Idempotent.
func (s *FileSource) Close() error { return nil }

// Refresh re-stats the bound path and updates the freshness state.
//
// This is called by the runtime on a periodic tick (e.g. every 60 seconds)
// so that StateActive can transition to StateStale (or back) as the file is
// written to or goes idle. Refresh does NOT re-run the layered resolver —
// once a source has bound a path, that path is stable until restart.
func (s *FileSource) Refresh(maxAge time.Duration) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.descriptor.State == StateMissing || s.descriptor.State == StateDisabled {
		return
	}
	if mt, ok := statMtime(s.descriptor.Path); ok {
		s.descriptor.Mtime = mt
		s.descriptor.State = freshnessState(mt, maxAge)
	} else {
		// File disappeared since startup — degrade to MISSING.
		s.descriptor.State = StateMissing
		s.descriptor.Reason = fmt.Sprintf("path %s no longer exists", s.descriptor.Path)
	}
}

// statMtime returns the file's modification time, or (zero, false) if the
// file does not exist or cannot be stat'd.
func statMtime(path string) (time.Time, bool) {
	if path == "" {
		return time.Time{}, false
	}
	// #nosec G304 -- path comes from distroconf or hard-coded fallback list,
	// not user input. Same risk profile as the v1.79.2 distroconf reader.
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}, false
	}
	return info.ModTime(), true
}

// freshnessState maps an mtime + threshold to ACTIVE or STALE.
func freshnessState(mtime time.Time, maxAge time.Duration) State {
	if maxAge <= 0 {
		maxAge = DefaultFreshnessMax
	}
	if time.Since(mtime) > maxAge {
		return StateStale
	}
	return StateActive
}

// === MemorySource: in-memory test implementation ===

// MemorySource is a Source implementation for unit tests. It holds a
// fixed Descriptor in memory and never touches the filesystem.
type MemorySource struct {
	descriptor Descriptor
	openErr    error
	closeErr   error
}

// NewMemorySource constructs a MemorySource with a synthetic descriptor.
// Used by tests to register sources without needing real distro confs or
// real files on disk.
func NewMemorySource(name string, state State) *MemorySource {
	return &MemorySource{
		descriptor: Descriptor{
			Name:       name,
			State:      state,
			Discovered: time.Now(),
			Reason:     "synthetic memory source",
		},
	}
}

// Name returns the source identifier.
func (s *MemorySource) Name() string { return s.descriptor.Name }

// Descriptor returns the in-memory descriptor.
func (s *MemorySource) Descriptor() Descriptor { return s.descriptor }

// Open returns the configured open error (default nil).
func (s *MemorySource) Open() error { return s.openErr }

// Close returns the configured close error (default nil).
func (s *MemorySource) Close() error { return s.closeErr }

// SetState updates the source state. Test helper.
func (s *MemorySource) SetState(st State) { s.descriptor.State = st }

// ErrNotImplemented is returned by stub source methods that have not been
// wired up yet.
var ErrNotImplemented = errors.New("source: not implemented")
