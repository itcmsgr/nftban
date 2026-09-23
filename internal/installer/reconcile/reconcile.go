// =============================================================================
// NFTBan v1.233.x Lane B — LIFECYCLE RECONCILIATION (RECONCILE)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-lifecycle-reconcile"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-23"
// meta:description="Derives lifecycle truth from proven live reality for a REBUILD_REFUSED_BUSY host, without mutating that reality. Holds the convergence lock for the whole proof, asserts package/runtime/connlimit semantics against ONE ruleset observation, attributes that observation with a versioned structure fingerprint, requires the convergence generation to be unchanged across the proof, and only then persists a complete replacement record atomically."
// meta:inventory.files="internal/installer/reconcile/reconcile.go"
// meta:inventory.binaries="nft,systemctl"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/var/lib/nftban/state/install_state"
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package reconcile

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/structure"
	"github.com/itcmsgr/nftban/internal/nftlock"
)

// ═════════════════════════════════════════════════════════════════════════════════
// THE CONTRACT
// ═════════════════════════════════════════════════════════════════════════════════
//
//	acquire convergence authority
//	        ↓  generation_before = G
//	assert eligibility        (state's own definition: no rebuild ran)
//	assert package identity   (what is installed == what the record claims)
//	assert live runtime       (daemon active, nftban authority present)
//	assert connlimit semantics(keyed per-source, family-correlated, zero bare)
//	        ↓  derive canonical static structure from THE SAME observation
//	        ↓  fingerprint = sha256(canonical)
//	        ↓  generation_after = G
//	require generation_before == generation_after
//	        ↓
//	atomically persist the complete replacement record
//
// ⛔ IF THE GENERATION MOVES, REFUSE — EVEN IF EVERY ASSERTION INDIVIDUALLY PASSED.
// A convergence that committed while the proof was running means the validator may have
// observed a structure that changed underneath it, and the fingerprint would then
// attribute a structure that no longer exists.
//
// ⛔ RUNTIME IS NEVER MUTATED. No rebuild, no reinstall, no reload, no nft write. The
// only write this package performs is the lifecycle record and its forensic event.
//
//	LIFECYCLE STATE MUST BE DERIVED FROM PROVEN LIVE REALITY;
//	LIVE REALITY MUST NEVER BE ALTERED MERELY TO SATISFY LIFECYCLE STATE.

// ForensicLogPath is the append-only RECONCILE event log.
//
// ⛔ IT IS NOT OPTIONAL BOOKKEEPING. state.Transition clears FAILURE_REASON when it
// reaches COMMITTED (V108 Item 5 terminal hygiene), so after a successful reconciliation
// the record itself no longer says the original SWITCH ever failed. This log is the ONLY
// place that fact survives. RECONCILIATION MUST NOT ERASE THE HISTORY IT RECONCILES.
const ForensicLogPath = "/var/log/nftban/lifecycle-reconcile.jsonl"

// DefaultLockTimeout bounds how long reconciliation waits for the convergence lock.
//
// Chosen to be SHORTER than a legitimate long-running convergence, not longer: if real
// convergence work is in progress, the correct outcome is to refuse and let it finish,
// not to queue behind it and then certify whatever it produced.
const DefaultLockTimeout = 20 * time.Second

// GenerationPath is the canonical convergence generation counter. ⛔ tmpfs; its
// ABSOLUTE value is forensic only — see Event.ObservedGenerationPre.
const GenerationPath = "/run/nftban/convergence-generation"

// bootIDPath identifies the boot the (tmpfs) generation counter belongs to.
const bootIDPath = "/proc/sys/kernel/random/boot_id"

// ─────────────────────────────────────────────────────────────────────────────────
// CONNLIMIT SEMANTICS — asserted on the CANONICAL form, never on raw nft output.
// ─────────────────────────────────────────────────────────────────────────────────
// ⛔ THIS IS WHY IT RUNS ON THE CANONICAL FORM. Counting "bare ct-count rules" over raw
// `nft list ruleset` previously reported 6 survivors on a correctly fixed host: the
// multi-line `elements = { … }` continuation lines of the dynamic connlimit sets each
// contain the literal text `ct count over N` and were counted as rules. That reading
// would have justified rolling back a working fix on a healthy production host.
// structure.FromRuleset elides element interiors and FAILS CLOSED if its brace tracking
// is unreliable, so the population can no longer be mistaken for the structure.
var (
	// add @connlimit_<svc>_v<fam> { <ip|ip6> saddr ct count over <N> }
	reKeyed = regexp.MustCompile(`add @connlimit_([a-z0-9]+)_v([46]) \{ (ip6?) saddr ct count over (\d+) \}`)
	// any ct-count enforcement at all
	reAnyCtCount = regexp.MustCompile(`ct count over \d+`)
)

// acquireConvergence is the convergence-authority seam. Production always uses the
// canonical nftlock; tests replace it. Keeping it a package var rather than an Inputs
// field means no production caller can accidentally pass a weaker lock.
var acquireConvergence = func(timeout time.Duration) (release func(), err error) {
	l, lerr := nftlock.AcquireExclusive(timeout)
	if lerr != nil {
		return nil, lerr
	}
	return l.Release, nil
}

// Inputs configure one reconciliation attempt.
type Inputs struct {
	Exec     executor.Executor
	StateDir string
	// LockTimeout bounds convergence-authority acquisition. Zero uses DefaultLockTimeout.
	LockTimeout time.Duration
	// RunID correlates this attempt with the surrounding operator session.
	RunID string
	// DryRun proves everything and persists NOTHING. The falsification matrix relies on
	// it: every negative case must leave state_before_sha256 == state_after_sha256.
	DryRun bool

	// ── Test seams. Empty means the canonical production path; production NEVER
	// sets these. They exist so the falsification matrix can run hermetically
	// instead of against /run and /var/log on the build host.
	GenerationPath string
	ForensicPath   string
}

// Event is the forensic RECONCILE record.
type Event struct {
	Timestamp     string `json:"timestamp"`
	RunID         string `json:"run_id,omitempty"`
	RecoveryClass string `json:"recovery_class"`
	Outcome       string `json:"outcome"`
	DryRun        bool   `json:"dry_run"`

	PreviousState string `json:"previous_state"`
	NewState      string `json:"new_state,omitempty"`

	// ⛔ THE INVARIANT THIS WHOLE LANE IS ACCOUNTABLE FOR.
	RuntimeMutated bool `json:"runtime_mutated"`

	StructureSchema      string `json:"structure_schema,omitempty"`
	StructureFingerprint string `json:"structure_fingerprint,omitempty"`

	// ⛔ NON-AUTHORITATIVE, FORENSIC ONLY. The convergence generation is a tmpfs
	// counter whose own contract reads only the within-run delta and explicitly not the
	// absolute value. It is recorded WITH the boot id so a reader can never mistake a
	// post-reboot 3 for the same 3 observed here.
	ObservedBootID        string `json:"observed_boot_id,omitempty"`
	ObservedGenerationPre int64  `json:"observed_generation_before"`
	ObservedGenerationPst int64  `json:"observed_generation_after"`

	// The original failure, preserved because the reconciled record cannot keep it.
	OriginalInstallTimestamp string `json:"original_install_timestamp,omitempty"`
	OriginalFailureReason    string `json:"original_failure_reason,omitempty"`
	OriginalRebuildExitCode  int    `json:"original_rebuild_exit_code"`

	Assertions []Assertion `json:"assertions"`
	Refusal    string      `json:"refusal,omitempty"`

	StateSHA256Before string `json:"state_sha256_before,omitempty"`
	StateSHA256After  string `json:"state_sha256_after,omitempty"`
}

// Assertion is one named proof obligation and its result.
type Assertion struct {
	Name    string `json:"name"`
	Passed  bool   `json:"passed"`
	Detail  string `json:"detail,omitempty"`
	Refusal string `json:"refusal,omitempty"`
}

// Outcome is the result of one reconciliation attempt.
type Outcome struct {
	Reconciled bool
	Refusal    string
	Event      Event
}

// Run performs one reconciliation attempt.
//
// It returns (Outcome, nil) for a clean REFUSAL — a refusal is a correct, expected
// result, not an execution error. A non-nil error means the attempt could not be
// carried out at all.
func Run(in Inputs) (Outcome, error) {
	if in.LockTimeout == 0 {
		in.LockTimeout = DefaultLockTimeout
	}
	if in.StateDir == "" {
		in.StateDir = state.DefaultStateDir
	}

	ev := Event{
		Timestamp:     time.Now().UTC().Format(time.RFC3339Nano),
		RunID:         in.RunID,
		RecoveryClass: string(state.RecoveryReconcile),
		DryRun:        in.DryRun,
		// ⛔ SET ONCE, HERE, AND NEVER RECOMPUTED. This package contains no code path
		// that writes to the kernel, so the value is a property of the package, not an
		// observation that could come out either way.
		RuntimeMutated: false,
	}

	sf := state.NewStateFile(in.StateDir)
	if err := sf.Read(); err != nil {
		return Outcome{}, fmt.Errorf("reconcile: cannot read lifecycle record at %s: %w", sf.Path(), err)
	}
	ev.PreviousState = string(sf.State)
	ev.OriginalInstallTimestamp = sf.Timestamp.UTC().Format(time.RFC3339Nano)
	ev.OriginalFailureReason = sf.FailureReason
	ev.OriginalRebuildExitCode = sf.RebuildExitCode
	ev.StateSHA256Before = fileSHA256(sf.Path())

	refuse := func(reason string) (Outcome, error) {
		ev.Outcome = "REFUSED"
		ev.Refusal = reason
		ev.StateSHA256After = fileSHA256(sf.Path())
		appendEvent(in.ForensicPath, ev)
		return Outcome{Reconciled: false, Refusal: reason, Event: ev}, nil
	}
	pass := func(name, detail string) {
		ev.Assertions = append(ev.Assertions, Assertion{Name: name, Passed: true, Detail: detail})
	}
	fail := func(name, reason string) {
		ev.Assertions = append(ev.Assertions, Assertion{Name: name, Passed: false, Refusal: reason})
	}

	// ─── A1. ELIGIBILITY ────────────────────────────────────────────────────────
	if !sf.State.ReconcileEligible() {
		r := fmt.Sprintf("not reconcile-eligible: %s", sf.State.ReconcileRefusalReason())
		fail("eligibility", r)
		return refuse(r)
	}
	pass("eligibility", fmt.Sprintf("%s asserts no rebuild executed and the firewall was not modified", sf.State))

	// ─── A2. CONVERGENCE AUTHORITY ──────────────────────────────────────────────
	// Held for the WHOLE proof. Without it, every assertion below is a snapshot of a
	// system that may be converging as it is read.
	release, lerr := acquireConvergence(in.LockTimeout)
	if lerr != nil {
		r := fmt.Sprintf(
			"convergence authority not acquired within %s (%v) — a convergence may be in progress; "+
				"refusing rather than certifying a structure that is still being written",
			in.LockTimeout, lerr)
		fail("convergence_authority", r)
		return refuse(r)
	}
	defer release()
	pass("convergence_authority", fmt.Sprintf("exclusive %s held for the duration of the proof", nftlock.LockPath))

	ev.ObservedBootID = strings.TrimSpace(readFile(in.Exec, bootIDPath))
	genBefore := readGeneration(in.Exec, in.GenerationPath)
	ev.ObservedGenerationPre = genBefore

	// ─── A3. PACKAGE IDENTITY ───────────────────────────────────────────────────
	installed := strings.TrimSpace(readFile(in.Exec, fhs.VersionFile))
	if installed == "" {
		r := fmt.Sprintf("installed version unreadable at %s — UNMEASURED, never assumed to match", fhs.VersionFile)
		fail("package_identity", r)
		return refuse(r)
	}
	if installed != sf.Version {
		r := fmt.Sprintf(
			"installed version %q does not match the record's INSTALL_VERSION %q — this host is not "+
				"running the transaction being reconciled", installed, sf.Version)
		fail("package_identity", r)
		return refuse(r)
	}
	pass("package_identity", fmt.Sprintf("installed %s == recorded %s", installed, sf.Version))

	// ─── A4. LIVE RUNTIME ───────────────────────────────────────────────────────
	act := in.Exec.Run("systemctl", "is-active", "nftband.service")
	if strings.TrimSpace(act.Stdout) != "active" {
		r := fmt.Sprintf(
			"nftband.service is %q, not active — a lifecycle record may not certify a transaction whose "+
				"runtime is not running", strings.TrimSpace(act.Stdout))
		fail("daemon_active", r)
		return refuse(r)
	}
	pass("daemon_active", "nftband.service active")

	// ─── A5. ONE OBSERVATION, USED FOR BOTH SEMANTICS AND ATTRIBUTION ───────────
	// ⛔ DELIBERATELY A SINGLE READ. If the semantics were proven on one observation
	// and the fingerprint taken from another, the digest would attribute a structure
	// that was never the subject of the proof.
	rs := in.Exec.Run("nft", "-a", "list", "ruleset")
	if rs.TimedOut {
		r := "`nft -a list ruleset` was KILLED by its deadline — the observation did not complete"
		fail("ruleset_observation", r)
		return refuse(r)
	}
	if rs.ExitCode != 0 {
		r := fmt.Sprintf("`nft -a list ruleset` exited %d: %s", rs.ExitCode, strings.TrimSpace(rs.Stderr))
		fail("ruleset_observation", r)
		return refuse(r)
	}
	fp, ferr := structure.FromRuleset(rs.Stdout)
	if ferr != nil {
		fail("structure_canonicalisation", ferr.Error())
		return refuse(ferr.Error())
	}
	pass("structure_canonicalisation",
		fmt.Sprintf("%s: %d structural lines kept, %d volatile lines elided", fp.Schema, fp.KeptLines, fp.ElidedLines))

	// ─── A6. CONNLIMIT SEMANTICS ────────────────────────────────────────────────
	if r := assertConnlimit(fp.Canonical); r != "" {
		fail("connlimit_semantics", r)
		return refuse(r)
	}
	pass("connlimit_semantics", connlimitSummary(fp.Canonical))

	// ─── A7. FRESHNESS ──────────────────────────────────────────────────────────
	genAfter := readGeneration(in.Exec, in.GenerationPath)
	ev.ObservedGenerationPst = genAfter
	if genBefore < 0 || genAfter < 0 {
		r := fmt.Sprintf(
			"convergence generation UNREADABLE (before=%d after=%d) — an unreadable counter is an absence "+
				"of evidence and must never be differenced into a 'did not move' conclusion",
			genBefore, genAfter)
		fail("generation_freshness", r)
		return refuse(r)
	}
	if genBefore != genAfter {
		r := fmt.Sprintf(
			"convergence generation moved %d -> %d DURING the proof — a commit landed while the structure "+
				"was being validated, so the assertions and the fingerprint may describe different rulesets. "+
				"REFUSING even though every individual assertion passed",
			genBefore, genAfter)
		fail("generation_freshness", r)
		return refuse(r)
	}
	pass("generation_freshness", fmt.Sprintf("generation %d unchanged across the proof (boot %s)", genAfter, short(ev.ObservedBootID)))

	ev.StructureSchema = fp.Schema
	ev.StructureFingerprint = fp.Digest
	ev.NewState = string(state.StateCommitted)

	// ─── PERSIST ────────────────────────────────────────────────────────────────
	if in.DryRun {
		ev.Outcome = "DRY_RUN_WOULD_RECONCILE"
		ev.NewState = ""
		ev.StateSHA256After = fileSHA256(sf.Path())
		appendEvent(in.ForensicPath, ev)
		return Outcome{Reconciled: false, Refusal: "", Event: ev}, nil
	}

	// The attempt is journalled BEFORE the record changes, so a crash in the rename
	// window still leaves the original failure on the record.
	attempt := ev
	attempt.Outcome = "PERSIST_ATTEMPT"
	appendEvent(in.ForensicPath, attempt)

	// ⛔ THE COMPLETE REPLACEMENT RECORD IS BUILT IN MEMORY FIRST. No intermediate
	// externally visible state: WriteAtomic renames a fully-formed file into place.
	sf.ConvergenceVerified = state.ConvergenceVerifiedValue
	sf.ConvergenceStructureSchema = fp.Schema
	sf.ConvergenceStructureFingerprint = fp.Digest
	if err := sf.Transition(state.StateCommitted, state.PhaseValidate, ""); err != nil {
		// The state-machine boundary invariant refused. It is a safety net, not a
		// formality — report it as the refusal it is.
		r := fmt.Sprintf("state machine refused the reconciled record: %v", err)
		fail("state_machine_boundary", r)
		return refuse(r)
	}
	if err := sf.WriteAtomic(); err != nil {
		r := fmt.Sprintf("atomic persist failed: %v", err)
		fail("atomic_persist", r)
		return refuse(r)
	}
	pass("atomic_persist", "complete replacement record renamed into place")

	ev.Outcome = "RECONCILED"
	ev.StateSHA256After = fileSHA256(sf.Path())
	appendEvent(in.ForensicPath, ev)
	return Outcome{Reconciled: true, Event: ev}, nil
}

// assertConnlimit proves the shipped per-source keying on the canonical structure.
// Returns "" on success, or the refusal reason.
func assertConnlimit(canonical string) string {
	type svc struct{ v4, v6 bool }
	seen := map[string]*svc{}
	var bare []string

	for _, line := range strings.Split(canonical, "\n") {
		if !reAnyCtCount.MatchString(line) {
			continue
		}
		m := reKeyed.FindStringSubmatch(line)
		if m == nil {
			bare = append(bare, strings.TrimSpace(line))
			continue
		}
		name, fam, key := m[1], m[2], m[3]
		// ⛔ FAMILY CORRELATION IS PROVEN EXPLICITLY, NOT BY ADJACENCY. A single loose
		// pattern such as `@connlimit_\w+_v[46] \{ ip6? saddr` would accept
		// `connlimit_ssh_v4 { ip6 saddr … }` — a set keyed on the WRONG family, which
		// silently governs nothing.
		if (fam == "4" && key != "ip") || (fam == "6" && key != "ip6") {
			return fmt.Sprintf(
				"connlimit set connlimit_%s_v%s is keyed on %q — the family of the set and the family of "+
					"its key selector disagree, so the set governs no traffic", name, fam, key+" saddr")
		}
		if seen[name] == nil {
			seen[name] = &svc{}
		}
		if fam == "4" {
			seen[name].v4 = true
		} else {
			seen[name].v6 = true
		}
	}

	// ⛔ POSITIVE PRESENCE FIRST. "zero bare rules" is satisfied vacuously by a host
	// with NO connlimit enforcement at all. Asserting only the absence would characterise
	// the fix instead of the defect — if the defect were WORSE (all enforcement gone),
	// that arm would still pass.
	if len(seen) == 0 {
		return "no keyed per-source connlimit sets are present — there is no per-source enforcement to certify"
	}
	if len(bare) > 0 {
		return fmt.Sprintf(
			"%d BARE host-wide ct-count rule(s) survive in the canonical structure (first: %q) — these are "+
				"rule-global aggregates with no source key", len(bare), bare[0])
	}
	var incomplete []string
	for name, s := range seen {
		if !s.v4 || !s.v6 {
			incomplete = append(incomplete, fmt.Sprintf("connlimit_%s (v4=%t v6=%t)", name, s.v4, s.v6))
		}
	}
	if len(incomplete) > 0 {
		sort.Strings(incomplete)
		return fmt.Sprintf(
			"service(s) missing a family pair: %s — a service governed on only one family is unprotected "+
				"on the other", strings.Join(incomplete, ", "))
	}
	return ""
}

func connlimitSummary(canonical string) string {
	names := map[string]bool{}
	n := 0
	for _, line := range strings.Split(canonical, "\n") {
		if m := reKeyed.FindStringSubmatch(line); m != nil {
			names[m[1]] = true
			n++
		}
	}
	var out []string
	for k := range names {
		out = append(out, k)
	}
	sort.Strings(out)
	return fmt.Sprintf("%d keyed rules across %d services (%s), 0 bare, all family-correlated",
		n, len(out), strings.Join(out, " "))
}

func readGeneration(exec executor.Executor, path string) int64 {
	if path == "" {
		path = GenerationPath
	}
	// ⛔ SAME SEMANTICS AS switchop.ReadConvergenceGeneration: -1 is NOT OBSERVED, never
	// zero. An absent counter must not be differenced against a real value.
	raw, err := exec.ReadFile(path)
	if err != nil {
		return -1
	}
	var v int64
	if _, serr := fmt.Sscanf(strings.TrimSpace(string(raw)), "%d", &v); serr != nil {
		return -1
	}
	return v
}

func readFile(exec executor.Executor, path string) string {
	b, err := exec.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}

func fileSHA256(path string) string {
	b, err := os.ReadFile(filepath.Clean(path)) // #nosec G304 — installer-owned state path
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func short(s string) string {
	if len(s) > 8 {
		return s[:8]
	}
	return s
}

// appendEvent appends one JSON line. A forensic-log failure never fails the
// reconciliation itself — but it is never silent either.
func appendEvent(path string, ev Event) {
	if path == "" {
		path = ForensicLogPath
	}
	b, err := json.Marshal(ev)
	if err != nil {
		fmt.Fprintf(os.Stderr, "reconcile: forensic event could not be encoded: %v\n", err)
		return
	}
	if mkErr := os.MkdirAll(filepath.Dir(path), 0750); mkErr != nil {
		fmt.Fprintf(os.Stderr, "reconcile: forensic log dir unavailable: %v\n", mkErr)
		return
	}
	f, oerr := os.OpenFile(filepath.Clean(path), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640) // #nosec G304
	if oerr != nil {
		fmt.Fprintf(os.Stderr, "reconcile: forensic log unwritable: %v\n", oerr)
		return
	}
	defer func() { _ = f.Close() }()
	if _, werr := f.Write(append(b, '\n')); werr != nil {
		fmt.Fprintf(os.Stderr, "reconcile: forensic event not written: %v\n", werr)
	}
}
