// SPDX-License-Identifier: MPL-2.0
//
// v1.229.2 TRACK B — reload semantics / operator truthfulness.
//
// The defect: reloadConfig refreshes the singleton configuration view and nothing
// else (it references no module, listener, timer or the registry), yet reported
// "Config reloaded successfully" — which reads as "the running daemon now reflects
// the new configuration". A lab4 witness disproved that: after changing
// NFTBAN_API_ADDR and reloading, the listener stayed on 9580 and only a restart
// moved it to 9581.
//
// These arms lock the contract the repository can actually prove. They deliberately
// require NO per-key classification: an evidence pass over all 42 Config fields left
// 18 unresolved and proved some effects materialize lazily after READY, so per-key
// "applied" state cannot be established and must not be asserted.
package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// --- B1: RELOAD_NO_CHANGE -------------------------------------------------

func TestReload_B1_NoChange_MakesNoRuntimeAppliedClaim(t *testing.T) {
	d := reloadResponseData(reloadNoChange, "abc123", time.Unix(0, 0).UTC())

	if got := d["reload_outcome"]; got != "RELOAD_NO_CHANGE" {
		t.Fatalf("reload_outcome = %v, want RELOAD_NO_CHANGE", got)
	}
	// Nothing was reparsed, so nothing exists for a restart to apply.
	v, ok := d["restart_may_be_required"]
	if !ok {
		t.Fatal("restart_may_be_required KEY ABSENT — property unobservable")
	}
	b, ok := v.(bool)
	if !ok {
		t.Fatalf("restart_may_be_required type %T, want bool", v)
	}
	if b {
		t.Error("restart_may_be_required = true on RELOAD_NO_CHANGE: " +
			"nothing changed, so this is a disguised always-on warning")
	}
}

// --- B2: RELOAD_ACCEPTED, the partial-application contract -----------------

func TestReload_B2_Accepted_ReportsSingletonOnlyAndNeverClaimsApplied(t *testing.T) {
	d := reloadResponseData(reloadAccepted, "deadbeefdeadbeef", time.Unix(0, 0).UTC())

	if got := d["reload_outcome"]; got != "RELOAD_ACCEPTED" {
		t.Fatalf("reload_outcome = %v, want RELOAD_ACCEPTED", got)
	}

	// The load-bearing claim: the daemon states it did NOT reconfigure components.
	v, ok := d["runtime_reconfiguration"]
	if !ok {
		t.Fatal("runtime_reconfiguration KEY ABSENT — property unobservable")
	}
	s, ok := v.(string)
	if !ok {
		t.Fatalf("runtime_reconfiguration type %T, want string", v)
	}
	if s != "not_performed" {
		t.Errorf("runtime_reconfiguration = %q, want \"not_performed\" — "+
			"reloadConfig reconfigures no running component", s)
	}

	r, ok := d["restart_may_be_required"].(bool)
	if !ok || !r {
		t.Error("restart_may_be_required must be true on RELOAD_ACCEPTED")
	}

	// "applied" is exactly the property that cannot be established per key.
	if _, exists := d["applied"]; exists {
		t.Error("payload exposes an \"applied\" claim, which the daemon cannot establish")
	}
	if _, exists := d["restart_required"]; exists {
		t.Error("payload exposes authoritative restart_required; only the " +
			"non-authoritative restart_may_be_required is supportable")
	}
}

func TestReload_BackwardCompatibleFieldsPreserved(t *testing.T) {
	ts := time.Unix(1700000000, 0).UTC()
	d := reloadResponseData(reloadAccepted, "hash123", ts)
	for _, k := range []string{"reloaded", "config_hash", "reloaded_at"} {
		if _, ok := d[k]; !ok {
			t.Errorf("pre-existing field %q removed — new metadata must be additive", k)
		}
	}
	if d["config_hash"] != "hash123" {
		t.Errorf("config_hash = %v, want hash123", d["config_hash"])
	}
	if d["reloaded_at"] != ts.Format(time.RFC3339) {
		t.Errorf("reloaded_at = %v, want RFC3339 of input", d["reloaded_at"])
	}
}

// --- B4: RELOAD_FAILED ----------------------------------------------------

func TestReload_B4_FailedOutcomeHasNoSuccessWording(t *testing.T) {
	if got := reloadFailed.String(); got != "RELOAD_FAILED" {
		t.Fatalf("reloadFailed.String() = %q, want RELOAD_FAILED", got)
	}
	// The zero value must be the failing state: an unclassified outcome must never
	// read as success.
	var zero reloadOutcome
	if zero != reloadFailed {
		t.Error("zero value of reloadOutcome is not reloadFailed; an uninitialised " +
			"outcome would report success")
	}
}

func TestReloadOutcome_StringsAreDistinctAndNeverSayApplied(t *testing.T) {
	seen := map[string]bool{}
	for _, o := range []reloadOutcome{reloadFailed, reloadNoChange, reloadAccepted} {
		s := o.String()
		if seen[s] {
			t.Errorf("duplicate outcome string %q", s)
		}
		seen[s] = true
		if strings.Contains(strings.ToUpper(s), "APPLIED") {
			t.Errorf("outcome %q claims APPLIED, which cannot be established", s)
		}
	}
}

// --- Structural guards: these are what INVERSION A and B must fail ---------

// INVERSION A target: restoring unqualified "Config reloaded successfully".
//
// Binds to STRING LITERALS only, via the AST — the wording matters where it reaches
// an operator, not where a comment explains why it was removed. A comment-blind
// regex flagged this file's own historical note, which would have forced deleting
// the explanation to satisfy the guard.
func TestNoUnqualifiedReloadSuccessWordingInDaemon(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatalf("glob failed: %v", err)
	}
	if len(files) == 0 {
		t.Fatal("SUBJECT_NOT_FOUND: no .go files matched — guard would pass vacuously")
	}

	checked, literals := 0, 0
	for _, f := range files {
		if strings.HasSuffix(f, "_test.go") {
			continue
		}
		fset := token.NewFileSet()
		file, err := parser.ParseFile(fset, f, nil, 0) // no ParseComments: comments excluded
		if err != nil {
			t.Fatalf("parse %s: %v", f, err)
		}
		checked++
		ast.Inspect(file, func(n ast.Node) bool {
			lit, ok := n.(*ast.BasicLit)
			if !ok || lit.Kind != token.STRING {
				return true
			}
			literals++
			if unqualifiedReloadSuccess(lit.Value) {
				t.Errorf("%s:%d emits reload success without qualifying that running "+
					"components are not reconfigured: %s",
					f, fset.Position(lit.Pos()).Line, lit.Value)
			}
			return true
		})
	}
	if checked == 0 || literals == 0 {
		t.Fatalf("SUBJECT_NOT_FOUND: checked=%d files, %d string literals — "+
			"guard would pass vacuously", checked, literals)
	}
}

// unqualifiedReloadSuccess is the shared subject of the guard and its falsifiability
// arm, so the two can never drift apart.
func unqualifiedReloadSuccess(s string) bool {
	return regexp.MustCompile(`(?i)config reloaded successfully`).MatchString(s)
}

// Proves the guard is falsifiable rather than matching nothing by construction, and
// that it does not fire on the qualified replacement wording.
func TestUnqualifiedWordingGuardIsFalsifiable(t *testing.T) {
	if !unqualifiedReloadSuccess(`"Config reloaded successfully (hash: %s)"`) {
		t.Fatal("guard does not match the wording it exists to forbid")
	}
	qualified := `"Configuration reloaded (hash: %s). Running components are not ` +
		`automatically reconfigured; some changes may require nftband restart to take effect."`
	if unqualifiedReloadSuccess(qualified) {
		t.Fatal("guard fires on the qualified replacement wording")
	}
}

// INVERSION B target: reporting runtime_reconfiguration as performed/true.
func TestRuntimeReconfigurationIsNeverReportedAsPerformed(t *testing.T) {
	if runtimeReconfigurationState != "not_performed" {
		t.Fatalf("runtimeReconfigurationState = %q; reloadConfig reconfigures no "+
			"running component, so any other value is false",
			runtimeReconfigurationState)
	}
	if configReloadMode != "singleton_only" {
		t.Fatalf("configReloadMode = %q, want singleton_only", configReloadMode)
	}
	for _, o := range []reloadOutcome{reloadFailed, reloadNoChange, reloadAccepted} {
		d := reloadResponseData(o, "h", time.Unix(0, 0).UTC())
		if d["runtime_reconfiguration"] != "not_performed" {
			t.Errorf("outcome %s reports runtime_reconfiguration=%v; the daemon never "+
				"reconfigures running components", o, d["runtime_reconfiguration"])
		}
	}
}

// The scope boundary: reloadConfig must not acquire component-reconfiguration
// machinery. This is the guard that fails if a future change quietly turns reload
// into a hot-reload engine.
func TestReloadConfigDoesNotReconfigureRunningComponents(t *testing.T) {
	src, err := os.ReadFile("daemon_lifecycle.go")
	if err != nil {
		t.Fatalf("read daemon_lifecycle.go: %v", err)
	}
	body := string(src)
	start := strings.Index(body, "func (d *Daemon) reloadConfig()")
	if start < 0 {
		t.Fatal("SUBJECT_NOT_FOUND: reloadConfig not located — guard cannot bind")
	}
	end := strings.Index(body[start:], "\n}\n")
	if end < 0 {
		t.Fatal("SUBJECT_NOT_FOUND: could not delimit reloadConfig body")
	}
	fn := body[start : start+end]

	for _, forbidden := range []string{
		"d.registry", "StopAll", "d.httpSrv", "d.opQueue", "Shutdown(", "startHTTP",
	} {
		if strings.Contains(fn, forbidden) {
			t.Errorf("reloadConfig references %q: it now touches running components, "+
				"which invalidates the singleton_only contract reported to operators",
				forbidden)
		}
	}
}
