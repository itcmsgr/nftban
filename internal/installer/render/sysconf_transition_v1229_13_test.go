// =============================================================================
// NFTBan - Lane 3D.4: authoritative include transition
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-render-sysconf-transition-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.229.13 Lane 3D.4. Proves the boot authority transition: exactly one ACTIVE include after integration, the legacy include removed on upgrade, idempotent re-apply, and — critically — that a FAILED render-boot leaves an existing legacy include INTACT rather than trading it for a projection that was never established."
// meta:inventory.files="internal/installer/render/sysconf.go,cmd/nftban-installer/phases.go"
// meta:inventory.privileges="none"
// =============================================================================
package render

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

const (
	legacyIncludeLine    = `include "/etc/nftban/nftables.conf"`
	generatedIncludeLine = `include "/etc/nftban/generated/nftban-boot.nft"`
)

func countLine(content, want string) int {
	n := 0
	for _, l := range strings.Split(content, "\n") {
		if strings.TrimSpace(l) == want {
			n++
		}
	}
	return n
}

func seedDistro(t *testing.T, body string) (*executor.MockExecutor, string) {
	t.Helper()
	m := executor.NewMockExecutor()
	p := "/etc/sysconfig/nftables.conf"
	m.Files[p] = []byte(body)
	m.Dirs["/etc/sysconfig"] = true
	return m, p
}

// TestTransition_Matrix covers the required 3D.4 behaviour matrix.
func TestTransition_Matrix(t *testing.T) {
	base := "flush ruleset\ntable inet filter {\n}\n"
	for _, tc := range []struct {
		name  string
		body  string
		ready bool
	}{
		{"neither include present -> generated added once", base, true},
		{"existing LEGACY include -> replaced by exactly one generated", base + legacyIncludeLine + "\n", true},
		{"existing GENERATED include -> idempotent", base + generatedIncludeLine + "\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m, p := seedDistro(t, tc.body)
			if err := IntegrateSystemConf(m, p, IncludeDependencyBootProjection, tc.ready, newTestLogger()); err != nil {
				t.Fatalf("integration failed: %v", err)
			}
			out := string(m.WrittenFiles[p])
			if got := countLine(out, generatedIncludeLine); got != 1 {
				t.Errorf("ACTIVE_GENERATED_INCLUDE_COUNT=%d, want 1\n%s", got, out)
			}
			if got := countLine(out, legacyIncludeLine); got != 0 {
				t.Errorf("ACTIVE_LEGACY_INCLUDE_COUNT=%d, want 0 — an upgraded host must not "+
					"carry two boot authorities\n%s", got, out)
			}
		})
	}
}

// TestTransition_ReapplyIsIdempotent runs integration twice and requires a stable result.
func TestTransition_ReapplyIsIdempotent(t *testing.T) {
	m, p := seedDistro(t, "flush ruleset\n"+legacyIncludeLine+"\n")
	if err := IntegrateSystemConf(m, p, IncludeDependencyBootProjection, true, newTestLogger()); err != nil {
		t.Fatalf("first integration: %v", err)
	}
	first := string(m.WrittenFiles[p])

	m2, p2 := seedDistro(t, first)
	if err := IntegrateSystemConf(m2, p2, IncludeDependencyBootProjection, true, newTestLogger()); err != nil {
		t.Fatalf("second integration: %v", err)
	}
	second, rewrote := m2.WrittenFiles[p2]
	if rewrote && string(second) != first {
		t.Errorf("re-apply was not idempotent:\n--- first ---\n%s\n--- second ---\n%s", first, string(second))
	}
	if countLine(first, generatedIncludeLine) != 1 {
		t.Errorf("expected exactly one generated include after re-apply")
	}
}

// TestTransition_FailedRenderPreservesLegacyInclude is the critical failure arm.
//
// ⛔ A FAILED ATTEMPT TO MOVE BOOT AUTHORITY MUST NOT LEAVE THE HOST WITH NO VALID
// BOOT INCLUDE. If render-boot failed, the projection was never established, so the
// legacy include must be left exactly as found — not removed in favour of an artifact
// that does not exist.
func TestTransition_FailedRenderPreservesLegacyInclude(t *testing.T) {
	body := "flush ruleset\n" + legacyIncludeLine + "\n"
	m, p := seedDistro(t, body)

	err := IntegrateSystemConf(m, p, IncludeDependencyBootProjection, false, newTestLogger())
	if err == nil {
		t.Fatal("integration proceeded with ready=false — the transition must REFUSE")
	}
	if len(m.WrittenFiles) != 0 {
		t.Fatalf("refusal mutated the system conf (%d file(s)) — the legacy include must be "+
			"left intact when the projection was never established", len(m.WrittenFiles))
	}
	// The on-disk content is unchanged: still exactly the legacy include, no generated one.
	cur := string(m.Files[p])
	if countLine(cur, legacyIncludeLine) != 1 {
		t.Errorf("legacy include was disturbed: %q", cur)
	}
	if countLine(cur, generatedIncludeLine) != 0 {
		t.Errorf("a generated include was added despite ready=false: %q", cur)
	}
}
