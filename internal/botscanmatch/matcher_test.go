// SPDX-License-Identifier: MPL-2.0
// meta:name="botscanmatch_matcher_test" meta:type="test" meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:inventory.files="matcher_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""

package botscanmatch

import (
	"bufio"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// loadRealPatterns reads the shipped BotScan corpus the way build_prefilter does: field 2 of
// each `name|pattern|type|...` line, with ^/$ line-anchors stripped (match the field within a line).
func loadRealPatterns(t *testing.T) []string {
	t.Helper()
	dir := filepath.Join("..", "..", "etc", "nftban", "patterns.d", "botscan")
	files, err := filepath.Glob(filepath.Join(dir, "*.patterns"))
	if err != nil || len(files) == 0 {
		t.Skipf("no pattern files under %s (%v)", dir, err)
	}
	var out []string
	for _, fp := range files {
		f, err := os.Open(fp)
		if err != nil {
			t.Fatalf("open %s: %v", fp, err)
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			cols := strings.Split(line, "|")
			if len(cols) < 2 {
				continue
			}
			p := strings.TrimPrefix(cols[1], "^")
			p = strings.TrimSuffix(p, "$")
			if p != "" {
				out = append(out, p)
			}
		}
		f.Close()
	}
	return out
}

// naive models `grep -E -f`: any pattern's RE2 matches the line.
func naive(res []*regexp.Regexp, line string) bool {
	for _, re := range res {
		if re != nil && re.MatchString(line) {
			return true
		}
	}
	return false
}

// fixtureLines: malicious probes (should match), benign traffic + 404 lines, and lines built by
// embedding each pattern's literal anchor (AC-hit → RE2-confirm parity stress).
func fixtureLines(patterns []string) []string {
	lines := []string{
		`1.2.3.4 - - [x] "GET /wp-content/c99.php HTTP/1.1" 200 10 "-" "Mozilla"`,
		`1.2.3.4 - - [x] "GET /shell12.php HTTP/1.1" 404 0 "-" "x"`,
		`1.2.3.4 - - [x] "GET /index.html HTTP/1.1" 200 1000 "-" "Mozilla/5.0"`,
		`1.2.3.4 - - [x] "POST /wp-login.php HTTP/1.1" 200 500 "-" "Chrome"`,
		`1.2.3.4 - - [x] "GET /favicon.ico HTTP/1.1" 404 0 "-" "Safari"`,
		`1.2.3.4 - - [x] "GET /style.css HTTP/1.1" 200 2000 "-" "-"`,
		`1.2.3.4 - - [x] "GET /api/v1/users HTTP/1.1" 200 50 "-" "curl/7.1"`,
	}
	// Embed each pattern's literal anchor in a synthetic line so the AC fires; parity must hold
	// whether or not the full RE2 confirms.
	for _, p := range patterns {
		anc, _ := longestLiteral(p)
		if len(anc) >= minAnchorLen {
			lines = append(lines, `9.9.9.9 - - "GET /x`+anc+`y HTTP/1.1" 404 0 "-" "UA-`+anc+`"`)
		}
	}
	return lines
}

func TestParity_AgainstNaiveRE2_RealCorpus(t *testing.T) {
	patterns := loadRealPatterns(t)
	if len(patterns) == 0 {
		t.Fatal("no patterns loaded")
	}
	t.Logf("loaded %d real BotScan patterns", len(patterns))

	// Audit: classify RE2-incompatible patterns. The only expected ones are the pre-existing
	// |-delimiter mis-split alternation patterns (broken in the shell too); they must be SKIPPED,
	// not silently treated as matching. Any OTHER non-compiling pattern is a real regression.
	res := make([]*regexp.Regexp, len(patterns))
	var broken []string
	for i, p := range patterns {
		re, err := regexp.Compile(p)
		if err != nil {
			broken = append(broken, p)
		}
		res[i] = re
	}
	t.Logf("RE2-incompatible (pre-existing mis-split) patterns: %d %v", len(broken), broken)

	m, err := Compile(patterns)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	if len(m.Skipped()) != len(broken) {
		t.Errorf("matcher skipped %d patterns, audit found %d broken — mismatch", len(m.Skipped()), len(broken))
	}

	for _, line := range fixtureLines(patterns) {
		got := m.MatchLine([]byte(line))
		want := naive(res, line)
		if got != want {
			t.Errorf("PARITY MISMATCH got=%v want=%v line=%q", got, want, line)
		}
	}
}

func TestParity_EveryLiteralPatternMatchesItsOwnLine(t *testing.T) {
	patterns := loadRealPatterns(t)
	m, err := Compile(patterns)
	if err != nil {
		t.Fatalf("Compile: %v", err)
	}
	// For each pure-literal pattern (\. unescaped to .), a line containing that literal must be kept.
	for _, p := range patterns {
		anc, pure := longestLiteral(p)
		if !pure || len(anc) < minAnchorLen {
			continue
		}
		line := "GET /probe/" + anc + " HTTP/1.1"
		if !m.MatchLine([]byte(line)) {
			t.Errorf("literal pattern %q: own line not kept: %q", p, line)
		}
	}
}

func TestLongestLiteral(t *testing.T) {
	cases := []struct {
		in   string
		want string
		pure bool
	}{
		{`c99\.php`, "c99.php", true},
		{`shell[0-9]*\.php`, "shell", false},
		{`/[a-z]{2}\.php`, ".php", false},
		{`wso\.php`, "wso.php", true},
		{`(bak)`, "bak", false},
		{`abc`, "abc", true},
		{`[0-9]+`, "", false},
	}
	for _, c := range cases {
		got, pure := longestLiteral(c.in)
		if got != c.want || pure != c.pure {
			t.Errorf("longestLiteral(%q) = (%q,%v), want (%q,%v)", c.in, got, pure, c.want, c.pure)
		}
	}
}

func TestAhoCorasick_MultiAnchorSinglePass(t *testing.T) {
	m, err := Compile([]string{`c99\.php`, `r57\.php`, `wso\.php`})
	if err != nil {
		t.Fatal(err)
	}
	if !m.MatchLine([]byte("GET /a/r57.php?x=1")) {
		t.Error("suffix anchor r57.php should match")
	}
	if m.MatchLine([]byte("GET /a/safe.php")) {
		t.Error("non-anchor line should not match")
	}
}

func TestNoUsablePatterns(t *testing.T) {
	if _, err := Compile([]string{"", ""}); err == nil {
		t.Error("expected error for empty pattern set")
	}
}
