// =============================================================================
// NFTBan v1.148 - Config-preservation (V148_CONFIG_PRESERVATION_CONTRACT) tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="payload-preserve-v148-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.148 config-preservation (3-way rpm-conffile) unit tests"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Unit tests for preserveOrStageConfig (the 3-way "rpm conffile" algorithm):
// fresh-install, update-if-unchanged-from-prior-default, preserve-if-edited
// (+ .nftban-new sidecar), unchanged, module main.conf, the .conf.local guard,
// and the no-baseline conservative branch. Parity-diff / restore-reboot /
// WARN+report-emission are integration tests (lab VMs), not unit tests.
// =============================================================================

package payload

import (
	"bytes"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

const (
	v148DDoS     = "/etc/nftban/conf.d/ddos.conf"
	v148DDoSBase = "/usr/share/nftban/defaults/conf.d/ddos.conf"
	v148Login    = "/etc/nftban/conf.d/login/main.conf"
	v148LoginBL  = "/usr/share/nftban/defaults/conf.d/login/main.conf"
)

// 1. Fresh install: target absent -> seed default, refresh baseline.
func TestPreserveV148_FreshInstall(t *testing.T) {
	m := executor.NewMockExecutor()
	def := []byte("KEY=default\n")
	entry, err := preserveOrStageConfig(m, def, v148DDoS, 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry.Action != ConfigInstalled {
		t.Fatalf("action = %q, want installed", entry.Action)
	}
	if !bytes.Equal(m.WrittenFiles[v148DDoS], def) {
		t.Errorf("dst not seeded with default")
	}
	if !bytes.Equal(m.WrittenFiles[v148DDoSBase], def) {
		t.Errorf("baseline not refreshed on fresh install")
	}
}

// 2. Target equals prior packaged default -> safe to replace with new default.
func TestPreserveV148_UnchangedFromPriorDefault_Updated(t *testing.T) {
	m := executor.NewMockExecutor()
	old := []byte("KEY=old\n")
	newd := []byte("KEY=new\n")
	m.Files[v148DDoS] = old     // live == prior default (operator never edited)
	m.Files[v148DDoSBase] = old // prior default baseline
	entry, err := preserveOrStageConfig(m, newd, v148DDoS, 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry.Action != ConfigUpdated {
		t.Fatalf("action = %q, want updated", entry.Action)
	}
	if !bytes.Equal(m.WrittenFiles[v148DDoS], newd) {
		t.Errorf("dst not updated to new default")
	}
	if _, ok := m.WrittenFiles[v148DDoS+configSidecarSuffix]; ok {
		t.Errorf("unexpected sidecar for an unmodified file")
	}
}

// 3. ACCEPTANCE: operator-edited base .conf is PRESERVED; new default -> sidecar.
func TestPreserveV148_OperatorEdited_Preserved(t *testing.T) {
	m := executor.NewMockExecutor()
	edited := []byte("KEY=OPERATOR_VALUE\n")
	prior := []byte("KEY=old_default\n")
	newd := []byte("KEY=new_default\n")
	m.Files[v148DDoS] = edited
	m.Files[v148DDoSBase] = prior // live != prior default => operator edited
	entry, err := preserveOrStageConfig(m, newd, v148DDoS, 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry.Action != ConfigPreserved {
		t.Fatalf("action = %q, want preserved", entry.Action)
	}
	// dst must NOT be overwritten.
	if _, ok := m.WrittenFiles[v148DDoS]; ok {
		t.Errorf("operator-edited dst was overwritten (must be preserved)")
	}
	if !bytes.Equal(m.Files[v148DDoS], edited) {
		t.Errorf("operator content changed")
	}
	// new default delivered as sidecar.
	sc := v148DDoS + configSidecarSuffix
	if entry.Sidecar != sc || !bytes.Equal(m.WrittenFiles[sc], newd) {
		t.Errorf("new default not delivered to sidecar %s", sc)
	}
}

// 4. ACCEPTANCE: module main.conf (subdir) is preserved when operator-edited.
func TestPreserveV148_ModuleMainConf_Preserved(t *testing.T) {
	m := executor.NewMockExecutor()
	m.Files[v148Login] = []byte("LOGIN_THRESHOLD=99\n")  // operator value
	m.Files[v148LoginBL] = []byte("LOGIN_THRESHOLD=5\n") // prior default
	entry, err := preserveOrStageConfig(m, []byte("LOGIN_THRESHOLD=7\n"), v148Login, 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry.Action != ConfigPreserved {
		t.Fatalf("module main.conf action = %q, want preserved", entry.Action)
	}
	if _, ok := m.WrittenFiles[v148Login]; ok {
		t.Errorf("module main.conf overwritten (must be preserved)")
	}
	if !bytes.Equal(m.WrittenFiles[v148Login+configSidecarSuffix], []byte("LOGIN_THRESHOLD=7\n")) {
		t.Errorf("module main.conf new default not in sidecar")
	}
}

// 5. Already equal to the new default -> no-op (unchanged), no rewrite.
func TestPreserveV148_AlreadyNewDefault_Unchanged(t *testing.T) {
	m := executor.NewMockExecutor()
	cur := []byte("KEY=same\n")
	m.Files[v148DDoS] = cur
	entry, err := preserveOrStageConfig(m, cur, v148DDoS, 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry.Action != ConfigUnchanged {
		t.Fatalf("action = %q, want unchanged", entry.Action)
	}
	if _, ok := m.WrittenFiles[v148DDoS]; ok {
		t.Errorf("dst rewritten when already equal to new default")
	}
}

// 6. NEGATIVE: a .conf.local destination is NEVER written by preserveOrStageConfig.
func TestPreserveV148_RefusesConfLocal(t *testing.T) {
	m := executor.NewMockExecutor()
	dst := "/etc/nftban/conf.d/rbl/main.conf.local"
	_, err := preserveOrStageConfig(m, []byte("anything"), dst, 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, ok := m.WrittenFiles[dst]; ok {
		t.Errorf(".conf.local destination was written — invariant #9 violated")
	}
	if _, ok := m.WrittenFiles[dst+configSidecarSuffix]; ok {
		t.Errorf("sidecar written for a .conf.local destination")
	}
}

// 7. No baseline yet (first v1.148 update): existing file differing from the new
// default is conservatively PRESERVED (never blind-overwritten).
func TestPreserveV148_NoBaseline_PreservesConservatively(t *testing.T) {
	m := executor.NewMockExecutor()
	m.Files[v148DDoS] = []byte("KEY=existing\n") // no baseline present
	entry, err := preserveOrStageConfig(m, []byte("KEY=new\n"), v148DDoS, 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry.Action != ConfigPreserved {
		t.Fatalf("action = %q, want preserved (conservative, no baseline)", entry.Action)
	}
	if _, ok := m.WrittenFiles[v148DDoS]; ok {
		t.Errorf("existing file overwritten with no baseline to prove it unmodified")
	}
}
