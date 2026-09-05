// =============================================================================
// NFTBan v1.73 - Installer System nftables.conf Integration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-render-sysconf"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Integrate NFTBan include into system nftables.conf"
// meta:inventory.files="internal/installer/render/sysconf.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package render

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// IncludeDependency classifies WHICH readiness authority an include write depends
// on. It is DELIBERATELY not inferred from the include path: keying safety off a
// literal path string would make the interlock depend on a second literal that a
// future edit could silently desynchronise from the guard.
//
// v1.229.13 Lane 3D.3 installs this interlock; Lane 3D.4 arms it by changing
// IncludeDirective and the shipping dependency together, atomically.
type IncludeDependency int

const (
	// IncludeDependencyLegacy — the included artifact does not depend on the
	// generated boot projection. This is the SHIPPING dependency as of 3D.3, and
	// boot-projection readiness is irrelevant to it.
	IncludeDependencyLegacy IncludeDependency = iota
	// IncludeDependencyBootProjection — the included artifact IS the generated
	// boot projection, so the include must not be written unless that projection
	// was established by the authoritative render in THIS run.
	IncludeDependencyBootProjection
)

func (d IncludeDependency) String() string {
	if d == IncludeDependencyBootProjection {
		return "BOOT_PROJECTION"
	}
	return "LEGACY"
}

// IncludeDirective is the line nftban adds to the distro nftables.conf so a
// plain `systemctl reload nftables.service` re-includes the nftban ruleset.
//
// v1.229.13 Lane 3D.4 — AUTHORITATIVE INCLUDE TRANSITION. Boot authority moved from
// the legacy runtime artifact to the VALIDATED generated boot projection. This
// constant and the shipping IncludeDependency in cmd/nftban-installer/phases.go
// changed TOGETHER, atomically: a tree carrying only one of the two transitions is
// invalid, and TestIncludeAuthorityTransitionIsAtomic fails on either half alone.
//
// ⛔ THIS IS THE ONLY ACTIVE BOOT AUTHORITY. See legacyIncludePath below.
const IncludeDirective = `include "/etc/nftban/generated/nftban-boot.nft"`

// legacyIncludePath is a MIGRATION MATCHER, NOT AN AUTHORITY.
//
// It exists so an upgraded host cannot end up carrying BOTH the legacy include and
// the generated one — two boot authorities is precisely the state this lane removes.
// The upgrader must still RECOGNISE and REMOVE the old line; recognising a retired
// literal is not the same as depending on it.
//
// ⛔ Structural authority checks must not count this as a second boot authority:
//
//	ACTIVE_LEGACY_INCLUDE_COUNT     = 0   (nothing includes this path any more)
//	LEGACY_MIGRATION_MATCHER_PRESENT = YES (this constant, used only for removal)
const legacyIncludePath = `"/etc/nftban/nftables.conf"`

// v1.146 PR Phase-D — fenced marker idempotency.
//
// Before v1.146 the writer emitted a bare comment + include with no end
// sentinel, and the purge remover used a loose case-sensitive `sed /nftban/d`.
// Result: the capitalised legacy comment ("# NFTBan firewall configuration")
// was orphaned and accumulated one line per install cycle, and there was no
// atomic way to remove exactly nftban's contribution.
//
// The fenced markers below bracket the managed region so both the writer
// (here) and the shell removers (deb postrm / rpm %postun) can strip exactly
// nftban's lines and nothing the operator added. Markers are lowercase so a
// stale pre-v1.146 `sed /nftban/d` from an older package still matches them.
// IncludeBeginMarker / IncludeEndMarker are the canonical sentinels; the shell
// scriptlets MUST match these byte-for-byte (drift-guarded by hermetic test).
const (
	IncludeBeginMarker = "# >>> nftban firewall include (managed; do not edit between markers) >>>"
	IncludeEndMarker   = "# <<< nftban firewall include (managed) <<<"

	// legacyComment is the unfenced comment emitted by pre-v1.146 writers.
	// stripNftbanInclude removes it (and any accumulated duplicates) so a
	// repair/upgrade self-heals an already-polluted distro file.
	legacyComment = "# NFTBan firewall configuration"
)

// fencedBlock is the exact managed region the writer emits.
func fencedBlock() string {
	return IncludeBeginMarker + "\n" + IncludeDirective + "\n" + IncludeEndMarker + "\n"
}

// stripNftbanInclude removes every nftban-owned line from a distro
// nftables.conf body, preserving all operator content. It removes:
//   - any fenced managed block (begin..end inclusive),
//   - standalone legacy comment lines ("# NFTBan firewall configuration"),
//   - standalone include directive lines for /etc/nftban/nftables.conf.
//
// It is the Go twin of the shell remover in packaging/deb/postrm and the RPM
// %postun. Idempotent: running it on already-clean content returns it
// unchanged. Pure function — unit-testable without an executor.
func stripNftbanInclude(content string) string {
	lines := strings.Split(content, "\n")
	out := make([]string, 0, len(lines))
	inFence := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		switch {
		case trimmed == IncludeBeginMarker:
			inFence = true
			continue
		case trimmed == IncludeEndMarker:
			inFence = false
			continue
		case inFence:
			continue
		case trimmed == legacyComment:
			continue
		// The generated (active) include OR the legacy one — the latter purely as a
		// migration matcher, so an upgrade cannot leave two boot authorities behind.
		case trimmed == IncludeDirective || strings.Contains(trimmed, legacyIncludePath) ||
			strings.Contains(trimmed, `"/etc/nftban/generated/nftban-boot.nft"`):
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// inetFilterEmptySkeleton reports whether a captured `table inet filter` block
// contains only structural declarations (table/chain/type/hook/policy/braces/
// comments) and no actual rules — i.e. the benign distro default accept-all
// skeleton. Mirrors the shell inet-filter classifier heuristic. Pure function.
func inetFilterEmptySkeleton(block []string) bool {
	for _, l := range block {
		t := strings.TrimSpace(l)
		if t == "" {
			continue
		}
		switch {
		case strings.HasPrefix(t, "table "),
			strings.HasPrefix(t, "chain "),
			strings.HasPrefix(t, "type "),
			strings.HasPrefix(t, "policy "),
			strings.HasPrefix(t, "#"),
			strings.HasPrefix(t, "{"),
			strings.HasPrefix(t, "}"):
			continue
		}
		return false // a rule line
	}
	return true
}

// neutralizeDistroSkeleton implements v1.146 Shape B (reboot-proven required by
// V146_BOOT_SUFFICIENCY_GATE2_REBOOT_PROOF_RECORD.md). It:
//   - comments out a bare `flush ruleset` so a `systemctl reload nftables.service`
//     cannot wipe the daemon-managed ip/ip6 nftban runtime tables, and
//   - removes the distro default EMPTY `table inet filter` skeleton (which would
//     shadow nftban blocking and trip the CVE-2025-NFTBAN-001 guard).
//
// A POPULATED, operator-owned `inet filter` table is preserved verbatim (never
// silently deleted) — symmetric with the shell classify-then-act policy. Pure
// function (log may be nil).
func neutralizeDistroSkeleton(content string, log *logging.Logger) string {
	lines := strings.Split(content, "\n")
	out := make([]string, 0, len(lines))
	for i := 0; i < len(lines); i++ {
		t := strings.TrimSpace(lines[i])

		if t == "flush ruleset" {
			out = append(out, "# flush ruleset  # neutralized by nftban (v1.146 Shape B): a flush here wipes daemon-managed ip/ip6 nftban runtime tables on reload (CVE-2025-NFTBAN-001 / lockout-safety)")
			if log != nil {
				log.Info("Shape B: neutralized distro `flush ruleset` in system nftables.conf")
			}
			continue
		}

		if strings.HasPrefix(t, "table inet filter") && strings.Contains(lines[i], "{") {
			depth := 0
			j := i
			for ; j < len(lines); j++ {
				depth += strings.Count(lines[j], "{") - strings.Count(lines[j], "}")
				if depth <= 0 {
					break
				}
			}
			if j >= len(lines) {
				j = len(lines) - 1
			}
			block := lines[i : j+1]
			if inetFilterEmptySkeleton(block) {
				out = append(out, "# table inet filter { ... }  # default empty skeleton removed by nftban (v1.146 Shape B): would shadow nftban blocking (CVE-2025-NFTBAN-001)")
				if log != nil {
					log.Info("Shape B: removed distro default empty `table inet filter` skeleton")
				}
				i = j
				continue
			}
			out = append(out, block...) // populated/operator-owned: preserve verbatim
			i = j
			if log != nil {
				log.Warn("Shape B: populated `table inet filter` preserved (operator-owned); review for nftban shadowing (CVE-2025-NFTBAN-001)")
			}
			continue
		}

		out = append(out, lines[i])
	}
	return strings.Join(out, "\n")
}

// IntegrateSystemConf renders exactly one fenced nftban include block into the
// system nftables.conf. It first strips any prior nftban contribution (legacy
// unfenced comment/include, duplicates, or an existing fenced block) so the
// result is always a single canonical block — self-healing an already-polluted
// file. Idempotent: when the file already contains exactly the canonical block
// and nothing stale, no write occurs (mtime preserved).
//
// v1.146 Shape B (reboot-proven): nftban KEEPS the distro include (the daemon
// recreates set structure via netlink but does NOT load the rendered SSH ports
// / @ssh_ports rate-limit rule — only `nft -f` via this include does, so
// removing it would silently drop v1.145 protection every reboot). In addition
// to the fenced include it neutralizes the distro skeleton (flush ruleset +
// default empty `table inet filter`) via neutralizeDistroSkeleton.
// dep declares what the include depends on; bootProjectionReady MUST come from the
// result of the authoritative boot-projection render in THIS run, never from
// file existence — a stale artifact from a previous run is exactly what this
// signal exists to distinguish (EXISTS != ESTABLISHED_THIS_RUN).
func IntegrateSystemConf(exec executor.Executor, nftConfPath string, dep IncludeDependency, bootProjectionReady bool, log *logging.Logger) error {
	// ⛔ PRE-MUTATION GATE. Refuse BEFORE reading, backing up or writing anything:
	// a post-hoc check is not a gate. When the include depends on the generated
	// boot projection and that projection was not established in this run, making
	// boot configuration point at it would produce a host whose boot include names
	// an artifact that is missing, stale or unvalidated.
	if dep == IncludeDependencyBootProjection && !bootProjectionReady {
		return fmt.Errorf("refusing to write the system include: dependency=%s but the boot "+
			"projection was not established in this run (bootProjectionReady=false); "+
			"boot configuration must not depend on an unestablished projection", dep)
	}
	if nftConfPath == "" {
		return fmt.Errorf("system nftables.conf path is empty")
	}
	if !exec.FileExists(nftConfPath) {
		log.Warn("system nftables.conf not found at %s — skipping integration", nftConfPath)
		return nil
	}

	data, err := exec.ReadFile(nftConfPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", nftConfPath, err)
	}
	original := string(data)

	// Normalise: strip any prior nftban lines (collapses accumulated
	// duplicate legacy comments and removes a previous fenced block), then
	// append exactly one fresh fenced block.
	// v1.146 Shape B: strip prior nftban lines, neutralize the distro skeleton
	// (flush ruleset + default empty inet filter), then append one fenced block.
	stripped := stripNftbanInclude(original)
	neutralized := neutralizeDistroSkeleton(stripped, log)
	if !strings.HasSuffix(neutralized, "\n") && neutralized != "" {
		neutralized += "\n"
	}
	updated := neutralized + fencedBlock()

	if updated == original {
		log.Debug("system nftables.conf already carries the canonical nftban include block")
		return nil
	}

	if err := exec.WriteFileAtomic(nftConfPath, []byte(updated), 0644); err != nil {
		return fmt.Errorf("write %s: %w", nftConfPath, err)
	}

	// Truthful log discriminator: "normalised" only when SOME nftban include was
	// already present — legacy (pre-transition host) or generated (re-apply).
	if strings.Contains(original, legacyIncludePath) ||
		strings.Contains(original, `"/etc/nftban/generated/nftban-boot.nft"`) {
		log.Info("normalised NFTBan include in %s (collapsed to one fenced block)", nftConfPath)
	} else {
		log.Info("added fenced NFTBan include block to %s", nftConfPath)
	}
	return nil
}

// DisarmSystemConf is the RESTORE-time inverse of IntegrateSystemConf: it strips
// the nftban-managed include (fenced block + legacy comment + any bare include
// line) from the distro nftables.conf, using the same drift-checked
// stripNftbanInclude logic. Once stripped, nftables.service can no longer
// `nft -f`-load /etc/nftban/nftables.conf and recreate the ip/ip6 nftban tables
// on boot.
//
// v1.148 (delta 2.1, SELECT_V148_RESTORE_SHAPE_B_INCLUDE_DISARM=yes). This is a
// restore-specific reversal of v1.146 Shape-B boot persistence — NOT a general
// Shape-B rollback; install/update still call IntegrateSystemConf normally.
// Idempotent (no-op when the include is already absent); backs up before
// editing; never deletes /etc/nftban/nftables.conf; leaves all non-nftban
// config intact (only nftban-owned lines are removed).
func DisarmSystemConf(exec executor.Executor, nftConfPath string, log *logging.Logger) error {
	if nftConfPath == "" || !exec.FileExists(nftConfPath) {
		return nil // nothing to disarm (idempotent)
	}
	data, err := exec.ReadFile(nftConfPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", nftConfPath, err)
	}
	original := string(data)
	stripped := stripNftbanInclude(original)
	if stripped == original {
		log.Info("RESTORE_SHAPE_B_INCLUDE_DISARMED: %s already free of the nftban include (idempotent no-op)", nftConfPath)
		return nil
	}
	// Back up before editing (operator-recoverable).
	backup := nftConfPath + ".nftban-restore.bak"
	if err := exec.WriteFileAtomic(backup, data, 0644); err != nil {
		log.Warn("could not back up %s before Shape-B include disarm: %v", nftConfPath, err)
	} else {
		log.Info("backed up %s -> %s before Shape-B include disarm", nftConfPath, backup)
	}
	if !strings.HasSuffix(stripped, "\n") && stripped != "" {
		stripped += "\n"
	}
	if err := exec.WriteFileAtomic(nftConfPath, []byte(stripped), 0644); err != nil {
		return fmt.Errorf("write %s: %w", nftConfPath, err)
	}
	log.Info("RESTORE_SHAPE_B_INCLUDE_DISARMED: removed nftban include from %s (backup %s); nftables.service can no longer recreate ip/ip6 nftban tables on boot", nftConfPath, backup)
	return nil
}
