// =============================================================================
// NFTBan — CSF-CLOSE-5: PROTECTED must not be reported while CSF can act
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator-csf-conflict"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-11"
// meta:description="Read-only, conservative CSF conflict truth for the validator. Emits a finding when CSF is effective or re-enterable, so the status authority cannot report PROTECTED on a contested host. No mutation, no vendor binary execution."
// meta:inventory.files="internal/validator/csf_conflict.go"
// meta:inventory.binaries=""
// meta:inventory.privileges="none"
// =============================================================================
//
// WHY THIS EXISTS — two proven runtime failures (el9-clean, 2026-08-11):
//
//	ARM 3  /etc/csf removed, csf.service failed BUT STILL ENABLED, binary
//	       present, 129 CSF rules live. Takeover neutralized nothing.
//	       Restoring the config and starting the still-enabled unit brought
//	       CSF back to 129 rules — and `nftban status` said PROTECTED
//	       throughout.
//
//	ARM 4  CSF detected and listed in CONFLICTS, yet the disarm path was
//	       skipped. lfd left enabled, binary left executable, PROTECTED.
//
// In both cases NFTBan's own authority was genuinely healthy. That is exactly
// the trap:
//
//	NFTBAN HEALTHY  !=  SOLE EFFECTIVE AUTHORITY
//	SERVICE INACTIVE !=  AUTHORITY ABSENT
//
// SCOPE (owner-constrained, deliberately narrow): this is NOT the future
// universal external-firewall observer. It answers one question about one
// product, conservatively. UFW / firewalld / native-nftables generalization
// belongs to a later lane and must not be built here.
//
// PURITY: this file performs NO mutation and NEVER executes a vendor firewall
// binary. `csf -s` is CSF's START command — using it as a probe re-armed a
// competing firewall from a read-only report (fixed in v1.229.0 R0). Evidence
// here is systemd state + filesystem presence only.
package validator

import (
	"os"
	"strings"

	"github.com/itcmsgr/nftban/internal/procenv"
)

// CSFConflictState is the conservative tri-state answer.
type CSFConflictState string

const (
	// CSFPresent — CSF is effective, or can re-enter without reinstallation.
	CSFPresent CSFConflictState = "PRESENT"
	// CSFNotObserved — no credible CSF evidence found.
	CSFNotObserved CSFConflictState = "NOT_OBSERVED"
	// CSFUnknown — the host could not be interrogated. Never treated as clean.
	CSFUnknown CSFConflictState = "UNKNOWN"
)

// CodeCSFConflict is the stable finding code for automation.
const CodeCSFConflict = "VAL-CSF-001"

// CSFConflictResult carries the verdict plus the evidence that produced it, so
// an operator is told WHY the host is contested rather than just that it is.
type CSFConflictResult struct {
	State    CSFConflictState
	Evidence []string
}

// csfUnits / csfBinaries are the canonical surfaces. Both units are listed
// because CSF ships two and either alone re-establishes authority; both
// binaries because takeover previously neutralized only /usr/sbin/csf and
// left lfd executable — a proven re-entry plane.
var (
	csfUnits    = []string{"csf.service", "lfd.service"}
	csfBinaries = []string{"/usr/sbin/csf", "/usr/sbin/lfd"}
	csfConfigs  = []string{"/etc/csf/csf.conf"}
	csfCrons    = []string{"/etc/cron.d/csf-cron", "/etc/cron.d/lfd-cron", "/etc/cron.d/csf_update"}
)

// DetectCSFConflict reports whether CSF is effective or re-enterable.
//
// CONSERVATIVE BY CONSTRUCTION. Any of the following counts as PRESENT:
//
//   - a CSF unit ACTIVE                     (effective now)
//   - a CSF unit ENABLED but failed/inactive (re-enters on boot or restart —
//     this is the arm-3 shape that previously read as "absent")
//   - an executable CSF binary at its canonical path (invokable directly)
//   - CSF config or cron persistence present (re-arms on reinstall/schedule)
//
// If systemd cannot be interrogated at all, the answer is UNKNOWN — never
// NOT_OBSERVED. Absence of evidence is not evidence of absence.
func DetectCSFConflict() CSFConflictResult {
	var ev []string
	var inert []string // persistence artifacts with no execution plane behind them
	systemdUsable := false

	checker := SystemdChecker{}
	for _, unit := range csfUnits {
		state, detail := checker.CheckUnit(unit)
		if state != RuntimeError {
			systemdUsable = true
		}
		if state == RuntimeRunning {
			ev = append(ev, unit+" active")
			continue
		}
		// ENABLED-BUT-NOT-ACTIVE is the arm-3 trap: the unit reads as
		// inactive/failed yet still starts on boot. Treat it as re-entry.
		// `masked` is the ONE enabled-state that is genuinely neutralized —
		// that is what an authorized takeover produces, and it must not be
		// reported as a conflict or takeover could never reach PROTECTED.
		if en, ok := unitEnabledState(unit); ok {
			systemdUsable = true
			switch en {
			case "enabled", "enabled-runtime", "static", "alias":
				ev = append(ev, unit+" "+en+" ("+detail+") — re-enters on boot")
			}
		}
	}

	// EXECUTION PLANE. Only an executable binary can actually act.
	executable := false
	for _, bin := range csfBinaries {
		if isExecutableFile(bin) {
			executable = true
			ev = append(ev, bin+" executable")
		}
	}

	// PERSISTENCE PLANE — CORRECTED 2026-08-12 after package-native validation.
	//
	// Config and cron were previously counted as conflicts on their own. That
	// made VAL-CSF-001 UNCLEARABLE after a SUCCESSFUL takeover: the doctrine
	// deliberately RETAINS /etc/csf as audit evidence, so the host stayed
	// "contested" forever and could never return to PROTECTED. Measured on
	// el9-clean: services masked, both binaries .disabled, cron.d empty — and
	// the finding still fired on csf.conf alone.
	//
	// Persistence is only re-entry when something can EXECUTE. A cron line or
	// a config file with no runnable binary and no startable unit cannot
	// re-arm anything:
	//
	//     PERSISTENCE_ARTIFACT_PRESENT != REENTRY_CAPABLE
	//
	// This is the false-FAIL mirror of the original defect, and it is just as
	// wrong: a status that can never say PROTECTED is as useless as one that
	// always does.
	for _, cron := range csfCrons {
		if fileExists(cron) {
			if executable {
				ev = append(ev, cron+" present — scheduled re-entry")
			} else {
				// Recorded but not a conflict: inert without an executable.
				inert = append(inert, cron+" present (inert — no executable CSF binary)")
			}
		}
	}
	for _, cfg := range csfConfigs {
		if fileExists(cfg) {
			if executable {
				ev = append(ev, cfg+" present")
			} else {
				inert = append(inert, cfg+" present (retained as evidence — no execution plane)")
			}
		}
	}

	switch {
	case len(ev) > 0:
		return CSFConflictResult{State: CSFPresent, Evidence: ev}
	case len(inert) > 0:
		// Neutralized: payload/config on disk, nothing able to run it.
		return CSFConflictResult{State: CSFNotObserved, Evidence: inert}
	case !systemdUsable:
		// Could not query systemd AND found nothing on disk: we did not prove
		// the host is clean, we failed to look. Fail closed.
		return CSFConflictResult{
			State:    CSFUnknown,
			Evidence: []string{"systemd not queryable — CSF state could not be established"},
		}
	default:
		return CSFConflictResult{State: CSFNotObserved}
	}
}

// csfConflictFinding converts the verdict into a validator finding.
// Returns nil when there is nothing to report.
//
// SeverityError (not Critical) is deliberate: a contested host is DEGRADED,
// not DOWN. NFTBan's own authority may be perfectly healthy — what is untrue
// is calling that state PROTECTED.
func csfConflictFinding(r CSFConflictResult) *Finding {
	switch r.State {
	case CSFPresent:
		return &Finding{
			Code:      CodeCSFConflict,
			Severity:  SeverityError,
			Component: "csf",
			Message: "CSF is effective or able to re-enter — NFTBan is not the sole firewall authority (" +
				strings.Join(r.Evidence, "; ") + ")",
			Remediation: "Run an authorized takeover to neutralize CSF, or remove CSF from this host.",
		}
	case CSFUnknown:
		return &Finding{
			Code:        CodeCSFConflict,
			Severity:    SeverityError,
			Component:   "csf",
			Message:     "CSF conflict state UNKNOWN — " + strings.Join(r.Evidence, "; ") + "; protection cannot be asserted",
			Remediation: "Restore systemd/D-Bus availability so firewall authority can be verified.",
		}
	default:
		return nil
	}
}

// isReentryEnabledState reports whether a `systemctl is-enabled` value means
// the unit can still come back on its own.
//
// `masked` / `masked-runtime` / `disabled` are EXCLUDED on purpose: masking is
// exactly what an authorized takeover produces. Counting it as a conflict
// would mean no host could ever reach PROTECTED after a successful takeover —
// trading a false PASS for a false FAIL.
func isReentryEnabledState(state string) bool {
	switch state {
	case "enabled", "enabled-runtime", "static", "alias":
		return true
	default:
		return false
	}
}

// unitEnabledState returns `systemctl is-enabled <unit>` output and whether
// the query itself succeeded in producing a state. Read-only.
//
// NOTE the exit code is deliberately ignored: `is-enabled` exits non-zero for
// perfectly meaningful states such as "disabled" and "masked". Treating a
// non-zero exit as "no answer" would discard the very evidence this probe
// exists to collect.
func unitEnabledState(unit string) (string, bool) {
	out, _ := procenv.Command("systemctl", "is-enabled", unit).Output()
	s := strings.TrimSpace(string(out))
	if s == "" {
		return "", false
	}
	return s, true
}

// ---- small read-only helpers -------------------------------------------------

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// isExecutableFile deliberately uses Lstat semantics via Stat on the canonical
// path: a payload renamed to `.disabled` is intentionally NOT matched, because
// it can no longer execute at that path. Retained evidence is not re-entry
// capability (PAYLOAD_PRESERVED_FOR_EVIDENCE != PAYLOAD_CAPABLE_OF_REENTRY).
func isExecutableFile(p string) bool {
	fi, err := os.Stat(p)
	if err != nil || fi.IsDir() {
		return false
	}
	return fi.Mode().Perm()&0o111 != 0
}
