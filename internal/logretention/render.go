// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-render"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Deterministically renders an EffectivePolicy + family inventory into logrotate stanza text, per file (main | suricata), reproducing the corrected shipped mechanism (copytruncate vs rename+create, delaycompress only where a writer holds the rotated inode, su/create/olddir/USR2). No timestamps or nondeterminism — byte-identical for identical inputs, which the DEB≡RPM parity requirement depends on."
// meta:depends="none (stdlib)"
// meta:inventory.files="internal/logretention/render.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package logretention

import (
	"fmt"
	"sort"
	"strings"
)

// bytesToLogrotateSize formats a byte count as a logrotate size token. All caps
// are whole MiB (the calculator rounds to MiB), so emit "<n>M"; fall back to G
// for large values to keep the token short.
func bytesToLogrotateSize(b uint64) string {
	if b == 0 {
		b = minFamilySizeBytes
	}
	if b >= GiB && b%GiB == 0 {
		return fmt.Sprintf("%dG", b/GiB)
	}
	m := b / MiB
	if m == 0 {
		m = 1
	}
	return fmt.Sprintf("%dM", m)
}

// RenderFile renders all stanzas belonging to the given file ("main" or
// "suricata") as logrotate text, using the calculated per-family policy. Output
// is deterministic for identical (policy, fams) inputs.
func RenderFile(policy EffectivePolicy, fams []LogFamily, file string) string {
	byKey := make(map[string]FamilyPolicy, len(policy.Families))
	for _, fp := range policy.Families {
		byKey[fp.Key] = fp
	}
	var b strings.Builder
	for _, f := range fams {
		if f.File != file {
			continue
		}
		fp, ok := byKey[f.Key]
		if !ok {
			continue
		}
		renderStanza(&b, f, fp)
		b.WriteByte('\n')
	}
	return b.String()
}

func renderStanza(b *strings.Builder, f LogFamily, fp FamilyPolicy) {
	// One path per line, then the shared brace body — matches the shipped style.
	for i, p := range f.Paths {
		b.WriteString(p)
		if i < len(f.Paths)-1 {
			b.WriteByte('\n')
		}
	}
	b.WriteString(" {\n")
	if f.Su != "" {
		fmt.Fprintf(b, "    su %s\n", f.Su)
	}
	fmt.Fprintf(b, "    %s\n", f.Cadence)
	fmt.Fprintf(b, "    rotate %d\n", fp.RotateCount)
	sizeKey := "size"
	if f.UseMaxsize {
		sizeKey = "maxsize"
	}
	fmt.Fprintf(b, "    %s %s\n", sizeKey, bytesToLogrotateSize(fp.SizeCapBytes))
	b.WriteString("    compress\n")
	if f.Delaycompress {
		b.WriteString("    delaycompress\n")
	}
	b.WriteString("    missingok\n")
	b.WriteString("    notifempty\n")
	if f.Copytruncate {
		b.WriteString("    copytruncate\n")
	}
	if f.Create != "" {
		fmt.Fprintf(b, "    create %s\n", f.Create)
	}
	if f.Olddir != "" {
		fmt.Fprintf(b, "    olddir %s\n", f.Olddir)
	}
	if f.CreateOlddir != "" {
		fmt.Fprintf(b, "    createolddir %s\n", f.CreateOlddir)
	}
	if f.PostrotateUSR2 {
		b.WriteString("    postrotate\n")
		b.WriteString("        systemctl kill -s USR2 suricata.service >/dev/null 2>&1 || true\n")
		b.WriteString("    endscript\n")
	}
	b.WriteString("}\n")
}

// FilesRendered returns the sorted set of distinct File values in the inventory
// (e.g. ["main","suricata"]).
func FilesRendered(fams []LogFamily) []string {
	seen := map[string]bool{}
	for _, f := range fams {
		seen[f.File] = true
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
