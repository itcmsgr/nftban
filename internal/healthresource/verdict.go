// SPDX-License-Identifier: MPL-2.0
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

	// ResolvedFrom records WHICH precedence branch of ResolveHealthResourceVerdict
	// produced this verdict: "current" (phaseConfigure reconciliation reused this
	// process), "live" (read-only systemd verify), "persisted" (cautious
	// install_state reconstruction), or "unavailable" (no live read + no persisted
	// evidence). v1.223.0: a resolution-source marker so tests can PROVE a fresh
	// per-pass live read happened (VALIDATE_2 must not reuse a mutated cache). It is
	// diagnostic only and is DELIBERATELY IGNORED by IsZero — a resolved verdict is
	// non-zero on its substantive fields regardless of this marker.
	ResolvedFrom string
}

// ProtectionRequired reports whether an ACTIVE effective drop-in is MANDATORY for
// this tier. Medium and large require it; small is satisfied by the packaged
// fallback (FALLBACK_MATCH) because the fallback already meets the small budget.
func ProtectionRequired(tier safety.ResourceTier) bool {
	return tier == safety.ResourceTierMedium || tier == safety.ResourceTierLarge
}

// AcceptableFor is the SINGLE tier-aware protection predicate:
//   - any tier + ACTIVE_MATCH            → acceptable
//   - small     + FALLBACK_MATCH         → acceptable (fallback meets calc)
//   - medium/large + anything-but-active → NOT acceptable (installer DEGRADED)
//
// v1.223.0: extracted so the installer verdict (Verdict.Acceptable), the
// repair/revalidate resolution, AND the read-only CLI (nftban health resources)
// all consume ONE predicate — INSTALLER_ACCEPTABLE == CLI_PROTECTION_ACTIVE ==
// REVALIDATE_ACCEPTABLE. Closes RESOURCES-VERDICT-TIER-BLIND (the CLI previously
// decided "protected" via the tier-blind State.ProtectionActive()).
func AcceptableFor(tier safety.ResourceTier, eff State) bool {
	if eff == StateActiveMatch {
		return true
	}
	if !ProtectionRequired(tier) && eff == StateFallbackMatch {
		return true
	}
	return false
}

// Acceptable reports whether the verdict satisfies the host-class policy via the
// shared AcceptableFor predicate.
func (v Verdict) Acceptable() bool {
	return AcceptableFor(v.Profile.Tier, v.EffectiveState)
}

// IsZero reports whether the verdict was never populated (a zero struct — e.g. a
// validate-only entry point that skipped phaseConfigure). v1.223.0: validation
// paths MUST resolve a real verdict (services.ResolveHealthResourceVerdict) rather
// than pass a zero struct into the assertion; the assertion treats a zero verdict
// as UNRESOLVED (honest skip-with-warning), NEVER as a fabricated 0/0 policy
// failure and NEVER as silently protected.
func (v Verdict) IsZero() bool {
	return v.Profile.Tier == "" && v.EffectiveState == "" &&
		v.CalculatedHigh == 0 && v.CalculatedMax == 0 &&
		v.EffectiveHigh == 0 && v.EffectiveMax == 0
}
