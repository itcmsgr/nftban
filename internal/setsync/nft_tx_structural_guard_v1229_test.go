// SPDX-License-Identifier: MPL-2.0
//
// v1.229.0 — INV-NFT-TX-01 structural (AST) guard.
//
// TestMutatingMethodsOwnPrivateTransactionConn parses the PRODUCTION source of
// this package and enforces the transaction-ownership contract by structure:
//
//	For every production mutating path:
//	  connection ownership begins inside that method (via txConn())
//	  queue and Flush occur on that private connection
//	  no shared connection is reachable
//
// Why this exists in addition to TestINVNFTTX01_ManagerHoldsNoSharedConn: the
// behavioural guard proves txConn() hands out distinct connections, but a
// future change could reintroduce sharing WITHOUT touching txConn — a
// differently named manager field, or a package-level Conn used directly by
// one method. Inversion testing showed the behavioural guard alone does not
// cover that class. This guard fails on:
//
//	G1  any field of NFTManager (or any struct in the package) whose type
//	    reaches *nftables.Conn — a persistent connection holder
//	G2  any package-level variable whose declared or inferred type is a
//	    *nftables.Conn
//	G3  any function containing a <recv>.Flush() call where <recv> is not
//	    (a) a local variable acquired from txConn() in that same function, or
//	    (b) a parameter of that function (ownership passed explicitly by a
//	        caller that itself satisfies this guard)
//	G4  any Flush-containing function that acquires a connection by calling
//	    nftables.New directly instead of txConn() — bypassing the single
//	    acquisition authority (and its test-injection point)
//
// The func-typed factory field (newConn func() (*nftables.Conn, error)) is
// exempt from G1: a factory produces connections, it does not hold one.
package setsync

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"strings"
	"testing"
)

// typeReachesConn reports whether a field/var type expression contains
// nftables.Conn anywhere EXCEPT behind a func type (factories are allowed).
func typeReachesConn(e ast.Expr) bool {
	switch t := e.(type) {
	case *ast.StarExpr:
		return typeReachesConn(t.X)
	case *ast.SelectorExpr:
		if id, ok := t.X.(*ast.Ident); ok {
			return id.Name == "nftables" && t.Sel.Name == "Conn"
		}
	case *ast.FuncType:
		// A factory type returning a Conn is the sanctioned pattern.
		return false
	case *ast.ArrayType:
		return typeReachesConn(t.Elt)
	case *ast.MapType:
		return typeReachesConn(t.Key) || typeReachesConn(t.Value)
	case *ast.ChanType:
		return typeReachesConn(t.Value)
	}
	return false
}

func TestMutatingMethodsOwnPrivateTransactionConn(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi fs.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatalf("parse package: %v", err)
	}

	var violations []string
	violate := func(pos token.Pos, rule, msg string) {
		violations = append(violations, fmt.Sprintf("%s: [%s] %s", fset.Position(pos), rule, msg))
	}

	for _, pkg := range pkgs {
		for _, file := range pkg.Files {
			// ---- G1: no struct field may hold a Conn ------------------------
			ast.Inspect(file, func(n ast.Node) bool {
				st, ok := n.(*ast.StructType)
				if !ok {
					return true
				}
				for _, f := range st.Fields.List {
					if typeReachesConn(f.Type) {
						name := "<embedded>"
						if len(f.Names) > 0 {
							name = f.Names[0].Name
						}
						violate(f.Pos(), "G1",
							fmt.Sprintf("struct field %q holds a *nftables.Conn — a persistent connection reintroduces the shared transaction buffer (INV-NFT-TX-01)", name))
					}
				}
				return true
			})

			// ---- G2: no package-level Conn variable -------------------------
			for _, decl := range file.Decls {
				gd, ok := decl.(*ast.GenDecl)
				if !ok || gd.Tok != token.VAR {
					continue
				}
				for _, spec := range gd.Specs {
					vs, ok := spec.(*ast.ValueSpec)
					if !ok {
						continue
					}
					if vs.Type != nil && typeReachesConn(vs.Type) {
						violate(vs.Pos(), "G2",
							fmt.Sprintf("package-level variable %v holds a *nftables.Conn — a global connection is a shared transaction buffer", vs.Names))
					}
					// Inferred type: var x = nftables.New(...) has no Type field.
					for _, v := range vs.Values {
						if call, ok := v.(*ast.CallExpr); ok {
							if sel, ok := call.Fun.(*ast.SelectorExpr); ok {
								if id, ok := sel.X.(*ast.Ident); ok && id.Name == "nftables" && sel.Sel.Name == "New" {
									violate(vs.Pos(), "G2",
										fmt.Sprintf("package-level variable %v initialised from nftables.New — a global connection is a shared transaction buffer", vs.Names))
								}
							}
						}
					}
				}
			}

			// ---- G3/G4: every Flush must run on a locally-owned conn --------
			for _, decl := range file.Decls {
				fn, ok := decl.(*ast.FuncDecl)
				if !ok || fn.Body == nil {
					continue
				}
				// txConn is the acquisition authority itself; its internal
				// nftables.New is the one sanctioned construction site.
				if fn.Name.Name == "txConn" {
					continue
				}

				params := map[string]bool{}
				if fn.Type.Params != nil {
					for _, p := range fn.Type.Params.List {
						for _, n := range p.Names {
							params[n.Name] = true
						}
					}
				}

				owned := map[string]bool{} // locals assigned from txConn()
				var flushes []*ast.SelectorExpr
				directNew := false

				ast.Inspect(fn.Body, func(n ast.Node) bool {
					switch node := n.(type) {
					case *ast.AssignStmt:
						for _, rhs := range node.Rhs {
							call, ok := rhs.(*ast.CallExpr)
							if !ok {
								continue
							}
							sel, ok := call.Fun.(*ast.SelectorExpr)
							if !ok {
								continue
							}
							if sel.Sel.Name == "txConn" {
								if len(node.Lhs) > 0 {
									if id, ok := node.Lhs[0].(*ast.Ident); ok {
										owned[id.Name] = true
									}
								}
							}
							if id, ok := sel.X.(*ast.Ident); ok && id.Name == "nftables" && sel.Sel.Name == "New" {
								directNew = true
							}
						}
					case *ast.CallExpr:
						if sel, ok := node.Fun.(*ast.SelectorExpr); ok && sel.Sel.Name == "Flush" {
							flushes = append(flushes, sel)
						}
					}
					return true
				})

				if len(flushes) == 0 {
					continue
				}
				if directNew {
					violate(fn.Pos(), "G4",
						fmt.Sprintf("%s acquires a connection via nftables.New directly; mutating paths must go through txConn() — the single acquisition authority and test-injection point", fn.Name.Name))
				}
				for _, sel := range flushes {
					id, ok := sel.X.(*ast.Ident)
					if !ok {
						violate(sel.Pos(), "G3",
							fmt.Sprintf("%s calls Flush on a non-local expression — the connection is not owned by this transaction", fn.Name.Name))
						continue
					}
					if !owned[id.Name] && !params[id.Name] {
						violate(sel.Pos(), "G3",
							fmt.Sprintf("%s calls %s.Flush() but %q was neither acquired from txConn() in this function nor received as a parameter — connection ownership does not begin in this method", fn.Name.Name, id.Name, id.Name))
					}
				}
			}
		}
	}

	if len(violations) > 0 {
		t.Fatalf("INV-NFT-TX-01 structural violations:\n  %s", strings.Join(violations, "\n  "))
	}
}
