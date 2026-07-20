// meta:name="verdict.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 2 wiring: the structured reconciliation Verdict returned by the installer health-resource reconciler and consumed by the phaseValidate assertion. Lives in the leaf healthresource package so the installer services producer and the validate consumer share ONE type with no import cycle and no second policy path."
package healthresource

import "github.com/itcmsgr/nftban/internal/safety"

// Verdict is the structured outcome of reconciling the health-service resource
// drop-in against live systemd. Callers must never reconstruct this from log text.
type Verdict struct {
	Profile   safety.HealthResourceProfile
	Authority string // always "internal/safety"

	CalculatedHigh int64
	CalculatedMax  int64

	EffectiveHigh     int64
	EffectiveMax      int64
	EffectiveTasksMax int64

	DropInPath    string
	DropInLoaded  bool
	LoadedDropIns []string // ALL loaded DropInPaths (for conflict evidence)

	GeneratedState State // file-level: ABSENT/READY_GENERATED/ACTIVE_MATCH/STALE_MISMATCH/INVALID/GENERATION_FAILED
	EffectiveState State // systemd-level: ACTIVE_MATCH/FALLBACK_MATCH/FALLBACK_UNDERSIZED/ACTIVATION_FAILED

	SourceVersion    string
	Changed          bool
	DaemonReloaded   bool
	ProtectionActive bool
	ValidationError  string
}

// ProtectionRequired reports whether an ACTIVE effective drop-in is MANDATORY for
// this tier. Medium and large require it; small is satisfied by the packaged
// fallback (FALLBACK_MATCH) because the fallback already meets the small budget.
func ProtectionRequired(tier safety.ResourceTier) bool {
	return tier == safety.ResourceTierMedium || tier == safety.ResourceTierLarge
}

// Acceptable reports whether the verdict satisfies the host-class policy:
//   - any tier + ACTIVE_MATCH            → acceptable
//   - small     + FALLBACK_MATCH         → acceptable (fallback meets calc)
//   - medium/large + anything-but-active → NOT acceptable (installer DEGRADED)
func (v Verdict) Acceptable() bool {
	if v.EffectiveState == StateActiveMatch {
		return true
	}
	if !ProtectionRequired(v.Profile.Tier) && v.EffectiveState == StateFallbackMatch {
		return true
	}
	return false
}
