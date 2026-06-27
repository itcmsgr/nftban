// =============================================================================
// NFTBan v1.209.1 - nftban-botscan-matcher (BotScan candidate prefilter helper)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Purpose: Bounded-memory replacement for `grep -E -f <patternfile>` in the BotScan
//          shell scan loop. Reads candidate-prefilter patterns (one ERE per line, the
//          $_pf file build_prefilter writes), streams stdin, and emits the lines grep
//          would keep. The shell `match_url_g` bash matcher stays authoritative for
//          attribution; this helper only fixes the prefilter's CPU/memory cost
//          (srv3 256 MiB cgroup OOM). Does NOT own ban policy / write nft / write
//          source_index / change thresholds.
//
//   nftban-botscan-matcher --filter <patternfile>   < lines  > matching-lines
//   nftban-botscan-matcher --selftest               (CI smoke; exits 0/non-0)
//   nftban-botscan-matcher --version
//
// Exit codes: 0 ok; 2 usage; 3 pattern load/compile failure (caller should fall back to
// grep -E -f, never silently drop lines).
//
// meta:name="nftban-botscan-matcher" meta:type="binary" meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:inventory.files="main.go"
// meta:inventory.binaries="nftban-botscan-matcher"
// meta:inventory.env_vars="NFTBAN_BIN_DIR"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/botscanmatch"
)

const version = "1.0.0"

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}
	switch args[0] {
	case "--version", "-v":
		fmt.Println(version)
	case "--selftest":
		os.Exit(selftest())
	case "--check":
		// Validate the pattern file compiles to >=1 usable pattern WITHOUT touching stdin, so the
		// shell can pick helper-vs-passthrough once per cycle. Exit 0 = usable; 3 = unusable.
		if len(args) < 2 {
			usage()
			os.Exit(2)
		}
		os.Exit(runCheck(args[1]))
	case "--filter":
		if len(args) < 2 {
			usage()
			os.Exit(2)
		}
		os.Exit(runFilter(args[1]))
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: nftban-botscan-matcher --filter <patternfile> | --check <patternfile> | --selftest | --version")
}

// runCheck loads+compiles patterns and reports usability (no stdin). Exit 0 if >=1 usable.
func runCheck(patternFile string) int {
	patterns, err := loadPatterns(patternFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "nftban-botscan-matcher: read patterns %q: %v\n", patternFile, err)
		return 3
	}
	m, err := botscanmatch.Compile(patterns)
	if err != nil {
		fmt.Fprintf(os.Stderr, "nftban-botscan-matcher: compile patterns: %v\n", err)
		return 3
	}
	fmt.Fprintf(os.Stderr, "nftban-botscan-matcher: %d usable, %d skipped\n", len(patterns)-len(m.Skipped()), len(m.Skipped()))
	return 0
}

// runFilter loads patterns and streams stdin → stdout, emitting matching lines.
func runFilter(patternFile string) int {
	patterns, err := loadPatterns(patternFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "nftban-botscan-matcher: read patterns %q: %v\n", patternFile, err)
		return 3
	}
	m, err := botscanmatch.Compile(patterns)
	if err != nil {
		fmt.Fprintf(os.Stderr, "nftban-botscan-matcher: compile patterns: %v\n", err)
		return 3
	}
	if sk := m.Skipped(); len(sk) > 0 {
		// Visible, non-fatal: these are pre-existing RE2-incompatible (|-delimiter mis-split)
		// patterns, also dead in the shell matcher. Surfaced so they are not silent.
		fmt.Fprintf(os.Stderr, "nftban-botscan-matcher: skipped %d RE2-incompatible pattern(s): %v\n", len(sk), sk)
	}
	if err := m.Filter(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintf(os.Stderr, "nftban-botscan-matcher: filter: %v\n", err)
		return 1
	}
	return 0
}

func loadPatterns(path string) ([]string, error) {
	f, err := os.Open(filepath.Clean(path)) // #nosec G304 -- operator-owned prefilter file from build_prefilter
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 16*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r\n")
		if line == "" {
			continue
		}
		out = append(out, line)
	}
	return out, sc.Err()
}

// selftest is a hermetic CI smoke: a known pattern set keeps the right lines.
func selftest() int {
	m, err := botscanmatch.Compile([]string{`c99\.php`, `shell[0-9]*\.php`, ` 404 `})
	if err != nil {
		fmt.Fprintln(os.Stderr, "selftest: compile:", err)
		return 1
	}
	keep := []string{`GET /x/c99.php HTTP/1.1`, `GET /shell12.php`, `"GET /a" 404 12`}
	drop := []string{`GET /index.html`, `POST /wp-login.php 200`, `GET /shell.txt`}
	for _, l := range keep {
		if !m.MatchLine([]byte(l)) {
			fmt.Fprintf(os.Stderr, "selftest: expected KEEP: %q\n", l)
			return 1
		}
	}
	for _, l := range drop {
		if m.MatchLine([]byte(l)) {
			fmt.Fprintf(os.Stderr, "selftest: expected DROP: %q\n", l)
			return 1
		}
	}
	return 0
}
