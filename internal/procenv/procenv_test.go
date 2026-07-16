// SPDX-License-Identifier: MPL-2.0
// meta:name="procenv_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Tests that child-process environment sanitization strips systemd sd_notify/watchdog variables while preserving everything else."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NOTIFY_SOCKET, WATCHDOG_USEC, WATCHDOG_PID"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package procenv

import (
	"strings"
	"testing"
)

// CHILD_ENV_STRIPS_SYSTEMD_NOTIFY_VARIABLES
func TestStripSystemdVars(t *testing.T) {
	in := []string{
		"PATH=/usr/bin",
		"NOTIFY_SOCKET=/run/systemd/notify",
		"HOME=/root",
		"WATCHDOG_USEC=120000000",
		"WATCHDOG_PID=1234",
		"NFTBAN_CONFIG_DIR=/etc/nftban",
	}
	out := StripSystemdVars(in)

	joined := strings.Join(out, "\n")
	for _, banned := range []string{"NOTIFY_SOCKET=", "WATCHDOG_USEC=", "WATCHDOG_PID="} {
		if strings.Contains(joined, banned) {
			t.Fatalf("sanitized env still contains %s:\n%s", banned, joined)
		}
	}
	// Everything else must be preserved, in order.
	for _, keep := range []string{"PATH=/usr/bin", "HOME=/root", "NFTBAN_CONFIG_DIR=/etc/nftban"} {
		if !strings.Contains(joined, keep) {
			t.Fatalf("sanitized env dropped a non-systemd var %q:\n%s", keep, joined)
		}
	}
	if len(out) != 3 {
		t.Fatalf("expected 3 vars after stripping 3 of 6, got %d: %v", len(out), out)
	}
}

// A variable that merely CONTAINS the substring but is a different name must be kept
// (exact-name match only).
func TestStripSystemdVars_ExactNameOnly(t *testing.T) {
	in := []string{
		"MY_NOTIFY_SOCKET=x",     // different name
		"NOTIFY_SOCKET_BACKUP=y", // different name
		"NOTIFY_SOCKET=z",        // exact — stripped
	}
	out := StripSystemdVars(in)
	if len(out) != 2 {
		t.Fatalf("exact-name match failed, got %v", out)
	}
	joined := strings.Join(out, "\n")
	if strings.Contains(joined, "NOTIFY_SOCKET=z") {
		t.Fatalf("exact NOTIFY_SOCKET not stripped: %s", joined)
	}
	if !strings.Contains(joined, "MY_NOTIFY_SOCKET=x") || !strings.Contains(joined, "NOTIFY_SOCKET_BACKUP=y") {
		t.Fatalf("similarly-named vars wrongly stripped: %s", joined)
	}
}

// Explicit coverage of the stated policy invariants:
// INPUT_ENV_NOT_MUTATED / *_REMOVED / UNRELATED_ENV_PRESERVED /
// DUPLICATE_KEYS_HANDLED / MALFORMED_ENTRIES_HANDLED_SAFELY.
func TestStripSystemdVars_Invariants(t *testing.T) {
	in := []string{
		"PATH=/usr/bin",
		"NOTIFY_SOCKET=/run/systemd/notify",
		"NOTIFY_SOCKET=/run/dup", // duplicate blocked key — both must go
		"WATCHDOG_USEC=120000000",
		"WATCHDOG_PID=1234",
		"DUP=1", // duplicate normal key — both must stay
		"DUP=2",
		"MALFORMED_NO_EQUALS", // no '=' — preserved verbatim
		"EMPTYVAL=",           // valid, empty value — preserved
	}
	// Snapshot the input to assert it is not mutated.
	orig := append([]string(nil), in...)

	out := StripSystemdVars(in)

	// INPUT_ENV_NOT_MUTATED
	for i := range orig {
		if in[i] != orig[i] {
			t.Fatalf("input env was mutated at %d: %q != %q", i, in[i], orig[i])
		}
	}
	joined := strings.Join(out, "\n")

	// *_REMOVED (all occurrences)
	if strings.Contains(joined, "NOTIFY_SOCKET=") ||
		strings.Contains(joined, "WATCHDOG_USEC=") ||
		strings.Contains(joined, "WATCHDOG_PID=") {
		t.Fatalf("a blocked systemd var survived:\n%s", joined)
	}

	// DUPLICATE_KEYS_HANDLED: both DUP kept, both NOTIFY_SOCKET gone
	dupCount := 0
	for _, e := range out {
		if strings.HasPrefix(e, "DUP=") {
			dupCount++
		}
	}
	if dupCount != 2 {
		t.Fatalf("duplicate normal key not preserved (got %d DUP entries)", dupCount)
	}

	// UNRELATED_ENV_PRESERVED + MALFORMED_ENTRIES + empty value
	for _, keep := range []string{"PATH=/usr/bin", "MALFORMED_NO_EQUALS", "EMPTYVAL="} {
		if !strings.Contains(joined, keep) {
			t.Fatalf("expected %q preserved:\n%s", keep, joined)
		}
	}

	// 5 blocked-removed → 9 in, 4 blocked → 5 out? blocked = 2 NOTIFY + 1 USEC + 1 PID = 4.
	if len(out) != len(in)-4 {
		t.Fatalf("expected %d entries after removing 4 blocked, got %d", len(in)-4, len(out))
	}
}

// An empty environment must not panic and must return an empty (usable) slice.
func TestStripSystemdVars_Empty(t *testing.T) {
	out := StripSystemdVars(nil)
	if len(out) != 0 {
		t.Fatalf("empty input should yield empty output, got %v", out)
	}
}

// Command / CommandContext must pre-set a sanitized environment.
func TestCommand_SetsSanitizedEnv(t *testing.T) {
	t.Setenv("NOTIFY_SOCKET", "/run/systemd/notify")
	t.Setenv("NFTBAN_KEEPME", "yes")

	c := Command("true")
	if c.Env == nil {
		t.Fatalf("Command did not set a sanitized Env")
	}
	joined := strings.Join(c.Env, "\n")
	if strings.Contains(joined, "NOTIFY_SOCKET=") {
		t.Fatalf("Command Env still carries NOTIFY_SOCKET:\n%s", joined)
	}
	if !strings.Contains(joined, "NFTBAN_KEEPME=yes") {
		t.Fatalf("Command Env dropped a normal var:\n%s", joined)
	}
}
