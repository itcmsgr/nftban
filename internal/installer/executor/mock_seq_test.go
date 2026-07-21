// SPDX-License-Identifier: MPL-2.0
// meta:name="mock_seq_test.go"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: MockExecutor TEST-ONLY sequential-response (RunResultSeq) contract — ordered per-key responses, static RunResults behavior preserved for keys without a sequence, sequence precedence over static for the same key, and FAIL-LOUD on exhaustion (sentinel exit 255 + recorded command) rather than a silent fall-back."
// meta:inventory.files="internal/installer/executor/mock_seq_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package executor

import (
	"strings"
	"testing"
)

func TestRunResultSeq_OrderedResponses(t *testing.T) {
	m := NewMockExecutor()
	m.RunResultSeq["systemctl:show:x"] = []Result{
		{Stdout: "first"},
		{Stdout: "second"},
	}
	if r := m.Run("systemctl", "show", "x"); r.Stdout != "first" {
		t.Fatalf("call 1: got %q want first", r.Stdout)
	}
	if r := m.Run("systemctl", "show", "x"); r.Stdout != "second" {
		t.Fatalf("call 2: got %q want second", r.Stdout)
	}
}

func TestRunResultSeq_ExhaustionFailsLoud(t *testing.T) {
	m := NewMockExecutor()
	m.RunResultSeq["a:b"] = []Result{{Stdout: "only"}}
	_ = m.Run("a", "b")  // consume the one element
	r := m.Run("a", "b") // exhausted
	if r.ExitCode != 255 {
		t.Fatalf("exhausted call must fail loud (exit 255); got exit=%d", r.ExitCode)
	}
	if !strings.Contains(r.Stderr, "RunResultSeq exhausted") {
		t.Errorf("exhausted call must carry the loud marker; stderr=%q", r.Stderr)
	}
	// The extra call is still RECORDED so the test can detect it.
	if m.CommandCallCount("a", "b") != 2 {
		t.Errorf("exhausted call must be recorded; call count=%d want 2", m.CommandCallCount("a", "b"))
	}
}

func TestRunResultSeq_StaticBehaviorPreservedForOtherKeys(t *testing.T) {
	m := NewMockExecutor()
	m.RunResultSeq["seq:key"] = []Result{{Stdout: "seq"}}
	m.RunResults["static:key"] = Result{Stdout: "static"}

	// A key WITHOUT a sequence keeps the exact static behavior.
	if r := m.Run("static", "key"); r.Stdout != "static" {
		t.Errorf("static key: got %q want static (static RunResults must be untouched)", r.Stdout)
	}
	// A completely unmapped key still returns exit 0 empty.
	if r := m.Run("no", "mapping"); r.ExitCode != 0 || r.Stdout != "" {
		t.Errorf("unmapped key: got exit=%d out=%q want 0/empty", r.ExitCode, r.Stdout)
	}
}

func TestRunResultSeq_PrecedenceOverStaticForSameKey(t *testing.T) {
	m := NewMockExecutor()
	m.RunResults["k:1"] = Result{Stdout: "static"}
	m.RunResultSeq["k:1"] = []Result{{Stdout: "seq0"}}
	// Sequence wins while it has elements.
	if r := m.Run("k", "1"); r.Stdout != "seq0" {
		t.Fatalf("sequence must take precedence over static for the same key; got %q", r.Stdout)
	}
	// Once exhausted it fails LOUD — it does NOT silently fall back to the static.
	if r := m.Run("k", "1"); r.ExitCode != 255 {
		t.Errorf("exhausted sequence must NOT silently fall back to static; got exit=%d out=%q", r.ExitCode, r.Stdout)
	}
}
