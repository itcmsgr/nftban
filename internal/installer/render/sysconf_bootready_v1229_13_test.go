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

// TestIncludeAuthorityTransitionIsAtomic is the 3D.4 atomicity guard and the NC1/NC2
// discriminator. The include TARGET and the shipping DEPENDENCY must move together;
// a tree carrying only one half is invalid:
//
//	NC1  generated target + LEGACY dependency      -> unguarded boot dependency
//	NC2  BOOT_PROJECTION dependency + legacy target -> gate armed against the wrong subject
func TestIncludeAuthorityTransitionIsAtomic(t *testing.T) {
	const generated = `include "/etc/nftban/generated/nftban-boot.nft"`

	targetIsGenerated := IncludeDirective == generated
	sysSrc := readRepoFile(t, "cmd/nftban-installer/phases.go")
	depIsBootProjection := strings.Contains(sysSrc, "render.IncludeDependencyBootProjection")
	depIsLegacy := strings.Contains(sysSrc, "render.IncludeDependencyLegacy")

	if targetIsGenerated != depIsBootProjection {
		t.Errorf("NON-ATOMIC AUTHORITY TRANSITION: include target generated=%v but shipping "+
			"dependency BOOT_PROJECTION=%v. Both must change together — one half alone either "+
			"leaves a generated include unguarded (NC1) or arms the gate against the legacy "+
			"target it does not protect (NC2).", targetIsGenerated, depIsBootProjection)
	}
	if depIsBootProjection && depIsLegacy {
		t.Error("phases.go selects BOTH dependencies — the shipping selection must be unambiguous")
	}
	// The legacy literal must survive ONLY as a migration matcher, never as authority.
	if strings.Contains(IncludeDirective, "/etc/nftban/nftables.conf") {
		t.Error("IncludeDirective still names the legacy artifact — it is no longer boot authority")
	}
	if legacyIncludePath != `"/etc/nftban/nftables.conf"` {
		t.Error("the legacy migration matcher was removed — an upgraded host could then keep " +
			"BOTH includes, which is two boot authorities (NC3)")
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
