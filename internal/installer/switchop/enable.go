// =============================================================================
// NFTBan v1.75.1 - Installer nftables Service Enable
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-enable"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Enable and start nftables service with xt-compat pre-check"
// meta:inventory.files="internal/installer/switchop/enable.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftables.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// EnableNftables enables and starts the nftables service, then verifies.
// Runs cleanXtCompat() first to remove stale xt target rules that would
// prevent nftables from starting (common on CSF/cPanel servers).
func EnableNftables(exec executor.Executor, distro *detect.DistroInfo, log *logging.Logger) error {
	if distro != nil {
		cleanXtCompat(exec, distro, log)
	}

	if err := exec.ServiceEnable("nftables"); err != nil {
		log.Warn("enable nftables: %v", err)
	}
	if err := exec.ServiceStart("nftables"); err != nil {
		return fmt.Errorf("start nftables: %w", err)
	}
	if !exec.ServiceActive("nftables") {
		return fmt.Errorf("nftables service not active after start")
	}
	log.Info("nftables service enabled and active")
	return nil
}

// cleanXtCompat detects and removes stale xt target / xtables compat rules
// from the system nftables.conf. These rules come from CSF/cPanel iptables-nft
// translation and cause `nft -f` to fail, preventing nftables.service from starting.
//
// Logic translated from cli/lib/nftban/helpers/autoheal.sh:378-414.
func cleanXtCompat(exec executor.Executor, distro *detect.DistroInfo, log *logging.Logger) {
	confPath := distro.NftConfPath
	if confPath == "" {
		log.Debug("no system nftables.conf path — skipping xt-compat check")
		return
	}
	if !exec.FileExists(confPath) {
		log.Debug("system nftables.conf not found at %s — skipping xt-compat check", confPath)
		return
	}

	// Dry-run validate the config
	res := exec.Run("nft", "-c", "-f", confPath)
	if res.ExitCode == 0 {
		log.Debug("system nftables.conf validates cleanly — no xt-compat issues")
		return
	}

	// Check if the failure is due to xt target / xtables compat rules
	combined := res.Stdout + "\n" + res.Stderr
	if !strings.Contains(combined, "xt target") && !strings.Contains(combined, "xtables compat") {
		log.Debug("nftables.conf validation failed but not due to xt-compat: %s",
			strings.TrimSpace(res.Stderr))
		return
	}

	log.Warn("detected incompatible xt target rules in %s", confPath)

	// =========================================================================
	// v1.229.12 P12-FPA — THIS NO LONGER REPLACES THE FILE.
	//
	// It used to overwrite confPath wholesale with a heredoc containing a bare
	// unfenced `include "/etc/nftban/nftables.conf"`. Three defects:
	//
	//   1. It DESTROYED every operator rule in the distro file. A timestamped
	//      backup is not preservation — the running configuration was gone.
	//   2. It wrote an UNFENCED include, invisible to render.IntegrateSystemConf
	//      (which owns the fenced BEGIN/END block) and to the deb postrm / rpm
	//      %postun remover, so uninstall could not remove it.
	//   3. It ran in phaseSwitch, AFTER phasePrepare had already written the
	//      canonical fenced block — so on this path it DELETED IntegrateSystemConf's
	//      work and substituted a competing include naming the legacy path.
	//
	// It now neutralises ONLY the offending lines. nft reports the line number of
	// each error, so those lines are commented out and everything else — operator
	// rules and NFTBan's managed fenced block alike — is preserved byte for byte.
	// The result is re-validated before it is published, and abandoned if it did
	// not actually help.
	//
	// ⛔ DO NOT REINSTATE A WHOLESALE REWRITE, AND DO NOT WRITE AN INCLUDE HERE.
	// The managed include has exactly one owner: render.IntegrateSystemConf.
	// =========================================================================
	data, err := exec.ReadFile(confPath)
	if err != nil {
		log.Warn("cannot read %s: %v", confPath, err)
		return
	}

	bad := offendingLines(combined)
	if len(bad) == 0 {
		log.Warn("xt-compat detected in %s but nft reported no line numbers — NOT modifying the file", confPath)
		log.Warn("  remove the xt target rules manually, then: systemctl restart nftables.service")
		return
	}

	lines := strings.Split(string(data), "\n")
	neutralised := 0
	for _, ln := range bad {
		i := ln - 1
		if i < 0 || i >= len(lines) || strings.HasPrefix(strings.TrimSpace(lines[i]), "#") {
			continue
		}
		lines[i] = "# " + lines[i] + "  # neutralized by nftban: xt target/xtables compat is unsupported by nftables.service"
		neutralised++
	}
	if neutralised == 0 {
		log.Warn("xt-compat lines in %s were already commented — NOT modifying the file", confPath)
		return
	}
	candidate := strings.Join(lines, "\n")

	// Validate the CANDIDATE before publishing it. A neutralisation that does not
	// actually fix the parse must not be written: it would edit an operator's file
	// for no benefit.
	tmpPath := fmt.Sprintf("%s.nftban-xt-candidate.%s", confPath, time.Now().Format("20060102150405"))
	if err := exec.WriteFileAtomic(tmpPath, []byte(candidate), 0644); err != nil {
		log.Warn("cannot stage xt-compat candidate: %v", err)
		return
	}
	check := exec.Run("nft", "-c", "-f", tmpPath)
	if check.ExitCode != 0 {
		exec.Run("rm", "-f", tmpPath)
		log.Warn("neutralising %d xt line(s) did not make %s valid — file left UNCHANGED", neutralised, confPath)
		log.Warn("  nft: %s", strings.TrimSpace(check.Stderr))
		return
	}

	// Keep a backup, then publish the minimally-edited file.
	backupPath := fmt.Sprintf("%s.xt-backup.%s", confPath, time.Now().Format("20060102150405"))
	if err := exec.WriteFileAtomic(backupPath, data, 0644); err != nil {
		log.Warn("cannot write backup %s — refusing to edit %s: %v", backupPath, confPath, err)
		exec.Run("rm", "-f", tmpPath)
		return
	}
	if err := exec.WriteFileAtomic(confPath, []byte(candidate), 0644); err != nil {
		log.Warn("cannot write %s: %v", confPath, err)
		exec.Run("rm", "-f", tmpPath)
		return
	}
	exec.Run("rm", "-f", tmpPath)
	log.Info("neutralized %d xt target line(s) in %s (backup %s); all other content preserved",
		neutralised, confPath, backupPath)
}

// nftErrorLineRe matches the line number in an nft diagnostic, e.g.
// "/etc/nftables.conf:12:1-20: Error: ...". Group 1 is the line number.
var nftErrorLineRe = regexp.MustCompile(`(?m)^[^\s:]*:(\d+):\d+`)

// offendingLines extracts the 1-based line numbers nft complained about, in
// ascending order and deduplicated. Pure function — unit-testable without an
// executor, which is the point: the neutraliser edits an operator's file, so the
// part that decides WHICH lines to touch must be testable in isolation.
func offendingLines(nftOutput string) []int {
	seen := map[int]bool{}
	out := []int{}
	for _, m := range nftErrorLineRe.FindAllStringSubmatch(nftOutput, -1) {
		n, err := strconv.Atoi(m[1])
		if err != nil || n <= 0 || seen[n] {
			continue
		}
		seen[n] = true
		out = append(out, n)
	}
	sort.Ints(out)
	return out
}
