// =============================================================================
// NFTBan - nftenforce_test (v1.228.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftenforce_test"
// meta:type="test"
// meta:version="1.228.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Scenario fixtures T1-T9 plus committed mutation fixtures proving the enforcement evaluator FAILS when the invariant is deliberately weakened"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftenforce

import (
	"encoding/json"
	"strings"
	"testing"
)

// goldenEnforcing is the shape a correctly-configured NFTBan host produces:
// a hooked base chain that JUMPS to a regular chain, and the set reference lives
// in the regular chain. The indirect jump is the realistic case — a verifier
// that only checked whether the referencing chain itself carries a "hook" field
// would report NOT ENFORCED on a working host.
const goldenEnforcing = `{"nftables":[
 {"chain":{"family":"ip","table":"nftban","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}},
 {"chain":{"family":"ip","table":"nftban","name":"blacklist_check"}},
 {"rule":{"family":"ip","table":"nftban","chain":"input","expr":[{"jump":{"target":"blacklist_check"}}]}},
 {"rule":{"family":"ip","table":"nftban","chain":"blacklist_check","expr":[
   {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"@blacklist_manual_ipv4"}},
   {"counter":{"packets":0,"bytes":0}},
   {"drop":null}]}}
]}`

func evalGolden(t *testing.T, ruleset string) Result {
	t.Helper()
	return Evaluate([]byte(ruleset), "ip", "nftban", "blacklist_manual_ipv4")
}

func requireOutcome(t *testing.T, got Result, want Outcome, label string) {
	t.Helper()
	if got.Outcome != want {
		t.Fatalf("%s: outcome = %s (want %s)\n  detail: %s", label, got.Outcome, want, got.Detail)
	}
	if want != ReachableEnforcingPath && got.Outcome.Enforced() {
		t.Fatalf("%s: non-enforcing outcome %s reported Enforced()=true", label, got.Outcome)
	}
}

// mutate rewrites one exact substring of a fixture. Mutations are applied to the
// FIXTURE, never to the checked-out implementation — a CI run must never edit
// and restore production source.
func mutate(t *testing.T, src, old, new string) string {
	t.Helper()
	if !strings.Contains(src, old) {
		t.Fatalf("mutation target %q not present in fixture — fixture drifted, mutation is no longer meaningful", old)
	}
	return strings.Replace(src, old, new, 1)
}

// ---------------------------------------------------------------------------
// T1–T9 — required scenario fixtures
// ---------------------------------------------------------------------------

// T3 first: the positive case. Without a green positive, every other assertion
// could be satisfied by an evaluator that always says "not enforced".
func TestT3_ReachableFromActiveHook_Enforced(t *testing.T) {
	got := evalGolden(t, goldenEnforcing)
	requireOutcome(t, got, ReachableEnforcingPath, "T3")
	if !got.Outcome.Enforced() {
		t.Fatal("T3: Enforced() must be true for REACHABLE_ENFORCING_PATH")
	}
	if got.BaseChain != "input" || got.Chain != "blacklist_check" {
		t.Fatalf("T3: expected reference in blacklist_check reached from input, got chain=%q base=%q", got.Chain, got.BaseChain)
	}
}

func TestT1_SetExistsButNoRuleReferencesIt(t *testing.T) {
	const rs = `{"nftables":[
	 {"chain":{"family":"ip","table":"nftban","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}},
	 {"set":{"family":"ip","table":"nftban","name":"blacklist_manual_ipv4","type":"ipv4_addr"}},
	 {"rule":{"family":"ip","table":"nftban","chain":"input","expr":[{"counter":{"packets":0,"bytes":0}}]}}
	]}`
	requireOutcome(t, evalGolden(t, rs), NoSetReference, "T1")
}

func TestT2_ReferencedByUnhookedUnreachableChain(t *testing.T) {
	// The chain holding the reference exists and enforces — but nothing jumps to
	// it and it has no hook, so no packet ever arrives.
	const rs = `{"nftables":[
	 {"chain":{"family":"ip","table":"nftban","name":"orphan"}},
	 {"rule":{"family":"ip","table":"nftban","chain":"orphan","expr":[
	   {"match":{"op":"==","left":{"payload":{"field":"saddr"}},"right":"@blacklist_manual_ipv4"}},
	   {"drop":null}]}}
	]}`
	requireOutcome(t, evalGolden(t, rs), SetReferenceUnreachable, "T2")
}

func TestT4_ParserFailure(t *testing.T) {
	requireOutcome(t, evalGolden(t, `{"nftables":`), ParserFailure, "T4/malformed")
	requireOutcome(t, evalGolden(t, `{"nftables":[]}`), ParserFailure, "T4/empty")
	requireOutcome(t, evalGolden(t, `{"something_else":[{"a":1}]}`), ParserFailure, "T4/no-nftables-key")
}

func TestT5_IPv4EnforcedIPv6Unhooked(t *testing.T) {
	// Same ruleset, both families present. ip enforces; ip6's base chain has no
	// hook, so the identical ip6 reference is unreachable. A family-blind
	// evaluator would report both as enforced.
	const rs = `{"nftables":[
	 {"chain":{"family":"ip","table":"nftban","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}},
	 {"rule":{"family":"ip","table":"nftban","chain":"input","expr":[
	   {"match":{"op":"==","left":{"payload":{"field":"saddr"}},"right":"@blacklist_manual_ipv4"}},{"drop":null}]}},
	 {"chain":{"family":"ip6","table":"nftban","name":"input"}},
	 {"rule":{"family":"ip6","table":"nftban","chain":"input","expr":[
	   {"match":{"op":"==","left":{"payload":{"field":"saddr"}},"right":"@blacklist_manual_ipv6"}},{"drop":null}]}}
	]}`
	requireOutcome(t, Evaluate([]byte(rs), "ip", "nftban", "blacklist_manual_ipv4"), ReachableEnforcingPath, "T5/ipv4")
	requireOutcome(t, Evaluate([]byte(rs), "ip6", "nftban", "blacklist_manual_ipv6"), SetReferenceUnreachable, "T5/ipv6")
}

func TestT6_EmergencyTableOnly_ProductBlacklistUnreferenced(t *testing.T) {
	// This is the observed P0 state: the only hooked chain belongs to the
	// install emergency table with policy accept, and the product blacklist set
	// exists but nothing references it.
	const rs = `{"nftables":[
	 {"chain":{"family":"inet","table":"nftban_install_emergency","name":"input","type":"filter","hook":"input","prio":0,"policy":"accept"}},
	 {"chain":{"family":"ip","table":"nftban","name":"portscan_detection"}},
	 {"set":{"family":"ip","table":"nftban","name":"blacklist_manual_ipv4","type":"ipv4_addr"}}
	]}`
	requireOutcome(t, evalGolden(t, rs), NoSetReference, "T6")
}

func TestT7_SimilarlyNamedSetIsNotAMatch(t *testing.T) {
	// A substring matcher would call this enforced. It must not.
	rs := mutate(t, goldenEnforcing, "@blacklist_manual_ipv4", "@blacklist_manual_ipv4_old")
	requireOutcome(t, evalGolden(t, rs), NoSetReference, "T7")

	// And the reverse direction: a shorter name must not match a longer set.
	got := Evaluate([]byte(goldenEnforcing), "ip", "nftban", "blacklist_manual")
	requireOutcome(t, got, NoSetReference, "T7/prefix")
}

func TestT8_ReachableButNonEnforcingVerdict(t *testing.T) {
	// counter-only: drop the verdict, keep the counter and the set match
	rs := mutate(t, goldenEnforcing,
		`{"counter":{"packets":0,"bytes":0}},`+"\n   "+`{"drop":null}`,
		`{"counter":{"packets":0,"bytes":0}}`)
	requireOutcome(t, evalGolden(t, rs), ReachableNonEnforcingPath, "T8/counter-only")

	// explicit accept
	rs = mutate(t, goldenEnforcing, `{"drop":null}`, `{"accept":null}`)
	requireOutcome(t, evalGolden(t, rs), ReachableNonEnforcingPath, "T8/accept")
}

func TestT8b_ShadowedByEarlierUnconditionalAccept(t *testing.T) {
	// The reference is reachable AND enforcing, but an unconditional accept
	// earlier in the same chain means no packet ever reaches it.
	const rs = `{"nftables":[
	 {"chain":{"family":"ip","table":"nftban","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}},
	 {"rule":{"family":"ip","table":"nftban","chain":"input","expr":[{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
	 {"rule":{"family":"ip","table":"nftban","chain":"input","expr":[
	   {"match":{"op":"==","left":{"payload":{"field":"saddr"}},"right":"@blacklist_manual_ipv4"}},{"drop":null}]}}
	]}`
	requireOutcome(t, evalGolden(t, rs), ReachableNonEnforcingPath, "T8b/shadowed")
}

// T9 — CYCLE CONTRACT (documented, deterministic):
// a jump/goto cycle is traversed exactly once via the visited set. A cycle is
// NOT ambiguity by itself. If no enforcing reference is found, the result is the
// ordinary non-enforced outcome. The assertion below also proves termination.
func TestT9_JumpCycleWithNoEnforcingPath(t *testing.T) {
	const rs = `{"nftables":[
	 {"chain":{"family":"ip","table":"nftban","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}},
	 {"chain":{"family":"ip","table":"nftban","name":"a"}},
	 {"chain":{"family":"ip","table":"nftban","name":"b"}},
	 {"rule":{"family":"ip","table":"nftban","chain":"input","expr":[{"jump":{"target":"a"}}]}},
	 {"rule":{"family":"ip","table":"nftban","chain":"a","expr":[{"jump":{"target":"b"}}]}},
	 {"rule":{"family":"ip","table":"nftban","chain":"b","expr":[{"jump":{"target":"a"}}]}}
	]}`
	requireOutcome(t, evalGolden(t, rs), NoSetReference, "T9/cycle")
}

func TestT9b_CycleStillFindsEnforcingReference(t *testing.T) {
	// A cycle must not cause a real enforcing reference to be missed.
	const rs = `{"nftables":[
	 {"chain":{"family":"ip","table":"nftban","name":"input","type":"filter","hook":"input","prio":0,"policy":"drop"}},
	 {"chain":{"family":"ip","table":"nftban","name":"a"}},
	 {"chain":{"family":"ip","table":"nftban","name":"b"}},
	 {"rule":{"family":"ip","table":"nftban","chain":"input","expr":[{"jump":{"target":"a"}}]}},
	 {"rule":{"family":"ip","table":"nftban","chain":"a","expr":[{"jump":{"target":"b"}}]}},
	 {"rule":{"family":"ip","table":"nftban","chain":"b","expr":[{"jump":{"target":"a"}}]}},
	 {"rule":{"family":"ip","table":"nftban","chain":"b","expr":[
	   {"match":{"op":"==","left":{"payload":{"field":"saddr"}},"right":"@blacklist_manual_ipv4"}},{"drop":null}]}}
	]}`
	requireOutcome(t, evalGolden(t, rs), ReachableEnforcingPath, "T9b/cycle-with-enforcement")
}

// ---------------------------------------------------------------------------
// DURABLE MUTATION FIXTURES
//
// Each mutation weakens the enforcement invariant in the golden ruleset and
// asserts the evaluator STOPS reporting enforcement. These are the committed,
// re-running proof that this control can fail — the property a one-off manual
// mutation cannot provide, because nothing reruns it and its decay is invisible.
//
// If a mutation target ever disappears from the golden fixture, mutate() fails
// loudly rather than silently testing nothing.
// ---------------------------------------------------------------------------

func TestMutation_ControlDetectsWeakenedEnforcement(t *testing.T) {
	// Guard: the golden fixture must be enforcing, or every mutation below is vacuous.
	requireOutcome(t, evalGolden(t, goldenEnforcing), ReachableEnforcingPath, "mutation/baseline")

	cases := []struct {
		name     string
		old, new string
		want     Outcome
	}{
		{
			name: "M1_remove_hook_from_base_chain",
			old:  `"type":"filter","hook":"input","prio":0,`,
			new:  ``,
			want: SetReferenceUnreachable,
		},
		{
			name: "M2_weaken_drop_to_accept",
			old:  `{"drop":null}`,
			new:  `{"accept":null}`,
			want: ReachableNonEnforcingPath,
		},
		{
			name: "M3_retarget_to_similar_name_set",
			old:  `"@blacklist_manual_ipv4"`,
			new:  `"@blacklist_manual_ipv44"`,
			want: NoSetReference,
		},
		{
			name: "M4_break_jump_target",
			old:  `{"jump":{"target":"blacklist_check"}}`,
			new:  `{"jump":{"target":"chain_that_does_not_exist"}}`,
			want: AmbiguousRuleset,
		},
		{
			name: "M5_jump_target_unreadable",
			old:  `{"jump":{"target":"blacklist_check"}}`,
			new:  `{"jump":{"target":""}}`,
			want: AmbiguousRuleset,
		},
		{
			name: "M6_unrecognised_verdict_on_referencing_rule",
			old:  `{"drop":null}`,
			new:  `{"teleport":null}`,
			want: AmbiguousRuleset,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := evalGolden(t, mutate(t, goldenEnforcing, tc.old, tc.new))
			requireOutcome(t, got, tc.want, tc.name)
			if got.Outcome.Enforced() {
				t.Fatalf("%s: mutation was NOT detected — control still reports enforced", tc.name)
			}
		})
	}
}

// The evaluator must never claim enforcement for an outcome other than
// ReachableEnforcingPath. This is the invariant the CLI contract rests on.
func TestOnlyOneOutcomeIsEnforced(t *testing.T) {
	all := []Outcome{
		ReachableEnforcingPath, NoSetReference, SetReferenceUnreachable,
		ReachableNonEnforcingPath, AmbiguousRuleset, ParserFailure,
	}
	enforced := 0
	for _, o := range all {
		if o.Enforced() {
			enforced++
			if o != ReachableEnforcingPath {
				t.Fatalf("outcome %s must not report Enforced()=true", o)
			}
		}
	}
	if enforced != 1 {
		t.Fatalf("exactly one outcome must be enforcing, got %d", enforced)
	}
}

func TestGoldenFixtureIsValidJSON(t *testing.T) {
	var v any
	if err := json.Unmarshal([]byte(goldenEnforcing), &v); err != nil {
		t.Fatalf("golden fixture is not valid JSON: %v", err)
	}
}
