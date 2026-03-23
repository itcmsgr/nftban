// =============================================================================
// NFTBan v1.34.0 - Schema Validator (Go daemon-side)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="schema_validator"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-22"
// meta:description="Daemon-side nftables schema validation via netlink for periodic health monitoring"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// This validator mirrors the canonical schema from cli/lib/nftban/lib/nft_schema.sh
// but operates via netlink inside the daemon (no shell calls). The shell-based
// nftban_nft_validate_full() is the user-facing CLI validator; this Go version
// feeds Prometheus metrics and the watchdog snapshot.
// =============================================================================

package watchdog

import (
	"fmt"

	"github.com/google/nftables"
)

// SchemaResult holds the outcome of a schema validation run
type SchemaResult struct {
	Valid    bool     `json:"valid"`
	Errors   []string `json:"errors,omitempty"`
	Warnings []string `json:"warnings,omitempty"`
}

// expectedSet defines an expected nftables set in the schema
type expectedSet struct {
	Name     string
	Optional bool // true for botguard sets (warning only if missing)
}

// SchemaValidator checks nftables schema against canonical expectations
type SchemaValidator struct {
	// Expected sets per family (from nft_schema.sh)
	ipv4Sets []expectedSet
	ipv6Sets []expectedSet

	// Expected chains (same for both families)
	expectedChains []string
}

// NewSchemaValidator creates a validator with the canonical nftban schema
func NewSchemaValidator() *SchemaValidator {
	// Required sets — must exist for correct operation
	requiredIPv4 := []expectedSet{
		{Name: "whitelist_ipv4"},
		{Name: "blacklist_ipv4"},
		{Name: "blacklist_manual_ipv4"},
		{Name: "tcp_ports_in"},
		{Name: "tcp_ports_out"},
		{Name: "udp_ports_in"},
		{Name: "udp_ports_out"},
	}

	// Botguard sets — always in base schema since v1.21.4, but optional warning
	botguardIPv4 := []expectedSet{
		{Name: "http_bot_suspect", Optional: true},
		{Name: "http_bot_pending", Optional: true},
		{Name: "http_bot_allow", Optional: true},
		{Name: "http_bot_grey", Optional: true},
		{Name: "http_bot_ban", Optional: true},
		{Name: "http_bot_emergency", Optional: true},
	}

	requiredIPv6 := []expectedSet{
		{Name: "whitelist_ipv6"},
		{Name: "blacklist_ipv6"},
		{Name: "blacklist_manual_ipv6"},
		{Name: "tcp_ports_in"},
		{Name: "tcp_ports_out"},
		{Name: "udp_ports_in"},
		{Name: "udp_ports_out"},
	}

	botguardIPv6 := []expectedSet{
		{Name: "http_bot_suspect6", Optional: true},
		{Name: "http_bot_pending6", Optional: true},
		{Name: "http_bot_allow6", Optional: true},
		{Name: "http_bot_grey6", Optional: true},
		{Name: "http_bot_ban6", Optional: true},
		{Name: "http_bot_emergency6", Optional: true},
	}

	return &SchemaValidator{
		ipv4Sets:       append(requiredIPv4, botguardIPv4...),
		ipv6Sets:       append(requiredIPv6, botguardIPv6...),
		expectedChains: []string{"input", "forward", "output"},
	}
}

// Validate checks current nftables state against expected schema
func (sv *SchemaValidator) Validate(conn *nftables.Conn) SchemaResult {
	result := SchemaResult{Valid: true}

	// 1. Check tables exist
	tables, err := conn.ListTables()
	if err != nil {
		result.Valid = false
		result.Errors = append(result.Errors, fmt.Sprintf("cannot list tables: %v", err))
		return result
	}

	var ipv4Table, ipv6Table *nftables.Table
	for _, t := range tables {
		if t.Name == "nftban" {
			switch t.Family {
			case nftables.TableFamilyIPv4:
				ipv4Table = t
			case nftables.TableFamilyIPv6:
				ipv6Table = t
			}
		}
	}

	if ipv4Table == nil {
		result.Valid = false
		result.Errors = append(result.Errors, "missing table: ip nftban")
	}
	if ipv6Table == nil {
		result.Warnings = append(result.Warnings, "missing table: ip6 nftban (IPv6 support disabled)")
	}

	// 2. Check sets
	if ipv4Table != nil {
		sv.validateSets(conn, ipv4Table, sv.ipv4Sets, &result)
		sv.validateChains(conn, ipv4Table, &result, false)
	}
	if ipv6Table != nil {
		sv.validateSets(conn, ipv6Table, sv.ipv6Sets, &result)
		sv.validateChains(conn, ipv6Table, &result, true)
	}

	return result
}

// validateSets checks that expected sets exist in the given table
func (sv *SchemaValidator) validateSets(conn *nftables.Conn, table *nftables.Table, expected []expectedSet, result *SchemaResult) {
	sets, err := conn.GetSets(table)
	if err != nil {
		result.Valid = false
		result.Errors = append(result.Errors, fmt.Sprintf("cannot list sets in %s nftban: %v", familyName(table.Family), err))
		return
	}

	// Build lookup of existing set names
	existing := make(map[string]bool, len(sets))
	for _, s := range sets {
		existing[s.Name] = true
	}

	for _, exp := range expected {
		if !existing[exp.Name] {
			if exp.Optional {
				result.Warnings = append(result.Warnings, fmt.Sprintf("optional set missing in %s nftban: %s", familyName(table.Family), exp.Name))
			} else {
				result.Valid = false
				result.Errors = append(result.Errors, fmt.Sprintf("required set missing in %s nftban: %s", familyName(table.Family), exp.Name))
			}
		}
	}
}

// validateChains checks that expected base chains exist
func (sv *SchemaValidator) validateChains(conn *nftables.Conn, table *nftables.Table, result *SchemaResult, warnOnly bool) {
	chains, err := conn.ListChainsOfTableFamily(table.Family)
	if err != nil {
		if warnOnly {
			result.Warnings = append(result.Warnings, fmt.Sprintf("cannot list chains in %s nftban: %v", familyName(table.Family), err))
		} else {
			result.Valid = false
			result.Errors = append(result.Errors, fmt.Sprintf("cannot list chains in %s nftban: %v", familyName(table.Family), err))
		}
		return
	}

	// Build lookup of existing chain names in this table
	existing := make(map[string]bool)
	for _, ch := range chains {
		if ch.Table != nil && ch.Table.Name == "nftban" {
			existing[ch.Name] = true
		}
	}

	for _, name := range sv.expectedChains {
		if !existing[name] {
			msg := fmt.Sprintf("missing chain in %s nftban: %s", familyName(table.Family), name)
			if warnOnly {
				result.Warnings = append(result.Warnings, msg)
			} else {
				result.Valid = false
				result.Errors = append(result.Errors, msg)
			}
		}
	}
}

// familyName returns a human-readable name for the table family
func familyName(f nftables.TableFamily) string {
	switch f {
	case nftables.TableFamilyIPv4:
		return "ip"
	case nftables.TableFamilyIPv6:
		return "ip6"
	default:
		return "unknown"
	}
}
