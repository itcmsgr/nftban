// =============================================================================
// NFTBan v1.235.1 - Portscan Module: Stop() != Disable()
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="portscan_stop_is_not_disable_v1235_1_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-14"
// meta:description="v1.235.1: every graceful nftband stop with PORTSCAN_ENABLED=true ran nftban_portscan_reconcile from Stop() (via disable()), re-applying classic rules over IPC to the daemon whose listener gracefulShutdown had already closed; socat got an empty response and each restart logged 'Classic enable FAILED' (lab4/lab2 upgrades, every systemctl restart nftband). Structural AST arm over the shipped module.go: Stop() has no call that can reach the shell/enforcement plane and (*Module).disable() is gone; negative control over the pre-fix Stop() body. Same contract as internal/ddos/stop_is_not_disable_v1233_1_test.go."
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing,go/ast,go/parser,go/token"
// meta:inventory.files="internal/portscan/module.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package portscan

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

// portscanForbiddenStopCalls walks one function body and reports every call that
// can reach the enforcement plane: the lifecycle helpers, any process spawn, or a
// literal naming a portscan shell entry point.
func portscanForbiddenStopCalls(body *ast.BlockStmt) []string {
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
			case "enable", "disable", "Command", "CommandContext", "Run", "Output", "CombinedOutput":
				hits = append(hits, "call "+name+"()")
			}
		case *ast.BasicLit:
			if x.Kind == token.STRING && strings.Contains(x.Value, "nftban_portscan_") {
				hits = append(hits, "literal "+x.Value)
			}
		}
		return true
	})
	return hits
}

func portscanStopBody(t *testing.T, fset *token.FileSet, f *ast.File) *ast.BlockStmt {
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
func TestPortscanStop_Structural_NoEnforcementPath(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "module.go", nil, 0)
	if err != nil {
		t.Fatalf("parse module.go: %v", err)
	}
	if hits := portscanForbiddenStopCalls(portscanStopBody(t, fset, f)); len(hits) > 0 {
		t.Fatalf("Stop() can reach the enforcement plane: %v", hits)
	}
	for _, d := range f.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok && fd.Recv != nil && fd.Name.Name == "disable" {
			t.Fatalf("(*Module).disable() still exists -- it ran nftban_portscan_reconcile and invites a Stop() caller back")
		}
	}
}

// NEGATIVE CONTROL: the walker must detect the pre-fix Stop() body (v1.235.0),
// otherwise the arm above is vacuous.
func TestPortscanStop_Structural_NegativeControl(t *testing.T) {
	const preFix = `package portscan
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
	if hits := portscanForbiddenStopCalls(portscanStopBody(t, fset, f)); len(hits) == 0 {
		t.Fatal("negative control: the walker did not detect m.disable() in the v1.235.0 Stop() body")
	}
}
