// =============================================================================
// NFTBan - Lane 3D.3: boot-projection readiness interlock
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-render-sysconf-bootready-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.229.13 Lane 3D.3. The interlock is INSTALLED here and ARMED in 3D.4. Proves: the legacy shipping path is unaffected by boot-projection readiness (no behaviour change before the authority moves); a BOOT_PROJECTION dependency is REFUSED without readiness; refusal happens BEFORE any mutation; and a stale projection file on disk cannot substitute for readiness established in this run."
// meta:inventory.files="internal/installer/render/sysconf.go,cmd/nftban-installer/phases.go"
// meta:inventory.privileges="none"
// =============================================================================
package render

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

const bootProjPath = "/etc/nftban/generated/nftban-boot.nft"

// distroConf seeds a mock with a realistic distro nftables.conf.
func distroConf(t *testing.T) (*executor.MockExecutor, string) {
	t.Helper()
	m := executor.NewMockExecutor()
	p := "/etc/sysconfig/nftables.conf"
	m.Files[p] = []byte("flush ruleset\ntable inet filter {\n}\n")
	m.Dirs["/etc/sysconfig"] = true
	return m, p
}

// TestBootReady_Matrix is the full 3D.3 behaviour matrix.
func TestBootReady_Matrix(t *testing.T) {
	for _, tc := range []struct {
		name       string
		dep        IncludeDependency
		ready      bool
		wantRefuse bool
		why        string
	}{
		{"LEGACY + render success -> integrate", IncludeDependencyLegacy, true, false,
			"legacy include never depended on the projection"},
		{"LEGACY + render FAILURE -> integrate exactly as before", IncludeDependencyLegacy, false, false,
			"⛔ COMPATIBILITY ARM: suppressing this would regress a currently-valid shipping path " +
				"before the include authority moves in 3D.4"},
		{"BOOT_PROJECTION + render success -> integrate", IncludeDependencyBootProjection, true, false,
			"projection established in this run"},
		{"BOOT_PROJECTION + render FAILURE -> REFUSE", IncludeDependencyBootProjection, false, true,
			"boot config must never depend on an unestablished projection"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m, p := distroConf(t)
			log := newTestLogger()

			err := IntegrateSystemConf(m, p, tc.dep, tc.ready, log)

			if tc.wantRefuse {
				if err == nil {
					t.Fatalf("expected REFUSAL, got nil — %s", tc.why)
				}
				if !strings.Contains(err.Error(), "bootProjectionReady=false") {
					t.Errorf("refusal must name the unmet condition; got: %v", err)
				}
				// ⛔ PRE-MUTATION: a post-hoc check is not a gate.
				if len(m.WrittenFiles) != 0 {
					t.Errorf("refusal mutated %d file(s) — the gate must refuse BEFORE any write: %v",
						len(m.WrittenFiles), keysOf(m.WrittenFiles))
				}
				return
			}
			if err != nil {
				t.Fatalf("expected integration to proceed, got %v — %s", err, tc.why)
			}
			out, ok := m.WrittenFiles[p]
			if !ok {
				t.Fatalf("integration wrote nothing to %s — %s", p, tc.why)
			}
			if !strings.Contains(string(out), IncludeDirective) {
				t.Errorf("include directive absent from the integrated file")
			}
		})
	}
}

// TestBootReady_StaleFileCannotBypassGate is the NC2 discriminator: if readiness
// were ever re-derived from FileExists/os.Stat instead of the render result, this
// arm would pass integration on a stale artifact. EXISTS != ESTABLISHED_THIS_RUN.
func TestBootReady_StaleFileCannotBypassGate(t *testing.T) {
	m, p := distroConf(t)
	// A projection from a PREVIOUS run is present on disk...
	m.Files[bootProjPath] = []byte("table ip nftban {\n}\n")
	log := newTestLogger()

	// ...but this run's render FAILED, so readiness is false.
	err := IntegrateSystemConf(m, p, IncludeDependencyBootProjection, false, log)
	if err == nil {
		t.Fatal("a STALE projection file satisfied the gate — readiness was derived from " +
			"file existence, not from the render result established in this run")
	}
	if len(m.WrittenFiles) != 0 {
		t.Errorf("stale-file arm mutated %d file(s)", len(m.WrittenFiles))
	}
}

// TestBootReady_ShippingDependencyIsLegacy is the NC3 discriminator: it fails if
// production is switched to the BOOT_PROJECTION dependency before 3D.4 does so
// deliberately, together with the include directive.
func TestBootReady_ShippingDependencyIsLegacy(t *testing.T) {
	src := readRepoFile(t, "cmd/nftban-installer/phases.go")
	if !strings.Contains(src, "render.IncludeDependencyLegacy") {
		t.Error("phases.go no longer ships IncludeDependencyLegacy — 3D.4 must change the " +
			"include directive and the dependency TOGETHER, atomically")
	}
	if strings.Contains(src, "render.IncludeDependencyBootProjection") {
		t.Error("phases.go selects IncludeDependencyBootProjection — that is 3D.4, and it must " +
			"land with the IncludeDirective change, not before it")
	}
	// INCLUDE_TARGET_UNCHANGED: 3D.4 owns moving it.
	sys := readRepoFile(t, "internal/installer/render/sysconf.go")
	if !strings.Contains(sys, `const IncludeDirective = `+"`"+`include "/etc/nftban/nftables.conf"`+"`") {
		t.Error("IncludeDirective changed — 3D.3 must not move the include target")
	}
}

func keysOf(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

func readRepoFile(t *testing.T, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("..", "..", "..", rel))
	if err != nil {
		t.Fatalf("read %s: %v", rel, err)
	}
	return string(b)
}
