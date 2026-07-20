// meta:name="generate.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 HEALTH-OOM hotfix Lane 2: installer-generated systemd drop-in that applies the profile-derived nftban-health.service memory budget. CONSUMES the canonical safety.HealthServiceMemoryLimits() (which consumes safety.ClassifyResourceTier) — it defines NO RAM thresholds, no size parser, no CPU parser. Renders a deterministic /etc/systemd/system/nftban-health.service.d/20-nftban-resource-profile.conf, classifies state (ABSENT/READY_GENERATED/ACTIVE_MATCH/STALE_MISMATCH/INVALID), writes atomically+durably only when content changes (no-churn), and reports whether a daemon-reload is required. Mirrors the log-retention generated-state/no-churn contract; reuses safety.WriteFileDurable rather than re-implementing durable writes. systemd rendering lives HERE, not in the generic internal/safety inventory package."
package healthresource

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/itcmsgr/nftban/internal/safety"
)

// Canonical derived-state location for the health resource-profile drop-in.
const (
	DropinDir  = "/etc/systemd/system/nftban-health.service.d"
	DropinFile = DropinDir + "/20-nftban-resource-profile.conf"
	dropinPerm = 0o644
)

// State is the generated-state classification for the drop-in.
type State string

const (
	StateAbsent           State = "ABSENT"              // no drop-in on disk
	StateReadyGen         State = "READY_GENERATED"     // written/updated this run
	StateActiveMatch      State = "ACTIVE_MATCH"        // effective systemd == calculated (protection ACTIVE)
	StateStaleMismatch    State = "STALE_MISMATCH"      // on-disk differs from desired (pre-write)
	StateInvalid          State = "INVALID"             // computed policy failed validation
	StateFallbackMatch    State = "FALLBACK_MATCH"      // no effective drop-in, but packaged fallback >= calculated (small host: OK)
	StateFallbackUnder    State = "FALLBACK_UNDERSIZED" // effective < calculated (medium/large: DEGRADED, protection NOT active)
	StateGenerationFailed State = "GENERATION_FAILED"   // policy valid but drop-in could not be written
	StateActivationFailed State = "ACTIVATION_FAILED"   // written but daemon-reload / effective verification failed
)

// ProtectionActive reports whether the health-OOM protection is effectively in
// force for a given state. Only ACTIVE_MATCH (drop-in effective) and
// FALLBACK_MATCH (small host where the packaged fallback already meets the
// calculated budget) count as protected; every other terminal state means the
// medium/large host is running under the proven-defective fallback.
func (s State) ProtectionActive() bool {
	return s == StateActiveMatch || s == StateFallbackMatch
}

// ClassifyEffective compares the host's LIVE systemd effective limits against the
// calculated policy and returns the operational state. This is the authority for
// "is the profile-derived protection actually active", independent of whether a
// file merely exists — the owner rule: do not trust file presence alone.
//
//   - effective == calculated (drop-in loaded)        → ACTIVE_MATCH (protected)
//   - effective >= calculated (no drop-in needed)     → FALLBACK_MATCH (small host, protected by fallback)
//   - effective <  calculated                         → FALLBACK_UNDERSIZED (medium/large, NOT protected)
func ClassifyEffective(calc safety.HealthResourceProfile, effHigh, effMax int64, dropinLoaded bool) State {
	if dropinLoaded && effHigh == calc.MemoryHigh && effMax == calc.MemoryMax {
		return StateActiveMatch
	}
	if effMax >= calc.MemoryMax && effHigh >= calc.MemoryHigh {
		return StateFallbackMatch
	}
	return StateFallbackUnder
}

// Test seams (mirrors the logretention pattern) — overridden in unit tests.
var (
	writeDurable = safety.WriteFileDurable
	readFile     = os.ReadFile
	mkdirAll     = os.MkdirAll
	removeFile   = os.Remove
)

// Result is the outcome of Generate.
type Result struct {
	// Changed is true if the file was written/updated (caller must daemon-reload).
	State       State
	Changed     bool
	Profile     safety.HealthResourceProfile
	DesiredPath string
}

// Validate enforces the health-policy invariants defensively before any write.
func Validate(p safety.HealthResourceProfile) error {
	if p.MemoryHigh <= 0 {
		return fmt.Errorf("MemoryHigh must be > 0, got %d", p.MemoryHigh)
	}
	if p.MemoryMax <= p.MemoryHigh {
		return fmt.Errorf("MemoryMax(%d) must be > MemoryHigh(%d)", p.MemoryMax, p.MemoryHigh)
	}
	const minViable = int64(128) << 20
	if p.MemoryMax < minViable {
		return fmt.Errorf("MemoryMax(%d) below minimum viable %d", p.MemoryMax, minViable)
	}
	if p.TotalRAM > 0 && p.MemoryMax > p.TotalRAM/4 && p.MemoryMax != minViable {
		return fmt.Errorf("MemoryMax(%d) exceeds 25%% of TotalRAM(%d)", p.MemoryMax, p.TotalRAM)
	}
	switch p.Tier {
	case safety.ResourceTierSmall, safety.ResourceTierMedium, safety.ResourceTierLarge:
	default:
		return fmt.Errorf("unknown resource tier %q", p.Tier)
	}
	return nil
}

// Render produces the deterministic drop-in content. It contains ONLY the
// settings owned by this policy (MemoryHigh/MemoryMax) plus provenance metadata
// as comments. It embeds NO timestamp so identical facts → byte-identical output
// (no-churn). sourceVersion is the nftban version stamping the file.
func Render(p safety.HealthResourceProfile, sourceVersion string) []byte {
	var b bytes.Buffer
	// Provenance header (comments): authority, tier, inputs, effective values, reason.
	fmt.Fprintf(&b, "# Generated by nftban %s — DO NOT EDIT (installer-managed derived state).\n", sourceVersion)
	fmt.Fprintf(&b, "# authority=internal/safety.HealthServiceMemoryLimits source_version=%s\n", sourceVersion)
	fmt.Fprintf(&b, "# tier=%s total_ram_bytes=%d avail_ram_bytes=%d cpu_cores=%d clamped=%t\n",
		p.Tier, p.TotalRAM, p.AvailRAM, p.CPUCores, p.Clamped)
	fmt.Fprintf(&b, "# reason=%s\n", p.Reason)
	b.WriteString("[Service]\n")
	fmt.Fprintf(&b, "MemoryHigh=%s\n", safety.SystemdMemBytes(p.MemoryHigh))
	fmt.Fprintf(&b, "MemoryMax=%s\n", safety.SystemdMemBytes(p.MemoryMax))
	return b.Bytes()
}

// Classify reports the state of an existing (possibly nil) drop-in vs desired.
func Classify(existing, desired []byte) State {
	if existing == nil {
		return StateAbsent
	}
	if bytes.Equal(existing, desired) {
		return StateActiveMatch
	}
	return StateStaleMismatch
}

// Generate resolves the host policy, validates it, and writes the drop-in only
// when its content differs from what is already on disk (no-churn). It NEVER
// leaves a partially-written override (WriteFileDurable is atomic temp+rename).
// Changed=true means the caller must run `systemctl daemon-reload`.
func Generate(sourceVersion string) (Result, error) {
	p := safety.HealthServiceMemoryLimits()
	res := Result{Profile: p, DesiredPath: DropinFile}

	if err := Validate(p); err != nil {
		res.State = StateInvalid
		return res, fmt.Errorf("health resource policy invalid (fallback packaged unit retained): %w", err)
	}

	desired := Render(p, sourceVersion)

	existing, rerr := readFile(DropinFile)
	if rerr != nil && !errors.Is(rerr, os.ErrNotExist) {
		return res, fmt.Errorf("read existing drop-in %s: %w", DropinFile, rerr)
	}
	if rerr != nil {
		existing = nil // ErrNotExist → absent
	}

	switch Classify(existing, desired) {
	case StateActiveMatch:
		res.State = StateActiveMatch
		res.Changed = false
		return res, nil
	default: // ABSENT or STALE_MISMATCH → (re)write
		if err := mkdirAll(DropinDir, 0o755); err != nil {
			return res, fmt.Errorf("mkdir %s: %w", DropinDir, err)
		}
		if err := writeDurable(DropinFile, desired, dropinPerm); err != nil {
			return res, fmt.Errorf("write drop-in %s: %w", DropinFile, err)
		}
		res.State = StateReadyGen
		res.Changed = true
		return res, nil
	}
}

// Remove durably deletes the v1.222.1-owned drop-in (rollback to a packaged unit
// that does not understand it). Returns changed=true if a file was removed, so
// the caller can daemon-reload. Absent is a no-op success.
func Remove() (changed bool, err error) {
	if _, rerr := readFile(DropinFile); errors.Is(rerr, os.ErrNotExist) {
		return false, nil
	}
	if err := removeFile(DropinFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, fmt.Errorf("remove drop-in %s: %w", DropinFile, err)
	}
	// Best-effort remove the now-possibly-empty drop-in dir (ignore ENOTEMPTY).
	_ = removeFile(filepath.Clean(DropinDir))
	return true, nil
}
