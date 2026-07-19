// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-core-logretention"
// meta:type="cli"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="nftban-core logretention subcommand (Gate B Phase 7): `status [--json]` reports the effective log-retention policy from the AUTHORITATIVE generated-state record + LIVE filesystem/usage/override facts (fabricating nothing — no bytes-reclaimed/last-cleanup guesses); `generate` runs the atomic generated-policy transaction (used by install/timer/config-change hooks). This imports internal/logretention, so the nftban-core binary changes; the nftband daemon does NOT import it."
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
	return 2
}

// retentionStatus is the reported view. Fields marked as live are read at report
// time; policy fields come from the authoritative generated-state record.
type retentionStatus struct {
	StateAvailable   bool   `json:"state_available"`
	StateStale       bool   `json:"state_stale"`
	StaleReason      string `json:"stale_reason,omitempty"`
	ValidationStatus string `json:"validation_status"`

	// policy facts (from generated state)
	PolicyVersion        string            `json:"policy_version"`
	GeneratorVersion     string            `json:"generator_version"`
	SourceVersion        string            `json:"source_version"`
	PolicyMode           string            `json:"policy_mode"`
	PolicySource         string            `json:"policy_source"`
	DetectedProfile      string            `json:"detected_profile"`
	EffectiveProfile     string            `json:"effective_profile"`
	EffectiveBudgetBytes uint64            `json:"effective_budget_bytes"`
	TheoreticalMaxBytes  uint64            `json:"theoretical_max_bytes"`
	FitVerdict           string            `json:"fit_verdict"`
	UnboundedStanzas     int               `json:"unbounded_stanzas"`
	GeneratedAt          string            `json:"generated_at"`
	GenerationReason     string            `json:"generation_reason"`
	ActivePolicyHashes   map[string]string `json:"active_policy_hashes"`
	PerFamilyPolicy      []lr.FamilyPolicy `json:"per_family_policy"`

	// live facts (read at report time)
	OperatorOverrides        lr.Overrides `json:"operator_overrides"`
	FilesystemPath           string       `json:"filesystem_path"`
	FilesystemTotalBytes     uint64       `json:"filesystem_total_bytes"`
	FilesystemAvailableBytes uint64       `json:"filesystem_available_bytes"`
	FilesystemUsedBytes      uint64       `json:"filesystem_used_bytes"`
	NftbanLogUsageBytes      uint64       `json:"nftban_log_usage_bytes"`

	// Timer fields are intentionally OMITTED until a regeneration timer is wired
	// (Phase 8); reporting them now would not be authoritative. bytes_reclaimed /
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

	// live facts first (always available even without a generated state)
	s.FilesystemPath = lrLogDir()
	if disk, err := lr.DetectDiskFacts(lrLogDir()); err == nil {
		s.FilesystemTotalBytes = disk.TotalBytes
		s.FilesystemAvailableBytes = disk.AvailBytes
		if disk.TotalBytes >= disk.AvailBytes {
			s.FilesystemUsedBytes = disk.TotalBytes - disk.AvailBytes
		}
	}
	s.NftbanLogUsageBytes = dirUsageBytes(lrNftbanLog())
	liveOverrides, _ := lr.LoadOverrides(lrConfPath())
	s.OperatorOverrides = liveOverrides

	// policy facts from the authoritative generated-state record
	data, err := os.ReadFile(lrStatePath())
	if err != nil {
		if os.IsNotExist(err) {
			s.ValidationStatus = "NOT_GENERATED"
		} else {
			s.ValidationStatus = "STATE_UNREADABLE"
		}
		s.PolicyMode = liveOverridesMode(liveOverrides)
		return s
	}
	var gs lr.GeneratedState
	if err := json.Unmarshal(data, &gs); err != nil {
		s.ValidationStatus = "STATE_UNPARSEABLE"
		s.PolicyMode = liveOverridesMode(liveOverrides)
		return s
	}

	s.StateAvailable = true
	s.PolicyVersion = gs.PolicyVersion
	s.GeneratorVersion = gs.GeneratorVersion
	s.SourceVersion = gs.SourceVersion
	s.PolicyMode = liveOverridesMode(gs.Overrides)
	s.PolicySource = gs.PolicySource
	s.DetectedProfile = gs.Profile.Name
	s.EffectiveProfile = gs.Profile.Name
	s.EffectiveBudgetBytes = gs.BudgetBytes
	s.TheoreticalMaxBytes = gs.TheoreticalMaxBytes
	s.FitVerdict = gs.FitVerdict
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

	// staleness: the live operator config differs from what generated the active
	// policy → the active policy predates a config change (a regeneration is due).
	// Compare normalized (""=="auto") so no spurious stale flag.
	if normalizeOverrides(liveOverrides) != normalizeOverrides(gs.Overrides) {
		s.StateStale = true
		s.StaleReason = "operator config changed since last generation"
	}
	return s
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
	fmt.Printf("  State:            %s%s\n", s.ValidationStatus, staleSuffix(s))
	if s.StateAvailable {
		fmt.Printf("  Policy version:   %s (generator %s)\n", s.PolicyVersion, s.GeneratorVersion)
		fmt.Printf("  Source version:   %s\n", orDash(s.SourceVersion))
		fmt.Printf("  Mode / source:    %s / %s\n", s.PolicyMode, s.PolicySource)
		fmt.Printf("  Profile:          %s\n", s.EffectiveProfile)
		fmt.Printf("  Generated at:     %s (reason: %s)\n", s.GeneratedAt, orDash(s.GenerationReason))
	} else {
		fmt.Printf("  Mode:             %s (no active generated policy yet)\n", s.PolicyMode)
	}
	fmt.Println("  --- filesystem (live) ---")
	fmt.Printf("  %-18s %s\n", s.FilesystemPath+":", human(s.FilesystemTotalBytes)+" total, "+human(s.FilesystemAvailableBytes)+" avail, "+human(s.FilesystemUsedBytes)+" used")
	fmt.Printf("  /var/log/nftban:   %s in use (live)\n", human(s.NftbanLogUsageBytes))
	if s.StateAvailable {
		fmt.Println("  --- budget (from generated state) ---")
		fmt.Printf("  Effective budget:  %s\n", human(s.EffectiveBudgetBytes))
		fmt.Printf("  Theoretical max:   %s\n", human(s.TheoreticalMaxBytes))
		fmt.Printf("  Fit verdict:       %s\n", s.FitVerdict)
		fmt.Printf("  Unbounded stanzas: %d\n", s.UnboundedStanzas)
		fmt.Printf("  Active hashes:     %s\n", hashSummary(s.ActivePolicyHashes))
		fmt.Println("  --- per-family (rotate / size / retention / forensic-floor) ---")
		for _, f := range s.PerFamilyPolicy {
			fmt.Printf("    %-18s rotate=%-3d size=%-6s ret=%-3dd floor=%-3dd worst=%s\n",
				f.Key, f.RotateCount, human(f.SizeCapBytes), f.RetentionDays, f.ForensicFloorDays, human(f.WorstCaseBytes))
		}
	}
	if s.StateStale {
		fmt.Printf("\n  NOTE: %s — run `nftban logs retention generate` (or wait for the next scheduled regeneration).\n", s.StaleReason)
	}
}

func staleSuffix(s retentionStatus) string {
	if s.StateStale {
		return " (STALE — config changed since generation)"
	}
	return ""
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

func hashSummary(m map[string]string) string {
	if len(m) == 0 {
		return "-"
	}
	out := ""
	for k, v := range m {
		short := v
		if len(short) > 12 {
			short = short[:12]
		}
		if out != "" {
			out += ", "
		}
		out += k + "=" + short
	}
	return out
}
