// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-readiness"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="DELTA-L1/L2/L3 post-generation policy-readiness invariant. After install-time generation + fallback handling, an install may report COMMITTED ONLY if a VALID ACTIVE policy exists: the generated set (every applicable target's live hash matches the generated-state transaction => READY_GENERATED) OR the APPROVED BOUNDED fallback (the active main policy is BYTE-IDENTICAL to the shipped template and bounded, with no generated-state claim => READY_FALLBACK). DELTA-L2: READY_FALLBACK is NOT syntax-only — it requires sha256(active)==sha256(shipped template) (the fallback is a verbatim template copy) AND unbounded_stanzas==0, so an arbitrary/unbounded/hand-edited valid policy can never masquerade as the fallback. DELTA-L3: READY_GENERATED covers the WHOLE generated set — when the state records a suricata policy (applicability = authoritative state key), the live /etc/logrotate.d/nftban-suricata must exist, validate, and hash-match state; a missing/drifted/stale suricata policy => NOT_READY. Single authority: the CLI, the installer assertion, and the acceptance collector all consume one Readiness() result. Pure + deterministic given an injected Validator."
// meta:depends="crypto/sha256,encoding/hex,encoding/json,os,strings"
// meta:inventory.files="internal/logretention/readiness.go"
// meta:inventory.env_vars=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.binaries="logrotate"
// meta:inventory.config_files="/etc/logrotate.d/nftban,/etc/logrotate.d/nftban-suricata,/etc/nftban/templates/nftban.logrotate,/var/lib/nftban/generated/logrotate/nftban-effective.state.json"
// meta:inventory.privileges="reads the generated policies + state + template (root in the install path)"
package logretention

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
)

// ReadinessVerdict is the install-readiness classification of the active policy.
type ReadinessVerdict string

const (
	ReadyGenerated ReadinessVerdict = "READY_GENERATED" // whole generated set matches state
	ReadyFallback  ReadinessVerdict = "READY_FALLBACK"  // active main == approved bounded template
	NotReady       ReadinessVerdict = "NOT_READY"       // no valid active policy — install must be DEGRADED
)

// ReadinessResult is the structured, durable outcome; every consumer (CLI,
// installer assertion, acceptance collector) reads these fields so no consumer
// re-implements a weaker check.
type ReadinessResult struct {
	Verdict          ReadinessVerdict `json:"verdict"`
	PolicySource     string           `json:"policy_source"` // "generated" | "fallback" | "none"
	PolicyPath       string           `json:"policy_path"`
	FileMode         string           `json:"file_mode"`
	FileBytes        int64            `json:"file_bytes"`
	ValidationResult string           `json:"validation_result"` // "valid" | error text | "not_run"

	// main policy
	ActiveMainHash   string `json:"active_main_hash"`
	ExpectedMainHash string `json:"expected_main_hash,omitempty"` // from state (generated) or template (fallback)
	MainHashMatch    bool   `json:"main_hash_match"`

	// DELTA-L2: fallback identity + boundedness
	FallbackIdentityMatch bool   `json:"fallback_identity_match"`
	FallbackTemplateHash  string `json:"fallback_template_hash,omitempty"`
	UnboundedStanzas      int    `json:"unbounded_stanzas"`

	// DELTA-L3: suricata generated policy (part of the generated set)
	SuricataApplicable bool   `json:"suricata_applicable"`
	ActiveSuricataHash string `json:"active_suricata_hash,omitempty"`
	ExpSuricataHash    string `json:"expected_suricata_hash,omitempty"`
	SuricataHashMatch  bool   `json:"suricata_hash_match"`

	JournalRecovered string `json:"journal_recovered,omitempty"`
	Reason           string `json:"reason,omitempty"`
	Remediation      string `json:"remediation,omitempty"`
	SelfHealPending  bool   `json:"self_heal_pending"` // true for READY_FALLBACK
}

// ReadinessOptions parameterizes the check (paths + injectable validator).
type ReadinessOptions struct {
	MainPath     string    // active generated main policy (required)
	SuricataPath string    // active generated suricata policy ("" if not installed)
	StatePath    string    // generated-state record (may be absent -> fallback)
	TemplatePath string    // shipped bounded fallback template (identity source for READY_FALLBACK)
	Validator    Validator // nil -> DefaultValidator (real logrotate -d)
}

const readinessRemediation = "run `nftban logs retention status`, then `nftban-core logretention generate install` (or restore the template), validate with `logrotate -d`, then rerun `nftban validate`"

func sha256Hex(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

// countUnboundedStanzas counts logrotate stanzas ({...} blocks) with NO `rotate`
// directive — an unbounded stanza defeats the disk-fill guarantee. NFTBan's
// generator and shipped template emit `rotate N` on every stanza, so a bounded
// policy has 0. Comments are stripped so a `#` before a brace/rotate cannot fool
// the count.
func countUnboundedStanzas(content string) int {
	n, depth, hasRotate := 0, 0, false
	for _, raw := range strings.Split(content, "\n") {
		line := raw
		if i := strings.Index(line, "#"); i >= 0 {
			line = line[:i]
		}
		if strings.Contains(line, "{") {
			depth, hasRotate = depth+1, false
			continue
		}
		if strings.Contains(line, "}") {
			if depth > 0 {
				if !hasRotate {
					n++
				}
				depth--
			}
			continue
		}
		if depth > 0 {
			for _, f := range strings.Fields(line) {
				if f == "rotate" {
					hasRotate = true
				}
			}
		}
	}
	return n
}

// Readiness computes the post-generation policy-readiness verdict — the single
// authority for the CLI, the installer assertion, and the acceptance collector.
func Readiness(opts ReadinessOptions) ReadinessResult {
	r := ReadinessResult{PolicyPath: opts.MainPath, PolicySource: "none", ValidationResult: "not_run", Remediation: readinessRemediation}

	// 1. The active main policy must exist, be a regular readable non-empty file
	//    with mode 0644 (what the generator + template fail-safe produce).
	fi, err := os.Stat(opts.MainPath)
	if err != nil {
		r.Verdict, r.Reason = NotReady, "policy file missing (generation and fallback both failed)"
		return r
	}
	r.FileMode = fi.Mode().Perm().String()
	r.FileBytes = fi.Size()
	if !fi.Mode().IsRegular() {
		r.Verdict, r.Reason = NotReady, "policy path is not a regular file"
		return r
	}
	if fi.Size() == 0 {
		r.Verdict, r.Reason = NotReady, "policy file is empty"
		return r
	}
	mainBytes, rerr := os.ReadFile(opts.MainPath) // #nosec G304 -- generator-owned policy path
	if rerr != nil {
		r.Verdict, r.Reason = NotReady, "policy file unreadable: "+rerr.Error()
		return r
	}
	if fi.Mode().Perm() != 0o644 {
		r.Verdict, r.Reason = NotReady, "policy file mode "+fi.Mode().Perm().String()+" != 0644"
		return r
	}
	r.ActiveMainHash = sha256Hex(mainBytes)
	r.UnboundedStanzas = countUnboundedStanzas(string(mainBytes))

	// 2. No unresolved activation journal may remain — recover first, then require
	//    resolution BEFORE any hash classification (hashes are meaningless over a
	//    half-activated set).
	if PendingActivation(opts.MainPath) {
		if res, recErr := Recover(opts.MainPath); recErr == nil {
			r.JournalRecovered = res.Action
			// the active bytes may have changed under recovery — re-read.
			if b, e := os.ReadFile(opts.MainPath); e == nil { // #nosec G304 -- generator-owned policy path
				mainBytes = b
				r.ActiveMainHash = sha256Hex(mainBytes)
				r.UnboundedStanzas = countUnboundedStanzas(string(mainBytes))
			}
		}
		if PendingActivation(opts.MainPath) {
			r.Verdict, r.Reason = NotReady, "unresolved activation journal (interrupted generation)"
			return r
		}
	}

	// 3. The active main policy must validate with logrotate -d (isolated temp state).
	validator := opts.Validator
	if validator == nil {
		validator = DefaultValidator
	}
	if _, verr := validator([]string{opts.MainPath}); verr != nil {
		r.ValidationResult = verr.Error()
		r.Verdict, r.Reason = NotReady, "active policy failed logrotate validation"
		return r
	}
	r.ValidationResult = "valid"

	// 4. Classify by source.
	data, serr := os.ReadFile(opts.StatePath) // #nosec G304 -- generator-owned state path
	var gs GeneratedState
	haveState := serr == nil && json.Unmarshal(data, &gs) == nil && len(gs.ActivePolicyHashes) > 0
	if !haveState {
		return r.classifyFallback(opts)
	}
	return r.classifyGenerated(opts, gs)
}

// classifyGenerated (DELTA-L3): READY_GENERATED requires EVERY applicable
// generated target to match the same state transaction — main always, and
// suricata when the state records it.
func (r ReadinessResult) classifyGenerated(opts ReadinessOptions, gs GeneratedState) ReadinessResult {
	r.PolicySource = "generated"
	r.ExpectedMainHash = gs.ActivePolicyHashes["nftban"]
	r.MainHashMatch = r.ActiveMainHash == r.ExpectedMainHash
	if !r.MainHashMatch {
		r.Verdict, r.Reason = NotReady, "active main policy hash drifted from generated state"
		return r
	}

	suriExpected, suriRecorded := gs.ActivePolicyHashes["nftban-suricata"]
	suriFileExists := false
	if opts.SuricataPath != "" {
		if _, e := os.Stat(opts.SuricataPath); e == nil {
			suriFileExists = true
		}
	}
	// Applicability = the state recorded a suricata policy (authoritative — it is
	// exactly what the generation transaction produced).
	r.SuricataApplicable = suriRecorded
	switch {
	case suriRecorded:
		r.ExpSuricataHash = suriExpected
		if opts.SuricataPath == "" || !suriFileExists {
			r.Verdict, r.Reason = NotReady, "generated state records a suricata policy but /etc/logrotate.d/nftban-suricata is missing"
			return r
		}
		fi, err := os.Stat(opts.SuricataPath)
		if err != nil || !fi.Mode().IsRegular() || fi.Size() == 0 {
			r.Verdict, r.Reason = NotReady, "suricata policy not a valid regular non-empty file"
			return r
		}
		if fi.Mode().Perm() != 0o644 {
			r.Verdict, r.Reason = NotReady, "suricata policy mode "+fi.Mode().Perm().String()+" != 0644"
			return r
		}
		validator := opts.Validator
		if validator == nil {
			validator = DefaultValidator
		}
		if _, verr := validator([]string{opts.SuricataPath}); verr != nil {
			r.Verdict, r.Reason = NotReady, "suricata policy failed logrotate validation"
			return r
		}
		sb, _ := os.ReadFile(opts.SuricataPath) // #nosec G304 -- generator-owned policy path
		r.ActiveSuricataHash = sha256Hex(sb)
		r.SuricataHashMatch = r.ActiveSuricataHash == suriExpected
		if !r.SuricataHashMatch {
			r.Verdict, r.Reason = NotReady, "active suricata policy hash drifted from generated state"
			return r
		}
	case suriFileExists:
		// State did NOT generate a suricata policy but a live suricata policy file
		// exists — a stale/unmanaged policy. Do not silently ignore it.
		r.Verdict, r.Reason = NotReady, "stale suricata policy present but not part of the generated state"
		return r
	}
	r.Verdict = ReadyGenerated
	return r
}

// classifyFallback (DELTA-L2): READY_FALLBACK requires the active main policy be
// BYTE-IDENTICAL to the approved shipped template (the fallback is a verbatim
// copy) AND bounded. A valid-syntax-but-not-the-template policy is NOT the
// approved fallback -> NOT_READY.
func (r ReadinessResult) classifyFallback(opts ReadinessOptions) ReadinessResult {
	r.PolicySource = "fallback"
	if opts.TemplatePath == "" {
		r.Verdict, r.Reason = NotReady, "no generated state and no fallback template path to verify identity"
		return r
	}
	tb, terr := os.ReadFile(opts.TemplatePath) // #nosec G304 -- packaged template path
	if terr != nil {
		r.Verdict, r.Reason = NotReady, "fallback template missing/unreadable: "+terr.Error()
		return r
	}
	if len(tb) == 0 {
		r.Verdict, r.Reason = NotReady, "fallback template is empty (malformed)"
		return r
	}
	r.FallbackTemplateHash = sha256Hex(tb)
	r.ExpectedMainHash = r.FallbackTemplateHash
	r.FallbackIdentityMatch = r.ActiveMainHash == r.FallbackTemplateHash
	r.MainHashMatch = r.FallbackIdentityMatch
	if !r.FallbackIdentityMatch {
		r.Verdict, r.Reason = NotReady, "FALLBACK_IDENTITY_MISMATCH: active policy is valid but is not the approved shipped bounded template"
		return r
	}
	if r.UnboundedStanzas != 0 {
		r.Verdict, r.Reason = NotReady, "fallback template contains unbounded stanzas"
		return r
	}
	r.Verdict, r.SelfHealPending = ReadyFallback, true
	return r
}

// Ready reports whether the verdict allows a COMMITTED install (generated or a
// verified bounded fallback). Only NOT_READY blocks COMMITTED.
func (r ReadinessResult) Ready() bool {
	return r.Verdict == ReadyGenerated || r.Verdict == ReadyFallback
}
