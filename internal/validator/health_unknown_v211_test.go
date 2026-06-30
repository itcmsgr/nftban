// =============================================================================
// NFTBan v1.211 — HEALTH-FALSE-ZERO regression tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="health-unknown-v211-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Locks v1.211 HEALTH-FALSE-ZERO: a FAILED enforcement-set read (countSetElementsState unknown=true — exec error / malformed JSON / permission-denied) degrades module health to a SeverityWarn finding and an UNSET Effective axis (never a false 'idle'/'enforcing'), while a genuinely EMPTY or CONFIRMED-ABSENT set on an enabled module stays neutral (idle, no WARN), a populated set still reports enforcing/observing, and a disabled module stays quiet. Hermetic: drives the countSetElementsStateFunc seam; no nft, no root."
// meta:inventory.files="internal/validator/module_health.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="conf.d/botguard/main.conf,conf.d/botguard/main.conf.local"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package validator

import "testing"

// botGuardSets is the structural set list BotGuard requires (IPv4 only here; the
// ip6 nftban table is not present in buildDoc, so v6 is not required).
var botGuardSets = []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
	"http_bot_grey", "http_bot_ban", "http_bot_emergency"}

// withBotGuardEnabled stands up an enabled+present+running BotGuard so the
// evaluator reaches the Effective set-read loop, with journal evidence present
// (so VAL-BOTGUARD-001 is not in play). Returns the evaluated health.
func withBotGuardEnabled(t *testing.T, stateFn func(family, name string) (int, bool, bool)) *ModuleHealth {
	t.Helper()
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf.local": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()

	old := countSetElementsStateFunc
	countSetElementsStateFunc = stateFn
	defer func() { countSetElementsStateFunc = old }()

	SetJournalReader(mockJournalReader{lines: []string{"module_start: botguard"}})
	defer SetJournalReader(SystemdJournalReader{})

	moduleFindings = nil // reset for this evaluation
	doc := buildDoc([]string{"http_bot_guard"}, botGuardSets)
	return evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})
}

func hasDegradedFinding(t *testing.T) bool {
	t.Helper()
	for _, f := range moduleFindings {
		if f.Code == CodeModuleDegraded && f.Severity == SeverityWarn {
			return true
		}
	}
	return false
}

// A FAILED read (exec error / timeout) → unknown → module degraded, NOT idle.
func TestBotGuardSetReadUnknownDegrades(t *testing.T) {
	h := withBotGuardEnabled(t, func(_, _ string) (int, bool, bool) {
		return 0, false, true // read failed: cannot prove empty
	})

	if h.Effective == EffectiveIdle {
		t.Errorf("effective = %q, want UNSET (a failed set read must NOT render false idle)", h.Effective)
	}
	if h.Effective == EffectiveEnforcing || h.Effective == EffectiveObserving {
		t.Errorf("effective = %q, want UNSET (a failed read must NOT claim active enforcement)", h.Effective)
	}
	if h.Effective != "" {
		t.Errorf("effective = %q, want \"\" (omitted on unknown)", h.Effective)
	}
	if !hasDegradedFinding(t) {
		t.Error("want a SeverityWarn VAL-MODULE-001 finding on a failed enforcement-set read (degraded visibility)")
	}
}

// Malformed-JSON and permission-denied both surface through the seam as unknown=true;
// the verdict path is the same (degrade, not idle). This locks both error classes.
func TestBotGuardSetReadUnknownVariantsDegrade(t *testing.T) {
	for _, name := range []string{"malformed-json", "permission-denied"} {
		t.Run(name, func(t *testing.T) {
			h := withBotGuardEnabled(t, func(_, _ string) (int, bool, bool) {
				return 0, false, true
			})
			if h.Effective == EffectiveIdle {
				t.Errorf("%s: effective rendered idle on a failed read", name)
			}
			if !hasDegradedFinding(t) {
				t.Errorf("%s: want degraded WARN finding", name)
			}
		})
	}
}

// A genuinely EMPTY set (present, 0 elements) on an enabled module → idle/neutral,
// NOT a false WARN. This preserves the "zero = NEUTRAL" rule (BUG-3 lesson).
func TestBotGuardEmptySetIsNeutralIdle(t *testing.T) {
	h := withBotGuardEnabled(t, func(_, _ string) (int, bool, bool) {
		return 0, true, false // present + empty
	})
	if h.Effective != EffectiveIdle {
		t.Errorf("effective = %q, want idle (empty set is neutral, not degraded)", h.Effective)
	}
	if hasDegradedFinding(t) {
		t.Error("empty set must NOT emit a degraded WARN finding (zero = NEUTRAL)")
	}
}

// A CONFIRMED-ABSENT set (exists=false, unknown=false) is also neutral → idle,
// never a false WARN.
func TestBotGuardConfirmedAbsentSetIsNeutralIdle(t *testing.T) {
	h := withBotGuardEnabled(t, func(_, _ string) (int, bool, bool) {
		return 0, false, false // confirmed absent
	})
	if h.Effective != EffectiveIdle {
		t.Errorf("effective = %q, want idle (confirmed-absent set is neutral)", h.Effective)
	}
	if hasDegradedFinding(t) {
		t.Error("confirmed-absent set must NOT emit a degraded WARN finding")
	}
}

// A populated enforcement set still reports enforcing (unchanged behavior).
func TestBotGuardPopulatedSetEnforcingUnchanged(t *testing.T) {
	h := withBotGuardEnabled(t, func(_, name string) (int, bool, bool) {
		if name == "http_bot_ban" {
			return 3, true, false
		}
		return 0, true, false
	})
	if h.Effective != EffectiveEnforcing {
		t.Errorf("effective = %q, want enforcing (ban set populated)", h.Effective)
	}
	if hasDegradedFinding(t) {
		t.Error("a clean populated read must NOT emit a degraded finding")
	}
}

// A populated observation set still reports observing (unchanged behavior).
func TestBotGuardPopulatedObservationUnchanged(t *testing.T) {
	h := withBotGuardEnabled(t, func(_, name string) (int, bool, bool) {
		if name == "http_bot_suspect" {
			return 5, true, false
		}
		return 0, true, false
	})
	if h.Effective != EffectiveObserving {
		t.Errorf("effective = %q, want observing (suspect set populated, ban empty)", h.Effective)
	}
}

// A disabled module never reads sets and stays quiet — a failing seam must not be
// reached, and no degraded finding is emitted.
func TestBotGuardDisabledStaysQuietOnReadFailure(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf.local": `HTTP_BOTGUARD_ENABLED="false"`,
	})
	defer cleanup()

	called := false
	old := countSetElementsStateFunc
	countSetElementsStateFunc = func(_, _ string) (int, bool, bool) {
		called = true
		return 0, false, true
	}
	defer func() { countSetElementsStateFunc = old }()

	moduleFindings = nil
	doc := buildDoc([]string{"http_bot_guard"}, botGuardSets)
	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})

	if called {
		t.Error("disabled BotGuard must NOT read kernel sets")
	}
	if h.Config != ConfigDisabled {
		t.Errorf("config = %q, want disabled", h.Config)
	}
	if hasDegradedFinding(t) {
		t.Error("disabled module must stay quiet (no degraded finding)")
	}
}

// =============================================================================
// Blacklist (manual) — THE enforcement set. v1.211 HEALTH-FALSE-ZERO closes the
// last legacy 0-on-error reader: a FAILED manual-set read must degrade (unknown)
// instead of collapsing to a false "idle" ("no bans").
// =============================================================================

// withBlacklistManual mocks the 3-valued set reader and disables geoban/feeds so
// evaluateBlacklist's Manual sub-health is deterministic. stateFn is keyed by
// (family, setName) — switch on setName to fail only the manual set if desired.
func withBlacklistManual(t *testing.T, doc *RulesetDocument, stateFn func(family, name string) (int, bool, bool)) *BlacklistHealth {
	t.Helper()
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()

	old := countSetElementsStateFunc
	countSetElementsStateFunc = stateFn
	defer func() { countSetElementsStateFunc = old }()

	moduleFindings = nil // reset for this evaluation
	return evaluateBlacklist(doc)
}

// A FAILED read on either family of blacklist_manual → "unknown", NOT a false idle,
// and a SeverityWarn CodeModuleDegraded finding is surfaced.
func TestBlacklistManualReadUnknownDegrades(t *testing.T) {
	for _, failSet := range []string{"blacklist_manual_ipv4", "blacklist_manual_ipv6"} {
		t.Run(failSet, func(t *testing.T) {
			bh := withBlacklistManual(t, buildDoc(nil, nil), func(_, name string) (int, bool, bool) {
				if name == failSet {
					return 0, false, true // read failed: cannot prove empty
				}
				return 0, true, false // other family present + empty
			})
			if bh.Manual.State == "idle" {
				t.Error("manual rendered false idle on a failed enforcement-set read")
			}
			if bh.Manual.State == "primed" || bh.Manual.State == "enforcing" {
				t.Errorf("manual state = %q, want unknown (a failed read must NOT claim bans loaded)", bh.Manual.State)
			}
			if bh.Manual.State != "unknown" {
				t.Errorf("manual state = %q, want unknown", bh.Manual.State)
			}
			if !hasDegradedFinding(t) {
				t.Error("want a SeverityWarn CodeModuleDegraded finding on a failed blacklist_manual read")
			}
		})
	}
}

// Both families present + empty (count 0) → idle/neutral, no spurious WARN.
// Preserves the zero = NEUTRAL rule.
func TestBlacklistManualEmptyIsNeutralIdle(t *testing.T) {
	bh := withBlacklistManual(t, buildDoc(nil, nil), func(_, _ string) (int, bool, bool) {
		return 0, true, false // present + empty
	})
	if bh.Manual.State != "idle" {
		t.Errorf("manual state = %q, want idle (both families empty is neutral)", bh.Manual.State)
	}
	if bh.Manual.Entries != 0 {
		t.Errorf("manual entries = %d, want 0", bh.Manual.Entries)
	}
	if hasDegradedFinding(t) {
		t.Error("a confirmed-empty manual set must NOT emit a degraded WARN finding (zero = NEUTRAL)")
	}
}

// Populated manual set + drops > 0 → enforcing (unchanged). Sum counts only from
// successful reads (4 per family → 8 total).
func TestBlacklistManualPopulatedEnforcingUnchanged(t *testing.T) {
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Counter: &NftCounter{Family: "ip", Table: "nftban", Name: "input_blacklist_manual_drop", Packets: 7}},
	}
	doc := ParseRuleset(&NftRuleset{Nftables: objects})
	bh := withBlacklistManual(t, doc, func(_, _ string) (int, bool, bool) {
		return 4, true, false // populated, present
	})
	if bh.Manual.State != "enforcing" {
		t.Errorf("manual state = %q, want enforcing (populated + drops)", bh.Manual.State)
	}
	if bh.Manual.Entries != 8 {
		t.Errorf("manual entries = %d, want 8 (4 ipv4 + 4 ipv6)", bh.Manual.Entries)
	}
	if hasDegradedFinding(t) {
		t.Error("a clean populated read must NOT emit a degraded finding")
	}
}

// Populated manual set, no drops → primed (unchanged).
func TestBlacklistManualPopulatedPrimedUnchanged(t *testing.T) {
	bh := withBlacklistManual(t, buildDoc(nil, nil), func(_, _ string) (int, bool, bool) {
		return 2, true, false // populated, present, no drop counter in empty doc
	})
	if bh.Manual.State != "primed" {
		t.Errorf("manual state = %q, want primed (populated, no drops)", bh.Manual.State)
	}
	if hasDegradedFinding(t) {
		t.Error("a clean populated read must NOT emit a degraded finding")
	}
}
