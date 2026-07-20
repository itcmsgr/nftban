// =============================================================================
// NFTBan Gate B — Log-retention capacity budget calculator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-calculator"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Deterministic, side-effect-free calculator that derives a bounded log-retention policy from /var/log filesystem CAPACITY (the stable basis) + detected profile + validated operator overrides. Produces per-family effective size/rotate/retention with the invariants UNBOUNDED_STANZAS=0 and THEORETICAL_MAX<=BUDGET, preserving a minimum forensic floor. Available free space is surfaced as headroom/health only, never as the permanent budget basis. Calculate() mutates nothing and never invokes logrotate."
// meta:input="DiskFacts (capacity+avail), Profile, validated Overrides, LogFamily inventory"
// meta:output="EffectivePolicy (budget, per-family caps, theoretical max, fit verdict, source+version)"
// meta:depends="none (stdlib)"
// meta:inventory.files="internal/logretention/logretention.go,internal/logretention/disk.go,internal/logretention/render.go,internal/logretention/generate.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="install/config/nftban.logrotate,install/config/nftban-suricata.logrotate"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// SCOPE (Gate B / v1.222.0): the calculator + generated-policy contract. As of
// Phase 6-7 this package IS imported by the nftban-core CLI (nftban logs
// retention status), reads operator overrides from conf.d/logs.conf
// (LoadOverrides), and the LOG_RETENTION_* keys are declared in config-schema.json.
// It is NOT imported by the nftband daemon. Runtime PACKAGING wiring of the
// generator (install/%post + timer + config-change) is pending (audit R2); until
// then the shipped static install/config/nftban.logrotate is the active authority.
package logretention

import (
	"errors"
	"fmt"
	"sort"

	"github.com/itcmsgr/nftban/internal/safeconv"
)

// Byte-size units.
const (
	KiB uint64 = 1024
	MiB uint64 = 1024 * KiB
	GiB uint64 = 1024 * MiB
)

// PolicyVersion is the schema version of the generated policy + state record.
// Bump when the generated logrotate structure or the state schema changes.
const PolicyVersion = "1"

// Calculator defaults. The budget derives PRIMARILY from filesystem capacity;
// available space is health/headroom only (owner directive: free space is
// volatile and must not be the permanent policy basis).
const (
	DefaultMaxPercent = 15 // default NFTBan log budget = 15% of /var/log capacity
	DefaultMinDays    = 7  // minimum forensic retention floor per family (days)
	DefaultMaxDays    = 90 // retention ceiling per family (days)

	// Absolute clamps so a tiny or enormous disk still yields a sane policy.
	minFamilySizeBytes = 5 * MiB   // never size-cap a family below this
	maxBudgetBytes     = 200 * GiB // sanity ceiling on total budget

	// Headroom: fraction of available space the budget may occupy before the
	// fit verdict degrades. Health signal only — does not change the budget.
	headroomFitPct   = 60 // <=60% of avail -> FITS
	headroomTightPct = 90 // <=90% -> TIGHT, else OVER_HEADROOM
)

// Fit verdicts (health signal derived from available space, not policy basis).
const (
	FitFits         = "FITS"
	FitTight        = "TIGHT"
	FitOverHeadroom = "OVER_HEADROOM"
	FitUnknown      = "UNKNOWN"
)

// VolumeClass groups families by expected write rate; it drives budget weighting
// and the default retention window.
type VolumeClass int

const (
	VolumeLow VolumeClass = iota
	VolumeMedium
	VolumeHigh
)

func (v VolumeClass) String() string {
	switch v {
	case VolumeHigh:
		return "high"
	case VolumeMedium:
		return "medium"
	default:
		return "low"
	}
}

// DiskFacts is the /var/log filesystem capacity snapshot. It is gathered by
// DetectDiskFacts (which reads the filesystem) and passed to Calculate as a pure
// input, so the calculator itself stays deterministic and side-effect free.
type DiskFacts struct {
	Path       string
	TotalBytes uint64 // filesystem capacity — the STABLE budget basis
	AvailBytes uint64 // non-root available — surfaced as headroom/health ONLY
}

// Profile is the retention profile classification. It is derived from disk
// capacity (primary) and may be nudged by control-panel presence; an operator
// override can force it.
type Profile struct {
	Name         string // "small" | "standard" | "high-volume"
	PanelPresent bool
}

// Overrides is the operator override model. In Phases 4-5 it is supplied
// directly; conf.d/logs.conf wiring is deferred. Zero value == fully automatic.
type Overrides struct {
	Mode       string // "" or "auto" (default) | "manual"
	MaxPercent int    // cap budget at this %% of capacity (0 = default)
	MaxBytes   uint64 // absolute budget cap (0 = unset)
	MinDays    int    // per-family retention floor (0 = default)
	MaxDays    int    // per-family retention ceiling (0 = default)
	Profile    string // "" or "auto" | "small" | "standard" | "high-volume"
}

// Validate enforces the override contract. An invalid override FAILS — it is
// never silently ignored or defaulted (owner directive: INVALID_OVERRIDE fails
// validation; it does not silently fall back).
func (o Overrides) Validate() error {
	switch o.Mode {
	case "", "auto", "fixed":
	default:
		return fmt.Errorf("logretention: invalid LOG_RETENTION_MODE %q (want auto|fixed)", o.Mode)
	}
	switch o.Profile {
	case "", "auto", "small", "standard", "high-volume":
	default:
		return fmt.Errorf("logretention: invalid LOG_RETENTION_PROFILE %q", o.Profile)
	}
	if o.MaxPercent != 0 && (o.MaxPercent < 1 || o.MaxPercent > 90) {
		return fmt.Errorf("logretention: invalid LOG_RETENTION_MAX_PERCENT %d (want 1..90)", o.MaxPercent)
	}
	if o.MinDays < 0 || o.MaxDays < 0 {
		return errors.New("logretention: retention days cannot be negative")
	}
	if o.MinDays != 0 && o.MaxDays != 0 && o.MinDays > o.MaxDays {
		return fmt.Errorf("logretention: LOG_RETENTION_MIN_DAYS %d exceeds MAX_DAYS %d", o.MinDays, o.MaxDays)
	}
	return nil
}

// FamilyPolicy is the calculated effective policy for one log family. The HARD
// forensic floor is RotateCount generations x SizeCapBytes = WorstCaseBytes; the
// day figures are TARGETS (best-case at/under the size cap), NOT guaranteed
// elapsed retention when size-triggered rotation fires before the cadence.
type FamilyPolicy struct {
	Key               string `json:"key"`
	RotateCount       int    `json:"rotate_count"` // retained generations (hard floor in generations)
	SizeCapBytes      uint64 `json:"size_cap_bytes"`
	RetentionDays     int    `json:"target_retention_days"`      // best-case elapsed days; size pressure may reduce actual days
	WorstCaseBytes    uint64 `json:"worst_case_bytes"`           // RotateCount * SizeCapBytes = hard byte floor (uncompressed)
	ForensicFloorDays int    `json:"forensic_floor_target_days"` // TARGET floor (NOT guaranteed under size pressure)
	CeilingDays       int    `json:"ceiling_days"`
	SizeTriggered     bool   `json:"size_triggered"` // a size cap exists -> may rotate before cadence

	// R11 semantic classification (surfaced by the CLI so enforcement/security
	// records are distinguishable from ordinary operational/debug logs).
	SemanticClass  string `json:"semantic_class"`
	AuthorityRole  string `json:"authority_role"`  // "authoritative" | "projection"
	WriterStrategy string `json:"writer_strategy"` // "copytruncate" | "rename+create"
	ReaderStrategy string `json:"reader_strategy"` // "same-inode" | "path-following"
}

// EffectivePolicy is the calculator's full output.
type EffectivePolicy struct {
	BudgetBytes         uint64 // effective budget (may be raised to the min-achievable floor)
	TheoreticalMaxBytes uint64 // UNCOMPRESSED worst-case retained bytes (compression not modeled — conservative upper bound, not expected disk use)
	UnboundedCount      int
	FitVerdict          string // headroom vs live available space (FITS/TIGHT/OVER_HEADROOM) — volatile
	Families            []FamilyPolicy
	Profile             Profile
	Disk                DiskFacts
	PolicySource        string // "automatic" | "operator-override"
	PolicyVersion       string

	// R7 capacity/achievability (structural, vs total capacity + operator cap):
	RequestedBudgetBytes   uint64 // capacity*pct capped by MaxBytes, BEFORE the floor raise
	MinimumAchievableBytes uint64 // sum of per-family forensic floors (generations x minSize) + fixed worst-case
	CapRaisedForFloor      bool   // the forensic floor forced the budget above the requested budget
	OperatorCapExceeded    bool   // MaxBytes set but the min-achievable floor exceeds it
	Achievable             bool   // false => the minimum policy does not fit the filesystem
	CapacityVerdict        string // ACHIEVABLE | CAP_RAISED_FOR_FLOOR | FLOOR_EXCEEDS_OPERATOR_CAP | INSUFFICIENT_HEADROOM | FLOOR_EXCEEDS_CAPACITY

	// R6 forensic-floor honesty: the hard floor is expressed in GENERATIONS +
	// BYTES per family (rotate count x size cap). Elapsed retention DAYS are a
	// target/best-case only — under size-triggered rotation a busy log rotates
	// before its cadence, so real elapsed days can be shorter while the
	// generation/byte floor still holds.
	ForensicFloorKind string // "generations_and_bytes"
}

// Capacity verdicts (structural achievability, distinct from the headroom FitVerdict).
const (
	CapAchievable        = "ACHIEVABLE"
	CapRaisedForFloor    = "CAP_RAISED_FOR_FLOOR"
	CapFloorOverOpCap    = "FLOOR_EXCEEDS_OPERATOR_CAP"
	CapInsufficientHead  = "INSUFFICIENT_HEADROOM"
	CapFloorOverCapacity = "FLOOR_EXCEEDS_CAPACITY"
)

// cadenceDays returns the number of days one rotation cycle covers.
func cadenceDays(cadence string) int {
	switch cadence {
	case "daily":
		return 1
	case "monthly":
		return 30
	default: // weekly
		return 7
	}
}

// rotationsForDays converts a retention window in days into a rotate count for a
// given cadence, never below 1.
func rotationsForDays(cadence string, days int) int {
	cd := cadenceDays(cadence)
	if days < cd {
		return 1
	}
	n := days / cd
	if days%cd != 0 {
		n++
	}
	if n < 1 {
		n = 1
	}
	return n
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// ClassifyProfile derives the retention profile from capacity (primary basis)
// and an operator override. Panel presence nudges the classification upward
// because control-panel hosts run more web/mail log producers.
func ClassifyProfile(disk DiskFacts, panelPresent bool, override string) Profile {
	switch override {
	case "small", "standard", "high-volume":
		return Profile{Name: override, PanelPresent: panelPresent}
	}
	name := "standard"
	switch {
	case disk.TotalBytes < 20*GiB:
		name = "small"
	case disk.TotalBytes >= 200*GiB || panelPresent:
		name = "high-volume"
	}
	return Profile{Name: name, PanelPresent: panelPresent}
}

// defaultRetentionDays is the target retention window per volume class before
// override clamping. High-volume logs keep a shorter window (they are the
// footprint dominators); low-volume logs keep more history cheaply.
func defaultRetentionDays(v VolumeClass, prof Profile) int {
	base := 30
	switch v {
	case VolumeHigh:
		base = 14
	case VolumeMedium:
		base = 30
	case VolumeLow:
		base = 60
	}
	// high-volume-profile hosts can afford a little more; small hosts less.
	switch prof.Name {
	case "small":
		base = base / 2
		if base < DefaultMinDays {
			base = DefaultMinDays
		}
	case "high-volume":
		base = base + base/2
	}
	return base
}

// ceilingDaysForVolume is the per-family SAFETY CEILING on retention when a
// family does not declare its own CeilingDays. It bounds capacity-driven
// expansion on large disks (so no single family retains for an unreasonable
// window even when the budget could afford it) WITHOUT a universal "never exceed
// the shipped baseline" rule. See the AUTO_MODE_CEILING_DECISION note in the
// package/scope docs. High-volume logs are the footprint dominators and get the
// tightest ceiling; low-volume logs may retain longest.
func ceilingDaysForVolume(v VolumeClass) int {
	switch v {
	case VolumeHigh:
		return 30
	case VolumeMedium:
		return 45
	default:
		return 120
	}
}

// FitVerdictFor recomputes the headroom fit verdict from a LIVE available-space
// reading. The CLI uses this so `status` reflects the CURRENT filesystem, not the
// (possibly stale) value frozen into the generated-state record.
func FitVerdictFor(theoreticalMax, availBytes uint64) string {
	return fitVerdict(theoreticalMax, availBytes)
}

func authorityRole(primary bool) string {
	if primary {
		return "authoritative"
	}
	return "projection"
}

func writerStrategy(copytruncate bool) string {
	if copytruncate {
		return "copytruncate"
	}
	return "rename+create"
}

func readerStrategy(copytruncate bool) string {
	if copytruncate {
		return "same-inode"
	}
	return "path-following"
}

// Calculate derives the effective, bounded retention policy. It is a pure
// function of its inputs: it reads no files, touches no filesystem, and never
// invokes logrotate. Invariants guaranteed on success:
//   - UnboundedCount == 0 (every family has a size cap)
//   - TheoreticalMaxBytes <= BudgetBytes
//   - each family retains at least its forensic floor (>= min(FloorDays,MinDays))
//   - a valid operator override wins; an invalid one was already rejected by Validate
func Calculate(disk DiskFacts, prof Profile, o Overrides, fams []LogFamily) (EffectivePolicy, error) {
	if err := o.Validate(); err != nil {
		return EffectivePolicy{}, err
	}
	if disk.TotalBytes == 0 {
		return EffectivePolicy{}, errors.New("logretention: zero filesystem capacity (bad DiskFacts)")
	}

	pct := DefaultMaxPercent
	if o.MaxPercent != 0 {
		pct = o.MaxPercent
	}
	minDays := DefaultMinDays
	if o.MinDays != 0 {
		minDays = o.MinDays
	}
	maxDays := DefaultMaxDays
	if o.MaxDays != 0 {
		maxDays = o.MaxDays
	}

	// Budget from CAPACITY (stable basis), capped by an absolute override + sanity.
	// `requested` is the capacity-derived budget BEFORE any forensic-floor raise
	// (R7 — so we can report REQUESTED vs EFFECTIVE and whether the floor forced
	// the budget up / past an operator cap / past the filesystem).
	requested := disk.TotalBytes / 100 * uint64(pct)
	if o.MaxBytes != 0 && o.MaxBytes < requested {
		requested = o.MaxBytes
	}
	if requested > maxBudgetBytes {
		requested = maxBudgetBytes
	}
	budget := requested

	// Retention window + rotate come FIRST, because the minimum achievable
	// worst-case (the floor that budget must cover) depends on the actual rotate
	// count. The forensic floor RAISES the per-family minimum retention: FloorDays
	// wins even over a low operator MaxDays (owner: MINIMUM_FORENSIC_FLOOR is
	// preserved). Fixed families (report documents) keep their base policy and do
	// not draw from the weighted size budget, so their full worst-case is covered.
	var nonFixedFloor, fixedWorst uint64
	work := make([]famWork, 0, len(fams))
	totalWeight := 0
	for _, f := range fams {
		if f.Fixed {
			rd := f.BaseRotate * cadenceDays(f.Cadence)
			w := famWork{f: f, rotate: f.BaseRotate, retDays: rd, size: f.BaseSizeBytes, fixed: true, floorDays: rd, ceilDays: rd}
			fixedWorst += safeconv.ToUint64OrZero(w.rotate) * w.size
			work = append(work, w)
			continue
		}
		effMin := minDays
		if f.FloorDays > effMin {
			effMin = f.FloorDays // forensic floor raises the minimum retention
		}
		// per-family SAFETY CEILING (from the family, else derived from volume),
		// further restricted by an operator MaxDays — but never below the forensic
		// floor: the floor always wins over a conflicting low ceiling.
		famCeil := f.CeilingDays
		if famCeil == 0 {
			famCeil = ceilingDaysForVolume(f.Volume)
		}
		ceil := maxDays
		if famCeil < ceil {
			ceil = famCeil
		}
		if ceil < effMin {
			ceil = effMin
		}
		retDays := clampInt(defaultRetentionDays(f.Volume, prof), effMin, ceil)
		rotate := rotationsForDays(f.Cadence, retDays)
		nonFixedFloor += safeconv.ToUint64OrZero(rotate) * minFamilySizeBytes
		totalWeight += f.Weight
		work = append(work, famWork{f: f, retDays: retDays, rotate: rotate, floorDays: effMin, ceilDays: ceil})
	}
	minAchievable := nonFixedFloor + fixedWorst
	capRaised := false
	if budget < minAchievable {
		budget = minAchievable // preserve the forensic floor
		capRaised = true
	}

	distributable := budget
	if fixedWorst < distributable {
		distributable -= fixedWorst
	} else {
		distributable = 0
	}
	if totalWeight == 0 {
		totalWeight = 1
	}

	// Size cap per non-fixed family from its weighted share (rotate already set),
	// clamped to [minFamilySize, baseSize] and rounded to whole MiB.
	for i := range work {
		w := &work[i]
		if w.fixed {
			continue
		}
		w.share = distributable / safeconv.ToUint64OrZero(totalWeight) * safeconv.ToUint64OrZero(w.f.Weight)
		size := w.share / safeconv.ToUint64OrZero(w.rotate)
		if size < minFamilySizeBytes {
			size = minFamilySizeBytes
		}
		if w.f.BaseSizeBytes != 0 && size > w.f.BaseSizeBytes {
			size = w.f.BaseSizeBytes
		}
		w.size = roundToMiB(size)
		if w.size < minFamilySizeBytes {
			w.size = minFamilySizeBytes
		}
	}

	// Guarantee THEORETICAL_MAX <= BUDGET: if clamping pushed the sum over budget,
	// trim the largest non-fixed families' size caps (down to the min floor) until
	// it fits. Because the budget was raised to floorTotal above, a fit at the min
	// floor is always achievable.
	trimToBudget(work, budget)

	// Assemble output in stable (input) order.
	var theoretical uint64
	families := make([]FamilyPolicy, 0, len(work))
	unbounded := 0
	for _, w := range work {
		worst := safeconv.ToUint64OrZero(w.rotate) * w.size
		theoretical += worst
		if w.size == 0 {
			unbounded++
		}
		families = append(families, FamilyPolicy{
			Key:               w.f.Key,
			RotateCount:       w.rotate,
			SizeCapBytes:      w.size,
			RetentionDays:     w.retDays,
			WorstCaseBytes:    worst,
			ForensicFloorDays: w.floorDays,
			CeilingDays:       w.ceilDays,
			SizeTriggered:     w.size > 0, // every family is size-capped -> may rotate before cadence
			SemanticClass:     w.f.SemanticClass,
			AuthorityRole:     authorityRole(w.f.Primary),
			WriterStrategy:    writerStrategy(w.f.Copytruncate),
			ReaderStrategy:    readerStrategy(w.f.Copytruncate),
		})
	}

	source := "automatic"
	if o.Mode == "fixed" || o.MaxPercent != 0 || o.MaxBytes != 0 || o.MinDays != 0 || o.MaxDays != 0 || (o.Profile != "" && o.Profile != "auto") {
		source = "operator-override"
	}

	// R7 capacity verdict (structural achievability, most-severe applicable).
	opCapExceeded := o.MaxBytes != 0 && minAchievable > o.MaxBytes
	achievable := true
	capVerdict := CapAchievable
	switch {
	case minAchievable > disk.TotalBytes:
		// even the minimum policy does not fit the whole filesystem — impossible.
		achievable = false
		capVerdict = CapFloorOverCapacity
	case fitVerdict(theoretical, disk.AvailBytes) == FitOverHeadroom:
		capVerdict = CapInsufficientHead
	case opCapExceeded:
		capVerdict = CapFloorOverOpCap
	case capRaised:
		capVerdict = CapRaisedForFloor
	}

	return EffectivePolicy{
		BudgetBytes:            budget,
		TheoreticalMaxBytes:    theoretical,
		UnboundedCount:         unbounded,
		FitVerdict:             fitVerdict(theoretical, disk.AvailBytes),
		Families:               families,
		Profile:                prof,
		Disk:                   disk,
		PolicySource:           source,
		PolicyVersion:          PolicyVersion,
		RequestedBudgetBytes:   requested,
		MinimumAchievableBytes: minAchievable,
		CapRaisedForFloor:      capRaised,
		OperatorCapExceeded:    opCapExceeded,
		Achievable:             achievable,
		CapacityVerdict:        capVerdict,
		ForensicFloorKind:      "generations_and_bytes",
	}, nil
}

// famWork is the calculator's per-family working state.
type famWork struct {
	f         LogFamily
	rotate    int
	retDays   int
	share     uint64
	size      uint64
	fixed     bool
	floorDays int // effective minimum retention (forensic floor applied)
	ceilDays  int // effective safety ceiling applied
}

// trimToBudget proportionally reduces non-fixed size caps (largest worst-case
// first) until the total fits the budget, never below minFamilySizeBytes.
func trimToBudget(work []famWork, budget uint64) {
	sum := func() uint64 {
		var t uint64
		for _, w := range work {
			t += safeconv.ToUint64OrZero(w.rotate) * w.size
		}
		return t
	}
	// index list sorted by worst-case desc for deterministic trimming
	idx := make([]int, 0, len(work))
	for i, w := range work {
		if !w.fixed {
			idx = append(idx, i)
		}
	}
	sort.SliceStable(idx, func(a, b int) bool {
		wa := safeconv.ToUint64OrZero(work[idx[a]].rotate) * work[idx[a]].size
		wb := safeconv.ToUint64OrZero(work[idx[b]].rotate) * work[idx[b]].size
		if wa != wb {
			return wa > wb
		}
		return work[idx[a]].f.Key < work[idx[b]].f.Key
	})
	// iterative one-MiB-step trim on the current largest until within budget
	for guard := 0; sum() > budget && guard < 1_000_000; guard++ {
		trimmed := false
		for _, i := range idx {
			if work[i].size > minFamilySizeBytes {
				work[i].size -= MiB
				if work[i].size < minFamilySizeBytes {
					work[i].size = minFamilySizeBytes
				}
				trimmed = true
				if sum() <= budget {
					return
				}
			}
		}
		if !trimmed {
			return // everything at the floor; budget already >= floorTotal so this fits
		}
	}
}

func roundToMiB(b uint64) uint64 {
	if b < MiB {
		return b
	}
	return (b / MiB) * MiB
}

func fitVerdict(theoretical, avail uint64) string {
	if avail == 0 {
		return FitUnknown
	}
	pct := theoretical * 100 / avail
	switch {
	case pct <= headroomFitPct:
		return FitFits
	case pct <= headroomTightPct:
		return FitTight
	default:
		return FitOverHeadroom
	}
}
