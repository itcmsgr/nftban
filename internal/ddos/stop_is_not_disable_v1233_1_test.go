// =============================================================================
// NFTBan v1.233.1 - DDoS Module: Stop() != Disable()
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="stop_is_not_disable_v1233_1_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-24"
// meta:description="v1.233.1 BUG-DDOS-DAEMON-SHUTDOWN-RECONCILE-FAILURE-LEAVES-PROTECTION-CHAINS-FLUSHED. A daemon Stop() must stop userspace only: it must never reach the shell reconcile root (which re-applies DDoS and, with the IPC listener already closed, left ddos_prefix/ddos_protection flushed for the whole downtime). Behavioural arm via the runReconcile seam with a positive control that enable() does reach it, plus a structural AST arm with a negative control over the pre-fix Stop() body."
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing,go/ast,go/parser,go/token"
// meta:inventory.files="internal/ddos/module.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ddos

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
)

// stubReconcile replaces the reconcile seam for one test and returns a pointer
// to the number of times it was reached.
func stubReconcile(t *testing.T) *int {
	t.Helper()
	calls := 0
	orig := runReconcile
	runReconcile = func() error {
		calls++
		return nil
	}
	t.Cleanup(func() { runReconcile = orig })
	return &calls
}

func newStoppableModule(t *testing.T, enabled bool) (*Module, *bool) {
	t.Helper()
	bus := eventbus.New()
	t.Cleanup(bus.Close)
	cancelled := false
	m := &Module{
		bus:    bus,
		status: module.NewStatus(ModuleName),
		config: ddosConfig{Enabled: enabled},
		cancel: func() { cancelled = true },
	}
	m.status.MarkRunning()
	return m, &cancelled
}

// POSITIVE CONTROL: the seam IS the real reconcile path. Without this, a stub
// that is never on any path would make the Stop() assertion vacuous.
func TestEnable_ReachesReconcileSeam(t *testing.T) {
	calls := stubReconcile(t)
	m, _ := newStoppableModule(t, true)
	if err := m.enable(); err != nil {
		t.Fatalf("enable() returned %v with a nil-returning stub", err)
	}
	if *calls != 1 {
		t.Fatalf("enable() reached the reconcile seam %d times, want 1 -- the seam is not the real path, so the Stop() arm below would prove nothing", *calls)
	}
}

// STOP-PRESERVES-PROTECTION (daemon side): an enabled module's Stop() stops
// userspace and never reaches the reconcile root.
func TestStop_Enabled_DoesNotReachReconcile(t *testing.T) {
	calls := stubReconcile(t)
	m, cancelled := newStoppableModule(t, true)
	if err := m.Stop(); err != nil {
		t.Fatalf("Stop() returned %v", err)
	}
	if *calls != 0 {
		t.Fatalf("Stop() reached nftban_ddos_reconcile %d time(s) -- a service stop must not re-apply or tear down DDoS (Stop() != Disable())", *calls)
	}
	if !*cancelled {
		t.Error("Stop() did not cancel the module context -- userspace was not stopped")
	}
	if m.Status().Running {
		t.Error("Stop() left the module status Running")
	}
}

// A disabled module (Start() never ran the reconcile) must not reach it on
// Stop() either.
func TestStop_Disabled_DoesNotReachReconcile(t *testing.T) {
	calls := stubReconcile(t)
	m, _ := newStoppableModule(t, false)
	if err := m.Stop(); err != nil {
		t.Fatalf("Stop() returned %v", err)
	}
	if *calls != 0 {
		t.Fatalf("Stop() on a disabled module reached nftban_ddos_reconcile %d time(s)", *calls)
	}
}

// forbiddenStopCalls walks one function body and reports every call that can
// reach the enforcement plane: the lifecycle helpers, the reconcile seam, any
// process spawn, or a literal naming a DDoS shell entry point.
func forbiddenStopCalls(body *ast.BlockStmt) []string {
	var hits []string
	ast.Inspect(body, func(n ast.Node) bool {
		switch x := n.(type) {
		case *ast.CallExpr:
			var name string
			switch fn := x.Fun.(type) {
			case *ast.SelectorExpr:
				name = fn.Sel.Name
			case *ast.Ident:
				name = fn.Name
			}
			switch name {
			case "enable", "disable", "runReconcile", "Command", "CommandContext", "Run", "Output", "CombinedOutput":
				hits = append(hits, "call "+name+"()")
			}
		case *ast.BasicLit:
			if x.Kind == token.STRING && strings.Contains(x.Value, "nftban_ddos_") {
				hits = append(hits, "literal "+x.Value)
			}
		}
		return true
	})
	return hits
}

func stopBody(t *testing.T, fset *token.FileSet, f *ast.File) *ast.BlockStmt {
	t.Helper()
	for _, d := range f.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Recv == nil || fd.Name.Name != "Stop" || len(fd.Recv.List) != 1 {
			continue
		}
		if star, ok := fd.Recv.List[0].Type.(*ast.StarExpr); ok {
			if id, ok := star.X.(*ast.Ident); ok && id.Name == "Module" {
				return fd.Body
			}
		}
	}
	t.Fatalf("SUBJECT_NOT_FOUND: func (m *Module) Stop() in %s", fset.File(f.Pos()).Name())
	return nil
}

// Structural arm over the SHIPPED source: Stop() contains no path to the
// enforcement plane, and the reconcile-running disable() helper is gone.
func TestStop_Structural_NoEnforcementPath(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "module.go", nil, 0)
	if err != nil {
		t.Fatalf("parse module.go: %v", err)
	}
	if hits := forbiddenStopCalls(stopBody(t, fset, f)); len(hits) > 0 {
		t.Fatalf("Stop() can reach the enforcement plane: %v", hits)
	}
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv != nil && fd.Name.Name == "disable" {
			t.Fatalf("(*Module).disable() still exists -- it ran nftban_ddos_reconcile and invites a Stop() caller back")
		}
	}
}

// NEGATIVE CONTROL: the structural walker must detect the pre-fix Stop() body
// (v1.233.0), otherwise the arm above is vacuous.
func TestStop_Structural_NegativeControl(t *testing.T) {
	const preFix = `package ddos
func (m *Module) Stop() error {
	if !m.config.Enabled {
		return nil
	}
	if m.cancel != nil {
		m.cancel()
	}
	m.disable()
	return nil
}
`
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "prefix_stop.go", preFix, 0)
	if err != nil {
		t.Fatalf("parse negative-control source: %v", err)
	}
	hits := forbiddenStopCalls(stopBody(t, fset, f))
	if len(hits) == 0 {
		t.Fatal("negative control: the walker did not detect m.disable() in the v1.233.0 Stop() body")
	}
}
