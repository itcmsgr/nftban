// =============================================================================
// NFTBan - Logrotate `create` parity test (v1.139 PR-B, FHS-UNGEN-LOGROTATE-CREATE)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logs_logrotate_create_parity_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-28"
// meta:description="v1.139 PR-B bridge: asserts every `create MODE OWNER GROUP` directive in install/config/{nftban,nftban-suricata}.logrotate matches the corresponding `file_permissions` entry in build/fhs-spec.yaml that carries `logrotate_create: true`. Closes the FHS-UNGEN-LOGROTATE-CREATE drift surface called out by the v1.139 re-challenge (the logrotate create modes were hand-authored with no generator or parity test; a future fhs-spec mode/owner change could silently leave the logrotate `create` lines pointing at the stale identity)."
// meta:input="build/fhs-spec.yaml, install/config/nftban.logrotate, install/config/nftban-suricata.logrotate"
// meta:output="None"
// meta:depends="testing,os,path/filepath,strings,fmt,gopkg.in/yaml.v3"
// meta:inventory.files="build/fhs-spec.yaml,install/config/nftban.logrotate,install/config/nftban-suricata.logrotate"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// This is the v1.139 PR-B sibling of the v1.137 B-12 drift test
// (logs_logrotate_drift_test.go). That test asserts the LogInventory() Go
// authority is covered by the logrotate templates with matching frequency +
// retain. This test asserts that the same logrotate templates' `create` lines
// (the third axis — file-create mode/owner/group at rotation time) match the
// fhs-spec.yaml authority. Both bridges together lock the logrotate templates
// to the canonical sources of truth (LogInventory for the WHICH/HOW-OFTEN, and
// fhs-spec.yaml for the WHO/WHAT-PERMS of the recreated file).
// =============================================================================

package nftbanconf

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

// filePermAuthority is one fhs-spec.yaml `file_permissions` entry that carries
// `logrotate_create: true` — i.e. governs a logrotate `create` directive.
type filePermAuthority struct {
	Path            string `yaml:"path"`
	Pattern         string `yaml:"pattern"`
	Mode            string `yaml:"mode"`
	Owner           string `yaml:"owner"`
	Group           string `yaml:"group"`
	Recursive       bool   `yaml:"recursive,omitempty"`
	Exclude         string `yaml:"exclude,omitempty"`
	LogrotateCreate bool   `yaml:"logrotate_create,omitempty"`
}

type fhsSpec struct {
	FilePermissions []filePermAuthority `yaml:"file_permissions"`
}

// createPolicy is the `create MODE OWNER GROUP` triple from one logrotate stanza.
// Mode is the literal as written (e.g. "0640") to match how fhs-spec.yaml stores it.
type createPolicy struct {
	mode  string
	owner string
	group string
	// sourceFile + sourceLine for diagnostic output on failure.
	sourceFile string
	sourceLine int
}

// parseLogrotateCreates reads a logrotate config file and returns a map of
// stanza-path → createPolicy. Each `create MODE OWNER GROUP` directive inside
// a `{ … }` block is associated with every path that begins that stanza's
// path list. Multi-path stanzas (one path per line ending with the last on the
// "{" line) are handled the same way as parseLogrotate() in the v1.137 test.
// Only nftban-prefixed paths (/var/log/nftban/…) are captured; comments and
// blanks are ignored.
func parseLogrotateCreates(t *testing.T, path string) map[string]createPolicy {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	const prefix = "/var/log/nftban/"
	out := map[string]createPolicy{}
	lines := strings.Split(string(data), "\n")
	var pending []string
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.Contains(line, "{") {
			before := strings.TrimSpace(strings.SplitN(line, "{", 2)[0])
			if before != "" {
				pending = append(pending, strings.Fields(before)...)
			}
			var pol createPolicy
			pol.sourceFile = path
			for i++; i < len(lines); i++ {
				d := strings.TrimSpace(lines[i])
				if strings.HasPrefix(d, "}") {
					break
				}
				if strings.HasPrefix(d, "create ") {
					var m, o, g string
					if _, err := fmt.Sscanf(d, "create %s %s %s", &m, &o, &g); err == nil {
						pol.mode = m
						pol.owner = o
						pol.group = g
						pol.sourceLine = i + 1
					}
				}
			}
			for _, p := range pending {
				if strings.HasPrefix(p, prefix) && pol.mode != "" {
					out[p] = pol
				}
			}
			pending = nil
			continue
		}
		pending = append(pending, strings.Fields(line)...)
	}
	return out
}

// loadFhsSpecAuthorities reads build/fhs-spec.yaml, extracts the file_permissions
// entries whose `logrotate_create: true` flag is set, and returns them. These
// are the authoritative source for logrotate `create` mode/owner/group.
func loadFhsSpecAuthorities(t *testing.T) []filePermAuthority {
	t.Helper()
	root := repoRoot(t)
	data, err := os.ReadFile(filepath.Join(root, "build", "fhs-spec.yaml"))
	if err != nil {
		t.Fatalf("read fhs-spec.yaml: %v", err)
	}
	var spec fhsSpec
	if err := yaml.Unmarshal(data, &spec); err != nil {
		t.Fatalf("unmarshal fhs-spec.yaml: %v", err)
	}
	var out []filePermAuthority
	for _, e := range spec.FilePermissions {
		if e.LogrotateCreate {
			out = append(out, e)
		}
	}
	return out
}

// matchAuthority returns the longest-path-prefix authority whose `exclude`
// (if set) does NOT match the stanza path. Returns nil if no authority covers
// the stanza path.
func matchAuthority(stanzaPath string, auths []filePermAuthority) *filePermAuthority {
	var best *filePermAuthority
	bestLen := -1
	for i := range auths {
		a := &auths[i]
		if !strings.HasPrefix(stanzaPath, a.Path+"/") && stanzaPath != a.Path {
			continue
		}
		// Honor exclude: a stanza under the excluded subtree does NOT match this entry.
		if a.Exclude != "" && (strings.HasPrefix(stanzaPath, a.Exclude+"/") || stanzaPath == a.Exclude) {
			continue
		}
		if len(a.Path) > bestLen {
			bestLen = len(a.Path)
			best = a
		}
	}
	return best
}

// TestLogrotateCreateMatchesFhsSpecAuthorities is the v1.139 PR-B parity
// assertion: every logrotate `create` line in both packaged logrotate
// templates must match the fhs-spec.yaml `file_permissions` authority for the
// stanza's path (longest-prefix match, honoring `exclude`). Fails on drift.
func TestLogrotateCreateMatchesFhsSpecAuthorities(t *testing.T) {
	root := repoRoot(t)
	auths := loadFhsSpecAuthorities(t)
	if len(auths) == 0 {
		t.Fatal("fhs-spec.yaml has zero file_permissions entries with logrotate_create: true — PR-B expects at least two (/var/log/nftban and /var/log/nftban/suricata)")
	}

	mainCreates := parseLogrotateCreates(t, filepath.Join(root, "install", "config", "nftban.logrotate"))
	suriCreates := parseLogrotateCreates(t, filepath.Join(root, "install", "config", "nftban-suricata.logrotate"))

	allCreates := map[string]createPolicy{}
	for k, v := range mainCreates {
		allCreates[k] = v
	}
	for k, v := range suriCreates {
		allCreates[k] = v
	}
	if len(allCreates) == 0 {
		t.Fatal("parsed zero logrotate stanzas with `create` directives — fixture broken")
	}

	for path, pol := range allCreates {
		auth := matchAuthority(path, auths)
		if auth == nil {
			t.Errorf("DRIFT: logrotate stanza %q (%s:%d, create %s %s %s) has no matching `logrotate_create: true` authority in build/fhs-spec.yaml",
				path, pol.sourceFile, pol.sourceLine, pol.mode, pol.owner, pol.group)
			continue
		}
		if pol.mode != auth.Mode || pol.owner != auth.Owner || pol.group != auth.Group {
			t.Errorf("DRIFT: logrotate stanza %q (%s:%d) has `create %s %s %s` — fhs-spec authority %q says `%s %s %s`",
				path, pol.sourceFile, pol.sourceLine, pol.mode, pol.owner, pol.group,
				auth.Path, auth.Mode, auth.Owner, auth.Group)
		}
	}
}

// TestLogrotateCreateAuthorityIsReached asserts that every fhs-spec.yaml entry
// flagged `logrotate_create: true` is actually reached by at least one stanza
// — otherwise the authority is dead metadata (no logrotate file depends on it).
func TestLogrotateCreateAuthorityIsReached(t *testing.T) {
	root := repoRoot(t)
	auths := loadFhsSpecAuthorities(t)

	all := map[string]createPolicy{}
	for k, v := range parseLogrotateCreates(t, filepath.Join(root, "install", "config", "nftban.logrotate")) {
		all[k] = v
	}
	for k, v := range parseLogrotateCreates(t, filepath.Join(root, "install", "config", "nftban-suricata.logrotate")) {
		all[k] = v
	}

	for _, a := range auths {
		hit := false
		for path := range all {
			if matchAuthority(path, []filePermAuthority{a}) != nil {
				hit = true
				break
			}
		}
		if !hit {
			t.Errorf("UNREACHED: fhs-spec.yaml file_permissions entry %q has logrotate_create:true but NO logrotate stanza in either template covers a path under it — dead authority", a.Path)
		}
	}
}

// TestLogrotateCreateNftbanLogsOnly asserts that the v1.139 PR-B-flagged
// authorities are exactly the two intended log roots (/var/log/nftban and
// /var/log/nftban/suricata) — guards against accidental over-application of
// the logrotate_create flag to non-log surfaces like /etc/nftban.
func TestLogrotateCreateNftbanLogsOnly(t *testing.T) {
	auths := loadFhsSpecAuthorities(t)
	const logRoot = "/var/log/nftban"
	for _, a := range auths {
		if a.Path != logRoot && !strings.HasPrefix(a.Path, logRoot+"/") {
			t.Errorf("OUT-OF-SCOPE: logrotate_create:true entry %q is outside %s — v1.139 PR-B intentionally scopes this flag to log roots only", a.Path, logRoot)
		}
	}
}
