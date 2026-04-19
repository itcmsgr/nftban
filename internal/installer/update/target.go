// =============================================================================
// NFTBan v1.99 PR-17 — Package-Install Target Version Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-target"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Detect target version from rpm -q / dpkg -s (package installs)"
// meta:inventory.files="internal/installer/update/target.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-17 deepens G3-U4 (preflight) with:
//
//   - DetectPackageTarget: query rpm -q / dpkg -s for the "staged" version
//     of nftban-core. For a package upgrade, the staged version is the one
//     on disk in the package DB; the running version is in VERSION. A
//     non-empty diff tells us an upgrade is pending.
//
//   - DetectInstallOrigin: probe rpm -q / dpkg -s to classify the host's
//     install origin when the operator didn't pass --rpm / --deb / --source.
//     Used by the update-dry-run orchestrator to render a sensible plan.
//
// Both functions are READ-ONLY. No mutation; no package manager transactions.
//
// Design principle — minimum stable discriminator set:
//
//   This package intentionally classifies at the level of "install origin"
//   (rpm / deb / source) only. It does NOT branch on distro point releases
//   (Ubuntu 22.04.1 vs 22.04.5, AlmaLinux 9.3 vs 9.5, etc.) because no
//   behavioural difference in the update trigger path changes with point
//   releases — the package manager (rpm / dpkg) is the stable discriminator,
//   not the OS version string.
//
//   Full VersionID is still captured upstream in detect.DistroInfo for
//   evidence and debugging, but it stays metadata — never branching input —
//   unless a concrete behavioural difference is proven (different package
//   semantics, service/unit path changes, polkit path changes, etc.).
//
//   This is the same discipline used by internal/installer/detect/distro.go
//   (only ID branches, VersionID is metadata) and by internal/installer/
//   payload/payload.go::isDebianFamily (family-level dispatch).
//
// =============================================================================

package update

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// PackageNames is the canonical ordered list of package identifiers to probe.
// Modern packages ship as "nftban-core"; pre-v1.73 packages shipped as
// "nftban". We try both for ownership probes so legacy hosts still classify
// correctly. This mirrors cli/lib/nftban/cli/cmd_update_detection.sh::
// _detect_install_type so the Go and shell paths report the same origin.
var PackageNames = []string{"nftban-core", "nftban"}

// DetectInstallOrigin returns "rpm", "deb", or "source" when it can infer
// the host's install origin, or "" when it cannot. Probing order:
//
//  1. rpm -q <pkg> for each name in PackageNames — if any exits 0, origin is "rpm"
//  2. dpkg -s <pkg> for each name in PackageNames — if any exits 0, origin is "deb"
//  3. NFTBAN_SOURCE_DIR env var set — origin is "source"
//  4. otherwise — "" (unknown)
//
// The probing is ORDER-SENSITIVE by design: package managers coexist on
// some systems (e.g. alien, conversion tooling), so we prefer rpm if it
// reports ownership. This is the Go mirror of the shell
// _detect_install_type helper; both must stay in sync until PR-21 removes
// the shell path.
func DetectInstallOrigin(exec executor.Executor, log *logging.Logger) string {
	for _, pkg := range PackageNames {
		if hasPackage(exec, "rpm", "-q", pkg) {
			log.Debug("update: install origin detected via rpm -q %s = rpm", pkg)
			return "rpm"
		}
	}
	for _, pkg := range PackageNames {
		if hasPackage(exec, "dpkg", "-s", pkg) {
			log.Debug("update: install origin detected via dpkg -s %s = deb", pkg)
			return "deb"
		}
	}
	if exec.Getenv("NFTBAN_SOURCE_DIR") != "" {
		log.Debug("update: install origin inferred from NFTBAN_SOURCE_DIR = source")
		return "source"
	}
	log.Debug("update: install origin not detected — no package manager ownership + no source dir")
	return ""
}

// hasPackage returns true when the package manager reports ownership
// (exit 0) for the given package. Empty output or non-zero exit = false.
func hasPackage(exec executor.Executor, name string, args ...string) bool {
	r := exec.Run(name, args...)
	if r.ExitCode != 0 {
		return false
	}
	return strings.TrimSpace(r.Stdout) != ""
}

// DetectPackageTarget queries the package database for the version of
// nftban-core that would be installed if an upgrade ran. For a real
// upgrade scenario this equals the version on disk in the package DB,
// which is ALSO the running version when the package is in sync.
//
// Returns ("", nil) when the package manager is present but the package
// is not owned. Returns ("", err) only on plumbing failures (unlikely —
// we explicitly tolerate non-zero exits as "not owned").
//
// PR-17 scope: this detection is advisory only. Apply work (PR-18) will
// use the SAME query to drive the rebuild-pipeline input delta — per
// INV-U-001 there is no separate package-specific apply path.
func DetectPackageTarget(exec executor.Executor, origin string, log *logging.Logger) (string, error) {
	for _, pkg := range PackageNames {
		switch origin {
		case "rpm":
			if v := queryRPM(exec, pkg, log); v != "" {
				return v, nil
			}
		case "deb":
			if v := queryDEB(exec, pkg, log); v != "" {
				return v, nil
			}
		default:
			// Source install: target is the source tree's VERSION file and
			// is handled in plan.DetectVersions directly. Unknown origin:
			// no query — fall through.
			return "", nil
		}
	}
	return "", nil
}

// queryRPM runs `rpm -q --queryformat '%{VERSION}' <pkg>`.
// Returns the version string, or "" when not installed.
func queryRPM(exec executor.Executor, pkg string, log *logging.Logger) string {
	r := exec.Run("rpm", "-q", "--queryformat", "%{VERSION}", pkg)
	if r.ExitCode != 0 {
		log.Debug("update: rpm -q %s exit=%d (package not installed)", pkg, r.ExitCode)
		return ""
	}
	v := strings.TrimSpace(r.Stdout)
	// rpm -q for a missing package sometimes prints the error to stdout AND
	// still exits non-zero, so this is belt-and-suspenders.
	if strings.Contains(v, "not installed") || strings.Contains(v, "is not installed") {
		return ""
	}
	return v
}

// queryDEB runs `dpkg -s <pkg>` and extracts the `Version:` field.
// Returns the version string, or "" when not installed.
func queryDEB(exec executor.Executor, pkg string, log *logging.Logger) string {
	r := exec.Run("dpkg", "-s", pkg)
	if r.ExitCode != 0 {
		log.Debug("update: dpkg -s %s exit=%d (package not installed)", pkg, r.ExitCode)
		return ""
	}
	for _, line := range strings.Split(r.Stdout, "\n") {
		if strings.HasPrefix(line, "Version:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "Version:"))
		}
	}
	return ""
}
