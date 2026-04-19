// =============================================================================
// NFTBan v1.98.x - Installer Safety Whitelist Seeding (PR-14-pre G-14-H)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-safety"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Seed /etc/nftban/whitelist.d/99-manual.conf with system IPs for source install"
// meta:inventory.files="internal/installer/safety/whitelist.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="SSH_CLIENT"
// meta:inventory.config_files="/etc/nftban/whitelist.d/99-manual.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Why this package exists:
//
// Package installs (RPM/DEB) ship the 99-manual.conf template as a
// %config(noreplace) / conffile entry. On fresh installs the template is
// dropped unchanged (header comments only) and later populated either by
// the operator or by a legacy shell helper that ran pre-canonization.
//
// Source install via --source has no shell helper. This package runs during
// phaseConfigure (gated behind pd.source) to seed the same IPs the legacy
// flow used to: interface IPs + SSH-client IP. The authoritative SSH-port
// safety path stays separate — switchop.InjectEmergencySSH handles
// port-level protection in phaseSwitch; this package only touches the
// IP-level whitelist file.
//
// Operator content is authoritative: if 99-manual.conf already exists with
// any non-comment content, SeedManualWhitelist is a no-op and the operator's
// content is preserved.
//
// =============================================================================

package safety

import (
	"fmt"
	"net"
	"os"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// manualWhitelistPath is the canonical path for operator-owned IP whitelist
// entries. Per invariant #9, installer code reads this path only to detect
// "file exists and non-empty" idempotency — it never rewrites an existing
// operator-edited file.
const manualWhitelistPath = "/etc/nftban/whitelist.d/99-manual.conf"

// manualWhitelistHeader is the canonical header written to newly-seeded files.
// Matches the shipped template shape so operators see a consistent format
// whether they got the file via package install or source install.
//
// Note: the shipped package template carries a license header; this seeded
// variant intentionally omits one because, once seeded, the file becomes
// operator-owned content (not a product artifact). Operators who want a
// license marker in their own whitelist may add one.
const manualWhitelistHeader = `# =============================================================================
# NFTBan Manual Whitelist - User-Added IPs
# =============================================================================
#
# Seeded by nftban-installer --source (v1.98.x PR-14-pre).
# Edit freely: subsequent installer runs will not overwrite this file.
#
# FORMAT:  <ip_address>   # Optional comment
# EXAMPLES:
#   192.168.1.100        # Office gateway
#   10.0.0.0/8           # Internal network
#   2001:db8::1          # IPv6 host
#
# =============================================================================

`

// SeedManualWhitelist ensures /etc/nftban/whitelist.d/99-manual.conf exists
// and contains the minimum entries needed to prevent accidental SSH lockout
// on a fresh source install.
//
// Contract:
//   - If the file exists and contains any non-comment / non-blank line, the
//     function is a no-op: the operator's content is preserved.
//   - If the file does not exist OR contains only header/blank lines, the
//     function writes a new file with the canonical header + detected system
//     IPs (interface IPs + SSH-client IP from $SSH_CLIENT if set).
//   - File mode and ownership match the shipped template:
//     root:nftban 0640 (the payload package will set this; this package only
//     writes content — ownership enforcement is payload's job).
//
// Non-fatal: errors detecting individual IPs are logged at Debug level and
// the seed proceeds with whatever was detected. If NO IPs are detected at
// all, the file is still created with the header only — the operator retains
// control and switchop.InjectEmergencySSH provides port-level protection
// independently.
func SeedManualWhitelist(exec executor.Executor, log *logging.Logger) error {
	// Idempotency: if the file already has operator content, do nothing.
	if hasOperatorContent(exec, manualWhitelistPath) {
		log.Debug("safety.SeedManualWhitelist: %s has operator content — preserving", manualWhitelistPath)
		return nil
	}

	// Detect IPs to seed.
	ips := detectSystemIPs(exec, log)

	// Build file content.
	var b strings.Builder
	b.WriteString(manualWhitelistHeader)
	if len(ips) == 0 {
		b.WriteString("# No system IPs auto-detected. Add entries manually as needed.\n")
		log.Warn("safety.SeedManualWhitelist: no system IPs detected; seeding file with header only")
	} else {
		for _, entry := range ips {
			fmt.Fprintf(&b, "%s   # %s\n", entry.ip, entry.comment)
		}
	}

	// Atomic write. File mode is 0640; ownership adjusted by payload package
	// which holds the destination contract for /etc/nftban/*.
	if err := exec.WriteFileAtomic(manualWhitelistPath, []byte(b.String()), 0640); err != nil {
		return fmt.Errorf("write %s: %w", manualWhitelistPath, err)
	}

	log.Info("seeded safety whitelist %s with %d IP entries", manualWhitelistPath, len(ips))
	return nil
}

// ipEntry is one line of the manual whitelist: an IP/CIDR plus a human comment.
type ipEntry struct {
	ip      string
	comment string
}

// hasOperatorContent returns true if the file exists AND contains at least
// one line that is neither blank nor a comment. This is the "don't overwrite
// operator edits" check.
func hasOperatorContent(exec executor.Executor, path string) bool {
	if !exec.FileExists(path) {
		return false
	}
	data, err := exec.ReadFile(path)
	if err != nil {
		// Unreadable file: conservative — treat as "has content" so we don't
		// overwrite something we can't inspect.
		return true
	}
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		return true
	}
	return false
}

// detectSystemIPs returns a deduplicated list of interface IPs + the SSH
// client IP (from $SSH_CLIENT). Best-effort: failures are logged at Debug
// and skipped. Loopback and link-local addresses are excluded.
func detectSystemIPs(exec executor.Executor, log *logging.Logger) []ipEntry {
	seen := make(map[string]bool)
	var out []ipEntry

	add := func(ip, comment string) {
		ip = strings.TrimSpace(ip)
		if ip == "" || seen[ip] {
			return
		}
		seen[ip] = true
		out = append(out, ipEntry{ip: ip, comment: comment})
	}

	// 1. SSH_CLIENT env (set by sshd for interactive sessions; format:
	//    "client_ip client_port server_port"). Present when an admin is
	//    installing over SSH — exactly the lockout-prevention target.
	if sshClient := os.Getenv("SSH_CLIENT"); sshClient != "" {
		fields := strings.Fields(sshClient)
		if len(fields) > 0 && isRoutableIP(fields[0]) {
			add(fields[0], "SSH installer client IP (auto-detected)")
		}
	}

	// 2. Interface IPs via Go's net package. Filters to global-unicast
	//    addresses (no loopback, no link-local) and excludes RFC 1918-only
	//    environments from being seeded as public addresses — the file
	//    format doesn't distinguish, but the comment text does.
	ifaces, err := net.Interfaces()
	if err != nil {
		log.Debug("safety.SeedManualWhitelist: net.Interfaces failed: %v", err)
		return out
	}
	for _, iface := range ifaces {
		// Skip down / loopback interfaces
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			log.Debug("safety.SeedManualWhitelist: addrs for %s failed: %v", iface.Name, err)
			continue
		}
		for _, addr := range addrs {
			ipnet, ok := addr.(*net.IPNet)
			if !ok {
				continue
			}
			ip := ipnet.IP
			if !isRoutableIP(ip.String()) {
				continue
			}
			add(ip.String(), fmt.Sprintf("Interface %s IP (auto-detected)", iface.Name))
		}
	}

	return out
}

// isRoutableIP returns true if the IP string parses cleanly and is not
// loopback, multicast, link-local, or unspecified (0.0.0.0 / ::).
func isRoutableIP(s string) bool {
	ip := net.ParseIP(strings.TrimSpace(s))
	if ip == nil {
		return false
	}
	if ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() {
		return false
	}
	if ip.IsMulticast() || ip.IsUnspecified() {
		return false
	}
	return true
}
