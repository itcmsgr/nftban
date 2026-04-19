// =============================================================================
// NFTBan v1.100 PR-P2-1 — Prior-Authority Record Detector (Read-Only)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-uninstall-prior"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="5-state prior-authority record detection for uninstall planning"
// meta:inventory.files="internal/installer/uninstall/prior.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-22 scope lock (preserved): READ-ONLY. Probes whether a prior-authority
// artifact exists and whether its contents are usable for a future
// --restore-prior-authority decision. Never writes, never deletes.
//
// PR-P2-1 strengthening: PR-24 restore-enforcement cannot trust
// under-defined records. This file hardens the schema and parsing
// semantics so "usable" has a stricter meaning:
//
//   NoRecord              — no artifact on disk
//   RecordMalformed       — artifact exists but JSON does not parse
//   RecordIncomplete      — JSON parses but required fields are missing,
//                           unknown, or semantically unusable
//   RecordUsableActive    — all requirements met AND the prior firewall
//                           was active at install time
//   RecordUsableInactive  — all requirements met AND the prior firewall
//                           was explicitly recorded as NOT active at
//                           install time
//
// Backward-safety rule (PR-P2-1): older records from before this tightening
// that lack recorded_at / installer_version / active_at_install are
// reclassified as RecordIncomplete by design. This is intentional safety
// tightening so PR-24 restore logic never trusts under-defined evidence.
//
// =============================================================================
package uninstall

import (
	"encoding/json"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// PriorRecordState classifies the usability of the prior-authority
// artifact for PR-24 restoration-path enforcement.
type PriorRecordState string

const (
	PriorNoRecord             PriorRecordState = "no_record"
	PriorRecordMalformed      PriorRecordState = "record_malformed"
	PriorRecordIncomplete     PriorRecordState = "record_incomplete"
	PriorRecordUsableActive   PriorRecordState = "record_usable_active"
	PriorRecordUsableInactive PriorRecordState = "record_usable_inactive"
)

// IsUsable reports whether a record-state represents a record that
// PR-24 may consider authorizing restoration from. The active/inactive
// distinction is exposed separately so the plan can surface the
// semantic difference; both are usable-at-this-layer.
func (s PriorRecordState) IsUsable() bool {
	return s == PriorRecordUsableActive || s == PriorRecordUsableInactive
}

// IncompleteReason is a typed enum describing exactly why a record was
// classified as RecordIncomplete. Machine-consumable so downstream
// tooling does not have to substring-match human notes.
type IncompleteReason string

const (
	IncompleteReasonNone                    IncompleteReason = ""
	IncompleteReasonUnreadable              IncompleteReason = "unreadable"
	IncompleteReasonSchemaMismatch          IncompleteReason = "schema_mismatch"
	IncompleteReasonMissingFirewallType     IncompleteReason = "missing_firewall_type"
	IncompleteReasonUnknownFirewallType     IncompleteReason = "unknown_firewall_type"
	IncompleteReasonMissingRecordedAt       IncompleteReason = "missing_recorded_at"
	IncompleteReasonMissingInstallerVersion IncompleteReason = "missing_installer_version"
	IncompleteReasonMissingActiveAtInstall  IncompleteReason = "missing_active_at_install"
)

// PriorAuthorityPath is the canonical on-disk location for the
// prior-authority record. Kept as a package constant so PR-23's
// install-side writer and any future reader agree on one location.
const PriorAuthorityPath = "/var/lib/nftban/state/prior_authority.json"

// PriorRecord is the schema for the recorded-at-install-time prior
// authority snapshot. PR-22 consumes this to classify usability; it
// does NOT construct, write, or mutate this struct.
//
// PR-P2-1 required fields for PriorRecordUsable* classification:
//
//   SchemaVersion     — freezes on-disk contract; reader must match
//   FirewallType      — "ufw" / "firewalld" / "iptables" / "csf"
//   RecordedAt        — timestamp when the record was written; enables
//                       freshness judgement in future tooling
//   InstallerVersion  — version of the installer that wrote the record;
//                       enables per-version quirk handling
//   ActiveAtInstall   — explicit tri-state pointer. nil = field absent
//                       (record is incomplete); &true = prior firewall
//                       was active; &false = prior firewall was explicitly
//                       recorded as NOT active
//
// json.Unmarshal tolerates unknown fields, so future additive fields
// do not break older readers. PR-P2-1 does NOT add signature/checksum
// infrastructure — that remains out of scope.
type PriorRecord struct {
	SchemaVersion    string     `json:"schema_version"`
	FirewallType     string     `json:"firewall_type"`
	RecordedAt       *time.Time `json:"recorded_at,omitempty"`
	InstallerVersion string     `json:"installer_version,omitempty"`
	ActiveAtInstall  *bool      `json:"active_at_install,omitempty"`
}

// PriorRecordSchemaVersion is the currently-expected on-disk contract.
// A record with a different schema_version is RecordIncomplete.
const PriorRecordSchemaVersion = "1.100.0"

// ProbeResult is the full classification + parsed record + typed
// incomplete reason. Plan renderers consume this rather than re-probing.
type ProbeResult struct {
	State            PriorRecordState `json:"state"`
	Record           *PriorRecord     `json:"record,omitempty"`
	IncompleteReason IncompleteReason `json:"incomplete_reason,omitempty"`
	Notes            []string         `json:"notes,omitempty"`
}

// Probe classifies the on-disk prior-authority record. READ-ONLY.
//
// Decision order (first match wins; fall-through means "acceptable so far"):
//
//  1. File absent                      → NoRecord
//  2. File present but unreadable      → Incomplete (Unreadable)
//  3. File readable but bad JSON       → Malformed
//  4. JSON parses but schema mismatch  → Incomplete (SchemaMismatch)
//  5. Required fields missing/invalid  → Incomplete (specific reason)
//  6. All required fields present AND
//       ActiveAtInstall=&true          → UsableActive
//       ActiveAtInstall=&false         → UsableInactive
//
// Read-only at every step: exec.FileExists + exec.ReadFile +
// json.Unmarshal + field check. No writes, no deletes, no mutation.
func Probe(exec executor.Executor, log *logging.Logger) *ProbeResult {
	res := &ProbeResult{}

	if !exec.FileExists(PriorAuthorityPath) {
		res.State = PriorNoRecord
		res.Notes = append(res.Notes,
			"no prior-authority record on disk at "+PriorAuthorityPath)
		log.Debug("uninstall/prior: no record")
		return res
	}

	data, err := exec.ReadFile(PriorAuthorityPath)
	if err != nil {
		res.State = PriorRecordIncomplete
		res.IncompleteReason = IncompleteReasonUnreadable
		res.Notes = append(res.Notes,
			"prior-authority record present but unreadable: "+err.Error())
		log.Warn("uninstall/prior: record unreadable: %v", err)
		return res
	}

	var rec PriorRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		res.State = PriorRecordMalformed
		res.Notes = append(res.Notes,
			"prior-authority record present but not valid JSON: "+err.Error())
		log.Warn("uninstall/prior: record not parseable: %v", err)
		return res
	}

	// Schema version check
	if rec.SchemaVersion != PriorRecordSchemaVersion {
		res.State = PriorRecordIncomplete
		res.IncompleteReason = IncompleteReasonSchemaMismatch
		res.Notes = append(res.Notes,
			"prior-authority record schema_version="+rec.SchemaVersion+
				" does not match expected "+PriorRecordSchemaVersion+
				" — record is not usable for restore")
		res.Record = &rec
		return res
	}

	// Required field: FirewallType present
	if rec.FirewallType == "" {
		res.State = PriorRecordIncomplete
		res.IncompleteReason = IncompleteReasonMissingFirewallType
		res.Notes = append(res.Notes,
			"prior-authority record missing firewall_type — not usable for restore")
		res.Record = &rec
		return res
	}

	// Required field: FirewallType known
	if !knownFirewallType(rec.FirewallType) {
		res.State = PriorRecordIncomplete
		res.IncompleteReason = IncompleteReasonUnknownFirewallType
		res.Notes = append(res.Notes,
			"prior-authority record firewall_type="+rec.FirewallType+
				" is not one of the known types (ufw / firewalld / iptables / csf)")
		res.Record = &rec
		return res
	}

	// PR-P2-1 required field: RecordedAt present AND parseable.
	//
	// Older records that pre-date PR-P2-1 omit this field entirely and
	// are deliberately reclassified as Incomplete here — the safety
	// tightening that unblocks PR-24 restore-enforcement.
	if rec.RecordedAt == nil || rec.RecordedAt.IsZero() {
		res.State = PriorRecordIncomplete
		res.IncompleteReason = IncompleteReasonMissingRecordedAt
		res.Notes = append(res.Notes,
			"prior-authority record missing recorded_at — older pre-PR-P2-1 record "+
				"or record written without a timestamp; not usable for restore")
		res.Record = &rec
		return res
	}

	// PR-P2-1 required field: InstallerVersion present.
	if rec.InstallerVersion == "" {
		res.State = PriorRecordIncomplete
		res.IncompleteReason = IncompleteReasonMissingInstallerVersion
		res.Notes = append(res.Notes,
			"prior-authority record missing installer_version — not usable for restore")
		res.Record = &rec
		return res
	}

	// PR-P2-1 required field: ActiveAtInstall EXPLICITLY present.
	//
	// The *bool pointer is intentional: a record that silently omits
	// this field cannot be distinguished from one that explicitly set
	// it to false. Requiring the pointer to be non-nil means the
	// installer writer committed to a value, and PR-24 can trust that
	// commitment when deciding whether restore means "re-enable a
	// firewall that was running" or "enable a firewall that was not
	// running at install time" (which is a very different operation).
	if rec.ActiveAtInstall == nil {
		res.State = PriorRecordIncomplete
		res.IncompleteReason = IncompleteReasonMissingActiveAtInstall
		res.Notes = append(res.Notes,
			"prior-authority record missing active_at_install — the record did not "+
				"commit to whether the prior firewall was active at install time, "+
				"so restore would be unsafe")
		res.Record = &rec
		return res
	}

	// All requirements met. Split by active state so the plan renderer
	// can surface the semantic difference without re-reading Record.
	res.Record = &rec
	if *rec.ActiveAtInstall {
		res.State = PriorRecordUsableActive
		res.Notes = append(res.Notes,
			"prior-authority record parseable; firewall_type="+rec.FirewallType+
				" active_at_install=yes (prior firewall was running at install time)")
		log.Debug("uninstall/prior: usable-active record firewall_type=%s", rec.FirewallType)
	} else {
		res.State = PriorRecordUsableInactive
		res.Notes = append(res.Notes,
			"prior-authority record parseable; firewall_type="+rec.FirewallType+
				" active_at_install=no (prior firewall was NOT running at install time; "+
				"restore would re-enable a firewall that was not active)")
		log.Debug("uninstall/prior: usable-inactive record firewall_type=%s", rec.FirewallType)
	}
	return res
}

func knownFirewallType(t string) bool {
	switch t {
	case "ufw", "firewalld", "iptables", "csf":
		return true
	}
	return false
}
