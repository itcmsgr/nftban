// =============================================================================
// NFTBan v1.100.x PR26.1 - Systemd Payload Validator Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-systemd-payload-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Fixture tests covering SYSTEMD-EXECSTART-001, SYSTEMD-TIMER-PAIR-001, PAYLOAD-INVENTORY-001, FAILED-UNIT-POSTINSTALL-001"
// meta:inventory.files="internal/installer/validate/systemd_payload_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validate

import (
	"strings"
	"testing"
)

// pathSet returns a PathExists closure backed by a map.
func pathSet(paths ...string) func(string) bool {
	m := make(map[string]bool, len(paths))
	for _, p := range paths {
		m[p] = true
	}
	return func(p string) bool { return m[p] }
}

// inv returns a PayloadInventory pre-populated with default prefixes
// and the given known-paths.
func inv(paths ...string) PayloadInventory {
	m := make(map[string]bool, len(paths))
	for _, p := range paths {
		m[p] = true
	}
	return PayloadInventory{
		Paths:                m,
		NftbanOwnedPrefixes:  DefaultNftbanOwnedPrefixes,
		SystemBinaryPrefixes: DefaultSystemBinaryPrefixes,
	}
}

// ----------------------------------------------------------------------------
// (a) Valid service+timer pair
// ----------------------------------------------------------------------------
func TestSystemdPayload_ValidPair(t *testing.T) {
	svc := ParseUnitFile("nftban-unified-exporter.service",
		"/usr/lib/systemd/system/nftban-unified-exporter.service",
		`[Unit]
Description=NFTBan unified exporter

[Service]
Type=oneshot
ExecStart=/usr/lib/nftban/exporters/nftban_unified_exporter.sh
`)
	timer := ParseUnitFile("nftban-unified-exporter.timer",
		"/usr/lib/systemd/system/nftban-unified-exporter.timer",
		`[Unit]
Description=Run unified exporter

[Timer]
OnUnitActiveSec=60s
Unit=nftban-unified-exporter.service
`)

	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units: []ParsedUnit{svc, timer},
		PathExists: pathSet(
			"/usr/lib/nftban/exporters/nftban_unified_exporter.sh",
		),
		Inventory: inv("/usr/lib/nftban/exporters/nftban_unified_exporter.sh"),
		AllUnitNames: map[string]bool{
			"nftban-unified-exporter.service": true,
			"nftban-unified-exporter.timer":   true,
		},
	})

	if !res.OK {
		t.Fatalf("expected OK; got %#v", res)
	}
}

// ----------------------------------------------------------------------------
// (b) Missing ExecStart path → SYSTEMD-EXECSTART-001 fails
//
// Regression shape from dns2 (2026-04-29): nftban-unified-exporter.service
// referenced /usr/lib/nftban/exporters/nftban_unified_exporter.sh, but the
// file was not staged. Test name structural; comment carries history.
// ----------------------------------------------------------------------------
func TestSystemdPayload_MissingExecStart_FilesystemAbsent(t *testing.T) {
	svc := ParseUnitFile("nftban-unified-exporter.service",
		"/usr/lib/systemd/system/nftban-unified-exporter.service",
		`[Service]
ExecStart=/usr/lib/nftban/exporters/nftban_unified_exporter.sh
`)

	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet(), // empty: file is missing on disk
		Inventory:    inv(),     // and not in payload inventory either
		AllUnitNames: map[string]bool{"nftban-unified-exporter.service": true},
	})

	if res.OK {
		t.Fatalf("expected NOT OK")
	}
	if len(res.MissingExecPaths) != 1 {
		t.Fatalf("expected 1 MissingExecPath; got %d", len(res.MissingExecPaths))
	}
	if res.MissingExecPaths[0].Path != "/usr/lib/nftban/exporters/nftban_unified_exporter.sh" {
		t.Errorf("unexpected path: %s", res.MissingExecPaths[0].Path)
	}
	if len(res.UnknownPayloadRefs) != 1 {
		t.Fatalf("expected 1 UnknownPayloadRef (PAYLOAD-INVENTORY-001); got %d", len(res.UnknownPayloadRefs))
	}
}

// ----------------------------------------------------------------------------
// (c) Timer activates missing service → SYSTEMD-TIMER-PAIR-001 fails
//
// Regression shape from dns2 (2026-04-29): nftban-metrics-exporter.timer
// remained installed while the paired service was absent. Test name
// structural; comment carries history.
// ----------------------------------------------------------------------------
func TestSystemdPayload_TimerOrphan_NoServicePair(t *testing.T) {
	timer := ParseUnitFile("nftban-metrics-exporter.timer",
		"/usr/lib/systemd/system/nftban-metrics-exporter.timer",
		`[Timer]
OnUnitActiveSec=60s
Unit=nftban-metrics-exporter.service
`)

	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:      []ParsedUnit{timer},
		PathExists: pathSet(),
		Inventory:  inv(),
		AllUnitNames: map[string]bool{
			// note: only the timer is installed; service is missing
			"nftban-metrics-exporter.timer": true,
		},
	})

	if res.OK {
		t.Fatalf("expected NOT OK")
	}
	if len(res.MissingTimerTargets) != 1 {
		t.Fatalf("expected 1 MissingTimerTarget; got %d", len(res.MissingTimerTargets))
	}
	mt := res.MissingTimerTargets[0]
	if mt.TimerUnit != "nftban-metrics-exporter.timer" || mt.TargetUnit != "nftban-metrics-exporter.service" {
		t.Errorf("unexpected pair: %+v", mt)
	}
}

// Implicit Unit= inference: if [Timer] omits Unit=, the target is the
// timer's basename with .service.
func TestSystemdPayload_TimerImplicitUnit(t *testing.T) {
	timer := ParseUnitFile("nftban-connector-exporter.timer",
		"/usr/lib/systemd/system/nftban-connector-exporter.timer",
		`[Timer]
OnUnitActiveSec=60s
`)
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{timer},
		PathExists:   pathSet(),
		Inventory:    inv(),
		AllUnitNames: map[string]bool{"nftban-connector-exporter.timer": true},
	})
	if res.OK {
		t.Fatalf("expected NOT OK")
	}
	if len(res.MissingTimerTargets) != 1 {
		t.Fatalf("expected 1 MissingTimerTarget; got %d", len(res.MissingTimerTargets))
	}
	if res.MissingTimerTargets[0].TargetUnit != "nftban-connector-exporter.service" {
		t.Errorf("expected implicit .service target; got %s", res.MissingTimerTargets[0].TargetUnit)
	}
}

// ----------------------------------------------------------------------------
// (d) nftban-owned path outside inventory → PAYLOAD-INVENTORY-001 fails
// ----------------------------------------------------------------------------
func TestSystemdPayload_NftbanPathNotInInventory(t *testing.T) {
	svc := ParseUnitFile("nftban-rogue.service",
		"/usr/lib/systemd/system/nftban-rogue.service",
		`[Service]
ExecStart=/usr/lib/nftban/sbin/rogue-helper
`)

	// Path EXISTS on disk (so SYSTEMD-EXECSTART-001 passes) but is
	// NOT in inventory — SYSTEMD-PAYLOAD-INVENTORY-001 must fire.
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet("/usr/lib/nftban/sbin/rogue-helper"),
		Inventory:    inv(), // empty inventory
		AllUnitNames: map[string]bool{"nftban-rogue.service": true},
	})

	if res.OK {
		t.Fatalf("expected NOT OK")
	}
	if !res.ExecStartOK() {
		t.Errorf("ExecStartOK should pass when file exists; got %v", res.MissingExecPaths)
	}
	if len(res.UnknownPayloadRefs) != 1 {
		t.Fatalf("expected 1 UnknownPayloadRef; got %d", len(res.UnknownPayloadRefs))
	}
}

// ----------------------------------------------------------------------------
// (e) Failed unit injected → FAILED-UNIT-POSTINSTALL-001 fails
// ----------------------------------------------------------------------------
func TestSystemdPayload_FailedUnit(t *testing.T) {
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		PathExists: pathSet(),
		Inventory:  inv(),
		FailedNftbanUnits: []FailedUnitFinding{
			{Unit: "nftban-unified-exporter.service", Active: "failed", Sub: "failed", Detail: "exit-code 203/EXEC"},
		},
	})

	if res.OK {
		t.Fatalf("expected NOT OK")
	}
	if len(res.FailedUnits) != 1 {
		t.Fatalf("expected 1 FailedUnit; got %d", len(res.FailedUnits))
	}
	if !strings.Contains(res.FailedUnits[0].Detail, "203/EXEC") {
		t.Errorf("detail should preserve systemctl reason; got %q", res.FailedUnits[0].Detail)
	}
}

// Non-nftban failed units are ignored (FAILED-UNIT-POSTINSTALL-001 is
// scoped to nftban-* only).
func TestSystemdPayload_FailedNonNftbanIgnored(t *testing.T) {
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		PathExists: pathSet(),
		Inventory:  inv(),
		FailedNftbanUnits: []FailedUnitFinding{
			{Unit: "maldet.service", Active: "failed", Sub: "failed"},
		},
	})
	if !res.OK {
		t.Fatalf("expected OK (non-nftban failure ignored); got %#v", res)
	}
}

// ----------------------------------------------------------------------------
// (f) Shell-wrapper ExecStart with nftban-owned path inside the command
// ----------------------------------------------------------------------------
func TestSystemdPayload_ShellWrapper_EmbeddedNftbanPath(t *testing.T) {
	svc := ParseUnitFile("nftban-wrapped.service",
		"/usr/lib/systemd/system/nftban-wrapped.service",
		`[Service]
ExecStart=/bin/sh -c '/usr/lib/nftban/sbin/wrapped-helper --flag'
`)

	if len(svc.Execs) != 1 {
		t.Fatalf("expected 1 Exec directive; got %d", len(svc.Execs))
	}
	if svc.Execs[0].Binary != "/bin/sh" {
		t.Errorf("expected /bin/sh wrapper; got %q", svc.Execs[0].Binary)
	}
	if len(svc.Execs[0].EmbeddedNftbanPaths) != 1 ||
		svc.Execs[0].EmbeddedNftbanPaths[0] != "/usr/lib/nftban/sbin/wrapped-helper" {
		t.Errorf("expected embedded nftban path; got %v", svc.Execs[0].EmbeddedNftbanPaths)
	}

	// Wrapper present, embedded path missing → both invariants fire on the embedded path.
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet("/bin/sh"), // wrapper exists; helper does not
		Inventory:    inv(),
		AllUnitNames: map[string]bool{"nftban-wrapped.service": true},
	})

	if res.OK {
		t.Fatalf("expected NOT OK")
	}
	if len(res.MissingExecPaths) != 1 {
		t.Fatalf("expected 1 missing path (the embedded helper); got %d", len(res.MissingExecPaths))
	}
	if res.MissingExecPaths[0].Path != "/usr/lib/nftban/sbin/wrapped-helper" {
		t.Errorf("unexpected missing path: %s", res.MissingExecPaths[0].Path)
	}
}

// /usr/bin/env wrapper variant.
func TestSystemdPayload_EnvWrapper_EmbeddedNftbanPath(t *testing.T) {
	svc := ParseUnitFile("nftban-envwrapped.service",
		"/usr/lib/systemd/system/nftban-envwrapped.service",
		`[Service]
ExecStart=/usr/bin/env FOO=bar /usr/lib/nftban/sbin/wrapped-helper
`)
	if svc.Execs[0].Binary != "/usr/bin/env" {
		t.Errorf("expected /usr/bin/env wrapper; got %q", svc.Execs[0].Binary)
	}
	if len(svc.Execs[0].EmbeddedNftbanPaths) != 1 {
		t.Fatalf("expected one embedded nftban path; got %v", svc.Execs[0].EmbeddedNftbanPaths)
	}
}

// ----------------------------------------------------------------------------
// (g) System binary path is allowed (not an inventory hit)
// ----------------------------------------------------------------------------
func TestSystemdPayload_SystemBinaryAllowed(t *testing.T) {
	svc := ParseUnitFile("nftban-syswrap.service",
		"/usr/lib/systemd/system/nftban-syswrap.service",
		`[Service]
ExecStart=/usr/bin/systemctl status
`)
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet("/usr/bin/systemctl"),
		Inventory:    inv(), // empty — but /usr/bin is system-binary territory
		AllUnitNames: map[string]bool{"nftban-syswrap.service": true},
	})
	if !res.OK {
		t.Fatalf("expected OK; system binary should be exempt: %#v", res)
	}
}

// ----------------------------------------------------------------------------
// Systemd Exec prefixes ('-', '+', '!') are stripped before path resolution.
// ----------------------------------------------------------------------------
func TestSystemdPayload_ExecPrefixesStripped(t *testing.T) {
	cases := []struct{ name, line string }{
		{"dash", "[Service]\nExecStartPre=-/usr/lib/nftban/sbin/nftban-apply"},
		{"plus", "[Service]\nExecStart=+/usr/lib/nftban/sbin/nftban-apply"},
		{"bang", "[Service]\nExecStart=!/usr/lib/nftban/sbin/nftban-apply"},
		{"combo", "[Service]\nExecStart=-+/usr/lib/nftban/sbin/nftban-apply"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := ParseUnitFile("nftban-prefixed.service", "/p", c.line+"\n")
			if len(u.Execs) != 1 {
				t.Fatalf("expected 1 directive; got %d", len(u.Execs))
			}
			if u.Execs[0].Binary != "/usr/lib/nftban/sbin/nftban-apply" {
				t.Errorf("prefix not stripped: %q", u.Execs[0].Binary)
			}
		})
	}
}

// Continuation lines (trailing backslash) are joined.
func TestSystemdPayload_ContinuationLine(t *testing.T) {
	u := ParseUnitFile("nftban-continued.service", "/p",
		"[Service]\nExecStart=/usr/lib/nftban/sbin/nftban-apply \\\n  --flag-a \\\n  --flag-b\n")
	if len(u.Execs) != 1 {
		t.Fatalf("expected 1 directive; got %d", len(u.Execs))
	}
	if !strings.Contains(u.Execs[0].Raw, "--flag-a") || !strings.Contains(u.Execs[0].Raw, "--flag-b") {
		t.Errorf("continuation not joined: %q", u.Execs[0].Raw)
	}
}

// Non-nftban units are filtered: a third-party unit referencing a
// missing path does NOT fire the validator.
func TestSystemdPayload_NonNftbanUnitsIgnored(t *testing.T) {
	svc := ParseUnitFile("foo.service", "/usr/lib/systemd/system/foo.service",
		`[Service]
ExecStart=/opt/foo/bin/foo
`)
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet(),
		Inventory:    inv(),
		AllUnitNames: map[string]bool{"foo.service": true},
	})
	if !res.OK {
		t.Fatalf("expected OK; third-party units are out of scope: %#v", res)
	}
}

// IsNftbanUnit naming matrix (P1-A): covers nftban-*, nftband*, and
// every supported unit suffix, plus deliberate negatives.
func TestSystemdPayload_NftbanUnitNaming(t *testing.T) {
	cases := map[string]bool{
		// singular / daemon
		"nftban.service":  true,
		"nftband.service": true,
		"nftban.timer":    true,
		"nftband.socket":  true,
		"nftband.timer":   true,
		"nftban.target":   true,

		// hyphenated nftban-*
		"nftban-unified-exporter.service": true,
		"nftban-metrics-exporter.timer":   true,
		"nftban-control.socket":           true,
		"nftban-maintenance.target":       true,

		// hyphenated nftband-*
		"nftband-rpc.socket":   true,
		"nftband-watch.service": true,

		// negatives — name not a complete identifier prefix
		"foo-nftban.service":  false,
		"sshd.service":        false,
		"nftbanfake.service":  false,
		"fake-nftban.service": false,

		// negatives — non-systemd unit suffix
		"nftban.conf":     false,
		"nftban.txt":      false,
		"nftban":          false,
		"nftban.":         false,
		"nftban-foo":      false, // missing extension entirely
	}
	for name, want := range cases {
		if got := IsNftbanUnit(name); got != want {
			t.Errorf("IsNftbanUnit(%q) = %v; want %v", name, got, want)
		}
	}
}

// ----------------------------------------------------------------------------
// P0-B: system-binary exemption table.
//
// Verifies every wrapper/system binary path commonly referenced by
// nftban units is exempt from PAYLOAD-INVENTORY-001 even when the
// inventory is empty. Companion test below proves the exemption does
// NOT extend to nftban-owned paths embedded inside the wrapper's
// command argument.
// ----------------------------------------------------------------------------
func TestSystemdPayload_SystemBinaryExemption_Table(t *testing.T) {
	exemptBinaries := []string{
		"/bin/sh", "/usr/bin/sh",
		"/bin/bash", "/usr/bin/bash",
		"/bin/env", "/usr/bin/env",
		"/bin/systemctl", "/usr/bin/systemctl",
		"/usr/bin/journalctl",
	}
	for _, bin := range exemptBinaries {
		t.Run(bin, func(t *testing.T) {
			svc := ParseUnitFile("nftban-syswrap.service",
				"/usr/lib/systemd/system/nftban-syswrap.service",
				"[Service]\nExecStart="+bin+" --version\n")
			res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
				Units:        []ParsedUnit{svc},
				PathExists:   pathSet(bin), // wrapper exists; inventory is empty
				Inventory:    inv(),
				AllUnitNames: map[string]bool{"nftban-syswrap.service": true},
			})
			if !res.OK {
				t.Errorf("expected OK for system binary %s; got %#v", bin, res)
			}
		})
	}
}

// Exemption boundary: /bin/sh -c '/usr/lib/nftban/missing.sh' MUST still
// fail when the embedded nftban-owned path is missing/uninventoried.
// The wrapper alone is exempt; the embedded payload reference is not.
func TestSystemdPayload_SystemBinaryExemption_DoesNotMaskEmbeddedNftbanPath(t *testing.T) {
	svc := ParseUnitFile("nftban-wrapped-fail.service",
		"/usr/lib/systemd/system/nftban-wrapped-fail.service",
		`[Service]
ExecStart=/bin/sh -c '/usr/lib/nftban/exporters/nftban_unified_exporter.sh'
`)
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet("/bin/sh"), // wrapper present, helper missing
		Inventory:    inv(),
		AllUnitNames: map[string]bool{"nftban-wrapped-fail.service": true},
	})
	if res.OK {
		t.Fatalf("expected NOT OK — embedded nftban path missing must still fire")
	}
	if len(res.MissingExecPaths) != 1 ||
		res.MissingExecPaths[0].Path != "/usr/lib/nftban/exporters/nftban_unified_exporter.sh" {
		t.Errorf("expected missing-path on embedded helper; got %v", res.MissingExecPaths)
	}
	// PAYLOAD-INVENTORY-001 should also fire (helper is nftban-owned, not in inventory).
	if len(res.UnknownPayloadRefs) != 1 {
		t.Errorf("expected UnknownPayloadRef on embedded helper; got %v", res.UnknownPayloadRefs)
	}
}

// Exemption boundary: pure-shell ExecStart that does not reference
// any nftban-owned path passes even with empty inventory.
func TestSystemdPayload_SystemBinaryExemption_PureShellPasses(t *testing.T) {
	svc := ParseUnitFile("nftban-shell-only.service",
		"/usr/lib/systemd/system/nftban-shell-only.service",
		`[Service]
ExecStart=/bin/sh -c 'echo ok'
`)
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet("/bin/sh"),
		Inventory:    inv(),
		AllUnitNames: map[string]bool{"nftban-shell-only.service": true},
	})
	if !res.OK {
		t.Fatalf("expected OK — pure shell ExecStart with no embedded nftban paths: %#v", res)
	}
}

// ----------------------------------------------------------------------------
// P0-C (upgraded P1-C): FAILED-UNIT-POSTINSTALL-001 fails closed when
// the failed-unit enumeration source itself errors. Empty FailedUnits +
// non-empty FailedUnitQueryError must NOT pass.
// ----------------------------------------------------------------------------
func TestSystemdPayload_FailedUnitQueryError_FailsClosed(t *testing.T) {
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		PathExists:           pathSet(),
		Inventory:            inv(),
		FailedNftbanUnits:    nil, // no findings
		FailedUnitQueryError: "systemctl list-units --state=failed exit=1 stderr=\"Failed to connect to bus\"",
	})
	if res.OK {
		t.Fatalf("expected NOT OK — query error must fail closed")
	}
	if res.FailedUnitsOK() {
		t.Errorf("FailedUnitsOK should be false when query errored")
	}
	if !res.ExecStartOK() || !res.TimerPairOK() || !res.PayloadInventoryOK() {
		t.Errorf("only FAILED-UNIT-POSTINSTALL-001 should fail; others should pass")
	}
}

// Healthy enumeration with zero findings still passes (the
// fail-closed semantics only kick in when the query errored).
func TestSystemdPayload_FailedUnits_ZeroFindings_NoQueryError_Passes(t *testing.T) {
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		PathExists:           pathSet(),
		Inventory:            inv(),
		FailedNftbanUnits:    nil,
		FailedUnitQueryError: "",
	})
	if !res.OK {
		t.Fatalf("expected OK — zero findings + no query error is healthy: %#v", res)
	}
}

// ----------------------------------------------------------------------------
// §9 cheap additions: empty unit file, multi-line ExecStart, symlink shape
// ----------------------------------------------------------------------------

// Empty / malformed unit file does not panic; it produces zero Execs
// and contributes nothing to the validator (no ExecStart to check).
func TestSystemdPayload_EmptyUnitFile_NoPanic(t *testing.T) {
	cases := []struct{ name, content string }{
		{"empty", ""},
		{"only-comments", "# nothing\n; nothing else\n"},
		{"only-section", "[Service]\n"},
		{"missing-equals", "[Service]\nExecStart\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u := ParseUnitFile("nftban-empty.service", "/p/nftban-empty.service", c.content)
			if len(u.Execs) != 0 {
				t.Errorf("expected 0 execs for %s; got %d", c.name, len(u.Execs))
			}
			res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
				Units:        []ParsedUnit{u},
				PathExists:   pathSet(),
				Inventory:    inv(),
				AllUnitNames: map[string]bool{"nftban-empty.service": true},
			})
			if !res.OK {
				t.Errorf("empty/malformed unit should not produce findings: %#v", res)
			}
		})
	}
}

// Multi-line ExecStart with backslash continuations resolves to a
// single directive whose Raw concatenates the joined logical line.
// Already covered by TestSystemdPayload_ContinuationLine but this
// adds end-to-end validation: the joined RHS still resolves to a
// real binary that exists on disk.
func TestSystemdPayload_MultiLineExecStart_EndToEnd(t *testing.T) {
	svc := ParseUnitFile("nftban-multiline.service",
		"/usr/lib/systemd/system/nftban-multiline.service",
		"[Service]\nExecStart=/usr/lib/nftban/sbin/nftban-apply \\\n  --foo \\\n  --bar\n")
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet("/usr/lib/nftban/sbin/nftban-apply"),
		Inventory:    inv("/usr/lib/nftban/sbin/nftban-apply"),
		AllUnitNames: map[string]bool{"nftban-multiline.service": true},
	})
	if !res.OK {
		t.Fatalf("multi-line ExecStart should pass when binary exists: %#v", res)
	}
}

// Symlink shape: the validator treats path-existence as the callback's
// boolean answer. A live host's PathExists returns true for a symlink
// pointing at a real file, false for a broken symlink. We assert both
// shapes via the closure.
func TestSystemdPayload_SymlinkShape(t *testing.T) {
	svc := ParseUnitFile("nftban-symlink.service",
		"/usr/lib/systemd/system/nftban-symlink.service",
		"[Service]\nExecStart=/usr/lib/nftban/sbin/nftban-apply\n")

	// Resolved symlink — callback says present.
	resOK := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet("/usr/lib/nftban/sbin/nftban-apply"),
		Inventory:    inv("/usr/lib/nftban/sbin/nftban-apply"),
		AllUnitNames: map[string]bool{"nftban-symlink.service": true},
	})
	if !resOK.OK {
		t.Errorf("resolved symlink should pass; got %#v", resOK)
	}

	// Broken symlink — callback says absent.
	resBroken := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		Units:        []ParsedUnit{svc},
		PathExists:   pathSet(), // empty — broken/dangling
		Inventory:    inv("/usr/lib/nftban/sbin/nftban-apply"),
		AllUnitNames: map[string]bool{"nftban-symlink.service": true},
	})
	if resBroken.OK {
		t.Errorf("broken symlink must fail SYSTEMD-EXECSTART-001")
	}
}
