// =============================================================================
// NFTBan v1.80 - pipeline source tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: source
// Purpose: Tests for Source interface and FileSource layered resolution.
//
// meta:name="loginmon_pipeline_source_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="source"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Tests for source.FileSource and MemorySource"
//
// meta:inventory.files="source_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package source

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/distroconf"
)

func TestStateString(t *testing.T) {
	cases := map[State]string{
		StateActive:   "ACTIVE",
		StateStale:    "STALE",
		StateMissing:  "MISSING",
		StateDisabled: "DISABLED",
	}
	for in, want := range cases {
		if in.String() != want {
			t.Errorf("State(%d).String: got %q, want %q", in, in.String(), want)
		}
	}
}

func TestMemorySource(t *testing.T) {
	s := NewMemorySource("test", StateActive)
	if s.Name() != "test" {
		t.Errorf("Name: got %q", s.Name())
	}
	if s.Descriptor().State != StateActive {
		t.Errorf("State: got %v", s.Descriptor().State)
	}
	if err := s.Open(); err != nil {
		t.Errorf("Open: %v", err)
	}
	if err := s.Close(); err != nil {
		t.Errorf("Close: %v", err)
	}
	s.SetState(StateMissing)
	if s.Descriptor().State != StateMissing {
		t.Errorf("after SetState: got %v", s.Descriptor().State)
	}
}

func TestFileSource_NoLoader_NoAuthority_NoFallback(t *testing.T) {
	// All four layers fail → MISSING.
	s := NewFileSource(FileSourceOptions{
		Name:      "noop",
		DistroKey: "anything",
	})
	d := s.Descriptor()
	if d.State != StateMissing {
		t.Errorf("State: got %v, want StateMissing", d.State)
	}
	if d.Path != "" {
		t.Errorf("Path: got %q, want empty", d.Path)
	}
}

func TestFileSource_FallbackResolves(t *testing.T) {
	// Layer 3 fallback wins because no loader and no authority.
	dir := t.TempDir()
	logPath := filepath.Join(dir, "exim.log")
	if err := os.WriteFile(logPath, []byte("seed\n"), 0644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	s := NewFileSource(FileSourceOptions{
		Name:      "exim",
		DistroKey: "exim_log",
		Fallback:  []string{"/nonexistent/foo", logPath},
	})
	d := s.Descriptor()
	if d.State != StateActive {
		t.Errorf("State: got %v, want StateActive", d.State)
	}
	if d.Path != logPath {
		t.Errorf("Path: got %q, want %q", d.Path, logPath)
	}
	if d.ResolvedBy != "fallback" {
		t.Errorf("ResolvedBy: got %q, want fallback", d.ResolvedBy)
	}
}

func TestFileSource_AuthorityWinsBeforeFallback(t *testing.T) {
	dir := t.TempDir()
	authPath := filepath.Join(dir, "authority.log")
	fallbackPath := filepath.Join(dir, "fallback.log")
	for _, p := range []string{authPath, fallbackPath} {
		if err := os.WriteFile(p, []byte("x\n"), 0644); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
	}

	s := NewFileSource(FileSourceOptions{
		Name:      "test",
		DistroKey: "test_log",
		AuthorityFn: func() (string, error) {
			return authPath, nil
		},
		AuthorityName: "test-tool --bP",
		Fallback:      []string{fallbackPath},
	})
	d := s.Descriptor()
	if d.Path != authPath {
		t.Errorf("Path: got %q, want %q (authority should win)", d.Path, authPath)
	}
	if d.ResolvedBy != "authority" {
		t.Errorf("ResolvedBy: got %q, want authority", d.ResolvedBy)
	}
}

func TestFileSource_DistroconfWinsAboveAll(t *testing.T) {
	// Build a synthetic distro conf and loader.
	dir := t.TempDir()
	logPath := filepath.Join(dir, "from-distroconf.log")
	if err := os.WriteFile(logPath, []byte("x\n"), 0644); err != nil {
		t.Fatalf("write log: %v", err)
	}

	confDir := t.TempDir()
	confPath := filepath.Join(confDir, "synthetic-1.conf")
	conf := "[distro]\nfamily = synthetic\n[paths]\nthe_log = " + logPath + "\n"
	if err := os.WriteFile(confPath, []byte(conf), 0644); err != nil {
		t.Fatalf("write conf: %v", err)
	}
	loader, err := distroconf.LoadFromFile(confPath)
	if err != nil {
		t.Fatalf("load distroconf: %v", err)
	}

	s := NewFileSource(FileSourceOptions{
		Name:      "test",
		DistroKey: "the_log",
		Loader:    loader,
		AuthorityFn: func() (string, error) {
			t.Fatalf("authority should not be called when distroconf resolves")
			return "", nil
		},
		Fallback: []string{"/should/not/be/used"},
	})
	d := s.Descriptor()
	if d.Path != logPath {
		t.Errorf("Path: got %q, want %q", d.Path, logPath)
	}
	if d.ResolvedBy != "distroconf" {
		t.Errorf("ResolvedBy: got %q, want distroconf", d.ResolvedBy)
	}
}

func TestFileSource_NotApplicableMarksDisabled(t *testing.T) {
	confDir := t.TempDir()
	confPath := filepath.Join(confDir, "na-1.conf")
	conf := "[distro]\nfamily = synthetic\n[paths]\nthe_log = n/a\n"
	if err := os.WriteFile(confPath, []byte(conf), 0644); err != nil {
		t.Fatalf("write conf: %v", err)
	}
	loader, err := distroconf.LoadFromFile(confPath)
	if err != nil {
		t.Fatalf("load distroconf: %v", err)
	}

	s := NewFileSource(FileSourceOptions{
		Name:      "test",
		DistroKey: "the_log",
		Loader:    loader,
		Fallback:  []string{"/some/fallback"}, // must NOT be tried
	})
	d := s.Descriptor()
	if d.State != StateDisabled {
		t.Errorf("State: got %v, want StateDisabled", d.State)
	}
}

func TestFileSource_FreshnessDegradesToStale(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "old.log")
	if err := os.WriteFile(logPath, []byte("x\n"), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}
	old := time.Now().Add(-48 * time.Hour)
	if err := os.Chtimes(logPath, old, old); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	s := NewFileSource(FileSourceOptions{
		Name:         "test",
		DistroKey:    "key",
		Fallback:     []string{logPath},
		FreshnessMax: 24 * time.Hour,
	})
	if s.Descriptor().State != StateStale {
		t.Errorf("State: got %v, want StateStale", s.Descriptor().State)
	}
}

func TestFileSource_RefreshDetectsDeletion(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "ephemeral.log")
	if err := os.WriteFile(logPath, []byte("x\n"), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}

	s := NewFileSource(FileSourceOptions{
		Name:      "test",
		DistroKey: "key",
		Fallback:  []string{logPath},
	})
	if s.Descriptor().State != StateActive {
		t.Errorf("initial: got %v", s.Descriptor().State)
	}

	if err := os.Remove(logPath); err != nil {
		t.Fatalf("remove: %v", err)
	}
	s.Refresh(24 * time.Hour)
	if s.Descriptor().State != StateMissing {
		t.Errorf("after delete + Refresh: got %v, want StateMissing", s.Descriptor().State)
	}
}
