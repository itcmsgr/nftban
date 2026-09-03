// =============================================================================
// NFTBan - RenderBoot must DELEGATE, never render or validate on its own
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-renderboot-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Acceptance matrix for the v1.229.13 Lane 3C Go integration. RenderBoot exists ONLY to invoke the shell boot-projection authority; render, validation and fail-closed publication semantics live in cli/lib/nftban/lib/boot_projection.sh and must not be reimplemented, mirrored or second-guessed in Go. A second renderer or a Go-side judgement about whether `nft -c` is usable would recreate the duplicated projection authority the FPA lane exists to remove. Asserts the EXACT argv (so the delegation cannot silently gain flags or an alternate path), that success and failure both propagate, and that a refusal — including the UNKNOWN/rc=2 fail-closed refusal the shell layer emits when validity cannot be established — surfaces as an error rather than a success."
// meta:inventory.files="internal/installer/switchop/renderboot.go"
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// wantKey is the ONLY command RenderBoot may issue.
const wantKey = fhs.NftbanCLI + ":firewall:render-boot:--quiet"

func newRB(t *testing.T) (*executor.MockExecutor, *logging.Logger) {
	t.Helper()
	m := executor.NewMockExecutor()
	// An unregistered command must be a LOUD failure, not a silent success:
	// otherwise a RenderBoot that shelled out to something else entirely would
	// still "pass" here.
	m.StrictUnregistered = true
	return m, logging.New(filepath.Join(t.TempDir(), "rb.log"), false)
}

// TestRenderBootDelegatesWithExactArgv pins the delegation itself.
func TestRenderBootDelegatesWithExactArgv(t *testing.T) {
	m, log := newRB(t)
	m.RunResults[wantKey] = executor.Result{ExitCode: 0}

	if err := RenderBoot(m, log); err != nil {
		t.Fatalf("SUCCESS_RC_PROPAGATES: rc=0 from the shell authority returned an error: %v", err)
	}
	if len(m.Commands) != 1 {
		t.Fatalf("RenderBoot issued %d commands, want exactly 1 — it must do nothing but delegate: %+v",
			len(m.Commands), m.Commands)
	}
	got := m.Commands[0]
	if got.Name != fhs.NftbanCLI {
		t.Errorf("delegated to %q, want %q", got.Name, fhs.NftbanCLI)
	}
	want := []string{"firewall", "render-boot", "--quiet"}
	if strings.Join(got.Args, " ") != strings.Join(want, " ") {
		t.Errorf("EXACT ARGV drifted:\n  got  %v\n  want %v\n"+
			"  a silently added flag or an alternate path is a second authority", got.Args, want)
	}
}

// TestRenderBootPropagatesFailure is the mandatory negative control: the shell
// authority refusing MUST NOT be reported as a published projection.
func TestRenderBootPropagatesFailure(t *testing.T) {
	for _, tc := range []struct {
		name   string
		result executor.Result
	}{
		{"generic render failure", executor.Result{ExitCode: 1, Stderr: "boot projection: render failed"}},
		{"fail-closed refusal (UNKNOWN validity, no existing projection)", executor.Result{
			ExitCode: 1,
			Stderr:   "[NFTBan ERROR] boot projection: validity could NOT be established and there is NO existing projection — REFUSING to publish",
		}},
		{"fail-closed refusal (UNKNOWN validity, candidate differs)", executor.Result{
			ExitCode: 1,
			Stderr:   "[NFTBan ERROR] boot projection: validity could NOT be established and the candidate DIFFERS",
		}},
		{"nonzero with only stdout", executor.Result{ExitCode: 3, Stdout: "refused"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m, log := newRB(t)
			m.RunResults[wantKey] = tc.result
			err := RenderBoot(m, log)
			if err == nil {
				t.Fatalf("FAILURE_RC_PROPAGATES violated: shell exit %d reported as SUCCESS.\n"+
					"  A refusal must never be mistaken for a published boot projection.", tc.result.ExitCode)
			}
			// The diagnostic must carry the authority's own words, not be swallowed.
			detail := tc.result.Stderr
			if detail == "" {
				detail = tc.result.Stdout
			}
			if detail != "" && !strings.Contains(err.Error(), strings.TrimSpace(detail)) {
				t.Errorf("the shell authority's diagnostic was dropped:\n  err:  %v\n  want it to contain: %q",
					err, detail)
			}
		})
	}
}

// stripGoComments removes // line comments and /* */ block comments so a structural
// scan cannot be tripped by documentation.
func stripGoComments(src string) string {
	var b strings.Builder
	inBlock := false
	for _, line := range strings.Split(src, "\n") {
		t := line
		if inBlock {
			if i := strings.Index(t, "*/"); i >= 0 {
				t, inBlock = t[i+2:], false
			} else {
				continue
			}
		}
		for {
			i := strings.Index(t, "/*")
			if i < 0 {
				break
			}
			if j := strings.Index(t[i:], "*/"); j >= 0 {
				t = t[:i] + t[i+j+2:]
				continue
			}
			t, inBlock = t[:i], true
			break
		}
		if i := strings.Index(t, "//"); i >= 0 {
			t = t[:i]
		}
		b.WriteString(t)
		b.WriteString("\n")
	}
	return b.String()
}

// TestRenderBootIsNotARenderer is the structural half: Go must not acquire
// rendering, substitution or validation logic of its own.
func TestRenderBootIsNotARenderer(t *testing.T) {
	src, err := os.ReadFile("renderboot.go")
	if err != nil {
		t.Fatalf("cannot read renderboot.go: %v", err)
	}
	// ⛔ SCAN CODE, NOT PROSE. renderboot.go's doc comment legitimately DESCRIBES
	// what the shell layer does ("validates it with nft -c"); that is documentation,
	// not a Go implementation of validation. An earlier revision of this test matched
	// the comment and failed the file for explaining itself — the same mention-vs-code
	// confusion these guards exist to prevent. Strip comments first, then scan.
	body := stripGoComments(string(src))

	// GO_RENDERS_NFTABLES_ITSELF=NO
	for _, forbidden := range []string{
		"__SSH_PORT__", "__CT_LIMIT_", "nftables.conf.tpl", "generated/nftban-boot.nft",
	} {
		if strings.Contains(body, forbidden) {
			t.Errorf("renderboot.go references %q — the schema, its placeholders and the output path "+
				"belong to the shell authority. Naming them here creates a second projection authority.", forbidden)
		}
	}

	// Go must not decide whether nft -c is usable. That judgement is the shell
	// validator's, and duplicating it would create a second truth authority for
	// "is this projection valid".
	for _, forbidden := range []string{"nft -c", "unshare", "netlink", "Operation not permitted"} {
		if strings.Contains(body, forbidden) {
			t.Errorf("renderboot.go mentions %q — Go must NOT independently judge validation "+
				"capability; boot_projection.sh owns validation semantics.", forbidden)
		}
	}

	// Exactly one delegation call, and it is exec.Run.
	if n := strings.Count(body, "exec.Run("); n != 1 {
		t.Errorf("renderboot.go makes %d exec.Run calls, want exactly 1", n)
	}
	if regexp.MustCompile(`os\.(WriteFile|Create|OpenFile|Rename)`).MatchString(body) {
		t.Error("renderboot.go writes files directly — publication belongs to the shell authority")
	}
}
