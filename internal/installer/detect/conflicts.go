// =============================================================================
// NFTBan v1.73 - Installer Conflict Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-conflicts"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Conflicting firewall detection (services + ghost nft tables)"
// meta:inventory.files="internal/installer/detect/conflicts.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package detect

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// Conflict represents a detected conflicting firewall.
type Conflict struct {
	Name    string // e.g., "CSF", "UFW", "firewalld", "iptables", "iptables-nft"
	Service string // systemd unit name (may be empty for ghost table conflicts)
	Active  bool   // true if service is currently running or table exists
}

// conflictServices are the systemd units checked for active conflicts.
var conflictServices = []struct {
	name    string // conflict display name
	service string // systemd unit
}{
	{"CSF", "csf.service"},
	{"CSF", "lfd.service"},
	{"UFW", "ufw.service"},
	{"firewalld", "firewalld.service"},
	{"iptables", "iptables.service"},
}

// nftbanOwnedTables are nft tables that belong to NFTBan (not conflicts).
var nftbanOwnedTables = map[string]bool{
	"ip nftban":                       true,
	"ip6 nftban":                      true,
	"ip raw":                          true,
	"ip6 raw":                         true,
	"inet nftban_install_emergency":   true,
}

// DetectConflicts checks for active conflicting firewalls via systemd services
// and ghost nftables tables. Returns a deduplicated slice of conflicts.
func DetectConflicts(exec executor.Executor, log *logging.Logger) []Conflict {
	seen := make(map[string]bool)
	var conflicts []Conflict

	// Check systemd services.
	// Dedup by service (not name) — CSF has two services (csf.service + lfd.service)
	// and both must be stopped+disabled+masked.
	for _, svc := range conflictServices {
		if exec.ServiceActive(svc.service) {
			if !seen[svc.service] {
				seen[svc.service] = true
				conflicts = append(conflicts, Conflict{
					Name:    svc.name,
					Service: svc.service,
					Active:  true,
				})
				log.Detect("conflict", svc.name, "active ("+svc.service+")")
			}
		}
	}

	// Check for ghost nft tables (non-NFTBan tables with hooks)
	if exec.CommandExists("nft") {
		res := exec.Run("nft", "list", "tables")
		if res.ExitCode == 0 {
			for _, line := range strings.Split(res.Stdout, "\n") {
				line = strings.TrimSpace(line)
				if line == "" {
					continue
				}
				// Remove "table " prefix to get "family name"
				tableName := strings.TrimPrefix(line, "table ")

				// Skip NFTBan-owned tables
				if nftbanOwnedTables[tableName] {
					continue
				}

				// Classify ghost tables
				if strings.Contains(tableName, "firewalld") {
					if !seen["firewalld"] {
						seen["firewalld"] = true
						conflicts = append(conflicts, Conflict{
							Name:   "firewalld",
							Active: true,
						})
						log.Detect("conflict", "firewalld", "ghost table: "+tableName)
					}
				} else if strings.Contains(tableName, "filter") ||
					strings.Contains(tableName, "nat") ||
					strings.Contains(tableName, "mangle") {
					if !seen["iptables-nft"] {
						seen["iptables-nft"] = true
						conflicts = append(conflicts, Conflict{
							Name:   "iptables-nft",
							Active: true,
						})
						log.Detect("conflict", "iptables-nft", "ghost table: "+tableName)
					}
				}
			}
		}
	}

	if len(conflicts) == 0 {
		log.Detect("conflict", "result", "none")
	} else {
		names := ConflictNames(conflicts)
		log.Detect("conflict", "result", strings.Join(names, ", "))
	}

	return conflicts
}

// ConflictNames returns a deduplicated list of conflict names.
func ConflictNames(conflicts []Conflict) []string {
	seen := make(map[string]bool)
	var names []string
	for _, c := range conflicts {
		if !seen[c.Name] {
			seen[c.Name] = true
			names = append(names, c.Name)
		}
	}
	return names
}
