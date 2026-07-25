// =============================================================================
// NFTBan - nftenforce (v1.228.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftenforce"
// meta:type="package"
// meta:version="1.228.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Decides whether a named nftables set is actually ENFORCING: exact set reference, chain reachable from an active hook, enforcing verdict. Fails closed on anything it cannot model"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package nftenforce answers one question: is a named nftables set actually
// ENFORCING, or does it merely exist?
//
// # WHY THIS EXISTS
//
// `nft get element` proves an address is a member of a set. It proves nothing
// about whether packets are filtered. A set can be populated and completely
// inert: unreferenced by any rule, referenced only from a chain nothing jumps
// to, referenced with a counter but no verdict, or shadowed by an earlier
// unconditional accept.
//
// That gap produced a P0: `nftban ban` verified set membership and then told the
// operator "the IP is now blocked by the firewall". On a host whose filter
// chains never loaded, both statements were issued together — the first true,
// the second false.
//
// Membership is not enforcement. This package evaluates the rest of the chain:
//
//	member in target set
//	  → a rule references that EXACT set
//	  → the rule's chain is reachable from a base chain with an active hook
//	  → the rule's verdict actually enforces (drop/reject)
//
// # PARSER AUTHORITY
//
// The nft JSON decode types come from internal/validator, which has carried a
// complete typed model (NftRuleset / NftObject / NftChain including Hook /
// NftRule) since v1.109. This package deliberately adds NO decode types of its
// own — only reachability semantics, which did not exist anywhere.
//
// The tree still holds several other ad-hoc `json:"nftables"` decodes (two in
// internal/metrics, two more in internal/validator/module_health.go). Those
// predate this package and consolidating them is a separate failure domain;
// this package simply does not add to the count.
//
// FAIL CLOSED. Anything this package cannot model — an unknown verdict on a
// referencing rule, a jump to a chain that does not exist, a malformed ruleset —
// is reported as ambiguity, never as enforcement. It is better to tell an
// operator "could not verify" than to tell them "protected" and be wrong.
package nftenforce

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/itcmsgr/nftban/internal/validator"
)

// Outcome is the result of an enforcement evaluation.
type Outcome string

const (
	// ReachableEnforcingPath is the ONLY outcome that means "enforced".
	ReachableEnforcingPath Outcome = "REACHABLE_ENFORCING_PATH"
	// NoSetReference means no rule anywhere references the set.
	NoSetReference Outcome = "NO_SET_REFERENCE"
	// SetReferenceUnreachable means a rule references the set, but its chain is
	// not reachable from any base chain with a hook.
	SetReferenceUnreachable Outcome = "SET_REFERENCE_UNREACHABLE"
	// ReachableNonEnforcingPath means the reference is reachable but does not
	// enforce: counter-only, accept, or shadowed by an earlier unconditional accept.
	ReachableNonEnforcingPath Outcome = "REACHABLE_NON_ENFORCING_PATH"
	// AmbiguousRuleset means the ruleset contains something this evaluator does
	// not model well enough to make a safe claim.
	AmbiguousRuleset Outcome = "AMBIGUOUS_RULESET"
	// ParserFailure means the input could not be decoded at all.
	ParserFailure Outcome = "PARSER_FAILURE"
)

// Enforced reports whether the outcome permits an enforcement claim.
// Exactly one outcome does.
func (o Outcome) Enforced() bool { return o == ReachableEnforcingPath }

// Result carries the outcome plus enough detail to explain it to an operator.
type Result struct {
	Outcome Outcome
	// Detail is a short human-readable explanation, safe to print.
	Detail string
	// Chain is the chain holding the set reference, when one was found.
	Chain string
	// BaseChain is the hooked chain the reference was reached from, when reachable.
	BaseChain string
}

// maxTraversalDepth bounds jump/goto traversal. Cycles are already handled by
// the visited set; this is a second backstop against a pathological ruleset.
const maxTraversalDepth = 128

// ErrNoRuleset is returned when the input contains no nftables array at all.
var ErrNoRuleset = errors.New("nft json: input contains no nftables ruleset")

// chainKey identifies a chain uniquely. Family and table are part of the key
// because the same chain name legitimately exists in both ip and ip6.
type chainKey struct {
	family string
	table  string
	name   string
}

func (k chainKey) String() string { return fmt.Sprintf("%s %s %s", k.family, k.table, k.name) }

// Evaluate decides whether setName in (family, table) is enforcing.
//
// rulesetJSON is the raw output of `nft -j list ruleset`. The caller supplies it
// rather than this package shelling out, so the evaluator stays pure and its
// fixtures need no root, no kernel and no nft binary.
func Evaluate(rulesetJSON []byte, family, table, setName string) Result {
	var rs validator.NftRuleset
	if err := json.Unmarshal(rulesetJSON, &rs); err != nil {
		return Result{Outcome: ParserFailure, Detail: "cannot decode nft JSON: " + err.Error()}
	}
	if len(rs.Nftables) == 0 {
		return Result{Outcome: ParserFailure, Detail: ErrNoRuleset.Error()}
	}

	chains := map[chainKey]*validator.NftChain{}
	rulesByChain := map[chainKey][]*validator.NftRule{}

	for i := range rs.Nftables {
		obj := &rs.Nftables[i]
		if c := obj.Chain; c != nil {
			chains[chainKey{c.Family, c.Table, c.Name}] = c
			continue
		}
		if r := obj.Rule; r != nil {
			k := chainKey{r.Family, r.Table, r.Chain}
			rulesByChain[k] = append(rulesByChain[k], r)
		}
	}

	if len(chains) == 0 {
		return Result{Outcome: ParserFailure, Detail: "ruleset contains no chains"}
	}

	// Reachability: BFS from every base chain in the target family. A base chain
	// is one carrying a hook — that is where packets enter.
	reachedFrom := map[chainKey]string{}
	queue := make([]chainKey, 0, len(chains))
	for k, c := range chains {
		if c.Family == family && c.Hook != "" {
			reachedFrom[k] = c.Name
			queue = append(queue, k)
		}
	}

	depth := 0
	for len(queue) > 0 {
		depth++
		if depth > maxTraversalDepth {
			return Result{
				Outcome: AmbiguousRuleset,
				Detail:  fmt.Sprintf("chain traversal exceeded %d steps", maxTraversalDepth),
			}
		}
		cur := queue[0]
		queue = queue[1:]
		origin := reachedFrom[cur]

		for _, r := range rulesByChain[cur] {
			targets, err := jumpTargets(r)
			if err != nil {
				return Result{
					Outcome: AmbiguousRuleset,
					Detail:  fmt.Sprintf("chain %s: %v", cur, err),
					Chain:   cur.name,
				}
			}
			for _, t := range targets {
				next := chainKey{cur.family, cur.table, t}
				if _, exists := chains[next]; !exists {
					// A jump to a chain that does not exist is a broken ruleset.
					// Never treat it as "nothing there, therefore fine".
					return Result{
						Outcome: AmbiguousRuleset,
						Detail:  fmt.Sprintf("chain %s jumps to missing chain %q", cur, t),
						Chain:   cur.name,
					}
				}
				if _, seen := reachedFrom[next]; seen {
					continue // cycle or diamond: already covered, traverse once
				}
				reachedFrom[next] = origin
				queue = append(queue, next)
			}
		}
	}

	// Now look for rules referencing the exact set, in the target family/table.
	found := false
	var lastChain string
	for k, rules := range rulesByChain {
		if k.family != family || k.table != table {
			continue
		}
		sawUnconditionalAccept := false
		for _, r := range rules {
			refs, err := referencesSet(r, setName)
			if err != nil {
				return Result{
					Outcome: AmbiguousRuleset,
					Detail:  fmt.Sprintf("chain %s: %v", k, err),
					Chain:   k.name,
				}
			}
			if !refs {
				if isUnconditionalAccept(r) {
					sawUnconditionalAccept = true
				}
				continue
			}
			found = true
			lastChain = k.name

			base, reachable := reachedFrom[k]
			if !reachable {
				continue // keep looking; another reference may be reachable
			}

			verdict, err := ruleVerdict(r)
			if err != nil {
				return Result{
					Outcome: AmbiguousRuleset,
					Detail:  fmt.Sprintf("chain %s references %s but its verdict is unrecognised: %v", k, setName, err),
					Chain:   k.name, BaseChain: base,
				}
			}
			if verdict != verdictEnforcing {
				continue // counter-only or accept: keep looking
			}
			if sawUnconditionalAccept {
				// The packet is accepted before it ever reaches this rule.
				continue
			}
			return Result{
				Outcome:   ReachableEnforcingPath,
				Detail:    fmt.Sprintf("set %s is referenced by an enforcing rule in chain %q, reachable from hooked chain %q", setName, k.name, base),
				Chain:     k.name,
				BaseChain: base,
			}
		}
	}

	switch {
	case !found:
		return Result{
			Outcome: NoSetReference,
			Detail:  fmt.Sprintf("no rule in %s %s references set %s", family, table, setName),
		}
	case len(reachedFrom) == 0:
		return Result{
			Outcome: SetReferenceUnreachable,
			Detail:  fmt.Sprintf("set %s is referenced in chain %q, but no base chain has an active hook", setName, lastChain),
			Chain:   lastChain,
		}
	default:
		// Referenced somewhere, but no reference was both reachable and enforcing.
		return Result{
			Outcome: ReachableNonEnforcingPath,
			Detail:  fmt.Sprintf("set %s is referenced in chain %q but no reachable reference reaches an enforcing verdict", setName, lastChain),
			Chain:   lastChain,
		}
	}
}

type verdictKind int

const (
	verdictNone verdictKind = iota
	verdictEnforcing
	verdictAccepting
)

// exprObject narrows one entry of NftRule.Expr to its object form.
// validator.NftRule.Expr is []interface{}, so expressions arrive already
// decoded — no second unmarshal, and no second decode type.
func exprObject(e interface{}) (map[string]interface{}, bool) {
	m, ok := e.(map[string]interface{})
	return m, ok
}

// jumpTargets returns the chains this rule transfers control to.
// An expression this evaluator does not recognise is NOT an error here: rules
// contain many expressions that cannot redirect control flow. Only a jump/goto
// whose target cannot be read is an error.
func jumpTargets(r *validator.NftRule) ([]string, error) {
	var out []string
	for _, e := range r.Expr {
		m, ok := exprObject(e)
		if !ok {
			continue
		}
		for _, key := range []string{"jump", "goto"} {
			raw, present := m[key]
			if !present {
				continue
			}
			obj, ok := exprObject(raw)
			if !ok {
				return nil, fmt.Errorf("%s expression has no readable target", key)
			}
			target, _ := obj["target"].(string)
			if target == "" {
				return nil, fmt.Errorf("%s expression has no readable target", key)
			}
			out = append(out, target)
		}
	}
	return out, nil
}

// referencesSet reports whether the rule references EXACTLY "@setName".
//
// Exact match is the point: "@blacklist_manual_ipv4_old" must not satisfy a
// query for "blacklist_manual_ipv4". Substring matching here would silently
// convert an unenforced ban into a claimed one.
func referencesSet(r *validator.NftRule, setName string) (bool, error) {
	want := "@" + setName
	var walk func(v interface{}) bool
	walk = func(v interface{}) bool {
		switch t := v.(type) {
		case string:
			return t == want
		case []interface{}:
			for _, it := range t {
				if walk(it) {
					return true
				}
			}
		case map[string]interface{}:
			for _, vv := range t {
				if walk(vv) {
					return true
				}
			}
		}
		return false // numbers, bools, null: cannot be a set reference
	}
	for _, e := range r.Expr {
		if walk(e) {
			return true, nil
		}
	}
	return false, nil
}

// ruleVerdict classifies the terminal verdict of a rule.
//
// A rule that references the target set but carries no verdict this evaluator
// recognises is an error, not a silent "non-enforcing" — the caller must fail
// closed rather than guess.
func ruleVerdict(r *validator.NftRule) (verdictKind, error) {
	kind := verdictNone
	for _, e := range r.Expr {
		m, ok := exprObject(e)
		if !ok {
			continue
		}
		for k := range m {
			switch k {
			case "drop", "reject":
				kind = verdictEnforcing
			case "accept", "return":
				if kind != verdictEnforcing {
					kind = verdictAccepting
				}
			case "counter", "match", "log", "limit", "jump", "goto", "meta", "payload", "ct", "set", "xt":
				// known, not a terminal verdict on its own
			default:
				return verdictNone, fmt.Errorf("unrecognised expression %q", k)
			}
		}
	}
	if kind == verdictNone {
		// Counter-only or match-only: real, and not enforcing.
		return verdictAccepting, nil
	}
	return kind, nil
}

// isUnconditionalAccept reports whether a rule accepts every packet reaching it,
// which shadows anything later in the same chain. Deliberately narrow: only a
// rule whose expressions are exactly accept (optionally with a counter) counts.
func isUnconditionalAccept(r *validator.NftRule) bool {
	sawAccept := false
	for _, e := range r.Expr {
		m, ok := exprObject(e)
		if !ok {
			return false
		}
		for k := range m {
			switch k {
			case "accept":
				sawAccept = true
			case "counter":
				// harmless
			default:
				return false // any match/condition means it is not unconditional
			}
		}
	}
	return sawAccept
}
