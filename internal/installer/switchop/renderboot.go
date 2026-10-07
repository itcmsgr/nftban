// =============================================================================
// NFTBan v1.229.13 - Installer Boot Projection Render (P12-FPA port, Lane 3C)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-renderboot"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-28"
// meta:description="Generate the persistent boot projection BEFORE the managed distro include is pointed at it. Delegates to the shell render authority via the CLI, the same canonical installer->shell interface switchop.Rebuild already uses."
// meta:inventory.files="internal/installer/switchop/renderboot.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// RenderBoot runs "nftban firewall render-boot", which renders the canonical
// package-owned schema, validates it with nft -c, and publishes it atomically to
// the boot projection path. It does NOT load a ruleset.
//
// WHY THIS EXISTS SEPARATELY FROM Rebuild:
// render.IntegrateSystemConf must not point the distro include at an artifact
// that does not exist yet, and it runs in phasePrepare — before nftables is
// enabled and before the SSH-safety invariants of `rebuild` hold. Rebuild both
// renders AND loads, so it cannot be moved that early. This renders only.
//
// ⛔ IT IS NOT A RENDERING AUTHORITY. It shells out to the CLI exactly as
// switchop.Rebuild does, which is the established installer->shell interface in
// this codebase; the render semantics stay in one place, in the shell.
//
// Failure is FATAL to the caller by contract: without a published projection the
// include must not be repointed, and continuing would produce a host whose boot
// include names a file that was never created.
func RenderBoot(exec executor.Executor, log *logging.Logger) error {
	log.Info("rendering the boot projection from the canonical schema (render-only, no load)")
	if err := runRenderBoot(exec, false); err != nil {
		return fmt.Errorf("boot projection render failed %w", err)
	}
	log.Info("boot projection published")
	return nil
}

// RenderBootInert runs "nftban firewall render-boot --inert": it publishes the
// INERT boot projection (no NFTBan table) through the same single shell
// publication authority. v1.235 row 486 (owner U1): while NFTBan is disabled
// (stored choice) an install/upgrade keeps the projection inert, so a disabled
// NFTBan never loads at the next boot. Same failure contract as RenderBoot.
func RenderBootInert(exec executor.Executor, log *logging.Logger) error {
	log.Info("publishing the INERT boot projection (NFTBan disabled: no NFTBan table at boot)")
	if err := runRenderBoot(exec, true); err != nil {
		return fmt.Errorf("inert boot projection publish failed %w", err)
	}
	log.Info("inert boot projection published")
	return nil
}

// runRenderBoot is the ONE delegation to the shell publication authority.
func runRenderBoot(exec executor.Executor, inert bool) error {
	args := []string{"firewall", "render-boot", "--quiet"}
	if inert {
		args = append(args, "--inert")
	}
	res := exec.Run(fhs.NftbanCLI, args...)
	if res.ExitCode != 0 {
		out := strings.TrimSpace(res.Stderr)
		if out == "" {
			out = strings.TrimSpace(res.Stdout)
		}
		return fmt.Errorf("(exit %d): %s", res.ExitCode, out)
	}
	return nil
}
