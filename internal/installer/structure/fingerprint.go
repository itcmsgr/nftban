// =============================================================================
// NFTBan v1.233.x Lane B — STRUCTURE FINGERPRINT (nft-structure-v1)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-structure-fingerprint"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-23"
// meta:description="Durable semantic identity of the validated static enforcement structure. Canonicalises `nft -a list ruleset` by eliding ONLY demonstrably volatile kernel state (dynamic set element interiors, counter values, rule handles) and hashing everything else in order. Versioned by an explicit schema token so a future normalisation change cannot make an old digest silently uninterpretable."
// meta:inventory.files="internal/installer/structure/fingerprint.go"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root (nft list ruleset)"
// =============================================================================
package structure

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// ═════════════════════════════════════════════════════════════════════════════════
// WHAT THIS IS, AND WHAT IT IS NOT
// ═════════════════════════════════════════════════════════════════════════════════
// THE VALIDATOR PROVES CORRECTNESS. THE FINGERPRINT IDENTIFIES THE EXACT STRUCTURE
// THAT WAS PROVEN CORRECT.
//
// ⛔ A MATCHING FINGERPRINT IS NEVER A SHORTCUT AROUND THE SEMANTIC ASSERTIONS.
// It carries no verdict of its own. It answers only "which structure was certified",
// so that a durable lifecycle record means something after the tmpfs convergence
// counter has been reset by a reboot.
//
// ⛔ WHY IT IS NOT THE CONVERGENCE GENERATION. /run/nftban/convergence-generation is
// the authoritative generation concept, but its own contract
// (switchop/convergence.go: "tmpfs, so it resets at boot; only the BEFORE/AFTER DELTA
// within one run is read here, never the absolute value") explicitly refuses durable
// meaning to its absolute value. Persisting it as lifecycle truth would manufacture an
// authority the system declares it does not have. The two are COMPLEMENTARY:
//
//	convergence-generation  role: freshness / serialization witness   durable: NO
//	STRUCTURE_FINGERPRINT   role: durable semantic attribution        durable: YES

// SchemaV1 is the normalisation contract this package implements. It is PERSISTED
// ALONGSIDE the digest.
//
// ⛔ THE DIGEST ALONE IS NOT SELF-DESCRIBING. A digest is only comparable to another
// digest produced by the SAME canonicalisation. Storing the bare hash would make every
// historical record uninterpretable the moment the normalisation changes — the reader
// could not tell "the structure changed" from "the ruler changed". Any change to what
// is kept or elided below REQUIRES a new schema token, never an edit to this one.
const SchemaV1 = "nft-structure-v1"

// rulesetCommand is the observation. `-a` is used and handles are stripped, rather than
// relying on their absence: an explicit strip is robust to a future default change,
// whereas "we did not ask for handles" is an assumption about nft's output policy.
var rulesetCommand = []string{"nft", "-a", "list", "ruleset"}

// ─────────────────────────────────────────────────────────────────────────────────
// VOLATILE STATE — the ONLY things permitted to leave the hashed surface.
// ─────────────────────────────────────────────────────────────────────────────────
// ⛔ STRIP VALUES, NOT SEMANTIC TOKENS. `counter` is part of the emitted static rule
// and must remain visible in the surface; only its packet/byte counts are volatile.
// Deleting the expression itself would hide a real structural change (a rule losing
// its counter) behind a normalisation rule.
var (
	// ` # handle 42` — kernel-assigned, changes on every reload.
	reHandle = regexp.MustCompile(` # handle \d+$`)

	// `counter packets 5 bytes 300` (inline, in a rule) and the standalone
	// `packets 5 bytes 300` continuation line of a named counter object. Both keep
	// their shape; only the numbers are replaced.
	rePacketsBytes = regexp.MustCompile(`packets \d+ bytes \d+`)

	// `last used 3661 seconds ago` — the `last` statement's observed age.
	reLastUsed = regexp.MustCompile(`last used \d+ \w+ ago`)

	// `over 5 mbytes used 120 kbytes` — a quota's consumed portion.
	reQuotaUsed = regexp.MustCompile(`used \d+ \w*bytes`)

	// The opening of a dynamic/element block. Its INTERIOR is population, not
	// structure: ban-set members, connlimit `ct count over N` per-source entries,
	// meter/limit entries with `expires`, all of which churn continuously under live
	// traffic. The DECLARATION around it (type/flags/size/timeout) stays.
	reElementsOpen = regexp.MustCompile(`^\s*elements = \{`)
)

// structuralKeyword matches a line that can only be structure. Used as a TRIPWIRE on
// the elided region: if brace tracking ever mis-identifies where an element block ends,
// real structure would silently vanish from the surface. Rather than trust the depth
// arithmetic, assert that nothing structural was swallowed.
var structuralKeyword = regexp.MustCompile(`^\s*(table|chain|set|map|counter|quota|flowtable|ct helper|ct timeout|ct expectation)\s`)

// Result is a computed structure identity.
type Result struct {
	// Schema is the normalisation contract token. Persist it WITH Digest.
	Schema string
	// Digest is "sha256:<hex>" over the canonical form.
	Digest string
	// KeptLines / ElidedLines are forensic counters, not authority.
	KeptLines   int
	ElidedLines int
	// Canonical is the hashed text. Returned for diagnosis and for the negative
	// controls; it is NOT persisted into the lifecycle record.
	Canonical string
}

// Fingerprint observes the live ruleset and returns its structure identity.
//
// ⛔ IT REFUSES RATHER THAN GUESSES. Every refusal below is a case where continuing
// would produce a digest that is confidently wrong, which is worse than no digest:
// the reconciliation that consumes it would then certify a structure nobody measured.
func Fingerprint(exec executor.Executor) (Result, error) {
	res := exec.Run(rulesetCommand[0], rulesetCommand[1:]...)
	// ⛔ TIMEOUT IS ITS OWN VERDICT CLASS. A killed observation is not a failed one and
	// is certainly not an empty ruleset; it must never be differenced or hashed.
	if res.TimedOut {
		return Result{}, fmt.Errorf(
			"structure fingerprint: %q was KILLED by its deadline — the observation did not complete, "+
				"so no structure identity exists for this host",
			strings.Join(rulesetCommand, " "))
	}
	if res.ExitCode != 0 {
		return Result{}, fmt.Errorf(
			"structure fingerprint: %q exited %d — the ruleset could not be observed, so no "+
				"structure identity exists for this host (stderr: %s)",
			strings.Join(rulesetCommand, " "), res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	return FromRuleset(res.Stdout)
}

// FromRuleset is the pure canonicalisation core, separated so the contract can be
// tested against fixture rulesets without a kernel.
func FromRuleset(raw string) (Result, error) {
	if strings.TrimSpace(raw) == "" {
		return Result{}, fmt.Errorf(
			"structure fingerprint: the ruleset observation was EMPTY — an empty reading is an " +
				"absence of evidence, never a structure with no rules")
	}

	var (
		canonical []string
		elided    int
		depth     int
		openLine  int
	)

	lines := strings.Split(raw, "\n")
	for i, line := range lines {
		// ─── inside an element block: the interior is population, not structure ───
		if depth > 0 {
			// TRIPWIRE. If depth tracking has drifted, structure is being swallowed.
			if structuralKeyword.MatchString(line) {
				return Result{}, fmt.Errorf(
					"structure fingerprint: line %d (%q) is STRUCTURAL but was reached while eliding "+
						"the element block opened at line %d — brace tracking is unreliable against "+
						"this ruleset and the surface cannot be trusted",
					i+1, strings.TrimSpace(line), openLine)
			}
			depth += strings.Count(line, "{") - strings.Count(line, "}")
			elided++
			continue
		}

		// ─── normalise volatile values IN PLACE (shape kept, numbers dropped) ───
		out := reHandle.ReplaceAllString(line, "")
		out = rePacketsBytes.ReplaceAllString(out, "packets <v> bytes <v>")
		out = reLastUsed.ReplaceAllString(out, "last used <v>")
		out = reQuotaUsed.ReplaceAllString(out, "used <v>")

		// ─── enter an element block ───
		if reElementsOpen.MatchString(out) {
			d := strings.Count(out, "{") - strings.Count(out, "}")
			if d > 0 {
				depth = d
				openLine = i + 1
			}
			// ⛔ THE WHOLE BLOCK GOES, INCLUDING ITS OPENING LINE — no placeholder.
			// MEASURED on production srv4: nft omits the `elements = { … }` line
			// ENTIRELY for an empty set. A set that was empty at t0 and had members
			// 60s later therefore GAINS a line, and an earlier version of this
			// canonicaliser emitted a placeholder for it — making EMPTINESS
			// structural and shifting every subsequent line by one. Same multiset,
			// different order, different digest: it churned on live traffic.
			//
			// Population CAPABILITY is not lost by this: it is declared by `type`,
			// `flags dynamic`, `size` and `timeout`, all of which are KEPT above and
			// below. Only "does this set currently have members" is dropped, and that
			// is exactly the volatile state the fingerprint must not see.
			elided++
			continue
		}

		// ─── cosmetic normalisation only ───
		out = strings.TrimRight(out, " \t")
		if strings.TrimSpace(out) == "" {
			continue
		}
		canonical = append(canonical, out)
	}

	// ⛔ AN UNCLOSED ELEMENT BLOCK MEANS THE TAIL OF THE RULESET WAS ELIDED WHOLESALE.
	if depth != 0 {
		return Result{}, fmt.Errorf(
			"structure fingerprint: the element block opened at line %d never closed (depth %d at "+
				"end of input) — the remainder of the ruleset was elided, so the surface is incomplete",
			openLine, depth)
	}

	// ⛔ A RULESET WITH NO TABLE IS NOT A STRUCTURE.
	if !hasPrefixLine(canonical, "table ") {
		return Result{}, fmt.Errorf(
			"structure fingerprint: the canonical form contains no `table` declaration — this is not " +
				"a ruleset observation and must not be hashed into a durable identity")
	}

	body := strings.Join(canonical, "\n")
	// The schema token is hashed INTO the digest as well as stored beside it, so two
	// schemas can never collide on the same input.
	sum := sha256.Sum256([]byte(SchemaV1 + "\n" + body + "\n"))

	return Result{
		Schema:      SchemaV1,
		Digest:      "sha256:" + hex.EncodeToString(sum[:]),
		KeptLines:   len(canonical),
		ElidedLines: elided,
		Canonical:   body,
	}, nil
}

func hasPrefixLine(lines []string, prefix string) bool {
	for _, l := range lines {
		if strings.HasPrefix(strings.TrimSpace(l), prefix) {
			return true
		}
	}
	return false
}
