// =============================================================================
// NFTBan v1.100.x PR26.1 - Reusable Install Validation: Systemd Payload
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-systemd-payload"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Generic systemd-payload validation: execstart paths, timer pairing, payload inventory, failed nftban units"
// meta:inventory.files="internal/installer/validate/systemd_payload.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR26.1 invariants enforced here:
//
//	SYSTEMD-EXECSTART-001     every nftban-* unit's ExecStart/Pre/Post
//	                          local executable path must exist on disk
//	                          after payload staging.
//	SYSTEMD-TIMER-PAIR-001    every installed nftban-*.timer must
//	                          activate an installed nftban service unit.
//	PAYLOAD-INVENTORY-001     every nftban-owned local path referenced
//	                          by an nftban systemd unit must belong to
//	                          the staged payload inventory.
//	FAILED-UNIT-POSTINSTALL-001 no nftban-* unit may be in failed state
//	                          after install/update apply.
//
// Generic by design — no panel logic, no DirectAdmin specifics, no
// firewall-runtime mutation. Decisions are file/parse only. The host-
// side wrapper that feeds this function lives in
// systemd_payload_gather.go; tests pass synthetic inputs directly.
//
// =============================================================================

package validate

import (
	"strings"
	"time"
)

// nftbanUnitExtensions lists the systemd unit suffixes considered in
// scope for PR26.1 invariants. Anything outside this set (e.g.,
// .conf in tmpfiles.d, .preset) is ignored.
var nftbanUnitExtensions = map[string]bool{
	"service": true,
	"timer":   true,
	"socket":  true,
	"target":  true,
	"path":    true,
	"mount":   true,
}

// IsNftbanUnit returns true if a unit basename is owned by nftban
// for the purposes of these invariants. Recognized shapes:
//
//	nftban.<ext>            — singular "nftban" unit (legacy)
//	nftband.<ext>           — Go daemon unit (note: no hyphen between
//	                          "nftban" and "d" — distinct from
//	                          nftban-* units; both are owned)
//	nftban-<anything>.<ext> — any hyphenated nftban-prefixed unit
//	nftband-<anything>.<ext>— any hyphenated nftband-prefixed unit
//
// where <ext> is one of the suffixes in nftbanUnitExtensions.
//
// The matcher is structural rather than enumerated so that future unit
// shapes (sockets, targets, paths) are covered without a code change.
// "fake-nftban.service" / "nftbanfake.service" / "sshd.service" do
// NOT match — the prefix must be a complete identifier separated by
// '-' or by the unit-extension dot.
func IsNftbanUnit(basename string) bool {
	dot := strings.LastIndexByte(basename, '.')
	if dot <= 0 || dot == len(basename)-1 {
		return false
	}
	ext := basename[dot+1:]
	if !nftbanUnitExtensions[ext] {
		return false
	}
	stem := basename[:dot]
	if stem == "nftban" || stem == "nftband" {
		return true
	}
	if strings.HasPrefix(stem, "nftban-") || strings.HasPrefix(stem, "nftband-") {
		return true
	}
	return false
}

// auxiliaryUnitStems lists nftban unit stems (basename without extension)
// whose failure is an observability/metrics degradation, NOT a loss of
// firewall protection. A failure in one of these is surfaced as a non-fatal
// warning and does NOT flip failed_units_postinstall_ok — so a transient
// auxiliary failure (notably the unified exporter's exit-2 during a package
// swap, D-EXPORTER-SETTLE-WINDOW) cannot DEGRADE the install or poison an
// update. Protection-critical units (nftband, nftban-core, firewall-init)
// are deliberately absent and remain hard failures.
var auxiliaryUnitStems = map[string]bool{
	"nftban-unified-exporter": true,
}

// IsAuxiliaryUnit reports whether an nftban unit basename is an auxiliary
// (metrics/observability) unit per auxiliaryUnitStems. Non-nftban units are
// never auxiliary (they are out of scope for these invariants entirely).
func IsAuxiliaryUnit(basename string) bool {
	if !IsNftbanUnit(basename) {
		return false
	}
	dot := strings.LastIndexByte(basename, '.')
	if dot <= 0 {
		return false
	}
	return auxiliaryUnitStems[basename[:dot]]
}

// staleClearableOneshotStems lists nftban oneshot-processor unit stems whose
// `failed` state is a sticky systemd latch (Type=oneshot) that does NOT clear
// itself and does NOT reflect live protection state (the root nftband.service is
// the protection authority). A failure of one of these strictly BEFORE the
// install window is, by construction, a latch from the PREVIOUS version — it
// cannot have been caused by this upgrade. Such a latch can itself make a live
// `nftban health` probe read unclean, which is a circular block that kept the
// general WARN_PRE_EXISTING_RECOVERED rule (which requires LiveHealthClean) from
// ever recovering it. v1.185.1 (CORE-BOTSCAN-PROCESSOR-TIMEOUT stale-DEGRADED on
// upgrade, proven on monitor: a v1.184 300s botscan timeout survived the v1.185
// upgrade and neither the upgrade nor --repair could clear it).
var staleClearableOneshotStems = map[string]bool{
	"nftban-botscan": true,
	// v1.198.1 PR-B (D-NFTBAN-ALERT-LOGGER-DEVLOG-PERMISSION /
	// D-V198-STICKY-DEGRADED-NO-RECOMMIT-PATH): the OnFailure service-failure
	// alert is Type=oneshot and latches `failed` from a past nftband restart
	// (before PR-A made its logger sandbox-safe, the alert exited non-zero every
	// time it fired). Its latch pre-dating the install window cannot have been
	// caused by this upgrade, and it can itself make the live-health probe read
	// unclean — the same circular block v1.185.1 fixed for nftban-botscan — so
	// recover it without the live-health gate. The stem is the TEMPLATE form
	// ("nftban-alert@"); isStaleClearableOneshot reduces instance stems
	// ("nftban-alert@nftband.service") to it.
	"nftban-alert@": true,
}

// isStaleClearableOneshot reports whether an nftban unit basename is a
// stale-clearable oneshot processor per staleClearableOneshotStems. Only the
// processor oneshot (nftban-botscan.service, stem "nftban-botscan") matches —
// the collector (stem "nftban-botscan-collector") does not.
func isStaleClearableOneshot(basename string) bool {
	if !IsNftbanUnit(basename) {
		return false
	}
	dot := strings.LastIndexByte(basename, '.')
	if dot <= 0 {
		return false
	}
	stem := basename[:dot]
	// v1.198.1 PR-B: a template-instance unit (nftban-alert@<instance>.service)
	// carries an instance-specific stem (e.g. "nftban-alert@nftband.service").
	// Reduce it to the template stem ("nftban-alert@") so one map entry matches
	// every instance. Non-template stems are unchanged.
	if at := strings.IndexByte(stem, '@'); at >= 0 {
		stem = stem[:at+1]
	}
	return staleClearableOneshotStems[stem]
}

// ParsedUnit is the minimum subset of a systemd unit file needed for
// PR26.1 validation. Constructed by the host-side gatherer or by
// tests directly.
type ParsedUnit struct {
	// Name is the unit basename (e.g., "nftban-unified-exporter.service").
	Name string

	// Path is the absolute on-disk path of the unit file.
	Path string

	// IsTimer is true for *.timer units.
	IsTimer bool

	// Execs is the list of ExecStart/Pre/Post/Stop directives extracted
	// from [Service]. Order preserved for diagnostic output.
	Execs []ExecDirective

	// TimerUnit is the [Timer] Unit= value (or implicit basename.service
	// when the directive is absent). Empty for non-timer units.
	TimerUnit string
}

// ExecDirective records one Exec* line from a unit file.
type ExecDirective struct {
	// Directive is one of ExecStart, ExecStartPre, ExecStartPost,
	// ExecStop, ExecStopPost, ExecReload.
	Directive string

	// Raw is the full RHS as written in the unit file (after the "=").
	Raw string

	// Binary is the resolved primary executable absolute path.
	// For wrapper invocations like "/bin/sh -c '...'", this is "/bin/sh"
	// and EmbeddedNftbanPaths captures any nftban-owned absolute paths
	// found inside the quoted argument.
	Binary string

	// EmbeddedNftbanPaths lists any nftban-owned absolute paths
	// discovered inside Raw that are NOT the primary Binary. Caught
	// from common shell-wrapper patterns ("/bin/sh -c '/usr/lib/...sh'",
	// "/usr/bin/env BAR=1 /usr/lib/...bin").
	EmbeddedNftbanPaths []string
}

// FailedUnitFinding describes one nftban-* unit currently in failed
// state per `systemctl list-units --state=failed`.
type FailedUnitFinding struct {
	Unit   string
	Active string // e.g., "failed"
	Sub    string // e.g., "failed", "exit-code"
	Detail string // best-effort short description, may be empty

	// FailureTime is the unit's last-failure timestamp (most recent of
	// InactiveEnterTimestamp / ExecMainExitTimestamp from `systemctl show`).
	// v1.174 D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE: used to classify
	// a failed unit as pre-existing (failed before the install window) vs
	// in-window. Zero value when unknown.
	FailureTime time.Time

	// FailureTimeKnown is true only when FailureTime was parsed
	// successfully. When false, the unit is treated as a hard failure
	// (fail closed) — an unparseable timestamp can never be classified as
	// pre-existing/recovered.
	FailureTimeKnown bool
}

// PayloadInventory describes which paths are considered known after
// install staging.
type PayloadInventory struct {
	// Paths is the set of absolute paths the staged install knows
	// about. Population strategy: populate from the install's payload
	// destination table (see internal/installer/payload).
	Paths map[string]bool

	// NftbanOwnedPrefixes lists absolute path prefixes that, if a unit
	// references a path under one of them, that path MUST be in Paths
	// or referenced via a system-binary wrapper. Typical:
	// "/usr/lib/nftban/", "/usr/sbin/nftban", "/etc/nftban/".
	NftbanOwnedPrefixes []string

	// SystemBinaryPrefixes lists absolute path prefixes whose contents
	// are NOT required to be in Paths. Typical: "/usr/bin/", "/bin/",
	// "/usr/sbin/" (excluding the singular "/usr/sbin/nftban"), "/sbin/".
	SystemBinaryPrefixes []string
}

// SystemdPayloadInputs aggregates everything ValidateInstalledSystemdPayload
// needs. Decoupled from executor.Executor and the live filesystem so
// the validator can be exercised by fixture tests.
type SystemdPayloadInputs struct {
	// Units is the parsed nftban-owned unit set in the install scope.
	// Non-nftban units are filtered upstream by the gatherer; this
	// validator does NOT enforce invariants on third-party units.
	Units []ParsedUnit

	// PathExists reports whether an absolute path exists on disk.
	// Tests stub with a closure over a map; production wires through
	// the executor.
	PathExists func(absPath string) bool

	// Inventory holds payload-known paths and prefix policy.
	Inventory PayloadInventory

	// FailedNftbanUnits is the set of currently-failed nftban units.
	// Populated upstream from `systemctl list-units --state=failed`.
	FailedNftbanUnits []FailedUnitFinding

	// FailedUnitQueryError is non-empty when the upstream gatherer
	// could not enumerate failed units (e.g., systemctl missing,
	// non-zero exit, dbus unavailable). When set,
	// FAILED-UNIT-POSTINSTALL-001 fails closed: the absence of
	// findings cannot be distinguished from a healthy install.
	// Operator must resolve the enumeration error before
	// StateCommitted is permitted.
	FailedUnitQueryError string

	// AllUnitNames is the set of every unit basename present in the
	// install's unit directories (services + timers + sockets). Used
	// by SYSTEMD-TIMER-PAIR-001 to confirm a timer's target service
	// is installed alongside it.
	AllUnitNames map[string]bool

	// InstallWindowStart is the wall-clock instant the current installer
	// run began (set once at the very start of the run via
	// SetInstallWindowStart). A failed unit whose FailureTime is strictly
	// before this instant is "pre-existing"; one at/after is "in-window".
	// v1.174 D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE.
	InstallWindowStart time.Time

	// InstallWindowStartKnown is true only when InstallWindowStart was
	// set. When false, no failed unit can be classified as pre-existing —
	// all non-aux failures stay fatal (fail closed).
	InstallWindowStartKnown bool

	// LiveHealthClean reports whether a bounded live `nftban health` probe
	// returned a clean overall status (Overall OK/IDLE, Findings: none, no
	// CRITICAL). Only consulted to downgrade a PRE_EXISTING latched failure.
	LiveHealthClean bool

	// LiveHealthKnown is true only when the live-health probe produced a
	// confident clean/not-clean verdict. When false (probe timeout, missing
	// binary, unparseable output, non-zero exit), no downgrade is permitted
	// — pre-existing failures stay fatal (fail closed).
	LiveHealthKnown bool
}

// MissingExecPath records one SYSTEMD-EXECSTART-001 hit.
type MissingExecPath struct {
	UnitFile  string
	Directive string
	Path      string
	RawLine   string
}

// MissingTimerTarget records one SYSTEMD-TIMER-PAIR-001 hit.
type MissingTimerTarget struct {
	TimerUnit  string
	TargetUnit string
}

// UnknownPayloadRef records one PAYLOAD-INVENTORY-001 hit: a unit
// references an nftban-owned path that is not known to the staged
// payload inventory.
type UnknownPayloadRef struct {
	UnitFile string
	Path     string
}

// FailedUnitPostInstall records one FAILED-UNIT-POSTINSTALL-001 hit.
type FailedUnitPostInstall struct {
	Unit   string
	Detail string

	// Classification is the v1.174 disposition of the failure, one of:
	// "" (default / in-window fatal), "IN_WINDOW", "PRE_EXISTING_FATAL"
	// (pre-existing but live health not clean/unknown), or
	// "WARN_PRE_EXISTING_RECOVERED" (pre-existing + live health clean —
	// non-fatal). Diagnostic only; the fatal/non-fatal decision is encoded
	// by which result bucket the entry lands in.
	Classification string
}

// SystemdPayloadValidationResult is the structured outcome.
type SystemdPayloadValidationResult struct {
	// OK is true iff every invariant passed.
	OK bool

	// MissingExecPaths is the SYSTEMD-EXECSTART-001 finding set.
	MissingExecPaths []MissingExecPath

	// MissingTimerTargets is the SYSTEMD-TIMER-PAIR-001 finding set.
	MissingTimerTargets []MissingTimerTarget

	// UnknownPayloadRefs is the PAYLOAD-INVENTORY-001 finding set.
	UnknownPayloadRefs []UnknownPayloadRef

	// FailedUnits is the FAILED-UNIT-POSTINSTALL-001 finding set, restricted
	// to protection-critical units. A non-empty slice fails the invariant.
	FailedUnits []FailedUnitPostInstall

	// FailedAuxiliaryUnits holds failed nftban units classified as auxiliary
	// (metrics/observability — see IsAuxiliaryUnit). These are surfaced as a
	// non-fatal warning and do NOT fail FAILED-UNIT-POSTINSTALL-001 (so a
	// transient exporter exit-2 cannot DEGRADE the install — D-EXPORTER-
	// SETTLE-WINDOW, v1.135).
	FailedAuxiliaryUnits []FailedUnitPostInstall

	// FailedUnitsPreExistingRecovered holds protection-critical nftban units
	// that were ALREADY in a failed state before this install window started
	// AND whose live `nftban health` probe is clean. v1.174 D-INSTALL-FAILED-
	// UNITS-STALE-LATCHED-STATE: these are a stale latch, not a fresh break,
	// so they are surfaced as WARN_PRE_EXISTING_RECOVERED and do NOT fail
	// FAILED-UNIT-POSTINSTALL-001 (install COMMITTED-with-warning). A newly-
	// failed unit, or a pre-existing one with live health not clean/unknown,
	// stays in FailedUnits (fatal) — fail safe toward DEGRADED.
	FailedUnitsPreExistingRecovered []FailedUnitPostInstall

	// FailedUnitQueryError mirrors SystemdPayloadInputs.FailedUnitQueryError
	// for the assertion-side detail message. When non-empty,
	// FAILED-UNIT-POSTINSTALL-001 fails closed regardless of
	// FailedUnits content.
	FailedUnitQueryError string
}

// ExecStartOK reports whether SYSTEMD-EXECSTART-001 passed.
func (r SystemdPayloadValidationResult) ExecStartOK() bool { return len(r.MissingExecPaths) == 0 }

// TimerPairOK reports whether SYSTEMD-TIMER-PAIR-001 passed.
func (r SystemdPayloadValidationResult) TimerPairOK() bool { return len(r.MissingTimerTargets) == 0 }

// PayloadInventoryOK reports whether PAYLOAD-INVENTORY-001 passed.
func (r SystemdPayloadValidationResult) PayloadInventoryOK() bool {
	return len(r.UnknownPayloadRefs) == 0
}

// FailedUnitsOK reports whether FAILED-UNIT-POSTINSTALL-001 passed.
// Fails closed if the failed-unit query itself errored: an empty
// FailedUnits slice cannot prove a healthy install when the
// enumeration source was unreachable.
func (r SystemdPayloadValidationResult) FailedUnitsOK() bool {
	return r.FailedUnitQueryError == "" && len(r.FailedUnits) == 0
}

// ValidateInstalledSystemdPayload runs all four PR26.1 invariants and
// returns the aggregate result. Pure function — no I/O. Caller assembles
// SystemdPayloadInputs from the live host (gatherer) or test fixtures.
func ValidateInstalledSystemdPayload(in SystemdPayloadInputs) SystemdPayloadValidationResult {
	var res SystemdPayloadValidationResult

	for _, u := range in.Units {
		if !IsNftbanUnit(u.Name) {
			continue
		}

		// SYSTEMD-EXECSTART-001 + PAYLOAD-INVENTORY-001
		for _, e := range u.Execs {
			checkExecPath(&res, in, u, e, e.Binary)
			for _, p := range e.EmbeddedNftbanPaths {
				checkExecPath(&res, in, u, e, p)
			}
		}

		// SYSTEMD-TIMER-PAIR-001
		if u.IsTimer {
			target := u.TimerUnit
			if target == "" {
				target = strings.TrimSuffix(u.Name, ".timer") + ".service"
			}
			if !IsNftbanUnit(target) {
				// Timer pointing at a non-nftban unit — outside scope.
				continue
			}
			if !in.AllUnitNames[target] {
				res.MissingTimerTargets = append(res.MissingTimerTargets, MissingTimerTarget{
					TimerUnit:  u.Name,
					TargetUnit: target,
				})
			}
		}
	}

	// FAILED-UNIT-POSTINSTALL-001
	res.FailedUnitQueryError = in.FailedUnitQueryError
	for _, f := range in.FailedNftbanUnits {
		if !IsNftbanUnit(f.Unit) {
			continue
		}
		detail := f.Detail
		if detail == "" {
			detail = strings.TrimSpace(f.Active + " " + f.Sub)
		}
		entry := FailedUnitPostInstall{Unit: f.Unit, Detail: detail}
		// v1.135 D-EXPORTER-SETTLE-WINDOW: route auxiliary (metrics/
		// observability) failures into a separate non-fatal bucket so they
		// do not flip FailedUnitsOK(). Protection units stay in FailedUnits.
		if IsAuxiliaryUnit(f.Unit) {
			res.FailedAuxiliaryUnits = append(res.FailedAuxiliaryUnits, entry)
			continue
		}

		// v1.174 D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE: classify a
		// protection-critical failure as pre-existing (failed strictly before
		// the install window started) vs in-window. A pre-existing latch with
		// a clean live `nftban health` probe is a stale flag from before this
		// run — downgrade to non-fatal WARN_PRE_EXISTING_RECOVERED. Everything
		// else (in-window failure, unparseable failure time, unknown window
		// start, live health not clean / unknown) stays FATAL — fail safe
		// toward DEGRADED. A newly-failed unit is NEVER labeled recovered.
		preExisting := in.InstallWindowStartKnown &&
			f.FailureTimeKnown &&
			f.FailureTime.Before(in.InstallWindowStart)
		// General rule: pre-existing + clean live health = stale latch, recovered.
		recovered := preExisting && in.LiveHealthKnown && in.LiveHealthClean
		// v1.185.1: a stale-clearable oneshot processor (nftban-botscan.service,
		// Type=oneshot) latches `failed` from a previous-version run; that latch can
		// itself make the live-health probe read unclean, a circular block that left
		// the general rule above unable to recover it. A failure strictly BEFORE the
		// install window cannot have been caused by this upgrade, so recover it
		// WITHOUT the live-health gate. Real in-window failures (FailureTime not
		// before the window → preExisting=false) still fall through to IN_WINDOW.
		if preExisting && isStaleClearableOneshot(f.Unit) {
			recovered = true
		}
		if recovered {
			entry.Classification = "WARN_PRE_EXISTING_RECOVERED"
			res.FailedUnitsPreExistingRecovered = append(res.FailedUnitsPreExistingRecovered, entry)
			continue
		}
		if preExisting {
			entry.Classification = "PRE_EXISTING_FATAL"
		} else {
			entry.Classification = "IN_WINDOW"
		}
		res.FailedUnits = append(res.FailedUnits, entry)
	}

	res.OK = res.ExecStartOK() && res.TimerPairOK() && res.PayloadInventoryOK() && res.FailedUnitsOK()
	return res
}

// checkExecPath applies SYSTEMD-EXECSTART-001 and PAYLOAD-INVENTORY-001
// to a single absolute path referenced by a unit's Exec* directive.
func checkExecPath(res *SystemdPayloadValidationResult, in SystemdPayloadInputs, u ParsedUnit, e ExecDirective, p string) {
	if p == "" {
		return
	}
	if !strings.HasPrefix(p, "/") {
		// Not an absolute path — the parser only emits absolute paths,
		// but guard anyway.
		return
	}

	// Decide ownership category.
	nftbanOwned := hasAnyPrefix(p, in.Inventory.NftbanOwnedPrefixes)
	systemBinary := hasAnyPrefix(p, in.Inventory.SystemBinaryPrefixes)

	// SYSTEMD-EXECSTART-001 — the file must exist on disk. System
	// binary wrappers are still required to exist; missing /bin/sh
	// is a real bug.
	if !in.PathExists(p) {
		res.MissingExecPaths = append(res.MissingExecPaths, MissingExecPath{
			UnitFile:  u.Path,
			Directive: e.Directive,
			Path:      p,
			RawLine:   e.Raw,
		})
	}

	// PAYLOAD-INVENTORY-001 — nftban-owned paths must be in the
	// staged inventory. System binaries are exempt by definition.
	if nftbanOwned && !systemBinary {
		if in.Inventory.Paths == nil || !in.Inventory.Paths[p] {
			res.UnknownPayloadRefs = append(res.UnknownPayloadRefs, UnknownPayloadRef{
				UnitFile: u.Path,
				Path:     p,
			})
		}
	}
}

// hasAnyPrefix returns true if p starts with any prefix in prefixes.
func hasAnyPrefix(p string, prefixes []string) bool {
	for _, pre := range prefixes {
		if pre == "" {
			continue
		}
		if strings.HasPrefix(p, pre) {
			return true
		}
	}
	return false
}

// ParseUnitFile parses raw systemd unit content and returns a ParsedUnit.
// path is the absolute on-disk path; name is the unit basename.
//
// Parsing scope (intentionally narrow):
//   - section detection by [Section] header
//   - Exec* directives in [Service]
//   - Unit= directive in [Timer]
//   - leading systemd prefixes ('-', '+', '!', '!!', '@') are stripped
//
// Continuation lines (trailing backslash) are joined. Comments (#, ;)
// and blank lines are ignored. Quoting is respected: a quoted token is
// treated as a single argument; absolute-path scan inside the
// shell-wrapper case looks for tokens starting with '/'.
func ParseUnitFile(name, path, content string) ParsedUnit {
	pu := ParsedUnit{
		Name:    name,
		Path:    path,
		IsTimer: strings.HasSuffix(name, ".timer"),
	}

	section := ""
	logical := joinContinuations(content)
	for _, line := range strings.Split(logical, "\n") {
		raw := strings.TrimSpace(line)
		if raw == "" || strings.HasPrefix(raw, "#") || strings.HasPrefix(raw, ";") {
			continue
		}
		if strings.HasPrefix(raw, "[") && strings.HasSuffix(raw, "]") {
			section = strings.TrimSuffix(strings.TrimPrefix(raw, "["), "]")
			continue
		}

		eq := strings.IndexByte(raw, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(raw[:eq])
		val := strings.TrimSpace(raw[eq+1:])

		switch section {
		case "Service":
			if isExecDirective(key) {
				bin, embedded := parseExecValue(val)
				pu.Execs = append(pu.Execs, ExecDirective{
					Directive:           key,
					Raw:                 val,
					Binary:              bin,
					EmbeddedNftbanPaths: embedded,
				})
			}
		case "Timer":
			if key == "Unit" {
				pu.TimerUnit = val
			}
		}
	}
	return pu
}

func isExecDirective(key string) bool {
	switch key {
	case "ExecStart", "ExecStartPre", "ExecStartPost",
		"ExecStop", "ExecStopPost", "ExecReload":
		return true
	}
	return false
}

// joinContinuations folds backslash-continued logical lines into a single
// physical line per logical entry.
func joinContinuations(s string) string {
	lines := strings.Split(s, "\n")
	var out []string
	var buf strings.Builder
	for _, ln := range lines {
		trimmedRight := strings.TrimRight(ln, " \t")
		if strings.HasSuffix(trimmedRight, "\\") {
			buf.WriteString(strings.TrimSuffix(trimmedRight, "\\"))
			buf.WriteString(" ")
			continue
		}
		buf.WriteString(ln)
		out = append(out, buf.String())
		buf.Reset()
	}
	if buf.Len() > 0 {
		out = append(out, buf.String())
	}
	return strings.Join(out, "\n")
}

// parseExecValue extracts the primary binary and any embedded nftban-owned
// absolute paths from a systemd Exec* RHS.
//
// Strips leading systemd prefixes ('-', '+', '!', '!!', '@') from the
// first token. For wrapper invocations like
//
//	/bin/sh -c '/usr/lib/nftban/exporters/x.sh'
//	/usr/bin/env FOO=bar /usr/lib/nftban/sbin/y
//
// Binary is the first absolute-path token, and EmbeddedNftbanPaths
// captures any nftban-owned absolute paths found in the remaining tokens
// (after stripping a single layer of single/double quotes).
func parseExecValue(rhs string) (binary string, embedded []string) {
	rhs = strings.TrimSpace(rhs)
	rhs = stripSystemdPrefixes(rhs)

	tokens := tokenizeShellish(rhs)
	if len(tokens) == 0 {
		return "", nil
	}

	binary = tokens[0]

	for _, tok := range tokens[1:] {
		// Look inside the token for absolute paths under nftban-owned
		// prefixes. We don't want to flag every "-c" or "--config".
		for _, frag := range scanAbsolutePaths(tok) {
			if isNftbanOwnedPath(frag) {
				embedded = append(embedded, frag)
			}
		}
	}
	return binary, embedded
}

// stripSystemdPrefixes removes the leading control characters systemd
// allows on Exec* values: '-' (ignore failure), '+' (full privilege),
// '!' / '!!' (run with raised privileges), '@' (custom argv[0]).
// They may be combined; strip iteratively until the next byte is a path
// or non-prefix character.
func stripSystemdPrefixes(s string) string {
	for {
		s = strings.TrimLeft(s, " \t")
		if s == "" {
			return s
		}
		switch s[0] {
		case '-', '+', '!', '@':
			s = s[1:]
		default:
			return s
		}
	}
}

// tokenizeShellish splits a systemd Exec line on whitespace, respecting
// single and double quotes. Not a full shell parser — adequate for
// argv-style ExecStart RHS values.
func tokenizeShellish(s string) []string {
	var tokens []string
	var cur strings.Builder
	inSingle, inDouble := false, false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case inSingle:
			if c == '\'' {
				inSingle = false
				continue
			}
			cur.WriteByte(c)
		case inDouble:
			if c == '"' {
				inDouble = false
				continue
			}
			cur.WriteByte(c)
		case c == '\'':
			inSingle = true
		case c == '"':
			inDouble = true
		case c == ' ' || c == '\t':
			if cur.Len() > 0 {
				tokens = append(tokens, cur.String())
				cur.Reset()
			}
		default:
			cur.WriteByte(c)
		}
	}
	if cur.Len() > 0 {
		tokens = append(tokens, cur.String())
	}
	return tokens
}

// scanAbsolutePaths returns every contiguous run of [/A-Za-z0-9_.-] that
// starts with '/' inside tok. Catches paths embedded in shell command
// strings like '/bin/sh -c "/usr/lib/nftban/exporters/x.sh"' even when
// the token itself is the whole quoted command.
func scanAbsolutePaths(tok string) []string {
	var out []string
	i := 0
	for i < len(tok) {
		if tok[i] != '/' {
			i++
			continue
		}
		j := i
		for j < len(tok) && isPathByte(tok[j]) {
			j++
		}
		if j > i+1 {
			out = append(out, tok[i:j])
		}
		i = j
		if i == j {
			i++
		}
	}
	return out
}

func isPathByte(b byte) bool {
	switch {
	case b >= 'a' && b <= 'z':
		return true
	case b >= 'A' && b <= 'Z':
		return true
	case b >= '0' && b <= '9':
		return true
	case b == '/' || b == '_' || b == '-' || b == '.':
		return true
	}
	return false
}

// isNftbanOwnedPath returns true for paths matching the canonical
// nftban-owned prefix set used by this validator's default policy.
// The full prefix policy is configurable via PayloadInventory; this
// helper is for the embedded-path scan inside shell wrappers, where
// the inventory prefix list is not yet visible.
func isNftbanOwnedPath(p string) bool {
	return strings.HasPrefix(p, "/usr/lib/nftban/") ||
		strings.HasPrefix(p, "/etc/nftban/") ||
		p == "/usr/sbin/nftban"
}
