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
	"github.com/itcmsgr/nftban/internal/validator"
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

// NewSchemaValidator creates a validator with the canonical nftban schema.
//
// B80-7: All set and chain lists are now sourced from the generated schema
// (internal/validator/schema_generated.go), which is itself generated from
// the canonical cli/lib/nftban/lib/nft_schema.sh. This eliminates the
// second-authority drift risk that existed when this file had its own
// hardcoded lists.
func NewSchemaValidator() *SchemaValidator {
	// Build required sets from generated canonical lists
	requiredIPv4 := make([]expectedSet, 0, len(validator.GeneratedRequiredSetsIPv4))
	for _, name := range validator.GeneratedRequiredSetsIPv4 {
		requiredIPv4 = append(requiredIPv4, expectedSet{Name: name})
	}

	requiredIPv6 := make([]expectedSet, 0, len(validator.GeneratedRequiredSetsIPv6))
	for _, name := range validator.GeneratedRequiredSetsIPv6 {
		requiredIPv6 = append(requiredIPv6, expectedSet{Name: name})
	}

	// Optional (module) sets from the full generated universe minus required.
	// These produce warnings, not errors, when missing.
	requiredV4Set := make(map[string]bool, len(validator.GeneratedRequiredSetsIPv4))
	for _, name := range validator.GeneratedRequiredSetsIPv4 {
		requiredV4Set[name] = true
	}
	for _, name := range validator.GeneratedAllSetsIPv4 {
		if !requiredV4Set[name] {
			requiredIPv4 = append(requiredIPv4, expectedSet{Name: name, Optional: true})
		}
	}

	requiredV6Set := make(map[string]bool, len(validator.GeneratedRequiredSetsIPv6))
	for _, name := range validator.GeneratedRequiredSetsIPv6 {
		requiredV6Set[name] = true
	}
	for _, name := range validator.GeneratedAllSetsIPv6 {
		if !requiredV6Set[name] {
			requiredIPv6 = append(requiredIPv6, expectedSet{Name: name, Optional: true})
		}
	}

	return &SchemaValidator{
		ipv4Sets:       requiredIPv4,
		ipv6Sets:       requiredIPv6,
		expectedChains: validator.GeneratedRequiredBaseChains,
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
