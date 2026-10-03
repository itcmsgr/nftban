// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="botscan_matcher_prefilter_runtime_v1234_test" meta:type="test" meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:inventory.files="prefilter_runtime_v1234_test.go"
// meta:inventory.binaries="bash"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/botscanmatch"
)

// TestPrefilter_ShellBuiltFileThroughGoMatcher drives the RUNTIME load chain end to end:
// the shell scanner loads the shipped rules from $NFTBAN_LIB_DIR/data plus the operator
// directory, builds the prefilter file (nftban_botscan_build_prefilter: anchor relaxing,
// quoted UA entries such as `"-"$`), and this binary reads that file (loadPatterns) and
// compiles it (botscanmatch.Compile). The botscanmatch package tests read the shipped
// pattern files directly and never see the shell's transformations; the shell arm S7
// (botscan_detection_correctness_v1234_test) checks the same file with grep -E only.
// v1.234: before the matcher anchor fix, a prefilter that actually filters dropped
// detection lines; this arm fails if the production engine drops any of them.
func TestPrefilter_ShellBuiltFileThroughGoMatcher(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash not available: the shell-built prefilter cannot be produced (NOT a pass): %v", err)
	}
	lib, err := filepath.Abs(filepath.Join("..", "..", "cli", "lib", "nftban"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(lib, "core", "nftban_botscan.sh")); err != nil {
		t.Fatalf("scanner module missing: %v", err)
	}
	tmp := t.TempDir()
	opDir := filepath.Join(tmp, "patterns.d")
	dataDir := filepath.Join(tmp, "data")
	for _, d := range []string{opDir, dataDir} {
		if err := os.MkdirAll(d, 0o750); err != nil {
			t.Fatal(err)
		}
	}
	pf := filepath.Join(tmp, "prefilter.ere")

	script := `set -uo pipefail
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh" >/dev/null 2>&1 || { echo "source failed" >&2; exit 3; }
nftban_botscan_load_config || exit 4
nftban_botscan_load_patterns || exit 5
nftban_botscan_build_prefilter "$PF" || exit 6`
	cmd := exec.Command(bash, "-c", script) // #nosec G204 -- fixed script, test-only
	// Production-shaped load: shipped rules from $NFTBAN_LIB_DIR/data/botscan_*.patterns,
	// an empty operator surface (BOTSCAN_PATTERNS_DIR), no /etc configuration.
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"LC_ALL=C",
		"NFTBAN_LIB_DIR=" + lib,
		"NFTBAN_DATA_DIR=" + dataDir,
		"BOTSCAN_PATTERNS_DIR=" + opDir,
		"NFTBAN_CONFIG_DIR=" + filepath.Join(tmp, "nonexistent"),
		"PF=" + pf,
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("shell prefilter build failed: %v\n%s", err, out)
	}

	patterns, err := loadPatterns(pf)
	if err != nil {
		t.Fatalf("loadPatterns(%s): %v", pf, err)
	}
	// Non-vacuity: the shipped set yields well over 100 prefilter entries; a handful means the
	// shipped rules were not loaded and the arm would prove nothing.
	if len(patterns) < 100 {
		t.Fatalf("prefilter has %d entries; the shipped rules were not loaded", len(patterns))
	}
	m, err := botscanmatch.Compile(patterns)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if sk := m.Skipped(); len(sk) > 0 {
		t.Logf("skipped %d RE2-incompatible prefilter entr(y/ies): %v", len(sk), sk)
	}

	line := func(method, path, status, ua string) string {
		return fmt.Sprintf(`45.33.32.99 - - [30/Sep/2026:08:00:00 +0000] "%s %s HTTP/1.1" %s 5 "-" "%s"`, method, path, status, ua)
	}
	ordinary := []string{
		line("GET", "/about-us/", "200", "Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0"),
		line("GET", "/feeds/items.xml", "200", "FeedSync/3.1 -"),
		line("POST", "/contact/send", "200", "Mozilla/5.0 Chrome/140"),
	}
	detections := []string{
		line("GET", "/cal.ics", "200", "-"), // SINGLE_DASH via the quoted `"-"$` entry
		line("GET", "/", "200", "sqlmap/1.7"),
		line("GET", "/.git/config", "404", "x"),
		line("GET", "/wp-json/wp/v2/users/7", "200", "x"),
		line("GET", "/nope.html", "404", "x"),
		line("GET", "/actuator/env", "200", "x"),
	}
	for _, l := range detections {
		if !m.MatchLine([]byte(l)) {
			t.Errorf("Go matcher DROPPED a detection line (false negative): %s", l)
		}
	}
	for _, l := range ordinary {
		if m.MatchLine([]byte(l)) {
			t.Errorf("Go matcher kept an ordinary line (prefilter does not filter): %s", l)
		}
	}

	// Filter (the streamed path the scanner uses) agrees with MatchLine.
	var in strings.Builder
	for _, l := range append(append([]string{}, ordinary...), detections...) {
		in.WriteString(l + "\n")
	}
	var out strings.Builder
	if err := m.Filter(strings.NewReader(in.String()), &out); err != nil {
		t.Fatalf("Filter: %v", err)
	}
	if got := strings.Count(out.String(), "\n"); got != len(detections) {
		t.Errorf("Filter kept %d lines, want %d (the detection lines only)", got, len(detections))
	}
}
