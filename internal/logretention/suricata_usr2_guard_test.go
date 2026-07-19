// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-suricata-usr2-guard-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Z5 DIRECT guard against reintroducing the Suricata eve USR2 postrotate reopen (the R1 regression: USR2 is a live RULE reload, not a log reopen, so rename+create+USR2 strands the held eve fd). Asserts (1) no LogFamily sets PostrotateUSR2; (2) the GENERATED suricata policy contains no USR2 and no postrotate block; (3) every Suricata eve family uses copytruncate (the correct held-fd mechanism). Complements the fail-closed real-logrotate behavioral proof in the shell suite and the su/create/olddir/postrotate template-parity binding."
// meta:inventory.files="internal/logretention/inventory.go,internal/logretention/render.go"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.binaries=""
// meta:inventory.privileges="none"
package logretention

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSuricataNoUSR2Reintroduction(t *testing.T) {
	// (1) DIRECT field guard: no family may set PostrotateUSR2. This is the field
	// the render turns into a `postrotate ... systemctl kill -s USR2 ...` block.
	for _, f := range DefaultFamilies() {
		if f.PostrotateUSR2 {
			t.Errorf("family %s sets PostrotateUSR2=true — USR2 is a rule reload, not a log reopen (R1 regression)", f.Key)
		}
	}

	// (2) RENDER guard: generate the real policy and inspect the suricata file.
	dir := t.TempDir()
	if _, err := Generate(baseOpts(dir)); err != nil {
		t.Fatalf("Generate: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "logrotate.d", "nftban-suricata"))
	if err != nil {
		t.Fatalf("read generated suricata policy: %v", err)
	}
	s := string(data)
	if strings.Contains(s, "USR2") {
		t.Error("generated suricata policy contains USR2 (reintroduced reopen block)")
	}
	if strings.Contains(s, "postrotate") || strings.Contains(s, "endscript") {
		t.Error("generated suricata policy contains a postrotate/endscript block")
	}
	if !strings.Contains(s, "copytruncate") {
		t.Error("generated suricata policy missing copytruncate (correct held-fd mechanism)")
	}

	// (3) every Suricata eve family uses copytruncate and does NOT request USR2.
	byKey := map[string]LogFamily{}
	for _, f := range DefaultFamilies() {
		byKey[f.Key] = f
	}
	for _, k := range []string{"suri-eve-alerts", "suri-eve-audit", "suri-eve-stats"} {
		f, ok := byKey[k]
		if !ok {
			t.Errorf("expected eve family %q missing from inventory", k)
			continue
		}
		if !f.Copytruncate {
			t.Errorf("eve family %s must use copytruncate (held-fd writer), Copytruncate=false", k)
		}
		if f.PostrotateUSR2 {
			t.Errorf("eve family %s must NOT set PostrotateUSR2", k)
		}
	}
}
