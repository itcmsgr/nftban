// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-generate"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Phase-5 generated-policy transaction (Model B). Treats the logrotate files as DERIVED STATE, never operator config. Acquires an exclusive generation lock; renders all candidates into the target filesystem; validates the COMBINED effective policy with `logrotate -d --state <tmp>` (debug=no rotation; temp state=real state untouched; explicit file args=active policy never co-loaded); then a two-file ATOMIC activation with explicit ROLLBACK (no split-brain: if either file fails to activate, BOTH previous files are restored); writes the generated-state record only after a fully successful activation; preserves the previous valid policy on any failure; removes temporaries; records prior+active SHA-256 hashes."
// meta:depends="crypto/sha256,encoding/json,os,os/exec,syscall"
// meta:inventory.files="internal/logretention/generate.go"
// meta:inventory.env_vars=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.binaries="logrotate"
// meta:inventory.config_files="install/config/nftban.logrotate,install/config/nftban-suricata.logrotate"
// meta:inventory.privileges="root (writes /etc/logrotate.d + /var/lib/nftban/generated)"
package logretention

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// GeneratorVersion is the version of the generation transaction/state writer,
// distinct from PolicyVersion (the rendered-policy + state schema version).
const GeneratorVersion = "1"

const prevSuffix = ".nftban-prev"

// Validator validates one or more candidate logrotate files TOGETHER without
// executing any rotation and without touching the real logrotate state or the
// active policy. It returns the exact command string (for the state record) and
// an error if any candidate is invalid or logrotate is unavailable.
type Validator func(candidatePaths []string) (cmd string, err error)

// DefaultValidator runs `logrotate -d --state <temp> <candidate>...`:
//   - `-d` (debug): parse + simulate only, no file is rotated.
//   - `--state <temp>`: a throwaway state file, so /var/lib/logrotate/logrotate.status
//     is never read or written — the real logrotate state is untouched.
//   - explicit candidate paths as the config args: logrotate reads ONLY those
//     files and does not pull in /etc/logrotate.d/* (no `include` in our
//     candidates), so the active policy is never co-loaded. Passing all
//     candidates together validates the combined effective policy.
//
// Missing logrotate returns an error → the caller fails safe and keeps the
// previous policy.
func DefaultValidator(candidatePaths []string) (string, error) {
	lr, err := exec.LookPath("logrotate")
	if err != nil {
		return "", fmt.Errorf("logretention: logrotate not found (cannot validate candidate): %w", err)
	}
	stateFile, err := os.CreateTemp("", "nftban-lr-validate-state-*")
	if err != nil {
		return "", fmt.Errorf("logretention: temp state: %w", err)
	}
	stateName := stateFile.Name()
	_ = stateFile.Close()
	defer func() { _ = os.Remove(stateName) }()

	bases := make([]string, len(candidatePaths))
	for i, p := range candidatePaths {
		bases[i] = filepath.Base(p)
	}
	cmdStr := "logrotate -d --state <temp> " + strings.Join(bases, " ")
	args := append([]string{"-d", "--state", stateName}, candidatePaths...)
	out, err := exec.Command(lr, args...).CombinedOutput() //nolint:gosec // fixed flags, candidate paths are generator-owned
	if err != nil {
		return cmdStr, fmt.Errorf("logretention: candidate failed logrotate validation: %w\n%s", err, strings.TrimSpace(string(out)))
	}
	return cmdStr, nil
}

// GenerateOptions parameterizes the transaction. Target paths are absolute; the
// temp/rename happens in each target's own directory so each rename is atomic on
// the same filesystem.
type GenerateOptions struct {
	LogDir        string // filesystem whose capacity backs the budget (default /var/log)
	MainPath      string // e.g. /etc/logrotate.d/nftban (required)
	SuricataPath  string // e.g. /etc/logrotate.d/nftban-suricata ("" to skip)
	StatePath     string // generated-state JSON path
	LockPath      string // exclusive generation lock ("" -> derived next to StatePath/MainPath)
	Families      []LogFamily
	Overrides     Overrides
	Disk          DiskFacts // if zero-value, DetectDiskFacts(LogDir) is used
	Profile       Profile   // if empty Name, ClassifyProfile is used
	PanelPresent  bool      // input to profile classification when Profile is auto
	SourceVersion string    // NFTBan version/commit stamped into the state record
	Reason        string    // "install" | "config-change" | "timer" | "manual"
	Now           time.Time // injected clock (zero -> time.Now().UTC())
	Validator     Validator // injectable (nil -> DefaultValidator)
}

// GeneratedState is the evidence record written after a successful activation.
type GeneratedState struct {
	PolicyVersion        string            `json:"policy_version"`
	GeneratorVersion     string            `json:"generator_version"`
	GeneratedAt          string            `json:"generated_at"`
	SourceVersion        string            `json:"source_version"`
	Reason               string            `json:"generation_reason"`
	Profile              Profile           `json:"profile"`
	Disk                 DiskFacts         `json:"filesystem"`
	Overrides            Overrides         `json:"operator_overrides"`
	PolicySource         string            `json:"policy_source"`
	BudgetBytes          uint64            `json:"budget_bytes"`
	TheoreticalMaxBytes  uint64            `json:"theoretical_max_bytes"`
	UnboundedCount       int               `json:"unbounded_stanzas"`
	FitVerdict           string            `json:"fit_verdict"`
	Families             []FamilyPolicy    `json:"families"` // each carries ForensicFloorDays + CeilingDays
	ValidationCmd        string            `json:"validation_cmd"`
	ValidationOK         bool              `json:"validation_ok"`
	ActivePolicyHashes   map[string]string `json:"active_policy_hashes"`
	PreviousPolicyHashes map[string]string `json:"previous_policy_hashes"`
}

// Generate runs the full transaction and returns the resulting state. On any
// error it guarantees the previously-active policy files are left intact (both
// files — no split-brain) and no state record is written.
func Generate(opts GenerateOptions) (GeneratedState, error) {
	if opts.MainPath == "" {
		return GeneratedState{}, errors.New("logretention: MainPath required")
	}
	if opts.LogDir == "" {
		opts.LogDir = DefaultLogDir
	}
	if opts.Families == nil {
		opts.Families = DefaultFamilies()
	}
	if opts.Validator == nil {
		opts.Validator = DefaultValidator
	}
	now := opts.Now
	if now.IsZero() {
		now = time.Now().UTC()
	}

	// 1. Exclusive generation lock (prevents concurrent generators / split writes).
	lockPath := opts.LockPath
	if lockPath == "" {
		base := opts.StatePath
		if base == "" {
			base = opts.MainPath
		}
		lockPath = filepath.Join(filepath.Dir(base), ".nftban-logrotate.gen.lock")
	}
	unlock, err := acquireLock(lockPath)
	if err != nil {
		return GeneratedState{}, err
	}
	defer unlock()

	disk := opts.Disk
	if disk.TotalBytes == 0 {
		d, err := DetectDiskFacts(opts.LogDir)
		if err != nil {
			return GeneratedState{}, err
		}
		disk = d
	}
	prof := opts.Profile
	if prof.Name == "" {
		prof = ClassifyProfile(disk, opts.PanelPresent, opts.Overrides.Profile)
	}

	policy, err := Calculate(disk, prof, opts.Overrides, opts.Families)
	if err != nil {
		return GeneratedState{}, err
	}
	// Hard invariant guard: never activate an unbounded or over-budget policy.
	if policy.UnboundedCount != 0 {
		return GeneratedState{}, fmt.Errorf("logretention: refusing to activate policy with %d unbounded stanzas", policy.UnboundedCount)
	}
	if policy.TheoreticalMaxBytes > policy.BudgetBytes {
		return GeneratedState{}, fmt.Errorf("logretention: theoretical max %d exceeds budget %d", policy.TheoreticalMaxBytes, policy.BudgetBytes)
	}

	header := renderHeader(policy, now, opts.SourceVersion)

	targets := []genTarget{{opts.MainPath, "main"}}
	if opts.SuricataPath != "" {
		targets = append(targets, genTarget{opts.SuricataPath, "suricata"})
	}

	// 2. Render + write all candidate temps into their target directories.
	candidates := make(map[string]string, len(targets))
	cleanupTemps := func() {
		for _, tmp := range candidates {
			_ = os.Remove(tmp)
		}
	}
	candidatePaths := make([]string, 0, len(targets))
	for _, t := range targets {
		content := header + "\n" + RenderFile(policy, opts.Families, t.file)
		tmp, err := writeTemp(t.path, content)
		if err != nil {
			cleanupTemps()
			return GeneratedState{}, err
		}
		candidates[t.path] = tmp
		candidatePaths = append(candidatePaths, tmp)
	}

	// 3. Validate the COMBINED effective policy (all candidates together).
	validationCmd, verr := opts.Validator(candidatePaths)
	if verr != nil {
		cleanupTemps()
		return GeneratedState{}, verr // previous policy untouched; no state written
	}

	// 4. Two-file ATOMIC activation with explicit rollback (no split-brain).
	prevHashes := map[string]string{}
	for _, t := range targets {
		prevHashes[filepath.Base(t.path)] = hashFileOrEmpty(t.path)
	}
	if err := activateWithRollback(targets, candidates); err != nil {
		cleanupTemps()
		return GeneratedState{}, err // both previous files restored
	}

	activeHashes := map[string]string{}
	for _, t := range targets {
		activeHashes[filepath.Base(t.path)] = hashFileOrEmpty(t.path)
	}

	state := GeneratedState{
		PolicyVersion:        policy.PolicyVersion,
		GeneratorVersion:     GeneratorVersion,
		GeneratedAt:          now.Format(time.RFC3339),
		SourceVersion:        opts.SourceVersion,
		Reason:               opts.Reason,
		Profile:              prof,
		Disk:                 disk,
		Overrides:            opts.Overrides,
		PolicySource:         policy.PolicySource,
		BudgetBytes:          policy.BudgetBytes,
		TheoreticalMaxBytes:  policy.TheoreticalMaxBytes,
		UnboundedCount:       policy.UnboundedCount,
		FitVerdict:           policy.FitVerdict,
		Families:             policy.Families,
		ValidationCmd:        validationCmd,
		ValidationOK:         true,
		ActivePolicyHashes:   activeHashes,
		PreviousPolicyHashes: prevHashes,
	}
	if opts.StatePath != "" {
		if err := writeStateAtomic(opts.StatePath, state); err != nil {
			return state, fmt.Errorf("logretention: policy activated but state write failed: %w", err)
		}
	}
	return state, nil
}

// genTarget is one generated policy file (path + which render "file" group).
type genTarget struct {
	path string
	file string
}

// activateWithRollback backs up each existing target (rename -> .prev), renames
// each validated candidate into place, and if ANY step fails restores every
// backed-up file — so the outcome is all-new or all-old, never split-brain.
func activateWithRollback(targets []genTarget, candidates map[string]string) error {
	type undo struct {
		path      string
		bak       string
		activated bool
	}
	var done []undo

	rollback := func() {
		// remove any newly-activated files, then restore backups
		for _, u := range done {
			if u.activated {
				_ = os.Remove(u.path)
			}
			if u.bak != "" {
				_ = os.Rename(u.bak, u.path)
			}
		}
	}

	for _, t := range targets {
		u := undo{path: t.path}
		if _, err := os.Stat(t.path); err == nil {
			bak := t.path + prevSuffix
			if err := os.Rename(t.path, bak); err != nil {
				rollback()
				return fmt.Errorf("logretention: backup %s: %w", t.path, err)
			}
			u.bak = bak
		}
		if err := os.Rename(candidates[t.path], t.path); err != nil {
			// this target failed to activate: undo its own backup first, then all prior
			if u.bak != "" {
				_ = os.Rename(u.bak, t.path)
			}
			rollback()
			return fmt.Errorf("logretention: activate %s: %w", t.path, err)
		}
		u.activated = true
		done = append(done, u)
	}
	// success: drop backups
	for _, u := range done {
		if u.bak != "" {
			_ = os.Remove(u.bak)
		}
	}
	return nil
}

// acquireLock takes an exclusive, non-blocking flock on lockPath. A held lock
// means another generation is in progress and the call fails (rather than
// racing). The returned func releases the lock.
func acquireLock(lockPath string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return nil, fmt.Errorf("logretention: lock dir: %w", err)
	}
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644) //nolint:gosec // generator-owned lock path
	if err != nil {
		return nil, fmt.Errorf("logretention: open lock: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, fmt.Errorf("logretention: another generation is in progress (lock held): %w", err)
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}, nil
}

func renderHeader(p EffectivePolicy, now time.Time, src string) string {
	var b strings.Builder
	b.WriteString("# NFTBan log rotation — GENERATED EFFECTIVE POLICY. DO NOT EDIT.\n")
	fmt.Fprintf(&b, "# generated=%s policy-version=%s generator-version=%s source=%s profile=%s policy-source=%s\n",
		now.Format(time.RFC3339), p.PolicyVersion, GeneratorVersion, orNA(src), p.Profile.Name, p.PolicySource)
	fmt.Fprintf(&b, "# basis: /var/log capacity=%s avail=%s | budget=%s theoretical-max=%s fit=%s unbounded=%d\n",
		humanBytes(p.Disk.TotalBytes), humanBytes(p.Disk.AvailBytes),
		humanBytes(p.BudgetBytes), humanBytes(p.TheoreticalMaxBytes), p.FitVerdict, p.UnboundedCount)
	b.WriteString("# Operator overrides live in /etc/nftban/conf.d/logs.conf. Edits to THIS file are\n")
	b.WriteString("# lost on the next regeneration. See `nftban logs retention status`.\n")
	return b.String()
}

func orNA(s string) string {
	if s == "" {
		return "n/a"
	}
	return s
}

func humanBytes(b uint64) string {
	switch {
	case b >= GiB:
		return fmt.Sprintf("%.1fG", float64(b)/float64(GiB))
	case b >= MiB:
		return fmt.Sprintf("%dM", b/MiB)
	default:
		return fmt.Sprintf("%dB", b)
	}
}

// writeTemp writes content to a temp file in the SAME directory as target (so a
// later os.Rename is atomic on the same filesystem), fsyncs it, and returns its
// path. The caller validates then renames or removes it.
func writeTemp(target, content string) (string, error) {
	dir := filepath.Dir(target)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("logretention: mkdir %s: %w", dir, err)
	}
	f, err := os.CreateTemp(dir, "."+filepath.Base(target)+".gen-*")
	if err != nil {
		return "", fmt.Errorf("logretention: temp in %s: %w", dir, err)
	}
	name := f.Name()
	if _, err := f.WriteString(content); err != nil {
		_ = f.Close()
		_ = os.Remove(name)
		return "", err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(name)
		return "", err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(name)
		return "", err
	}
	_ = os.Chmod(name, 0o644)
	return name, nil
}

func writeStateAtomic(path string, state GeneratedState) error {
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := writeTemp(path, string(data)+"\n")
	if err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func hashFileOrEmpty(path string) string {
	data, err := os.ReadFile(path) //nolint:gosec // generator-owned path
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
