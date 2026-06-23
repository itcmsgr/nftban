// =============================================================================
// NFTBan v1.199 - Installer Logger run-id correlation tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logger_runid_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-23"
// meta:description="v1.199 lifecycle forensics: verifies the installer Logger carries a run-id that (a) honors NFTBAN_RUN_ID so it matches the shell update path's per-run record id, (b) is generated <UTC compact>-<pid> when the env is unset, and (c) is stamped into the RUN header block written to installer.log."
// meta:input="Logger.New()/RunID()/RunHeader() over a t.TempDir() log file with NFTBAN_RUN_ID set/unset"
// meta:output="t.Error on missing/wrong run-id or missing header stamp"
// meta:depends="testing,os,path/filepath,strings"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_RUN_ID"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package logging

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunIDHonorsEnv(t *testing.T) {
	t.Setenv("NFTBAN_RUN_ID", "20260623T120000Z-pinned")
	l := New(filepath.Join(t.TempDir(), "installer.log"), false)
	t.Cleanup(l.Close)
	if got := l.RunID(); got != "20260623T120000Z-pinned" {
		t.Errorf("RunID() = %q, want the pinned NFTBAN_RUN_ID", got)
	}
}

func TestRunIDGeneratedWhenEnvUnset(t *testing.T) {
	t.Setenv("NFTBAN_RUN_ID", "")
	l := New(filepath.Join(t.TempDir(), "installer.log"), false)
	t.Cleanup(l.Close)
	got := l.RunID()
	if got == "" {
		t.Fatal("RunID() empty when NFTBAN_RUN_ID unset; want generated id")
	}
	// shape: <UTC compact ts>T...Z-<pid>
	if !strings.Contains(got, "Z-") {
		t.Errorf("generated RunID() = %q, want <UTC compact>-<pid> shape", got)
	}
}

func TestRunHeaderStampsRunID(t *testing.T) {
	t.Setenv("NFTBAN_RUN_ID", "20260623T120000Z-hdr")
	p := filepath.Join(t.TempDir(), "installer.log")
	l := New(p, false)
	l.RunHeader("v1.199.0", "update", "host1", "linux")
	l.Close()
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read installer.log: %v", err)
	}
	if !strings.Contains(string(data), "run_id=20260623T120000Z-hdr") {
		t.Errorf("RUN header missing run_id stamp; log:\n%s", data)
	}
}
