// =============================================================================
// NFTBan v1.230.0 Gate 6R F2 — hermetic log-retention fixture
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-hermetic-logretention-fixture"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="Materialises the SHIPPED log-retention policy entirely under t.TempDir() so logretention_policy_ready performs a REAL logrotate validation on a bare runner that has no /var/log/nftban. The policy body is derived from install/config/nftban.logrotate — the canonical packaged source — with exactly two ENVIRONMENT bindings relocated (log root and create-ownership) and zero policy semantics changed."
// meta:inventory.files="cmd/nftban-installer/hermetic_logretention_fixture_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_LR_MAIN,NFTBAN_LR_TEMPLATE,NFTBAN_LR_STATE,NFTBAN_LR_SURICATA"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"testing"
)

// ═════════════════════════════════════════════════════════════════════════════════
// WHY THIS EXISTS
// ═════════════════════════════════════════════════════════════════════════════════
// F2's acceptance requires the recovered host to reach INSTALL_STATE=COMMITTED, which
// means EVERY post-install assertion must pass — including logretention_policy_ready,
// which is unrelated to the recovery under test. On lab2/lab4 it passed for the wrong
// reason: nftban is installed there, so the shipped policy's real target
// /var/log/nftban/bans.log exists. On a bare CI runner it does not, `logrotate -d`
// exits 1 with "stat of /var/log/nftban/bans.log failed", and the run ends DEGRADED.
//
//	A TEST THAT PASSES BECAUSE THE HOST HAPPENS TO BE PROVISIONED IS NOT HERMETIC.
//
// ⛔ THE BAR STAYS AT COMMITTED. Narrowing F2 to a hand-picked set of sub-verdicts would
// let a future unrelated-but-legitimate blocker keep a host out of COMMITTED while F2
// stayed green — recreating the very problem the executable recovery test exists to
// prevent. So the ENVIRONMENT is made hermetic instead of the assertion made weaker.
//
// ⛔ NOTHING IS WRITTEN OUTSIDE t.TempDir(). Creating /var/log/nftban/bans.log on the
// runner would make the suite order-dependent and would HIDE exactly the portability
// defect this failure exposed.
//
// ⛔ AND THE ASSERTION IS NOT BYPASSED. The real logrotate(1) validator runs — the
// injected stub is deliberately NOT used here — so the fixture must be a policy that
// genuinely validates. The NC2 negative control proves this: corrupting the fixture
// policy must still fail the assertion.

// canonicalLogrotatePolicy is the packaged source of truth for the shipped baseline
// policy — the same file install/ deploys to /etc/logrotate.d/nftban and
// /etc/nftban/templates/nftban.logrotate.
//
// ⛔ DERIVED, NOT SYNTHESISED. A hand-written "test-friendly" policy would prove nothing
// about what ships: it would have different stanza counts, different boundedness and
// different directives, and logretention_policy_ready checks precisely those.
const canonicalLogrotatePolicy = "install/config/nftban.logrotate"

// hermeticLogDirToken is the absolute log root the shipped policy names. Relocating it
// is one of the two ENVIRONMENT bindings this fixture rewrites.
const hermeticLogDirToken = "/var/log/nftban"

// repoRoot walks up from the test's working directory to the module root.
func repoRoot(t *testing.T) string {
	t.Helper()
	d, err := os.Getwd()
	if err != nil {
		t.Fatalf("TEST_INVALID: cannot resolve working directory: %v", err)
	}
	for i := 0; i < 12; i++ {
		if _, err := os.Stat(filepath.Join(d, "go.mod")); err == nil {
			return d
		}
		parent := filepath.Dir(d)
		if parent == d {
			break
		}
		d = parent
	}
	t.Fatalf("TEST_INVALID: could not locate the module root above %s", d)
	return ""
}

// currentOwner returns the user/group names the test process runs as, so the shipped
// policy's `create` ownership can be rebound to an identity that EXISTS on this runner.
//
// ⛔ THIS IS AN ENVIRONMENT BINDING, NOT A POLICY CHANGE. `create 0640 nftban nftban`
// fails config parse with "unknown user 'nftban'" on any host where nftban is not
// installed (measured: logrotate -d exits 1). Creating that user would be a global
// mutation, which is forbidden. Mode, cadence, rotate counts, size triggers, compress /
// delaycompress / copytruncate and olddir are all preserved verbatim.
func currentOwner(t *testing.T) (string, string) {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatalf("TEST_INVALID: cannot resolve the current user: %v", err)
	}
	name := u.Username
	group := name
	if g, gerr := user.LookupGroupId(u.Gid); gerr == nil && g.Name != "" {
		group = g.Name
	}
	return name, group
}

// hermeticLogretention materialises the shipped policy under root and points the four
// supported NFTBAN_LR_* overrides at it. Returns the relocated log directory.
//
// It uses the EXISTING supported override mechanism (assertions.go reads
// NFTBAN_LR_MAIN / NFTBAN_LR_SURICATA / NFTBAN_LR_STATE / NFTBAN_LR_TEMPLATE) — no
// production code is changed to make this hermetic.
func hermeticLogretention(t *testing.T, root string) string {
	t.Helper()
	if _, err := exec.LookPath("logrotate"); err != nil {
		// Repo precedent (see the shell suites' `command -v flock || TEST_INVALID`):
		// a missing TEST DEPENDENCY fails loudly rather than skipping, because a
		// silently skipped arm removes the COMMITTED bar without anyone noticing.
		t.Fatalf("TEST_INVALID: logrotate(1) not found — this arm validates the shipped " +
			"policy with the REAL validator and cannot be honestly run without it")
	}

	src := filepath.Join(repoRoot(t), canonicalLogrotatePolicy)
	raw, err := os.ReadFile(src) // #nosec G304 -- in-repo canonical fixture source
	if err != nil {
		t.Fatalf("TEST_INVALID: cannot read the canonical shipped policy %s: %v", src, err)
	}
	body := string(raw)

	// ── ENVIRONMENT BINDING 1: the log root ──────────────────────────────────────
	logDir := filepath.Join(root, "var", "log", "nftban")
	body = strings.ReplaceAll(body, hermeticLogDirToken, logDir)

	// ── ENVIRONMENT BINDING 2: create/createolddir ownership ─────────────────────
	owner, group := currentOwner(t)
	body = strings.ReplaceAll(body, "create 0640 nftban nftban", "create 0640 "+owner+" "+group)
	body = strings.ReplaceAll(body, "createolddir 0750 nftban nftban", "createolddir 0750 "+owner+" "+group)
	body = strings.ReplaceAll(body, "su nftban nftban", "su "+owner+" "+group)

	// ⛔ DRIFT GUARD. If the canonical policy grows a directive naming an identity or a
	// path this fixture does not relocate, the arm must say so rather than silently
	// validating a policy that is not the shipped one.
	//
	// Every remaining occurrence of the token must be the TAIL of the relocated root —
	// a bare one would be a path still pointing at the host.
	if strings.Count(body, hermeticLogDirToken) != strings.Count(body, logDir) {
		t.Fatalf("TEST_INVALID: the canonical policy still names the HOST log root after "+
			"relocation — the fixture would touch global state (source: %s)", src)
	}
	if strings.Contains(body, " nftban nftban") {
		t.Fatalf("TEST_INVALID: the canonical policy still names the nftban identity after "+
			"relocation — it cannot parse on a host without that user (source: %s)", src)
	}

	// Every LITERAL path the policy names must exist, or logrotate -d exits 1
	// (measured). Glob stanzas legitimately match nothing and are left alone.
	created := 0
	for _, line := range strings.Split(body, "\n") {
		p := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(line), "{"))
		if !strings.HasPrefix(p, logDir) || strings.ContainsAny(p, "*?") {
			continue
		}
		if strings.HasSuffix(p, "/archive") { // olddir target — a directory, not a log
			if err := os.MkdirAll(p, 0o750); err != nil {
				t.Fatalf("TEST_INVALID: create olddir %s: %v", p, err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
			t.Fatalf("TEST_INVALID: create log dir for %s: %v", p, err)
		}
		if err := os.WriteFile(p, []byte("seed\n"), 0o640); err != nil {
			t.Fatalf("TEST_INVALID: create log %s: %v", p, err)
		}
		created++
	}
	if created == 0 {
		t.Fatal("TEST_INVALID: the canonical policy named no literal log path — the fixture " +
			"would validate nothing")
	}

	// The ACTIVE policy and the FALLBACK TEMPLATE must be byte-identical: that is the
	// READY_FALLBACK classification the assertion performs (readiness.go
	// classifyFallback compares their hashes).
	mainPath := filepath.Join(root, "etc", "logrotate.d", "nftban")
	tmplPath := filepath.Join(root, "etc", "nftban", "templates", "nftban.logrotate")
	for _, p := range []string{mainPath, tmplPath} {
		if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
			t.Fatalf("TEST_INVALID: mkdir %s: %v", filepath.Dir(p), err)
		}
		// Mode 0644 is mandatory — Readiness rejects anything else.
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil { // #nosec G306 -- logrotate policy is 0644 by contract
			t.Fatalf("TEST_INVALID: write %s: %v", p, err)
		}
		if err := os.Chmod(p, 0o644); err != nil { // defeat umask
			t.Fatalf("TEST_INVALID: chmod %s: %v", p, err)
		}
	}

	t.Setenv("NFTBAN_LR_MAIN", mainPath)
	t.Setenv("NFTBAN_LR_TEMPLATE", tmplPath)
	// No generated state → the fallback path, which is what a freshly installed host has.
	t.Setenv("NFTBAN_LR_STATE", filepath.Join(root, "nonexistent-state.json"))
	t.Setenv("NFTBAN_LR_SURICATA", filepath.Join(root, "nonexistent-suricata"))
	return logDir
}
