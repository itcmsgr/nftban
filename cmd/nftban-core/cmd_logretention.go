// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-core-logretention"
// meta:type="cli"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="nftban-core logretention subcommand (Gate B / v1.222.0): `status [--json]` reports the effective log-retention policy from the AUTHORITATIVE generated-state record + LIVE filesystem/usage/override facts (fabricating nothing — no bytes-reclaimed/last-cleanup guesses); `generate` runs the atomic generated-policy transaction (INTENDED to be invoked by install/%post + timer + config-change hooks — that wiring is pending audit R2; today it is a manual/root entrypoint). This imports internal/logretention, so the nftban-core binary changes; the nftband daemon does NOT import it."
// meta:input="generated-state JSON, statfs(/var/log), du(/var/log/nftban), conf.d/logs.conf"
// meta:output="human or JSON status; generation transaction"
// meta:depends="github.com/itcmsgr/nftban/internal/logretention,github.com/itcmsgr/nftban/pkg/version"
// meta:inventory.files="cmd/nftban-core/cmd_logretention.go"
// meta:inventory.binaries="nftban-core,logrotate"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/logs.conf,/etc/logrotate.d/nftban,/etc/logrotate.d/nftban-suricata"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root (generate writes /etc/logrotate.d + /var/lib/nftban/generated); status is read-only"
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"

	lr "github.com/itcmsgr/nftban/internal/logretention"
	"github.com/itcmsgr/nftban/pkg/version"
)

// Default paths. Each is overridable by an env var (used by tests and, where
// useful, hooks); production uses the defaults.
func lrStatePath() string {
	return envOr("NFTBAN_LR_STATE", "/var/lib/nftban/generated/logrotate/nftban-effective.state.json")
}
func lrMainPath() string  { return envOr("NFTBAN_LR_MAIN", "/etc/logrotate.d/nftban") }
func lrSuriPath() string  { return envOr("NFTBAN_LR_SURICATA", "/etc/logrotate.d/nftban-suricata") }
func lrLogDir() string    { return envOr("NFTBAN_LR_LOGDIR", "/var/log") }
func lrNftbanLog() string { return envOr("NFTBAN_LR_NFTBANLOG", "/var/log/nftban") }
func lrConfPath() string  { return envOr("NFTBAN_LR_CONF", "/etc/nftban/conf.d/logs.conf") }

func envOr(env, def string) string {
	if v := os.Getenv(env); v != "" {
		return v
	}
	return def
}

func cmdLogRetention(args []string) int {
	if len(args) == 0 {
		return lrUsage()
	}
	switch args[0] {
	case "status":
		return lrStatusCmd(args[1:])
	case "generate":
		return lrGenerateCmd(args[1:])
	case "recover":
		return lrRecoverCmd(args[1:])
	case "help", "-h", "--help":
		return lrUsage()
	default:
		fmt.Fprintf(os.Stderr, "unknown logretention subcommand: %s\n", args[0])
		return lrUsage()
	}
}

func lrUsage() int {
	fmt.Println("Usage:")
	fmt.Println("  nftban-core logretention status [--json]   Report the effective log-retention policy")
	fmt.Println("  nftban-core logretention generate [reason] Regenerate the effective logrotate policy")
	fmt.Println("  nftban-core logretention recover           Complete/undo an interrupted activation (crash-safe)")
	return 2
}

// retentionStatus is the reported view. LIVE fields are read at report time;
// policy fields come from the authoritative generated-state record. R9: fit is
// RECOMPUTED from live available space, active files are RE-HASHED live (drift is
// surfaced, never assumed from the frozen record), and detected != effective
// profile are reported separately.
type retentionStatus struct {
	// overall state machine (R9/Z1): INTERRUPTED_ACTIVATION | NOT_GENERATED |
	// STATE_UNREADABLE | STATE_UNPARSEABLE | POLICY_MISSING | CAPACITY_CONFLICT |
	// ACTIVE_DRIFT | STALE_STATE | ACTIVE_MATCH | GENERATION_FAILED
	OverallState     string `json:"overall_state"`
	StateAvailable   bool   `json:"state_available"`
	StateStale       bool   `json:"state_stale"`
	StaleReason      string `json:"stale_reason,omitempty"`
	ValidationStatus string `json:"validation_status"`

	// Z1: an activation journal is present -> a prior generation was interrupted
	// and the on-disk policy set may be split until `logretention recover` (or the
	// next generate) runs. While true, status NEVER reports ACTIVE_MATCH.
	InterruptedActivation bool `json:"interrupted_activation"`

	// policy facts (from generated state)
	PolicyVersion          string            `json:"policy_version"`
	GeneratorVersion       string            `json:"generator_version"`
	SourceVersion          string            `json:"source_version"`
	PolicyMode             string            `json:"policy_mode"`
	PolicySource           string            `json:"policy_source"`
	DetectedProfile        string            `json:"detected_profile"`  // LIVE, disk-only classification NOW
	EffectiveProfile       string            `json:"effective_profile"` // what the ACTIVE policy was generated with
	EffectiveBudgetBytes   uint64            `json:"effective_budget_bytes"`
	RequestedBudgetBytes   uint64            `json:"requested_budget_bytes"`
	MinimumAchievableBytes uint64            `json:"minimum_achievable_bytes"`
	TheoreticalMaxBytes    uint64            `json:"theoretical_max_bytes_uncompressed"`
	ForensicFloorKind      string            `json:"forensic_floor_kind"`
	FitVerdictAtGeneration string            `json:"fit_verdict_at_generation"`
	LiveFitVerdict         string            `json:"live_fit_verdict"` // recomputed vs CURRENT available space
	CapacityVerdict        string            `json:"capacity_verdict"`
	Achievable             bool              `json:"achievable"`
	UnboundedStanzas       int               `json:"unbounded_stanzas"`
	GeneratedAt            string            `json:"generated_at"`
	GenerationReason       string            `json:"generation_reason"`
	ActivePolicyHashes     map[string]string `json:"active_policy_hashes"` // hashes recorded at generation
	ActivePolicyDrift      map[string]string `json:"active_policy_drift"`  // path -> match|drift|missing (LIVE re-hash)
	PerFamilyPolicy        []lr.FamilyPolicy `json:"per_family_policy"`

	// live facts (read at report time)
	OperatorOverrides           lr.Overrides `json:"operator_overrides"`
	FilesystemPath              string       `json:"filesystem_path"`
	FilesystemTotalBytes        uint64       `json:"filesystem_total_bytes"`
	FilesystemNonRootAvailBytes uint64       `json:"filesystem_nonroot_available_bytes"`
	FilesystemUsedReservedBytes uint64       `json:"filesystem_used_or_reserved_bytes"` // total - non-root-avail
	NftbanLogUsageBytes         uint64       `json:"nftban_log_usage_bytes"`

	// Timer fields OMITTED until a regeneration timer is wired; bytes_reclaimed /
	// last_cleanup_success are never reported (no durable runtime record exists).
}

func lrStatusCmd(args []string) int {
	asJSON := false
	for _, a := range args {
		if a == "--json" {
			asJSON = true
		}
	}
	st := buildStatus()
	if asJSON {
		b, err := json.MarshalIndent(st, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return 1
		}
		fmt.Println(string(b))
		return 0
	}
	printStatusHuman(st)
	return 0
}

func buildStatus() retentionStatus {
	var s retentionStatus

	// LIVE facts first (always available even without a generated state).
	s.FilesystemPath = lrLogDir()
	var liveDisk lr.DiskFacts
	if disk, err := lr.DetectDiskFacts(lrLogDir()); err == nil {
		liveDisk = disk
		s.FilesystemTotalBytes = disk.TotalBytes
		s.FilesystemNonRootAvailBytes = disk.AvailBytes
		if disk.TotalBytes >= disk.AvailBytes {
			s.FilesystemUsedReservedBytes = disk.TotalBytes - disk.AvailBytes
		}
		// detected profile is the LIVE disk-only classification right now.
		s.DetectedProfile = lr.ClassifyProfile(disk, false, "").Name
	}
	s.NftbanLogUsageBytes = dirUsageBytes(lrNftbanLog())
	liveOverrides, _ := lr.LoadOverrides(lrConfPath())
	s.OperatorOverrides = liveOverrides
	s.PolicyMode = liveOverridesMode(liveOverrides)

	// Z1: detect an interrupted activation up front (read-only). It overrides
	// every coherent verdict below so status can never claim ACTIVE_MATCH (or even
	// NOT_GENERATED) over a policy set that may be split mid-activation.
	s.InterruptedActivation = lr.PendingActivation(lrMainPath())

	// policy facts from the authoritative generated-state record
	data, err := os.ReadFile(lrStatePath())
	if err != nil {
		if os.IsNotExist(err) {
			s.ValidationStatus, s.OverallState = "NOT_GENERATED", "NOT_GENERATED"
		} else {
			s.ValidationStatus, s.OverallState = "STATE_UNREADABLE", "STATE_UNREADABLE"
		}
		if s.InterruptedActivation {
			s.OverallState = "INTERRUPTED_ACTIVATION"
		}
		return s
	}
	var gs lr.GeneratedState
	if err := json.Unmarshal(data, &gs); err != nil {
		s.ValidationStatus, s.OverallState = "STATE_UNPARSEABLE", "STATE_UNPARSEABLE"
		if s.InterruptedActivation {
			s.OverallState = "INTERRUPTED_ACTIVATION"
		}
		return s
	}

	s.StateAvailable = true
	s.PolicyVersion = gs.PolicyVersion
	s.GeneratorVersion = gs.GeneratorVersion
	s.SourceVersion = gs.SourceVersion
	s.PolicyMode = liveOverridesMode(gs.Overrides)
	s.PolicySource = gs.PolicySource
	s.EffectiveProfile = gs.Profile.Name
	if s.DetectedProfile == "" {
		s.DetectedProfile = gs.Profile.Name
	}
	s.EffectiveBudgetBytes = gs.BudgetBytes
	s.RequestedBudgetBytes = gs.RequestedBudgetBytes
	s.MinimumAchievableBytes = gs.MinimumAchievableBytes
	s.TheoreticalMaxBytes = gs.TheoreticalMaxBytes
	s.ForensicFloorKind = gs.ForensicFloorKind
	s.FitVerdictAtGeneration = gs.FitVerdict
	// R9: recompute fit against CURRENT available space (the frozen record may lie).
	if liveDisk.TotalBytes > 0 {
		s.LiveFitVerdict = lr.FitVerdictFor(gs.TheoreticalMaxBytes, liveDisk.AvailBytes)
	} else {
		s.LiveFitVerdict = gs.FitVerdict
	}
	s.CapacityVerdict = gs.CapacityVerdict
	s.Achievable = gs.Achievable
	s.UnboundedStanzas = gs.UnboundedCount
	s.GeneratedAt = gs.GeneratedAt
	s.GenerationReason = gs.Reason
	s.ActivePolicyHashes = gs.ActivePolicyHashes
	s.PerFamilyPolicy = gs.Families
	if gs.ValidationOK {
		s.ValidationStatus = "VALIDATED"
	} else {
		s.ValidationStatus = "UNVALIDATED"
	}

	// R9: LIVE re-hash of the activated policy files vs the recorded hashes →
	// surface content drift (a hand-edit of the generated file is otherwise
	// invisible) and missing files.
	s.ActivePolicyDrift = map[string]string{}
	anyDrift, anyMissing := false, false
	for base, recorded := range gs.ActivePolicyHashes {
		path := lrMainPath()
		if base == "nftban-suricata" {
			path = lrSuriPath()
		}
		live := fileSHA256(path)
		switch {
		case live == "":
			s.ActivePolicyDrift[base] = "missing"
			anyMissing = true
		case live == recorded:
			s.ActivePolicyDrift[base] = "match"
		default:
			s.ActivePolicyDrift[base] = "drift"
			anyDrift = true
		}
	}

	// staleness: live operator config differs from what generated the active policy.
	if normalizeOverrides(liveOverrides) != normalizeOverrides(gs.Overrides) {
		s.StateStale = true
		s.StaleReason = "operator config changed since last generation"
	}

	// R9 overall state machine (most-severe first). Z1: an interrupted activation
	// is the most severe — the on-disk set may be split, so no coherent verdict
	// (least of all ACTIVE_MATCH) may be reported until recovery runs.
	switch {
	case s.InterruptedActivation:
		s.OverallState = "INTERRUPTED_ACTIVATION"
	case !gs.ValidationOK:
		s.OverallState = "GENERATION_FAILED"
	case anyMissing:
		s.OverallState = "POLICY_MISSING"
	case !gs.Achievable:
		s.OverallState = "CAPACITY_CONFLICT"
	case anyDrift:
		s.OverallState = "ACTIVE_DRIFT"
	case s.StateStale:
		s.OverallState = "STALE_STATE"
	default:
		s.OverallState = "ACTIVE_MATCH"
	}
	return s
}

func fileSHA256(path string) string {
	data, err := os.ReadFile(path) // #nosec G304 -- status reads generator-owned policy/state paths (NFTBAN_LR_* or fixed defaults)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func normalizeOverrides(o lr.Overrides) lr.Overrides {
	if o.Mode == "" {
		o.Mode = "auto"
	}
	if o.Profile == "" {
		o.Profile = "auto"
	}
	return o
}

func liveOverridesMode(o lr.Overrides) string {
	if o.Mode == "" {
		return "auto"
	}
	return o.Mode
}

// dirUsageBytes sums regular-file sizes under root (best-effort; skips errors).
func dirUsageBytes(root string) uint64 {
	var total uint64
	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip unreadable entries; never fail the whole report
		}
		if d.Type().IsRegular() {
			if info, e := d.Info(); e == nil && info.Size() > 0 {
				total += uint64(info.Size())
			}
		}
		return nil
	})
	return total
}

func printStatusHuman(s retentionStatus) {
	fmt.Println("NFTBan Log Retention — Effective Policy")
	fmt.Println("=======================================")
	fmt.Printf("  Status:           %s\n", s.OverallState)
	if s.StateAvailable {
		fmt.Printf("  Validation:       %s\n", s.ValidationStatus)
		fmt.Printf("  Policy version:   %s (generator %s)\n", s.PolicyVersion, s.GeneratorVersion)
		fmt.Printf("  Source version:   %s\n", orDash(s.SourceVersion))
		fmt.Printf("  Mode / source:    %s / %s\n", s.PolicyMode, s.PolicySource)
		fmt.Printf("  Profile:          effective=%s  detected-now=%s\n", s.EffectiveProfile, s.DetectedProfile)
		fmt.Printf("  Generated at:     %s (reason: %s)\n", s.GeneratedAt, orDash(s.GenerationReason))
	} else {
		fmt.Printf("  Mode:             %s (no active generated policy yet)\n", s.PolicyMode)
	}
	fmt.Println("  --- filesystem (live) ---")
	fmt.Printf("  %-18s %s total, %s non-root-avail, %s used+reserved\n", s.FilesystemPath+":",
		human(s.FilesystemTotalBytes), human(s.FilesystemNonRootAvailBytes), human(s.FilesystemUsedReservedBytes))
	fmt.Printf("  /var/log/nftban:   %s in use (live)\n", human(s.NftbanLogUsageBytes))
	if s.StateAvailable {
		fmt.Println("  --- budget (from generated state) ---")
		fmt.Printf("  Requested / effective budget: %s / %s\n", human(s.RequestedBudgetBytes), human(s.EffectiveBudgetBytes))
		fmt.Printf("  Min achievable (floor):       %s\n", human(s.MinimumAchievableBytes))
		fmt.Printf("  Theoretical max (uncompressed worst-case, NOT expected disk use): %s\n", human(s.TheoreticalMaxBytes))
		fmt.Printf("  Capacity verdict:  %s (achievable=%v)\n", s.CapacityVerdict, s.Achievable)
		fmt.Printf("  Fit (at generation / LIVE now): %s / %s\n", s.FitVerdictAtGeneration, s.LiveFitVerdict)
		fmt.Printf("  Forensic floor:    %s (day figures are TARGETS; size pressure may shorten elapsed days)\n", s.ForensicFloorKind)
		fmt.Printf("  Active policy:     %s\n", driftSummary(s.ActivePolicyDrift))
		fmt.Println("  --- per-family (class | rotate=generations / size / target-days / floor / writer) ---")
		for _, f := range s.PerFamilyPolicy {
			fmt.Printf("    %-18s %-18s rotate=%-3d size=%-6s target=%-3dd floor=%-3dd worst=%-6s %s/%s\n",
				f.Key, f.SemanticClass, f.RotateCount, human(f.SizeCapBytes), f.RetentionDays, f.ForensicFloorDays,
				human(f.WorstCaseBytes), f.AuthorityRole, f.WriterStrategy)
		}
	}
	if s.InterruptedActivation {
		fmt.Println("\n  WARNING: a prior policy generation was interrupted (activation journal present). The on-disk policy set may be split. Run `nftban-core logretention recover` (or wait for the next maintenance cycle) — status will not report a coherent state until then.")
	}
	if s.OverallState == "ACTIVE_DRIFT" {
		fmt.Println("\n  NOTE: an activated policy file was edited by hand (content drift). Overrides belong in /etc/nftban/conf.d/logs.conf; the generated file is derived state.")
	}
	if s.StateStale {
		fmt.Printf("\n  NOTE: %s — regenerated on the next maintenance cycle.\n", s.StaleReason)
	}
	if s.OverallState == "CAPACITY_CONFLICT" {
		fmt.Println("\n  WARNING: the forensic floor exceeds the filesystem capacity — the active policy may be a preserved prior policy. Add capacity or lower LOG_RETENTION_MIN_DAYS.")
	}
}

func driftSummary(m map[string]string) string {
	if len(m) == 0 {
		return "-"
	}
	out := ""
	for k, v := range m {
		if out != "" {
			out += ", "
		}
		out += k + "=" + v
	}
	return out
}

func lrGenerateCmd(args []string) int {
	reason := "manual"
	if len(args) > 0 && args[0] != "" {
		reason = args[0]
	}
	src := version.Version
	if version.GitCommit != "" && version.GitCommit != "dev" {
		src = version.Version + "+" + version.GitCommit
	}
	suri := ""
	if _, err := os.Stat(lrSuriPath()); err == nil {
		suri = lrSuriPath() // only regenerate the suricata file if it is installed
	}
	// honor operator overrides from logs.conf (invalid overrides fail here, before
	// any file is touched — the previous policy is preserved).
	overrides, err := lr.LoadOverrides(lrConfPath())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: invalid log-retention config (previous policy preserved): %v\n", err)
		return 1
	}
	st, err := lr.Generate(lr.GenerateOptions{
		LogDir:        lrLogDir(),
		MainPath:      lrMainPath(),
		SuricataPath:  suri,
		StatePath:     lrStatePath(),
		Overrides:     overrides,
		SourceVersion: src,
		Reason:        reason,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: log-retention generation failed (previous policy preserved): %v\n", err)
		return 1
	}
	fmt.Printf("Generated effective log-retention policy: profile=%s budget=%s theoretical-max=%s fit=%s unbounded=%d\n",
		st.Profile.Name, human(st.BudgetBytes), human(st.TheoreticalMaxBytes), st.FitVerdict, st.UnboundedCount)
	return 0
}

// lrRecoverCmd deterministically completes or unwinds an interrupted activation.
// It is the explicit entry point for startup and for the maintenance step that
// runs BEFORE logrotate, so a crash never leaves a split policy set to be fixed
// only by the next full regeneration.
func lrRecoverCmd(_ []string) int {
	res, err := lr.Recover(lrMainPath())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: log-retention recovery failed: %v\n", err)
		return 1
	}
	if !res.JournalFound {
		fmt.Println("Log-retention: no interrupted activation pending (nothing to recover).")
		return 0
	}
	fmt.Printf("Log-retention: recovered an interrupted activation (from=%s action=%s targets=%v).\n",
		res.FromState, res.Action, res.Targets)
	return 0
}

func human(b uint64) string {
	const k = 1024
	switch {
	case b >= k*k*k:
		return fmt.Sprintf("%.1fG", float64(b)/float64(k*k*k))
	case b >= k*k:
		return fmt.Sprintf("%dM", b/(k*k))
	case b >= k:
		return fmt.Sprintf("%dK", b/k)
	default:
		return fmt.Sprintf("%dB", b)
	}
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
