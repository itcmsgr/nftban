// =============================================================================
// NFTBan v1.229.7 — shared mode-plan reader (PR-4B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="modeplan"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-24"
// meta:description="The single Go implementation of the mode-plan read contract. Resolves NOTHING: it reads the transient plan record published by the shell reconcile root, validates module identity, convergence binding, config currency and explicit-intent agreement, and returns UNKNOWN whenever any of those fail. internal/validator and internal/{ddos,portscan} all consume this rather than each carrying their own copy, because three implementations of one contract is three chances to drift."
// =============================================================================

package nftbanconf

import (
	"os"
	"path/filepath"
	"strings"
)

// ModeUnknown is returned when the effective mode CANNOT be established.
// It is never a mode the system runs in — it is the refusal to guess one.
const ModeUnknown = "unknown"

// Basis values explain WHY EffectiveMode is what it is. They are diagnostic,
// never policy: nothing may branch on a basis to pick a mode.
const (
	BasisCurrentPlan    = "current_plan"
	BasisExplicitIntent = "explicit_configured_mode"
	BasisNoPlan         = "no_current_plan"
	BasisMalformed      = "plan_malformed"
	BasisUnbound        = "plan_not_bound_to_current_convergence"
	BasisSuperseded     = "plan_superseded_by_config_change"
	BasisContradiction  = "plan_contradicts_explicit_intent"
	BasisUnknownModule  = "unknown_module"
)

// ReadEffectiveMode reports the effective mode for a module WITHOUT ever
// resolving `auto`.
//
//	STATUS/CONSUMER MUST NOT RESOLVE AUTO.
//	CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
//
// It never probes Suricata availability, never infers a mode from observed
// kernel objects, and never falls back from a broken plan to the configured
// mode. Every failure path returns ModeUnknown.
//
// Pure with respect to package state: configDir and runDir are passed in, so
// callers with their own directory authority (the validator's test isolation,
// the daemon's nftbanconf paths) share one rule set instead of copying it.
//
// Returns (effectiveMode, basis).
func ReadEffectiveMode(module, configDir, runDir string) (string, string) {
	switch module {
	case "ddos", "portscan":
	default:
		return ModeUnknown, BasisUnknownModule
	}

	configured := readModeKey(module, configDir)
	explicit := configured == "classic" || configured == "suricata"

	// #nosec G304 -- module is constrained to the closed set above and runDir is
	// caller-supplied configuration, so no part of this filename is attacker-derived.
	data, err := os.ReadFile(filepath.Clean(filepath.Join(runDir, "module-plan-"+module+".env")))
	if err != nil {
		// No record. An explicit mode is self-authoritative — the plan is not
		// needed to know what was asked for. `auto` (or a legacy value such as
		// hybrid) is genuinely unresolved here.
		if explicit {
			return configured, BasisExplicitIntent
		}
		return ModeUnknown, BasisNoPlan
	}

	var gotModule, effective, planConfigured, boundGen string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if v, ok := strings.CutPrefix(line, "NFTBAN_PLAN_MODULE="); ok {
			gotModule = v
		}
		if v, ok := strings.CutPrefix(line, "NFTBAN_PLAN_EFFECTIVE_MODE="); ok {
			effective = v
		}
		if v, ok := strings.CutPrefix(line, "NFTBAN_PLAN_CONFIGURED_MODE="); ok {
			planConfigured = v
		}
		if v, ok := strings.CutPrefix(line, "NFTBAN_PLAN_BOUND_GENERATION="); ok {
			boundGen = v
		}
	}

	// MALFORMED: wrong module, or an effective_mode outside the closed set.
	// A present-but-invalid record is a BROKEN CONTRACT, not evidence of absence,
	// so it must not degrade into "well, the operator said auto".
	if gotModule != module || planConfigured == "" ||
		(effective != "classic" && effective != "suricata" && effective != "inactive") {
		return ModeUnknown, BasisMalformed
	}

	// UNBOUND / STALE: a record is usable only if it describes the convergence
	// that is actually rendered.
	//   A PLAN RECORD IS USABLE ONLY IF ITS BINDING IS CURRENT.
	if boundGen == "" || boundGen != CurrentConvergenceGeneration(runDir) {
		return ModeUnknown, BasisUnbound
	}

	// SUPERSEDED: the record names the configured_mode it was resolved FROM.
	if planConfigured != configured {
		return ModeUnknown, BasisSuperseded
	}

	// CONTRADICTION: a plan may RESOLVE `auto`; it may never OVERRIDE an
	// explicit operator intent.
	if explicit && effective != configured {
		return ModeUnknown, BasisContradiction
	}

	return effective, BasisCurrentPlan
}

// CurrentConvergenceGeneration returns the generation of the convergence that is
// actually rendered. An absent file is generation 0 — the coherent
// pre-convergence generation, not an error.
func CurrentConvergenceGeneration(runDir string) string {
	// #nosec G304 -- constant filename under caller-supplied runDir.
	data, err := os.ReadFile(filepath.Clean(filepath.Join(runDir, "convergence-generation")))
	if err != nil {
		return "0"
	}
	g := strings.TrimSpace(string(data))
	if g == "" {
		return "0"
	}
	for _, r := range g {
		if r < '0' || r > '9' {
			return "0"
		}
	}
	return g
}

// readModeKey reads <MODULE>_MODE with the same base + .local layering the rest
// of nftban uses. Absent means `auto`.
func readModeKey(module, configDir string) string {
	key := "DDOS_MODE"
	if module == "portscan" {
		key = "PORTSCAN_MODE"
	}
	base := filepath.Join(configDir, "conf.d", module, "main.conf")
	val := "auto"
	if v := readKeyFrom(base, key); v != "" {
		val = v
	}
	if v := readKeyFrom(base+".local", key); v != "" {
		val = v
	}
	return val
}

func readKeyFrom(path, key string) string {
	// #nosec G304 -- path is composed from caller-supplied configDir and a
	// constant relative layout; no component is attacker-derived.
	data, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		v, ok := strings.CutPrefix(line, key+"=")
		if !ok {
			continue
		}
		return strings.Trim(strings.TrimSpace(v), `"`)
	}
	return ""
}
