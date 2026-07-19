// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-inventory-parity-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="R8: canonical-inventory parity. Binds the THREE otherwise-driftable authorities — DefaultFamilies() (Go, what the generator renders from), the shipped static logrotate templates (install/config/nftban{,-suricata}.logrotate), and nftbanconf.LogInventory() (the FHS log authority). Fails if any path/cadence/rotate/size/copytruncate/delaycompress disagrees, if a template stanza has no family, or if a LogInventory /var/log/nftban entry is not covered by a family with matching rotation+retain."
// meta:inventory.files="internal/logretention/inventory.go,install/config/nftban.logrotate,install/config/nftban-suricata.logrotate,internal/nftbanconf/logs.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="install/config/nftban.logrotate,install/config/nftban-suricata.logrotate"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package logretention

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

type stanzaPolicy struct {
	cadence       string
	rotate        int
	sizeBytes     uint64
	copytruncate  bool
	delaycompress bool
	su            string // Z5: "su <user> <group>" args ("" = absent)
	create        string // "create <mode> <user> <group>" args ("" = absent)
	olddir        string // "olddir <dir>" arg ("" = absent)
	createolddir  string // "createolddir <mode> <user> <group>" args ("" = absent)
	postrotate    bool   // Z5: a postrotate block is present (USR2 reintroduction vector)
}

var reStanza = regexp.MustCompile(`(?s)([^{}]*?)\{([^{}]*)\}`)

// parseLogrotate parses a logrotate file into path -> stanzaPolicy. Z5: parsing
// is LINE-BASED so multi-argument directives (su/create/olddir) keep their
// argument boundaries, and postrotate blocks are detected directly.
func parseLogrotate(t *testing.T, path string) map[string]stanzaPolicy {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	// strip comments so braces in comments don't confuse the parser
	var clean strings.Builder
	for _, line := range strings.Split(string(data), "\n") {
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		clean.WriteString(line)
		clean.WriteString("\n")
	}
	out := map[string]stanzaPolicy{}
	for _, m := range reStanza.FindAllStringSubmatch(clean.String(), -1) {
		header, body := m[1], m[2]
		sp := stanzaPolicy{}
		for _, line := range strings.Split(body, "\n") {
			fields := strings.Fields(line)
			if len(fields) == 0 {
				continue
			}
			switch fields[0] {
			case "daily", "weekly", "monthly":
				sp.cadence = fields[0]
			case "copytruncate":
				sp.copytruncate = true
			case "delaycompress":
				sp.delaycompress = true
			case "postrotate":
				sp.postrotate = true
			case "rotate":
				if len(fields) > 1 {
					sp.rotate, _ = strconv.Atoi(fields[1])
				}
			case "size", "maxsize":
				if len(fields) > 1 {
					sp.sizeBytes = parseSizeToken(fields[1])
				}
			case "su":
				sp.su = strings.Join(fields[1:], " ")
			case "create":
				sp.create = strings.Join(fields[1:], " ")
			case "olddir":
				sp.olddir = strings.Join(fields[1:], " ")
			case "createolddir":
				sp.createolddir = strings.Join(fields[1:], " ")
			}
		}
		for _, p := range strings.Fields(header) {
			if strings.HasPrefix(p, "/var/") {
				out[p] = sp
			}
		}
	}
	return out
}

func parseSizeToken(s string) uint64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	unit := s[len(s)-1]
	mult := uint64(1)
	num := s
	switch unit {
	case 'k', 'K':
		mult = KiB
		num = s[:len(s)-1]
	case 'M':
		mult = MiB
		num = s[:len(s)-1]
	case 'G':
		mult = GiB
		num = s[:len(s)-1]
	}
	n, err := strconv.ParseUint(num, 10, 64)
	if err != nil {
		return 0
	}
	return n * mult
}

// isGlobPath reports whether the final path element contains a glob metacharacter.
func isGlobPath(p string) bool {
	return strings.ContainsAny(filepath.Base(p), "*?[")
}

// matchTemplateStanza finds the template stanza owning a family path, returning
// the covered template key. Z4: a LITERAL (non-glob) family path requires an
// EXACT template stanza — there is NO same-directory fallback, so a literal path
// can never be silently satisfied by an unrelated sibling stanza (which would
// mask real drift). Only a GLOB family path (e.g. reports/*.html) may match a
// concrete enumerated template key, and then only via a precise filepath.Match —
// never a loose directory prefix.
func matchTemplateStanza(stanzas map[string]stanzaPolicy, p string) (stanzaPolicy, string, bool) {
	if sp, ok := stanzas[p]; ok { // exact (works for literals AND for glob==glob templates)
		return sp, p, true
	}
	if !isGlobPath(p) {
		return stanzaPolicy{}, "", false // literal path: exact-or-nothing
	}
	for tp, tsp := range stanzas {
		if ok, err := filepath.Match(p, tp); err == nil && ok {
			return tsp, tp, true
		}
	}
	return stanzaPolicy{}, "", false
}

func repoRoot(t *testing.T) string {
	t.Helper()
	wd, _ := os.Getwd() // .../internal/logretention
	return filepath.Clean(filepath.Join(wd, "..", ".."))
}

func TestInventoryParityFamiliesVsTemplates(t *testing.T) {
	root := repoRoot(t)
	main := parseLogrotate(t, filepath.Join(root, "install/config/nftban.logrotate"))
	suri := parseLogrotate(t, filepath.Join(root, "install/config/nftban-suricata.logrotate"))

	covered := map[string]bool{}
	for _, f := range DefaultFamilies() {
		stanzas := main
		if f.File == "suricata" {
			stanzas = suri
		}
		for _, p := range f.Paths {
			sp, key, ok := matchTemplateStanza(stanzas, p)
			if !ok {
				t.Errorf("family %s path %s has NO matching logrotate stanza", f.Key, p)
				continue
			}
			covered[key] = true
			if sp.cadence != f.Cadence {
				t.Errorf("%s: cadence template=%s family=%s", p, sp.cadence, f.Cadence)
			}
			if sp.rotate != f.BaseRotate {
				t.Errorf("%s: rotate template=%d family=%d", p, sp.rotate, f.BaseRotate)
			}
			if sp.sizeBytes != f.BaseSizeBytes {
				t.Errorf("%s: size template=%d family=%d", p, sp.sizeBytes, f.BaseSizeBytes)
			}
			if sp.copytruncate != f.Copytruncate {
				t.Errorf("%s: copytruncate template=%v family=%v", p, sp.copytruncate, f.Copytruncate)
			}
			if sp.delaycompress != f.Delaycompress {
				t.Errorf("%s: delaycompress template=%v family=%v", p, sp.delaycompress, f.Delaycompress)
			}
			// Z5: bind su/create/olddir/createolddir and the postrotate block, so a
			// template can never drift from the generator on the mechanism fields —
			// in particular a reintroduced Suricata USR2 postrotate block would fail.
			if sp.su != f.Su {
				t.Errorf("%s: su template=%q family=%q", p, sp.su, f.Su)
			}
			if sp.create != f.Create {
				t.Errorf("%s: create template=%q family=%q", p, sp.create, f.Create)
			}
			if sp.olddir != f.Olddir {
				t.Errorf("%s: olddir template=%q family=%q", p, sp.olddir, f.Olddir)
			}
			if sp.createolddir != f.CreateOlddir {
				t.Errorf("%s: createolddir template=%q family=%q", p, sp.createolddir, f.CreateOlddir)
			}
			if sp.postrotate != f.PostrotateUSR2 {
				t.Errorf("%s: postrotate template=%v family.PostrotateUSR2=%v (Suricata USR2 reintroduction?)", p, sp.postrotate, f.PostrotateUSR2)
			}
		}
	}
	// no orphan template stanza (every template path must belong to a family)
	for _, stanzas := range []map[string]stanzaPolicy{main, suri} {
		for p := range stanzas {
			if !covered[p] {
				t.Errorf("logrotate stanza %s has NO owning family (drift)", p)
			}
		}
	}
}

func TestInventoryParityFamiliesVsLogInventory(t *testing.T) {
	// every /var/log/nftban LogInventory entry must be covered by a family with the
	// same rotation + retain (BaseRotate). This binds the FHS log authority to the
	// retention inventory so a family cannot silently diverge from LogInventory().
	famByAbs := map[string]LogFamily{}
	for _, f := range DefaultFamilies() {
		for _, p := range f.Paths {
			famByAbs[p] = f
		}
	}
	for _, lp := range nftbanconf.LogInventory() {
		abs := "/var/log/nftban/" + lp.Name
		f, ok := famByAbs[abs]
		if !ok {
			// LogInventory may list logs outside /var/log/nftban or not size-managed
			// here; only enforce coverage for main/suricata template logs.
			if lp.Template == nftbanconf.TemplateMain || lp.Template == nftbanconf.TemplateSuricata {
				t.Errorf("LogInventory %q (%s) not covered by any retention family", lp.Name, lp.Rotation)
			}
			continue
		}
		if f.Cadence != lp.Rotation {
			t.Errorf("%s: cadence family=%s LogInventory=%s", abs, f.Cadence, lp.Rotation)
		}
		if f.BaseRotate != lp.Retain {
			t.Errorf("%s: rotate family=%d LogInventory.Retain=%d", abs, f.BaseRotate, lp.Retain)
		}
	}
}

// Z4: the parity matcher must not let a literal family path be satisfied by an
// unrelated same-directory sibling (the old prefix-fallback escape), and ghost
// paths must never match. Glob paths still match a concrete enumeration precisely.
func TestMatchTemplateStanzaNoLiteralEscape(t *testing.T) {
	stanzas := map[string]stanzaPolicy{
		"/var/log/nftban/bans.log":             {cadence: "daily", rotate: 7},
		"/var/log/nftban/audit.log":            {cadence: "daily", rotate: 30},
		"/var/lib/nftban/reports/2026-07.html": {cadence: "monthly", rotate: 3},
		"/var/lib/nftban/reports/2026-07.txt":  {cadence: "monthly", rotate: 3},
	}

	// exact literal -> matched on its own key.
	if sp, key, ok := matchTemplateStanza(stanzas, "/var/log/nftban/bans.log"); !ok || key != "/var/log/nftban/bans.log" || sp.rotate != 7 {
		t.Errorf("exact literal match failed: ok=%v key=%s", ok, key)
	}

	// literal with NO exact stanza but a same-dir sibling present -> MUST NOT match
	// (this is the Z4 escape being closed).
	if _, _, ok := matchTemplateStanza(stanzas, "/var/log/nftban/ghost.log"); ok {
		t.Error("literal ghost path was matched by a same-dir sibling (Z4 prefix-escape not closed)")
	}

	// a set of randomized ghost literal paths in the same dirs must all miss.
	for _, ghost := range []string{
		"/var/log/nftban/x1.log", "/var/log/nftban/portscan-x.log",
		"/var/lib/nftban/reports/notaglob.md", "/var/log/nftban/audit.log.1",
	} {
		if _, _, ok := matchTemplateStanza(stanzas, ghost); ok {
			t.Errorf("ghost literal %q must not match any stanza", ghost)
		}
	}

	// glob path matches a concrete enumeration precisely (fallback still works)...
	if _, key, ok := matchTemplateStanza(stanzas, "/var/lib/nftban/reports/*.html"); !ok || key != "/var/lib/nftban/reports/2026-07.html" {
		t.Errorf("glob path should match the concrete .html enumeration, got ok=%v key=%s", ok, key)
	}
	// ...but a glob must NOT match a different extension in the same dir.
	if _, key, _ := matchTemplateStanza(stanzas, "/var/lib/nftban/reports/*.json"); key == "/var/lib/nftban/reports/2026-07.txt" {
		t.Error("glob *.json incorrectly matched a .txt sibling (loose prefix, not precise Match)")
	}
}

// Z6: the semantic class map must be COMPLETE and PINNED. Every family is
// classified explicitly (no silent OPERATIONAL default), every map key
// corresponds to a real family (no orphan keys), the ENFORCEMENT_AUDIT and
// SECURITY_EVENT sets are frozen (a downgrade to a weaker class or a deletion
// fails), and the self-bounded update-run logs (run.jsonl/human.log/installer.log)
// are classified LIFECYCLE_FORENSICS.
func TestSemanticClassMapCompleteAndPinned(t *testing.T) {
	fams := DefaultFamilies()
	classMap := semanticClassMap()

	famKeys := map[string]bool{}
	for _, f := range fams {
		famKeys[f.Key] = true
	}

	// completeness: every family is explicitly classified (no silent default).
	for _, f := range fams {
		if _, ok := classMap[f.Key]; !ok {
			t.Errorf("family %q is not explicitly classified in semanticClassMap (silent OPERATIONAL default)", f.Key)
		}
	}
	// no orphan keys: every map key corresponds to a real family.
	for k := range classMap {
		if !famKeys[k] {
			t.Errorf("semanticClassMap has orphan key %q (no such family)", k)
		}
	}

	// PINNED sets — a downgrade (class change) or deletion (silent default) moves a
	// key out of these sets and fails. Update these deliberately when the inventory
	// legitimately changes.
	got := map[string][]string{}
	for k, c := range classMap {
		got[c.class] = append(got[c.class], k)
	}
	assertSet(t, "ENFORCEMENT_AUDIT", got[ClassEnforcementAudit], []string{"audit", "bans"})
	assertSet(t, "SECURITY_EVENT", got[ClassSecurityEvent], []string{
		"permissions-audit", "security-audit", "suri-eve-alerts", "suri-eve-audit", "suri-fast", "suricata-events",
	})

	// self-bounded update-run logs are classified LIFECYCLE_FORENSICS.
	want := map[string]bool{"run.jsonl": false, "human.log": false, "installer.log": false}
	for _, sb := range SelfBoundedForensicLogs() {
		if sb.SemanticClass != ClassLifecycle {
			t.Errorf("self-bounded %s class=%s, want LIFECYCLE_FORENSICS", sb.Path, sb.SemanticClass)
		}
		if sb.BoundedBy == "" {
			t.Errorf("self-bounded %s missing BoundedBy mechanism", sb.Path)
		}
		for name := range want {
			if strings.HasSuffix(sb.Path, "/"+name) {
				want[name] = true
			}
		}
	}
	for name, seen := range want {
		if !seen {
			t.Errorf("update-run forensic log %q not classified in SelfBoundedForensicLogs", name)
		}
	}
}

func assertSet(t *testing.T, label string, got, want []string) {
	t.Helper()
	gs := append([]string(nil), got...)
	ws := append([]string(nil), want...)
	sort.Strings(gs)
	sort.Strings(ws)
	if strings.Join(gs, ",") != strings.Join(ws, ",") {
		t.Errorf("%s set drift:\n  got=  %v\n  want= %v", label, gs, ws)
	}
}

func TestSemanticClassificationAndEnforcementFloor(t *testing.T) {
	valid := map[string]bool{
		ClassEnforcementAudit: true, ClassSecurityEvent: true, ClassModuleHighVolume: true,
		ClassLifecycle: true, ClassOperational: true, ClassDebug: true,
	}
	for _, f := range DefaultFamilies() {
		if !valid[f.SemanticClass] {
			t.Errorf("family %s has invalid/empty semantic class %q", f.Key, f.SemanticClass)
		}
	}
	// bans + audit are the enforcement source-of-truth
	byKey := map[string]LogFamily{}
	for _, f := range DefaultFamilies() {
		byKey[f.Key] = f
	}
	for _, k := range []string{"bans", "audit"} {
		if byKey[k].SemanticClass != ClassEnforcementAudit || !byKey[k].Primary {
			t.Errorf("%s should be ENFORCEMENT_AUDIT + authoritative, got %s primary=%v", k, byKey[k].SemanticClass, byKey[k].Primary)
		}
	}

	// R11/ENFORCEMENT_FORENSIC_FLOOR: enforcement + security families keep their
	// forensic floor even under an aggressively low operator MaxDays.
	disk := DiskFacts{TotalBytes: 100 * GiB, AvailBytes: 80 * GiB}
	p, err := Calculate(disk, ClassifyProfile(disk, false, ""), Overrides{MaxDays: 3}, DefaultFamilies())
	if err != nil {
		t.Fatal(err)
	}
	for _, fp := range p.Families {
		lf := byKey[fp.Key]
		if lf.SemanticClass == ClassEnforcementAudit || lf.SemanticClass == ClassSecurityEvent {
			if fp.RetentionDays < lf.FloorDays {
				t.Errorf("%s (%s): MaxDays=3 cut retention %dd below forensic floor %dd", fp.Key, lf.SemanticClass, fp.RetentionDays, lf.FloorDays)
			}
			if fp.SemanticClass != lf.SemanticClass {
				t.Errorf("%s: FamilyPolicy semantic class %q != family %q", fp.Key, fp.SemanticClass, lf.SemanticClass)
			}
		}
	}
}
