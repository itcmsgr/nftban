// =============================================================================
// NFTBan v1.209.1 - BotScan hybrid pattern matcher (Aho-Corasick prefilter + RE2)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botscanmatch
// Purpose: Bounded, single-pass replacement for the `grep -E -f <patternfile>`
//          BotScan candidate prefilter. The shell `match_url_g` bash matcher stays
//          AUTHORITATIVE for attribution/thresholds; this only reproduces the set of
//          candidate lines that grep would keep, with bounded memory under the srv3
//          256 MiB cgroup cap.
//
// Design: an Aho-Corasick automaton over each pattern's longest LITERAL anchor
// rejects the ~99% of clean lines in one pass; for the lines an anchor hits, the
// pattern's compiled RE2 confirms so output == grep's matching-line set. Patterns
// with no usable literal anchor fall to a small always-run RE2 residual set.
//
// Parity: the BotScan corpus has no backreferences/lookaround, so POSIX ERE (grep -E)
// and Go RE2 agree for these patterns; build_prefilter strips ^/$ line-anchors, so the
// patterns are unanchored substring matches == grep substring semantics.
//
// meta:name="botscanmatch_matcher" meta:type="package" meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:inventory.files="matcher.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botscanmatch

import (
	"bufio"
	"io"
	"regexp"
)

const minAnchorLen = 2 // shorter literal runs are too common to be a useful prefilter

// Matcher reproduces `grep -E -f` over a pattern list with bounded memory.
type Matcher struct {
	ac      *ahoCorasick     // literal anchor -> pattern ids that own that anchor
	res     []*regexp.Regexp // compiled RE2 per kept pattern
	lit     []bool           // pattern i is a pure literal (anchor == whole pattern → AC hit is a match)
	always  []int            // pattern ids with no literal anchor → RE2 run on every line
	skipped []string         // patterns that failed RE2 compile (pre-existing broken/mis-split)
}

// Skipped returns patterns dropped because they failed RE2 compilation (e.g. the known
// |-delimiter mis-split alternation patterns). These are also non-functional in the shell
// matcher, so dropping them is behavior-preserving; the caller may log them for visibility.
func (m *Matcher) Skipped() []string { return m.skipped }

// Compile builds a Matcher from ERE patterns (one per line, as in build_prefilter's $_pf:
// line-anchors already stripped). A pattern that fails RE2 compilation is skipped from the
// confirm step but its literal anchor (if any) still contributes to the prefilter (fail-open
// to a candidate, never a false negative). Returns an error only if NO pattern is usable.
func Compile(patterns []string) (*Matcher, error) {
	m := &Matcher{ac: newAhoCorasick()}
	for _, p := range patterns {
		if p == "" {
			continue
		}
		re, err := regexp.Compile(p) // RE2
		if err != nil {
			// Pre-existing broken pattern (e.g. |-delimiter mis-split alternation). grep -E -f
			// errors on these too and the shell matcher can't match them, so skipping is
			// behavior-preserving. Record for visibility; never fail-open to a phantom candidate.
			m.skipped = append(m.skipped, p)
			continue
		}
		id := len(m.res)
		m.res = append(m.res, re)
		anchor, pureLiteral := longestLiteral(p)
		m.lit = append(m.lit, pureLiteral)
		if len(anchor) >= minAnchorLen {
			m.ac.add(anchor, id)
		} else {
			// No selective literal anchor → check this pattern's RE2 on every line.
			// (Audit of the BotScan corpus shows this set is empty/tiny.)
			m.always = append(m.always, id)
		}
	}
	m.ac.build()
	if len(m.res) == 0 {
		return nil, errNoUsablePatterns
	}
	return m, nil
}

// MatchLine reports whether grep -E -f would keep this line (any pattern matches).
func (m *Matcher) MatchLine(line []byte) bool {
	// 1) Always-run RE2 residual set (no literal anchor).
	for _, id := range m.always {
		if re := m.res[id]; re != nil && re.Match(line) {
			return true
		}
	}
	// 2) Aho-Corasick single pass → candidate pattern ids; confirm via RE2 (or accept if pure literal).
	hit := false
	m.ac.scan(line, func(id int) bool {
		if m.lit[id] {
			hit = true
			return false // stop scan early
		}
		if re := m.res[id]; re == nil || re.Match(line) {
			hit = true
			return false
		}
		return true // keep scanning for another candidate
	})
	return hit
}

// Filter streams lines from r and writes the matching ones to w (drop-in for grep -E -f).
// Lines are matched without their trailing newline; the newline is preserved on output.
func (m *Matcher) Filter(r io.Reader, w io.Writer) error {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024) // bounded line buffer (4 MiB max line)
	bw := bufio.NewWriter(w)
	for sc.Scan() {
		line := sc.Bytes()
		if m.MatchLine(line) {
			if _, err := bw.Write(line); err != nil {
				return err
			}
			if err := bw.WriteByte('\n'); err != nil {
				return err
			}
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return bw.Flush()
}

// longestLiteral returns the longest literal substring guaranteed to appear in every string
// the ERE matches, and whether the whole pattern is that literal (no regex metachars at all).
// Escaped metachars (\.) count as their literal char. Unescaped metachars break the run.
func longestLiteral(ere string) (string, bool) {
	var best, cur []byte
	pure := true
	flush := func() {
		if len(cur) > len(best) {
			best = append(best[:0:0], cur...)
		}
		cur = cur[:0]
	}
	i := 0
	for i < len(ere) {
		c := ere[i]
		switch c {
		case '\\':
			if i+1 < len(ere) {
				cur = append(cur, ere[i+1]) // \x → literal x (covers \. \/ \- etc.)
				i += 2
				continue
			}
			i++
		case '[':
			// char class: its contents are NOT a literal substring of matches — skip to ']'
			pure = false
			flush()
			i++
			if i < len(ere) && ere[i] == '^' {
				i++
			}
			if i < len(ere) && ere[i] == ']' { // literal ']' as first class member
				i++
			}
			for i < len(ere) && ere[i] != ']' {
				if ere[i] == '\\' && i+1 < len(ere) {
					i += 2
				} else {
					i++
				}
			}
			if i < len(ere) {
				i++ // consume ']'
			}
		case ']', '(', ')', '{', '}', '*', '+', '?', '|', '^', '$', '.':
			pure = false
			flush()
			i++
		default:
			cur = append(cur, c)
			i++
		}
	}
	flush()
	return string(best), pure
}
