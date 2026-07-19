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
}

var reStanza = regexp.MustCompile(`(?s)([^{}]*?)\{([^{}]*)\}`)

// parseLogrotate parses a logrotate file into path -> stanzaPolicy.
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
		for _, f := range strings.Fields(body) {
			switch f {
			case "daily", "weekly", "monthly":
				sp.cadence = f
			case "copytruncate":
				sp.copytruncate = true
			case "delaycompress":
				sp.delaycompress = true
			}
		}
		sp.rotate = intDirective(body, "rotate")
		sp.sizeBytes = sizeDirective(body)
		for _, p := range strings.Fields(header) {
			if strings.HasPrefix(p, "/var/") {
				out[p] = sp
			}
		}
	}
	return out
}

func intDirective(body, key string) int {
	fields := strings.Fields(body)
	for i, f := range fields {
		if f == key && i+1 < len(fields) {
			if n, err := strconv.Atoi(fields[i+1]); err == nil {
				return n
			}
		}
	}
	return 0
}

func sizeDirective(body string) uint64 {
	fields := strings.Fields(body)
	for i, f := range fields {
		if (f == "size" || f == "maxsize") && i+1 < len(fields) {
			return parseSizeToken(fields[i+1])
		}
	}
	return 0
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
			// glob report paths in the template are not enumerated per-file; match by prefix
			sp, ok := stanzas[p]
			if !ok {
				// report globs use "*.html" etc — match a template key with the same dir prefix
				matched := false
				for tp, tsp := range stanzas {
					if strings.HasPrefix(tp, filepath.Dir(p)+"/") {
						sp, matched = tsp, true
						covered[tp] = true
						break
					}
				}
				if !matched {
					t.Errorf("family %s path %s has NO logrotate stanza", f.Key, p)
					continue
				}
			} else {
				covered[p] = true
			}
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
