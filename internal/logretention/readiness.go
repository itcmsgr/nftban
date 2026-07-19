// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-readiness"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="DELTA-L1 post-generation policy-readiness invariant. After the install-time generation + fallback handling, an install may report COMMITTED ONLY if a VALID ACTIVE retention policy exists — either the generated policy (state hash matches the live file => READY_GENERATED) or a valid bounded fallback (file validates but no matching generated state => READY_FALLBACK). Anything else (missing / not-regular / empty / unreadable / wrong mode / logrotate -d invalid / unresolved activation journal / state present but hash-drifted) is NOT_READY and must drive the installer verdict to DEGRADED, never a false-clean COMMITTED. This is the derived-state OWNERSHIP boundary the static payload inventory used to (incorrectly) approximate: static payload verification -> generation/fallback -> POSTCONDITION verification (this) -> truthful install verdict. Pure + deterministic given an injected Validator; the installer assertion and the CLI both call Readiness()."
// meta:depends="crypto/sha256,encoding/json,os,syscall"
// meta:inventory.files="internal/logretention/readiness.go"
// meta:inventory.env_vars=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.binaries="logrotate"
// meta:inventory.config_files="/etc/logrotate.d/nftban,/var/lib/nftban/generated/logrotate/nftban-effective.state.json"
// meta:inventory.privileges="reads the generated policy + state (root in the install path)"
package logretention

import (
	"encoding/json"
	"os"
)

// ReadinessVerdict is the install-readiness classification of the active policy.
type ReadinessVerdict string

const (
	ReadyGenerated ReadinessVerdict = "READY_GENERATED" // generated policy active + state hash matches
	ReadyFallback  ReadinessVerdict = "READY_FALLBACK"  // valid bounded fallback active (self-heal pending)
	NotReady       ReadinessVerdict = "NOT_READY"       // no valid active policy — install must be DEGRADED
)

// ReadinessResult is the structured, durable outcome of the readiness check.
type ReadinessResult struct {
	Verdict          ReadinessVerdict `json:"verdict"`
	PolicySource     string           `json:"policy_source"` // "generated" | "fallback" | "none"
	PolicyPath       string           `json:"policy_path"`
	FileMode         string           `json:"file_mode"`
	FileBytes        int64            `json:"file_bytes"`
	ValidationResult string           `json:"validation_result"` // "valid" | error text | "not_run"
	Reason           string           `json:"reason,omitempty"`  // why NOT_READY
	JournalRecovered string           `json:"journal_recovered,omitempty"`
	Remediation      string           `json:"remediation,omitempty"`
	SelfHealPending  bool             `json:"self_heal_pending"` // true for READY_FALLBACK
}

// ReadinessOptions parameterizes the check (paths + injectable validator).
type ReadinessOptions struct {
	MainPath  string    // active generated policy (required)
	StatePath string    // generated-state record (may be absent -> fallback)
	Validator Validator // nil -> DefaultValidator (real logrotate -d)
}

const readinessRemediation = "run `nftban logs retention status`, then `nftban-core logretention generate install` (or restore the template), validate with `logrotate -d`, then rerun `nftban validate`"

// Readiness computes the post-generation policy-readiness verdict. It is the
// single authority both the CLI (`logretention readiness`) and the installer
// (`logretention_policy_ready` assertion) use, so their verdicts cannot diverge.
func Readiness(opts ReadinessOptions) ReadinessResult {
	r := ReadinessResult{PolicyPath: opts.MainPath, PolicySource: "none", ValidationResult: "not_run", Remediation: readinessRemediation}

	// 1. The active policy file must exist, be a regular readable non-empty file
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
	if f, e := os.Open(opts.MainPath); e != nil { // #nosec G304 -- generator-owned policy path
		r.Verdict, r.Reason = NotReady, "policy file unreadable: "+e.Error()
		return r
	} else {
		_ = f.Close()
	}
	if fi.Mode().Perm() != 0o644 {
		r.Verdict, r.Reason = NotReady, "policy file mode "+fi.Mode().Perm().String()+" != 0644"
		return r
	}

	// 2. No unresolved activation journal may remain — attempt deterministic
	//    recovery first, then require it to be resolved.
	if PendingActivation(opts.MainPath) {
		if res, rerr := Recover(opts.MainPath); rerr == nil {
			r.JournalRecovered = res.Action
		}
		if PendingActivation(opts.MainPath) {
			r.Verdict, r.Reason = NotReady, "unresolved activation journal (interrupted generation)"
			return r
		}
	}

	// 3. The active policy must validate with logrotate -d (isolated temp state).
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

	// 4. Source: a matching generated-state record => GENERATED; no state (fallback
	//    was used, which clears stale state) => FALLBACK; state present but the file
	//    hash DRIFTED from it => real drift => NOT_READY (never masquerade as ready).
	data, serr := os.ReadFile(opts.StatePath) // #nosec G304 -- generator-owned state path
	if serr != nil {
		r.Verdict, r.PolicySource, r.SelfHealPending = ReadyFallback, "fallback", true
		return r
	}
	var gs GeneratedState
	if json.Unmarshal(data, &gs) != nil {
		// State unparseable but the file itself is valid -> treat as fallback
		// (bounded valid policy active), self-heal pending.
		r.Verdict, r.PolicySource, r.SelfHealPending = ReadyFallback, "fallback", true
		return r
	}
	if hashFileOrEmpty(opts.MainPath) == gs.ActivePolicyHashes["nftban"] {
		r.Verdict, r.PolicySource = ReadyGenerated, "generated"
		return r
	}
	r.Verdict, r.Reason = NotReady, "active policy hash drifted from generated state"
	return r
}

// Ready reports whether the verdict allows a COMMITTED install (generated or
// valid fallback). Only NOT_READY blocks COMMITTED.
func (r ReadinessResult) Ready() bool {
	return r.Verdict == ReadyGenerated || r.Verdict == ReadyFallback
}
