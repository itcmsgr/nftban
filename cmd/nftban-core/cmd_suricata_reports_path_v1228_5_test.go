// SPDX-License-Identifier: MPL-2.0
package main

// v1.228.5 FHS — focused proof for the Suricata analytics reports path.
//
// The defect: initAnalyticsIfNeeded built its reports directory as dataDir+"/reports",
// so the Suricata analytics writer RECREATED /var/lib/nftban/reports at runtime after
// postinstall had migrated that tree to /var/log/nftban/reports. main.go already derived
// the same argument from LogDir, so the two writers disagreed.
//
// This asserts BEHAVIOUR, not a literal:
//   - getSuricataPaths returns the configured LogDir and DataDir unchanged
//   - the state-class analytics directory is created under DataDir  (NOT relocated to /var/log)
//   - the operational reports directory is created under LogDir
//   - the pre-migration operational path is NOT created
//
// It deliberately does NOT assert a broad "nothing under /var/lib/nftban/reports" rule:
// reports/{baseline,watchdog,archive,auditors} legitimately live there as state.
//
// BOUNDARY: this cannot invoke initAnalyticsIfNeeded() itself. That function calls
// nftbanconf.MustLoad(), whose Load() is a sync.Once singleton bound to the const
// DefaultConfigFile (/etc/nftban/nftban.conf) and cannot be redirected in-process. The
// second test therefore binds the CALL SITE to the same expression this test exercises, so
// the behavioural proof cannot silently drift from production. The EL9 package-native
// runtime gate remains the authority for the real execution path.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/analytics"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

func mustBeDir(t *testing.T, path, why string) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("%s: expected directory %s, got error: %v", why, path, err)
	}
	if !fi.IsDir() {
		t.Fatalf("%s: expected %s to be a directory", why, path)
	}
}

func mustNotExist(t *testing.T, path, why string) {
	t.Helper()
	if _, err := os.Stat(path); err == nil {
		t.Fatalf("%s: %s exists but must NOT have been created", why, path)
	} else if !os.IsNotExist(err) {
		t.Fatalf("%s: unexpected error stat-ing %s: %v", why, path, err)
	}
}

func TestSuricataAnalyticsPathsV1228_5(t *testing.T) {
	tmp := t.TempDir()
	dataDir := filepath.Join(tmp, "var", "lib", "nftban")
	logDir := filepath.Join(tmp, "var", "log", "nftban")

	cfg := &nftbanconf.Config{DataDir: dataDir, LogDir: logDir}

	_, _, gotLogDir, gotDataDir := getSuricataPaths(cfg)
	if gotDataDir != dataDir {
		t.Fatalf("getSuricataPaths dataDir = %q, want %q", gotDataDir, dataDir)
	}
	if gotLogDir != logDir {
		t.Fatalf("getSuricataPaths logDir = %q, want %q", gotLogDir, logDir)
	}

	// The exact expression the production call site uses (bound by the test below).
	if err := analytics.Init(gotDataDir, gotLogDir+"/reports"); err != nil {
		t.Fatalf("analytics.Init: %v", err)
	}

	mustBeDir(t, filepath.Join(dataDir, "analytics"),
		"analytics STATE must stay under DataDir")
	mustBeDir(t, filepath.Join(logDir, "reports"),
		"operational reports must be created under LogDir")
	mustNotExist(t, filepath.Join(dataDir, "reports"),
		"the pre-migration operational reports path must NOT be recreated")
}

func TestSuricataInitCallSiteBindsLogDirV1228_5(t *testing.T) {
	const file = "cmd_suricata_status.go"
	raw, err := os.ReadFile(file)
	if err != nil {
		t.Fatalf("read %s: %v", file, err)
	}

	// GUARD SUBJECT == GUARD INPUT: strip line comments so the explanatory comment above
	// the call (which names dataDir while describing the OLD defect) can neither satisfy
	// nor violate this assertion.
	var code []string
	for _, line := range strings.Split(string(raw), "\n") {
		if i := strings.Index(line, "//"); i >= 0 {
			line = line[:i]
		}
		code = append(code, line)
	}
	src := strings.Join(code, "\n")

	if !strings.Contains(src, `analytics.Init(dataDir, logDir+"/reports")`) {
		t.Fatalf("%s: analytics.Init must derive its reports argument from logDir; "+
			"the behavioural test above proves that expression and would otherwise drift", file)
	}
	if strings.Contains(src, `dataDir+"/reports"`) {
		t.Fatalf("%s: reports path is rebuilt from dataDir — this is the v1.228.5 defect", file)
	}
}
