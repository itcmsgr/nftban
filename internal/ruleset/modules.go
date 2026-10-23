// =============================================================================
// NFTBan - Ruleset content: live module objects carried through a replacement (v1.236 step B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ruleset-modules"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-23"
// meta:description="Step B of the one-transaction replacement (design V1236_STAGE2_DESIGN_DRAFT.md §2.1, owner decision 2026-10-23: preserve the live module objects). The schema does not declare module objects (ddos/portscan/botguard chains, their sets, meters, counters and the jumps into them); a schema-only load used to remove them until rebuild step 8 re-applied each module. Under the same LOCK_EX as the set-content read, the live table text is parsed, the objects owned by ENABLED modules are carried into the load file (set declarations without elements; their elements go through Render with remaining TTL and the never-ban authority), and every jump is placed before the same anchor rule it precedes in the live chain. Objects of disabled modules are not carried (as before). Anything that cannot be reconstructed safely is an error: the replacement is refused."
// meta:inventory.binaries="nft"
// meta:inventory.privileges="root (the live read)"
// =============================================================================

package ruleset

import (
	"bytes"
	"fmt"
	"os/exec"
	"regexp"
	"sort"
	"strings"
)

// moduleOwners maps object-name prefixes to the module that owns them. Module objects are
// never declared by the schema; ownership decides whether an object is carried.
var moduleOwners = []struct{ prefix, module string }{
	{"ddos_", "ddos"},
	{"connlimit_", "ddos"},
	{"portscan_", "portscan"},
	{"http_bot", "botguard"},
}

func moduleOf(name string) string {
	for _, o := range moduleOwners {
		if strings.HasPrefix(name, o.prefix) {
			return o.module
		}
	}
	return ""
}

// Jump is one rule in a schema chain that jumps into a carried module chain.
type Jump struct {
	Chain  string // schema chain holding the rule (e.g. input)
	Rule   string // rule text as listed by nft
	Anchor string // NFTBAN_ANCHOR token of the next anchor rule after it
}

// ModuleObjects are the carried module objects of one family.
type ModuleObjects struct {
	Family  string
	Blocks  []string // declarations (set elements stripped), kernel order
	Sets    []string // carried set names (elements via Render)
	Jumps   []Jump
	Skipped []string // module objects of modules that are not enabled (not carried)
}

type tblock struct {
	kind, name string
	lines      []string
}

var reBlockStart = regexp.MustCompile(`^\s*(set|map|chain|counter|quota|limit|flowtable|ct helper|ct timeout|ct expectation|synproxy|secmark)\s+(\S+)\s*\{`)
var reAnchor = regexp.MustCompile(`NFTBAN_ANCHOR:([A-Z0-9_]+)`)
var reJump = regexp.MustCompile(`^\s*(?:jump|goto)\s+(\S+)|\s(?:jump|goto)\s+(\S+)`)

// jumpTarget is the first jump/goto target of a rule line ("" if none). Text after
// `comment` is ignored, so a comment mentioning "jump" cannot hide or fake a jump.
func jumpTarget(line string) string {
	if i := strings.Index(line, " comment "); i >= 0 {
		line = line[:i]
	}
	m := reJump.FindStringSubmatch(line)
	if m == nil {
		return ""
	}
	if m[1] != "" {
		return m[1]
	}
	return m[2]
}

// parseTableBody returns the top-level object blocks of the `table <fam> nftban {` body in
// text (the full body; a one-line `table ... { }` is skipped).
func parseTableBody(text, fam string) ([]tblock, bool) {
	head := "table " + fam + " nftban {"
	var out []tblock
	in, found := false, false
	depth := 0
	var cur *tblock
	for _, line := range strings.Split(text, "\n") {
		t := strings.TrimSpace(line)
		if !in {
			if t == head {
				in, found, depth = true, true, 1
			}
			continue
		}
		opens, closes := strings.Count(line, "{"), strings.Count(line, "}")
		if cur == nil && depth == 1 {
			if m := reBlockStart.FindStringSubmatch(line); m != nil {
				cur = &tblock{kind: m[1], name: m[2]}
			}
		}
		if cur != nil {
			cur.lines = append(cur.lines, line)
		}
		depth += opens - closes
		if cur != nil && depth == 1 {
			out = append(out, *cur)
			cur = nil
		}
		if depth <= 0 {
			in = false // end of this table body (a second full body would restart)
		}
	}
	return out, found
}

// stripElements removes the `elements = { ... }` part of a set/map block.
func stripElements(lines []string) []string {
	var out []string
	skip, depth := false, 0
	for _, l := range lines {
		if !skip && strings.HasPrefix(strings.TrimSpace(l), "elements = {") {
			skip, depth = true, 0
		}
		if skip {
			depth += strings.Count(l, "{") - strings.Count(l, "}")
			if depth <= 0 {
				skip = false
			}
			continue
		}
		out = append(out, l)
	}
	return out
}

// ExtractModules decides the carried module objects of one family from the live table text
// and the schema text. enabled = effectively enabled modules (the shell module authority).
func ExtractModules(fam, live, schema string, enabled map[string]bool) (*ModuleObjects, error) {
	mo := &ModuleObjects{Family: fam}
	liveBlocks, ok := parseTableBody(live, fam)
	if !ok {
		return mo, nil // no live table: nothing to carry (fresh kernel)
	}
	schemaBlocks, ok := parseTableBody(schema, fam)
	if !ok {
		return nil, fmt.Errorf("schema has no full `table %s nftban {` body", fam)
	}
	declared := map[string]bool{}
	schemaChains := map[string]bool{}
	for _, b := range schemaBlocks {
		declared[b.kind+" "+b.name] = true
		if b.kind == "chain" {
			schemaChains[b.name] = true
		}
	}
	carriedChains := map[string]bool{}
	for _, b := range liveBlocks {
		if declared[b.kind+" "+b.name] {
			continue
		}
		mod := moduleOf(b.name)
		if mod == "" || !enabled[mod] {
			mo.Skipped = append(mo.Skipped, b.kind+" "+b.name)
			continue
		}
		lines := b.lines
		text := strings.Join(b.lines, "\n")
		switch {
		case b.kind == "map" && strings.Contains(text, "elements = {"):
			// No safe reconstruction for map elements here: refuse rather than drop them.
			return nil, fmt.Errorf("%s map %s carries elements — not reconstructable, replacement refused", fam, b.name)
		case b.kind == "set" && strings.Contains(text, "dynamic"):
			// A meter (filled from the packet path, per-element rate state): declared empty;
			// its state resets, as accepted for meters (design §8).
			lines = stripElements(lines)
		case b.kind == "set":
			// Elements are carried through Render (remaining TTL, never-ban authority).
			lines = stripElements(lines)
			mo.Sets = append(mo.Sets, b.name)
		}
		if b.kind == "chain" {
			carriedChains[b.name] = true
		}
		mo.Blocks = append(mo.Blocks, strings.Join(lines, "\n"))
	}
	// Jumps from schema chains into carried module chains, with the anchor that follows them.
	for _, b := range liveBlocks {
		if b.kind != "chain" || !schemaChains[b.name] {
			continue
		}
		var pending []Jump
		for _, l := range b.lines {
			if tgt := jumpTarget(l); tgt != "" && carriedChains[tgt] {
				pending = append(pending, Jump{Chain: b.name, Rule: strings.TrimSpace(l)})
				continue
			}
			if a := reAnchor.FindStringSubmatch(l); a != nil && len(pending) > 0 {
				for _, j := range pending {
					j.Anchor = a[1]
					mo.Jumps = append(mo.Jumps, j)
				}
				pending = nil
			}
		}
		if len(pending) > 0 {
			return nil, fmt.Errorf("%s %s: jump %q has no anchor rule after it — cannot be placed in the replacement", fam, b.name, pending[0].Rule)
		}
	}
	return mo, nil
}

// Compose returns the load file: the schema with the generation marker and the carried module
// objects inside each full table body, each jump inserted before its anchor rule (the
// in-batch equivalent of `insert rule ... position <anchor>`), followed by content (the
// `add element` statements from Render). Every jump must be placed, or it is an error.
func Compose(schema, nonce string, mods []*ModuleObjects, content string) (string, error) {
	byFam := map[string]*ModuleObjects{}
	for _, m := range mods {
		byFam[m.Family] = m
	}
	placed := map[*Jump]bool{}
	var out strings.Builder
	var fam, chain string
	depth := 0
	for _, line := range strings.Split(schema, "\n") {
		t := strings.TrimSpace(line)
		if depth == 0 {
			for _, f := range []string{"ip", "ip6"} {
				if t == "table "+f+" nftban {" {
					fam = f
				}
			}
		}
		if fam != "" && depth == 1 {
			if m := reBlockStart.FindStringSubmatch(line); m != nil && m[1] == "chain" {
				chain = m[2]
			}
		}
		if fam != "" && chain != "" && depth == 2 {
			if a := reAnchor.FindStringSubmatch(line); a != nil && byFam[fam] != nil {
				indent := line[:len(line)-len(strings.TrimLeft(line, " \t"))]
				mo := byFam[fam]
				for i := range mo.Jumps {
					j := &mo.Jumps[i]
					if j.Chain == chain && j.Anchor == a[1] && !placed[j] {
						out.WriteString(indent + j.Rule + "\n")
						placed[j] = true
					}
				}
			}
		}
		out.WriteString(line + "\n")
		opens, closes := strings.Count(line, "{"), strings.Count(line, "}")
		depth += opens - closes
		if fam != "" && depth == 1 && t == "table "+fam+" nftban {" {
			out.WriteString("    comment \"nftban-gen=" + nonce + "\"\n")
			if mo := byFam[fam]; mo != nil {
				for _, b := range mo.Blocks {
					out.WriteString(b + "\n")
				}
			}
		}
		if depth == 1 && closes > opens {
			chain = ""
		}
		if depth == 0 {
			fam, chain = "", ""
		}
	}
	for _, m := range mods {
		for i := range m.Jumps {
			if !placed[&m.Jumps[i]] {
				j := m.Jumps[i]
				return "", fmt.Errorf("%s %s: anchor %s for %q not found in the schema — cannot be placed", m.Family, j.Chain, j.Anchor, j.Rule)
			}
		}
	}
	return strings.TrimRight(out.String(), "\n") + "\n" + content, nil
}

// NftTableText reads `nft list table <fam> nftban` (text). A missing table is "" (nothing
// to carry); any other failure is an error.
func NftTableText(fam string) (string, error) {
	cmd := exec.Command("nft", "list", "table", fam, "nftban") // #nosec G204 -- fixed table
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if strings.Contains(stderr.String(), "No such file or directory") {
			return "", nil
		}
		return "", fmt.Errorf("nft list table %s nftban: %v: %s", fam, err, strings.TrimSpace(stderr.String()))
	}
	return string(out), nil
}

// SortedSkipped is a stable report of the module objects not carried.
func (m *ModuleObjects) SortedSkipped() []string {
	s := append([]string(nil), m.Skipped...)
	sort.Strings(s)
	return s
}
