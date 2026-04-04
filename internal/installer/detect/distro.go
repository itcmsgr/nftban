// =============================================================================
// NFTBan v1.73 - Installer Distro Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-distro"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="OS distribution detection and nftables.conf path resolution"
// meta:inventory.files="internal/installer/detect/distro.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/os-release"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// DistroInfo holds detected OS distribution information.
type DistroInfo struct {
	ID          string // normalized: "rocky", "almalinux", "centos", "rhel", "debian", "ubuntu", "fedora"
	VersionID   string // e.g., "9", "10", "24.04"
	PrettyName  string // e.g., "AlmaLinux 9.7 (Moss Jungle Cat)"
	NftConfPath string // system nftables.conf path for this distro
}

// DetectDistro parses /etc/os-release and determines the nftables.conf path.
func DetectDistro(exec executor.Executor, log *logging.Logger) (*DistroInfo, error) {
	data, err := exec.ReadFile("/etc/os-release")
	if err != nil {
		return nil, fmt.Errorf("read /etc/os-release: %w", err)
	}

	info := &DistroInfo{}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "ID=") {
			info.ID = unquote(strings.TrimPrefix(line, "ID="))
		} else if strings.HasPrefix(line, "VERSION_ID=") {
			info.VersionID = unquote(strings.TrimPrefix(line, "VERSION_ID="))
		} else if strings.HasPrefix(line, "PRETTY_NAME=") {
			info.PrettyName = unquote(strings.TrimPrefix(line, "PRETTY_NAME="))
		}
	}

	// Normalize distro ID (matching shell nftban_distro_detect)
	info.ID = normalizeDistroID(info.ID)

	// Determine nftables.conf path
	info.NftConfPath = nftConfPath(info.ID, exec)

	log.Detect("distro", "id", info.ID)
	log.Detect("distro", "version", info.VersionID)
	log.Detect("distro", "pretty", info.PrettyName)
	log.Detect("distro", "nft_conf", info.NftConfPath)

	return info, nil
}

// normalizeDistroID maps variant IDs to canonical names.
func normalizeDistroID(id string) string {
	switch strings.ToLower(id) {
	case "centos", "centos-stream":
		return "centos"
	case "rhel", "redhat":
		return "rhel"
	case "rocky":
		return "rocky"
	case "almalinux", "alma":
		return "almalinux"
	case "debian":
		return "debian"
	case "ubuntu":
		return "ubuntu"
	case "fedora":
		return "fedora"
	default:
		return id
	}
}

// nftConfPath returns the system nftables.conf path for the given distro.
// RHEL-family uses /etc/sysconfig/nftables.conf; Debian-family uses /etc/nftables.conf.
func nftConfPath(distroID string, exec executor.Executor) string {
	switch distroID {
	case "centos", "rhel", "rocky", "almalinux", "fedora":
		// RHEL-family: prefer /etc/sysconfig/nftables.conf if it exists
		if exec.FileExists("/etc/sysconfig/nftables.conf") {
			return "/etc/sysconfig/nftables.conf"
		}
		return "/etc/nftables.conf"
	default:
		// Debian/Ubuntu and others
		return "/etc/nftables.conf"
	}
}

// unquote removes surrounding double quotes from a string.
func unquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		return s[1 : len(s)-1]
	}
	return s
}
