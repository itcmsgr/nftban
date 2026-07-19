// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-generate"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Phase-5 generated-policy transaction (Model B). Treats the logrotate files as DERIVED STATE, never operator config. Acquires an exclusive generation lock; renders all candidates into the target filesystem; validates the COMBINED effective policy with `logrotate -d --state <tmp>` (debug=no rotation; temp state=real state untouched; explicit file args=active policy never co-loaded); writes a DURABLE activation journal (candidate+backup paths, prev+candidate hashes) BEFORE touching any target; then a two-file ATOMIC activation with in-process ROLLBACK on error; writes the generated-state record only after a fully successful activation; preserves the previous valid policy on any failure; removes temporaries; records prior+active SHA-256 hashes. Z1: a crash between the per-file renames is NOT left to the next regeneration — Recover() (recover.go) deterministically rolls the set forward or back to a uniform state at every consumer (generate, status, maintenance-before-logrotate)."
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

// stagingDirFor is the dot-subdir of the target directory holding candidates,
// backups, and the activation journal. It is NEVER scanned by the system
// logrotate (logrotate's `include` reads regular files directly in the dir and
// does not recurse), yet lives on the SAME filesystem as the targets so every
// activation rename is atomic. Activator and recoverer derive it identically.
func stagingDirFor(mainPath string) string {
	return filepath.Join(filepath.Dir(mainPath), ".nftban-logrotate-staging")
}

// journalPathIn is the fixed activation-journal path inside a staging dir.
func journalPathIn(stagingDir string) string {
	return filepath.Join(stagingDir, "activation.journal")
}

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
	out, err := exec.Command(lr, args...).CombinedOutput() // #nosec G204 -- fixed logrotate flags; candidate paths are generator-owned staging files
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
	PolicyVersion          string            `json:"policy_version"`
	GeneratorVersion       string            `json:"generator_version"`
	GeneratedAt            string            `json:"generated_at"`
	SourceVersion          string            `json:"source_version"`
	Reason                 string            `json:"generation_reason"`
	Profile                Profile           `json:"profile"`
	Disk                   DiskFacts         `json:"filesystem"`
	Overrides              Overrides         `json:"operator_overrides"`
	PolicySource           string            `json:"policy_source"`
	BudgetBytes            uint64            `json:"budget_bytes"`
	RequestedBudgetBytes   uint64            `json:"requested_budget_bytes"`
	MinimumAchievableBytes uint64            `json:"minimum_achievable_bytes"`
	TheoreticalMaxBytes    uint64            `json:"theoretical_max_bytes_uncompressed"`
	UnboundedCount         int               `json:"unbounded_stanzas"`
	FitVerdict             string            `json:"fit_verdict"`
	CapacityVerdict        string            `json:"capacity_verdict"`
	Achievable             bool              `json:"achievable"`
	CapRaisedForFloor      bool              `json:"cap_raised_for_floor"`
	OperatorCapExceeded    bool              `json:"operator_cap_exceeded"`
	ForensicFloorKind      string            `json:"forensic_floor_kind"`
	Families               []FamilyPolicy    `json:"families"` // each carries ForensicFloorDays + CeilingDays
	ValidationCmd          string            `json:"validation_cmd"`
	ValidationOK           bool              `json:"validation_ok"`
	ActivePolicyHashes     map[string]string `json:"active_policy_hashes"`
	PreviousPolicyHashes   map[string]string `json:"previous_policy_hashes"`
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
	// R7: never silently activate an impossible policy. If even the minimum
	// forensic floor exceeds the filesystem capacity, refuse and preserve the
	// previous valid policy — the operator must add capacity or lower floors.
	if !policy.Achievable {
		return GeneratedState{}, fmt.Errorf("logretention: refusing to activate an unachievable policy (%s): minimum floor %s exceeds filesystem capacity %s (raise capacity or lower LOG_RETENTION_MIN_DAYS)",
			policy.CapacityVerdict, humanBytes(policy.MinimumAchievableBytes), humanBytes(policy.Disk.TotalBytes))
	}

	header := renderHeader(policy, now, opts.SourceVersion)

	targets := []genTarget{{opts.MainPath, "main"}}
	if opts.SuricataPath != "" {
		targets = append(targets, genTarget{opts.SuricataPath, "suricata"})
	}

	// R4: stage candidates + backups + the activation journal in a dot-SUBDIR of
	// the target directory. logrotate's `include` reads only regular files
	// directly in /etc/logrotate.d and does NOT recurse into subdirectories, so
	// nothing here is ever parsed by the system logrotate (no duplicate-stanza
	// error, no crash-poisoning), while staying on the SAME filesystem as the
	// targets so the activation renames are atomic.
	stagingDir := stagingDirFor(opts.MainPath)
	if err := os.MkdirAll(stagingDir, 0o700); err != nil {
		return GeneratedState{}, fmt.Errorf("logretention: staging dir: %w", err)
	}
	journalPath := journalPathIn(stagingDir)
	// Z1: a leftover journal means a prior generation crashed mid-activation.
	// DETERMINISTICALLY complete (roll-forward) or undo (roll-back) that
	// transaction NOW so the on-disk set is uniform before we start a fresh one —
	// never leave it split for "the next regeneration" to fix.
	if rr, rerr := Recover(opts.MainPath); rerr != nil {
		return GeneratedState{}, fmt.Errorf("logretention: pre-generation recovery of an interrupted activation failed: %w", rerr)
	} else if rr.JournalFound {
		fmt.Fprintf(os.Stderr, "logretention: recovered an interrupted prior activation (%s) before regenerating\n", rr.Action)
	}
	cleanStaging := func() { _ = removeDirContents(stagingDir) }
	cleanStaging()

	// 2. Render + write all candidate temps into the STAGING dir.
	candidates := make(map[string]string, len(targets)) // targetPath -> staged temp
	candidatePaths := make([]string, 0, len(targets))
	for _, t := range targets {
		content := header + "\n" + RenderFile(policy, opts.Families, t.file)
		tmp, err := writeStaged(stagingDir, filepath.Base(t.path), content)
		if err != nil {
			cleanStaging()
			return GeneratedState{}, err
		}
		candidates[t.path] = tmp
		candidatePaths = append(candidatePaths, tmp)
	}

	// 3. Validate the COMBINED effective policy (all staged candidates together).
	validationCmd, verr := opts.Validator(candidatePaths)
	if verr != nil {
		cleanStaging()
		return GeneratedState{}, verr // previous policy untouched; no state written
	}

	// 4. Record prior hashes, write the activation journal, then two-file ATOMIC
	// activation (backups + rollback in staging), fsync the target directory, and
	// only then drop the journal.
	prevHashes := map[string]string{}
	for _, t := range targets {
		prevHashes[filepath.Base(t.path)] = hashFileOrEmpty(t.path)
	}
	if err := writeActivationJournal(journalPath, now.Format(time.RFC3339), targets, candidates, stagingDir); err != nil {
		cleanStaging()
		return GeneratedState{}, err
	}
	if err := activateWithRollback(targets, candidates, stagingDir); err != nil {
		cleanStaging()
		return GeneratedState{}, err // both previous files restored
	}
	fsyncDir(filepath.Dir(opts.MainPath))
	_ = os.Remove(journalPath)

	activeHashes := map[string]string{}
	for _, t := range targets {
		activeHashes[filepath.Base(t.path)] = hashFileOrEmpty(t.path)
	}

	state := GeneratedState{
		PolicyVersion:          policy.PolicyVersion,
		GeneratorVersion:       GeneratorVersion,
		GeneratedAt:            now.Format(time.RFC3339),
		SourceVersion:          opts.SourceVersion,
		Reason:                 opts.Reason,
		Profile:                prof,
		Disk:                   disk,
		Overrides:              opts.Overrides,
		PolicySource:           policy.PolicySource,
		BudgetBytes:            policy.BudgetBytes,
		RequestedBudgetBytes:   policy.RequestedBudgetBytes,
		MinimumAchievableBytes: policy.MinimumAchievableBytes,
		TheoreticalMaxBytes:    policy.TheoreticalMaxBytes,
		UnboundedCount:         policy.UnboundedCount,
		FitVerdict:             policy.FitVerdict,
		CapacityVerdict:        policy.CapacityVerdict,
		Achievable:             policy.Achievable,
		CapRaisedForFloor:      policy.CapRaisedForFloor,
		OperatorCapExceeded:    policy.OperatorCapExceeded,
		ForensicFloorKind:      policy.ForensicFloorKind,
		Families:               policy.Families,
		ValidationCmd:          validationCmd,
		ValidationOK:           true,
		ActivePolicyHashes:     activeHashes,
		PreviousPolicyHashes:   prevHashes,
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

// activateWithRollback backs up each existing target (rename -> stagingDir/*.prev,
// OUT of the logrotate scan dir), renames each validated candidate into place, and
// if ANY step fails restores every backed-up file — so the outcome is all-new or
// all-old, never split-brain across a returned error.
func activateWithRollback(targets []genTarget, candidates map[string]string, stagingDir string) error {
	type undo struct {
		path      string
		bak       string
		activated bool
	}
	var done []undo

	rollback := func() {
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
			bak := backupPathFor(stagingDir, t.path)
			if err := os.Rename(t.path, bak); err != nil {
				rollback()
				return fmt.Errorf("logretention: backup %s: %w", t.path, err)
			}
			u.bak = bak
		}
		if err := os.Rename(candidates[t.path], t.path); err != nil {
			if u.bak != "" {
				_ = os.Rename(u.bak, t.path)
			}
			rollback()
			return fmt.Errorf("logretention: activate %s: %w", t.path, err)
		}
		u.activated = true
		done = append(done, u)
	}
	for _, u := range done {
		if u.bak != "" {
			_ = os.Remove(u.bak)
		}
	}
	return nil
}

// writeStaged writes content to a fsync'd temp file in stagingDir (a dot-subdir
// of the target directory — same filesystem, not scanned by logrotate).
func writeStaged(stagingDir, targetBase, content string) (string, error) {
	f, err := os.CreateTemp(stagingDir, targetBase+".gen-*")
	if err != nil {
		return "", fmt.Errorf("logretention: staged temp in %s: %w", stagingDir, err)
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

// activationJournal is the durable record of an in-flight two-phase activation.
// It carries EVERYTHING recovery needs to reach a uniform all-new or all-old
// state after a crash at any rename boundary: the staged candidate (roll-forward
// source), the deterministic backup path (roll-back source), and both hashes so
// the current on-disk file can be classified NEW vs OLD without re-deriving the
// policy. Written + fsync'd BEFORE the first target is touched; removed only
// after the whole set is activated and the target dir is fsync'd.
type activationJournal struct {
	Version   int            `json:"version"`
	CreatedAt string         `json:"created_at"`
	Entries   []journalEntry `json:"entries"`
}

type journalEntry struct {
	Target        string `json:"target"`
	CandidatePath string `json:"candidate_path"` // staged temp — roll-forward source
	CandidateHash string `json:"candidate_hash"` // == NEW on-disk hash
	BackupPath    string `json:"backup_path"`    // deterministic staging/*.prev — roll-back source
	PrevHash      string `json:"prev_hash"`      // == OLD on-disk hash; "" if target did not exist
}

const activationJournalVersion = 1

// backupPathFor is the deterministic backup location for a target during
// activation (a dot-subdir sibling, never scanned by logrotate). Both the
// activator and the recoverer compute the same path, so recovery can find the
// pre-image without guessing.
func backupPathFor(stagingDir, target string) string {
	return filepath.Join(stagingDir, filepath.Base(target)+prevSuffix)
}

// writeActivationJournal records the intended activation durably so a crash
// mid-activation is both DETECTABLE and REPAIRABLE (see Recover) on the next
// entry into any consumer — not merely on the next full regeneration.
func writeActivationJournal(path, createdAt string, targets []genTarget, candidates map[string]string, stagingDir string) error {
	j := activationJournal{Version: activationJournalVersion, CreatedAt: createdAt}
	for _, t := range targets {
		j.Entries = append(j.Entries, journalEntry{
			Target:        t.path,
			CandidatePath: candidates[t.path],
			CandidateHash: hashFileOrEmpty(candidates[t.path]),
			BackupPath:    backupPathFor(stagingDir, t.path),
			PrevHash:      hashFileOrEmpty(t.path),
		})
	}
	data, err := json.MarshalIndent(j, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600) // #nosec G304 -- staging path is generator-owned under the fixed staging dir
	if err != nil {
		return fmt.Errorf("logretention: activation journal: %w", err)
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// removeDirContents deletes the contents of dir (keeping dir itself).
func removeDirContents(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, e := range entries {
		_ = os.RemoveAll(filepath.Join(dir, e.Name()))
	}
	return nil
}

// fsyncDir best-effort fsyncs a directory so a rename into it is durable across a
// crash (silently ignored on filesystems that reject directory fsync).
func fsyncDir(dir string) {
	d, err := os.Open(dir) // #nosec G304 -- generator-owned directory path for fsync
	if err != nil {
		return
	}
	_ = d.Sync()
	_ = d.Close()
}

// acquireLock takes an exclusive, non-blocking flock on lockPath. A held lock
// means another generation is in progress and the call fails (rather than
// racing). The returned func releases the lock.
func acquireLock(lockPath string) (func(), error) {
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		return nil, fmt.Errorf("logretention: lock dir: %w", err)
	}
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644) // #nosec G304 -- generator-owned lock path derived from MainPath dir
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
	data, err := os.ReadFile(path) // #nosec G304 -- generator-owned policy/state path
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
