// =============================================================================
// NFTBan v1.76.0 - Installer Dependency Auto-Install
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-deps"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="Auto-install missing dependencies during postinst (dpkg lock released)"
// meta:inventory.files="internal/installer/deps/deps.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package deps

import (
	"fmt"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// dep maps a command name to the package(s) that provide it.
type dep struct {
	cmd    string // command to check (e.g., "jq")
	rpm    string // RPM package name
	deb    string // DEB package name
	critical bool // if true, missing dep after install attempt → error
}

// requiredDeps lists commands that NFTBan needs at runtime.
// Order matters: critical deps first.
var requiredDeps = []dep{
	{cmd: "jq", rpm: "jq", deb: "jq", critical: true},
	{cmd: "curl", rpm: "curl", deb: "curl", critical: true},
	{cmd: "socat", rpm: "socat", deb: "socat", critical: true},
	{cmd: "bc", rpm: "bc", deb: "bc", critical: false},
	{cmd: "gawk", rpm: "gawk", deb: "gawk", critical: false},
	{cmd: "getfacl", rpm: "acl", deb: "acl", critical: false},
	{cmd: "tar", rpm: "tar", deb: "tar", critical: true},
}

// InstallMissing checks for missing dependencies and installs them.
// Returns an error only if a critical dependency is still missing after the install attempt.
func InstallMissing(exec executor.Executor, distro *detect.DistroInfo, log *logging.Logger) error {
	// Find missing commands
	var missingRPM, missingDEB []string
	var missingCmds []dep

	for _, d := range requiredDeps {
		if !exec.CommandExists(d.cmd) {
			missingCmds = append(missingCmds, d)
			missingRPM = append(missingRPM, d.rpm)
			missingDEB = append(missingDEB, d.deb)
			log.Warn("missing dependency: %s", d.cmd)
		}
	}

	if len(missingCmds) == 0 {
		log.Info("all dependencies present")
		return nil
	}

	// Determine package manager based on distro
	isRPM := isRPMFamily(distro.ID)
	var pkgs []string
	if isRPM {
		pkgs = dedup(missingRPM)
	} else {
		pkgs = dedup(missingDEB)
	}

	log.Info("installing missing packages: %s", strings.Join(pkgs, " "))

	if isRPM {
		if err := installRPM(exec, pkgs, log); err != nil {
			log.Warn("RPM package install failed: %v", err)
		}
	} else {
		if err := installDEB(exec, pkgs, log); err != nil {
			log.Warn("DEB package install failed: %v", err)
		}
	}

	// Verify critical deps are now available
	var stillMissing []string
	for _, d := range missingCmds {
		if !exec.CommandExists(d.cmd) {
			if d.critical {
				stillMissing = append(stillMissing, d.cmd)
			} else {
				log.Warn("optional dependency still missing: %s (non-critical)", d.cmd)
			}
		} else {
			log.Info("installed: %s", d.cmd)
		}
	}

	if len(stillMissing) > 0 {
		return fmt.Errorf("critical dependencies still missing after install: %s", strings.Join(stillMissing, ", "))
	}

	return nil
}

// isRPMFamily returns true for RHEL/Rocky/AlmaLinux/CentOS/Fedora.
func isRPMFamily(distroID string) bool {
	switch distroID {
	case "centos", "rhel", "rocky", "almalinux", "fedora":
		return true
	default:
		return false
	}
}

// installRPM uses dnf (preferred) or yum to install packages.
func installRPM(exec executor.Executor, pkgs []string, log *logging.Logger) error {
	// Prefer dnf over yum
	pkgMgr := "dnf"
	if !exec.CommandExists("dnf") {
		if exec.CommandExists("yum") {
			pkgMgr = "yum"
		} else {
			return fmt.Errorf("neither dnf nor yum available")
		}
	}

	args := append([]string{"install", "-y"}, pkgs...)
	log.Debug("running: %s %s", pkgMgr, strings.Join(args, " "))

	res := exec.RunTimeout(120*time.Second, pkgMgr, args...)
	if res.ExitCode != 0 {
		return fmt.Errorf("%s install failed (exit %d): %s", pkgMgr, res.ExitCode, res.Stderr)
	}

	return nil
}

// installDEB uses apt-get to install packages.
func installDEB(exec executor.Executor, pkgs []string, log *logging.Logger) error {
	if !exec.CommandExists("apt-get") {
		return fmt.Errorf("apt-get not available")
	}

	args := append([]string{"install", "-y", "--no-install-recommends"}, pkgs...)
	log.Debug("running: apt-get %s", strings.Join(args, " "))

	res := exec.RunTimeout(120*time.Second, "apt-get", args...)
	if res.ExitCode != 0 {
		return fmt.Errorf("apt-get install failed (exit %d): %s", res.ExitCode, res.Stderr)
	}

	return nil
}

// dedup removes duplicate strings preserving order.
func dedup(ss []string) []string {
	seen := make(map[string]bool, len(ss))
	var out []string
	for _, s := range ss {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
