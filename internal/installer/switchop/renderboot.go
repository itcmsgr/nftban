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

	res := exec.Run(fhs.NftbanCLI, "firewall", "render-boot", "--quiet")
	if res.ExitCode != 0 {
		out := strings.TrimSpace(res.Stderr)
		if out == "" {
			out = strings.TrimSpace(res.Stdout)
		}
		return fmt.Errorf("boot projection render failed (exit %d): %s", res.ExitCode, out)
	}
	log.Info("boot projection published")
	return nil
}
