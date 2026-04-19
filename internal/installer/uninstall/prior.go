// =============================================================================
// NFTBan v1.100 PR-22 — Prior-Authority Record Detector (Read-Only)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-uninstall-prior"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="3-state prior-authority record detection for uninstall planning"
// meta:inventory.files="internal/installer/uninstall/prior.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-22 scope lock: READ-ONLY. This file probes whether a prior-authority
// artifact exists and, if so, whether its contents are usable for a
// future --restore-prior-authority decision. It does NOT write any
// prior-authority record (write-path is install-side, tracked for
// PR-23 or a companion install-mode PR per V1100 contract §9 Q9).
//
// The 3 states are the PR-22-scoped answer to "can a future restore
// plan trust this data":
//
//   NoRecord            — no artifact on disk
//   RecordUsable        — artifact parseable + has the required fields
//   RecordIncomplete    — artifact exists but missing fields / malformed /
//                         unrecognized firewall type
//
// PR-22 reports the state; PR-24 enforces "refuse --restore when
// RecordIncomplete". Keeping the split means the plan renderer can
// surface ambiguity to the operator instead of silently deciding for
// them.
//
// =============================================================================
package uninstall

import (
	"encoding/json"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// PriorRecordState classifies the usability of the prior-authority
// artifact for PR-24 restoration-path enforcement.
type PriorRecordState string

const (
	PriorNoRecord         PriorRecordState = "no_record"
	PriorRecordUsable     PriorRecordState = "record_usable"
	PriorRecordIncomplete PriorRecordState = "record_incomplete"
)

// PriorAuthorityPath is the canonical on-disk location for the
// prior-authority record. Kept as a package constant so PR-23's
// install-side writer and any future reader agree on one location.
const PriorAuthorityPath = "/var/lib/nftban/state/prior_authority.json"

// PriorRecord is the schema for the recorded-at-install-time prior
// authority snapshot. PR-22 consumes this to classify usability; it
// does NOT construct, write, or mutate this struct.
//
// The set of required fields is intentionally minimal (per V1100
// contract §13 Q9 answer: "narrow snapshot, not a registry"):
//
//   FirewallType   — "ufw" / "firewalld" / "iptables" / "csf"
//   ActiveAtInstall — was the prior firewall actively holding authority
//   SchemaVersion  — freezes on-disk contract; reader must match
//
// Any extra fields can be added later without breaking backward
// compatibility because the reader uses json.Unmarshal which tolerates
// unknown fields.
type PriorRecord struct {
	SchemaVersion   string `json:"schema_version"`
	FirewallType    string `json:"firewall_type"`
	ActiveAtInstall bool   `json:"active_at_install"`
}

// PriorRecordSchemaVersion is the currently-expected on-disk contract.
// A record with a different schema_version is RecordIncomplete (PR-22
// does not attempt migration; Q8 answer = A = no migration unless
// demonstrated break).
const PriorRecordSchemaVersion = "1.100.0"

// ProbeResult is the full classification + parsed record (nil when the
// classification is NoRecord or RecordIncomplete with no parseable
// JSON). Plan renderers consume this rather than re-probing.
type ProbeResult struct {
	State  PriorRecordState `json:"state"`
	Record *PriorRecord     `json:"record,omitempty"`
	Notes  []string         `json:"notes,omitempty"`
}

// Probe classifies the on-disk prior-authority record. READ-ONLY.
//
// Inputs (all read-only):
//   - exec.FileExists(PriorAuthorityPath)
//   - exec.ReadFile(PriorAuthorityPath)
//   - json.Unmarshal + field check
//
// Never writes. Never deletes. Never mutates.
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
		res.Notes = append(res.Notes,
			"prior-authority record present but unreadable: "+err.Error())
		log.Warn("uninstall/prior: record unreadable: %v", err)
		return res
	}

	var rec PriorRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		res.State = PriorRecordIncomplete
		res.Notes = append(res.Notes,
			"prior-authority record present but not valid JSON: "+err.Error())
		log.Warn("uninstall/prior: record not parseable: %v", err)
		return res
	}

	// Schema version check — mismatched schema is Incomplete (Q8 = A)
	if rec.SchemaVersion != PriorRecordSchemaVersion {
		res.State = PriorRecordIncomplete
		res.Notes = append(res.Notes,
			"prior-authority record schema_version="+rec.SchemaVersion+
				" does not match expected "+PriorRecordSchemaVersion+
				" — record is not usable for restore")
		res.Record = &rec
		return res
	}

	// Required fields check
	if rec.FirewallType == "" {
		res.State = PriorRecordIncomplete
		res.Notes = append(res.Notes,
			"prior-authority record missing firewall_type — not usable for restore")
		res.Record = &rec
		return res
	}
	if !knownFirewallType(rec.FirewallType) {
		res.State = PriorRecordIncomplete
		res.Notes = append(res.Notes,
			"prior-authority record firewall_type="+rec.FirewallType+
				" is not one of the known types (ufw / firewalld / iptables / csf)")
		res.Record = &rec
		return res
	}

	res.State = PriorRecordUsable
	res.Record = &rec
	res.Notes = append(res.Notes,
		"prior-authority record parseable; firewall_type="+rec.FirewallType+
			" active_at_install="+boolYN(rec.ActiveAtInstall))
	log.Debug("uninstall/prior: usable record firewall_type=%s", rec.FirewallType)
	return res
}

func knownFirewallType(t string) bool {
	switch t {
	case "ufw", "firewalld", "iptables", "csf":
		return true
	}
	return false
}

func boolYN(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
