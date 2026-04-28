// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-26-code-D — restore evidence record
// =============================================================================
// meta:name="nftban-installer-restore-evidence"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Post-restore evidence-record writer per §39.3 + §48.6 lock. Writes a structured JSON record under /var/lib/nftban/state/restore-evidence/ on every restore-mode terminal so a fresh reader can reconstruct the post-mutation state without consulting private memory or the host's runtime state. Recording-only — does NOT re-run PR-24 decisions, rebuild TargetAuthority, run the validator, or probe module health. Separate artefact from update-history.json (§19.2 layer 4 / main.go:132 mode-gate retained)."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/logging,github.com/itcmsgr/nftban/internal/installer/restore,github.com/itcmsgr/nftban/internal/installer/state,github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files="/var/lib/nftban/state/restore-evidence/restore-evidence-<UTC>-<rand>.json"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Recording-only invariant (operator design call, §39.3):
//
//   This module RECORDS the output of §21 / §32 verification. It MUST
//   NOT become a second truth engine:
//
//     - no calls to restore.Decide / restore.PlanFromDecision
//     - no calls to uninstall.Probe (Classify is permitted only via
//       the existing inline-verify dep's CurrentAuthorityClass — we
//       consume the value already produced, never re-derive)
//     - no calls to detect.DetectPanel
//     - no validator full-sweep / module-health probes
//     - no rebuild / cleanup invocations
//     - no update-history.json write (the §19.2 layer 4 mode-gate at
//       main.go:132 already excludes restore mode; this module
//       inherits that invariant)
//
// All evidence-record writes route through the SINGLE helper
// writeRestoreEvidenceRecord, which uses the named constant
// restoreEvidenceDir for its destination directory. The CI gate
// G4-RESTORE-EVIDENCE-RECORD enforces this structurally.
// =============================================================================

package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// =============================================================================
// Constants — paths and schema
// =============================================================================

const (
	// restoreEvidenceSchemaVersion is the on-disk schema version of
	// every record this module writes. Readers parse it before
	// trusting fields. Bumping is a contract event.
	restoreEvidenceSchemaVersion = "1.0.0"

	// restoreEvidenceDir is the named constant the CI gate
	// G4-RESTORE-EVIDENCE-RECORD pins. ALL evidence-record file
	// writes in this module MUST resolve their destination through
	// this constant. No write outside this directory is permitted
	// by writeRestoreEvidenceRecord.
	restoreEvidenceDir = "/var/lib/nftban/state/restore-evidence"

	// restoreEvidenceFilenamePrefix is the basename prefix; full
	// filename is restoreEvidenceFilenamePrefix + "<UTC-RFC3339-basic>"
	// + "-" + "<short-random>" + ".json".
	restoreEvidenceFilenamePrefix = "restore-evidence-"

	// restoreEvidenceMode is the file mode applied to evidence-record
	// files. 0640 — root-readable + group-readable, no world access.
	restoreEvidenceMode = 0o640

	// restoreEvidenceDirMode is the directory mode applied to
	// restoreEvidenceDir on first write.
	restoreEvidenceDirMode = 0o750
)

// =============================================================================
// Schema types — the §48.6 lock
// =============================================================================

// RestoreEvidenceRecord is the on-disk JSON shape. Schema_version is
// the gate; consumers reject mismatches.
type RestoreEvidenceRecord struct {
	SchemaVersion string                  `json:"schema_version"`
	TimestampUTC  time.Time               `json:"timestamp_utc"`
	Mode          string                  `json:"mode"`  // always "restore"
	Phase         string                  `json:"phase"` // always "post_restore_verify"
	Target        RestoreEvidenceTarget   `json:"target"`
	Result        RestoreEvidenceResult   `json:"result"`
	Verification  RestoreEvidenceVerify   `json:"verification"`
	HistoryGate   RestoreEvidenceHistory  `json:"history_gate"`
	Warnings      []string                `json:"warnings,omitempty"`
}

// RestoreEvidenceTarget records the planner-resolved target identity.
// Recording-only — never re-derived.
type RestoreEvidenceTarget struct {
	Kind         string `json:"kind"`          // "recorded_prior" | "panel_native" | "none"
	FirewallType string `json:"firewall_type"` // "csf" | "" (empty for non-csf paths under Amendment 1)
	Panel        string `json:"panel"`         // "directadmin" | "none" | other detect.PanelType
}

// RestoreEvidenceResult records the §22 terminal + §19.4 exit code.
type RestoreEvidenceResult struct {
	State    string `json:"state"`     // state.InstallState string form
	ExitCode int    `json:"exit_code"` // §19.4 exit code mapped from State
	Stage    string `json:"stage"`     // execRes.Stage from §23
	Success  bool   `json:"success"`   // true iff State == StateRestoreExecuted
}

// RestoreEvidenceVerify records the §21.1 + §32 post-mutation
// observations. Source values come from execRes.VerifyResult AND
// from read-only kernel/service queries the dispatcher performs at
// record time (NftTableExists for emergency + nftban tables;
// detect.SSHPortWithSource for sshd port + which source yielded it).
type RestoreEvidenceVerify struct {
	TargetFirewallActive       bool   `json:"target_firewall_active"`
	AuthorityClass             string `json:"authority_class"` // from inline-verify CurrentAuthorityClass
	SafetyNetRemovalSafe       bool   `json:"safety_net_removal_safe"`
	EmergencyTablePresentAfter bool   `json:"emergency_table_present_after"`
	NftbanTablesPresentAfter   bool   `json:"nftban_tables_present_after"`
	SSHPort                    int    `json:"ssh_port"`
	SSHPortSource              string `json:"ssh_port_source"` // "ss" | "sshd_config" | "state" | "config" | ""
}

// RestoreEvidenceHistory pins the §19.2 layer-4 invariant in the
// record itself. Both flags are constant true because main.go:132
// excludes restore mode; the record makes that pinning machine-
// auditable.
type RestoreEvidenceHistory struct {
	UpdateHistoryUnchanged           bool `json:"update_history_unchanged"`
	RestoreModeHistoryWriteForbidden bool `json:"restore_mode_history_write_forbidden"`
}

// =============================================================================
// Sentinels
// =============================================================================

var (
	// ErrEvidenceWriteFailed wraps any underlying mkdir / marshal /
	// WriteFileAtomic failure. The dispatcher consumes this to
	// decide whether to downgrade a successful StateRestoreExecuted
	// terminal to StateRestoreDegraded (per the §48.6 rule:
	// failure-to-write-evidence after a successful restore is a
	// degraded outcome, not a clean success).
	ErrEvidenceWriteFailed = errors.New("restore evidence: write failed")

	// ErrEvidenceNilExecutor / ErrEvidenceNilRecord are defensive
	// guards on the writer.
	ErrEvidenceNilExecutor = errors.New("restore evidence: executor is nil")
	ErrEvidenceNilRecord   = errors.New("restore evidence: record is nil")
)

// =============================================================================
// Single-helper writer — the only function authorized to write under
// restoreEvidenceDir. Per the §46 G4-RESTORE-EVIDENCE-RECORD gate,
// no other function in this module (or in any other PR-26 production
// file) may call exec.WriteFileAtomic with a /var/lib/nftban/state/
// restore-evidence/* literal.
// =============================================================================

// writeRestoreEvidenceRecord is the SINGLE helper authorized to write
// a RestoreEvidenceRecord under restoreEvidenceDir. Filename is
// generated from a UTC RFC3339-basic timestamp + short random hex
// suffix to keep concurrent writes from colliding.
//
// Returns ErrEvidenceWriteFailed wrapping the underlying error on
// any failure (mkdir / marshal / write).
//
// Recording-only: this helper does not consult the host runtime or
// re-derive anything. It serializes the record the caller already
// assembled and persists it.
func writeRestoreEvidenceRecord(
	_ context.Context,
	exec executor.Executor,
	rec *RestoreEvidenceRecord,
	log *logging.Logger,
) error {
	if exec == nil {
		return ErrEvidenceNilExecutor
	}
	if rec == nil {
		return ErrEvidenceNilRecord
	}

	if err := exec.MkdirAll(restoreEvidenceDir, restoreEvidenceDirMode); err != nil {
		return fmt.Errorf("%w: mkdir %s: %v", ErrEvidenceWriteFailed, restoreEvidenceDir, err)
	}

	body, err := json.MarshalIndent(rec, "", "  ")
	if err != nil {
		return fmt.Errorf("%w: marshal: %v", ErrEvidenceWriteFailed, err)
	}
	body = append(body, '\n')

	suffix, err := evidenceShortRandom()
	if err != nil {
		return fmt.Errorf("%w: random suffix: %v", ErrEvidenceWriteFailed, err)
	}
	stamp := rec.TimestampUTC.UTC().Format("20060102T150405Z")
	abs := restoreEvidenceDir + "/" + restoreEvidenceFilenamePrefix + stamp + "-" + suffix + ".json"

	if err := exec.WriteFileAtomic(abs, body, restoreEvidenceMode); err != nil {
		return fmt.Errorf("%w: write %s: %v", ErrEvidenceWriteFailed, abs, err)
	}
	if log != nil {
		log.Info("restore evidence: recorded %s (%d bytes, schema_version=%s)",
			abs, len(body), rec.SchemaVersion)
	}
	return nil
}

// evidenceShortRandom returns 8 hex characters from crypto/rand — used
// as the per-file random suffix so two evidence writes within the
// same UTC second do not collide.
func evidenceShortRandom() (string, error) {
	var buf [4]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf[:]), nil
}

// =============================================================================
// Record assembler — translates dispatcher state into a record.
// Recording-only: every field is sourced from a value the dispatcher
// already has + a small set of read-only kernel/service queries.
// =============================================================================

// buildRestoreEvidenceRecord assembles a RestoreEvidenceRecord from
// the dispatcher's existing state (target, execRes, panel) and a
// small set of read-only queries (NftTableExists for the two
// table families + the emergency table; detect.SSHPortWithSource).
//
// Does NOT call uninstall.Probe / restore.Decide / restore.PlanFromDecision /
// detect.DetectPanel — INV-PR26-VERIFICATION-IS-PROOF-NOT-DECISION.
func buildRestoreEvidenceRecord(
	exec executor.Executor,
	log *logging.Logger,
	target restore.TargetAuthority,
	execRes restore.ExecuteResult,
) *RestoreEvidenceRecord {
	now := time.Now().UTC()

	rec := &RestoreEvidenceRecord{
		SchemaVersion: restoreEvidenceSchemaVersion,
		TimestampUTC:  now,
		Mode:          "restore",
		Phase:         "post_restore_verify",
		Target: RestoreEvidenceTarget{
			Kind:         string(target.Kind()),
			FirewallType: target.FirewallType(),
			Panel:        string(target.Panel()),
		},
		Result: RestoreEvidenceResult{
			State:    string(execRes.Terminal),
			ExitCode: execRes.Terminal.ExitCode(),
			Stage:    execRes.Stage,
			Success:  execRes.Terminal == state.StateRestoreExecuted,
		},
		Verification: RestoreEvidenceVerify{
			TargetFirewallActive: execRes.VerifyResult.TargetFirewallActive,
			AuthorityClass:       string(execRes.VerifyResult.ObservedAuthority),
			SafetyNetRemovalSafe: execRes.VerifyResult.SafetyNetRemovalSafe,
		},
		HistoryGate: RestoreEvidenceHistory{
			// §19.2 layer 4 / main.go:132 mode-gate excludes restore
			// from update-history writes; both flags are constants
			// pinned by the contract.
			UpdateHistoryUnchanged:           true,
			RestoreModeHistoryWriteForbidden: true,
		},
	}

	// Post-mutation kernel-table observations. Read-only.
	if exec != nil {
		rec.Verification.EmergencyTablePresentAfter = exec.NftTableExists("inet", "nftban_install_emergency")
		rec.Verification.NftbanTablesPresentAfter =
			exec.NftTableExists("ip", "nftban") || exec.NftTableExists("ip6", "nftban")
	}

	// SSH port + source (read-only typed introspection per §51.5-A2).
	if exec != nil {
		port, source, err := detect.SSHPortWithSource(exec, log)
		if err == nil {
			rec.Verification.SSHPort = port
			rec.Verification.SSHPortSource = source
		} else {
			rec.Warnings = append(rec.Warnings,
				"ssh port not resolvable at evidence-record time: "+err.Error())
		}
	}

	// Surface verify-result classification correctness as an
	// authority-class warning when CurrentAuthorityClass diverges
	// from AuthorityExternal (the expected post-mutation class for
	// csf restore).
	expected := uninstall.AuthorityExternal
	if string(execRes.VerifyResult.ObservedAuthority) != "" &&
		execRes.VerifyResult.ObservedAuthority != expected {
		rec.Warnings = append(rec.Warnings,
			fmt.Sprintf("authority-class observed %q diverges from expected %q",
				execRes.VerifyResult.ObservedAuthority, expected))
	}

	return rec
}
