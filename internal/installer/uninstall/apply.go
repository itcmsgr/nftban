// =============================================================================
// NFTBan v1.100 PR-23 — Uninstall Mutation Phase 1 (Authority Release Core)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-uninstall-apply"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="Authority release core — PR-23 uninstall mutation orchestrator"
// meta:inventory.files="internal/installer/uninstall/apply.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-23 authorized scope (frozen 2026-04-20):
//
//   Allowed mutation:
//     - releasing nftban kernel authority (flush + delete ip/ip6 nftban tables)
//     - controlled teardown of nftban-owned service (stop + disable + mask)
//     - emergency SSH safety injection before mutation, removal after success
//     - v1.233.1 (owner GO 2026-09-26): deleting NFTBan's own SYNPROXY
//       notrack rules, by handle, from the foreign ip/ip6 raw prerouting
//       chains (comment-scoped; never the tables, chains or other rules)
//
//   NOT allowed (non-goals):
//     - external firewall restoration (PR-24)
//     - filesystem artifact deletion / purge semantics (PR-25)
//     - .conf.local touch — read or write
//     - cross-system cleanup (logrotate, timers beyond mask, user/group)
//     - any package-manager transactions
//
// This file is the ONLY mutation path in the uninstall package. Every
// other file in internal/installer/uninstall/ (authority.go, prior.go,
// plan.go) remains strictly read-only — the G3-UN-NO-MUTATION CI gate
// scopes its structural audit to exclude this file explicitly.
//
// Caller contract:
//   - Operator passed --confirm-mutation on the CLI (flags.go validates)
//   - Caller classified authority via Classify() and verified one of:
//       * Classify().State == AuthorityNFTBan
//       * Classify().State == AuthorityAmbiguous AND
//         Classify().Ambiguity == AmbiguityOrphanNFTBan
//     Any other pre-state must refuse BEFORE calling Apply.
//
// =============================================================================
package uninstall

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
)

// ApplyConfig is the input to Apply. Intentionally minimal — Apply is
// authority release core and should not grow consumer-specific knobs.
type ApplyConfig struct {
	// SSHPort is the port the emergency SSH safety table accepts on.
	// Must be > 0 and a valid TCP port.
	SSHPort int

	// Mode is the §4.4 artifact-removal policy. Default ModeRemove.
	// Added in v1.100.4 (UPSTREAM-UNINSTALL-INCOMPLETE-001) to wire
	// payload-symmetric artifact removal into the existing release
	// sequence.
	Mode Mode

	// Distro is passed through to RemoveArtifacts so the destination
	// catalog matches install-time staging (currently only polkit
	// branch differs by distro family).
	Distro *detect.DistroInfo
}

// ApplyResult is the output of Apply. Consumed by the dispatcher
// (cmd/nftban-installer/uninstall_apply.go) to transition the state
// file and set the process exit code.
type ApplyResult struct {
	// State is the terminal installer state the dispatcher should
	// persist via sf.Transition. Exactly one of:
	//   StateUninstallReleased     — full success
	//   StateUninstallFailedRelease — kernel mutation started but
	//                                 did not complete / validate
	//   StateDegraded              — kernel released but service
	//                                 teardown incomplete (authority
	//                                 released, state persists)
	//   StateFailedNoFirewall      — emergency SSH inject failed;
	//                                 no mutation was attempted
	State state.InstallState
	// Reason is the human-readable rationale for State. Placed in the
	// state file's FailureReason on failure, logged on success.
	Reason string
	// EmergencyInjected reports whether the emergency SSH table was
	// inserted during this run. True means the table was put in place;
	// for StateUninstallReleased it has been cleanly removed, for
	// failure states it MAY still be present as a safety net (leaving
	// it up is the deliberate failure-mode behaviour — an
	// over-permissive SSH rule is safer than a potential lockout).
	EmergencyInjected bool
	// Steps is an ordered audit trail of each mutation step attempted.
	// Used by the dispatcher for real-host evidence output + test
	// assertions.
	Steps []StepResult
}

// StepResult records the outcome of one Apply step.
type StepResult struct {
	Name    string
	Success bool
	Detail  string
}

// Apply runs the v1.100.4 authority release mutation sequence.
//
// The sequence is 12 explicit steps, executed in order:
//
//	 1. Inject emergency SSH safety table (inet nftban_install_emergency)
//	 2. Stop nftband.service (prevent it from fighting kernel mutation)
//	 3. Flush ip nftban table
//	 4. Flush ip6 nftban table (if present)
//	 5. Delete ip nftban table
//	 6. Delete ip6 nftban table (if present)
//	 7. Remove NFTBan's SYNPROXY notrack rules from the FOREIGN ip/ip6
//	    raw prerouting chains (v1.233.1 — comment-scoped by handle; the
//	    raw tables, chains and operator rules are never touched). See
//	    removeSynproxyRaw.
//	 8. Disable nftband.service
//	 9. Remove staged payload artifacts per cfg.Mode (v1.100.4 — closes
//	    UPSTREAM-UNINSTALL-INCOMPLETE-001). Walks payload.Destinations
//	    and rm -rf's installer-owned paths; mode gates operator-owned
//	    territory. ServiceUnmask("nftband.service") happens inside this
//	    step before unit-file rm.
//	10. Mask nftband.service ONLY if its unit file still exists (skipped
//	    when step 9 removed it — masking an absent unit creates a
//	    phantom /etc/systemd/system/nftband.service -> /dev/null
//	    symlink that fails the next reinstall with "Unit file is masked")
//	11. Validate end-state:
//	      - no ip nftban / ip6 nftban tables
//	      - nftband.service not active
//	      - emergency SSH table STILL PRESENT (step 12 removes it)
//	12. Remove emergency SSH table (warn-only on failure — leaving an
//	    over-permissive SSH rule in place is safer than lockout)
//
// Failure mapping:
//
//	Step 1 fails    → StateFailedNoFirewall (no kernel mutation; safe to retry)
//	Step 2 fail     → log warn, continue (stop-of-already-stopped is OK)
//	Steps 3-6 fail  → StateUninstallFailedRelease (kernel partial; emergency up)
//	Step 7 fail     → log warn, continue; the step is recorded Success=false
//	                  with NOT_OBSERVED / remaining=N in Detail (the nftban
//	                  authority is already released; a foreign-table residue
//	                  must be REPORTED, it must not abort the release)
//	Steps 8+10 fail → StateDegraded (kernel released; service lingers)
//	Step 9 fail     → log warn, continue (best-effort artifact removal;
//	                  end-state residue is the operator-visible signal)
//	Step 11 fail    → StateUninstallFailedRelease (end-state mismatch)
//	Step 12 fail    → log warn; State stays StateUninstallReleased (over-permissive safer than lockout)
//	All pass        → StateUninstallReleased
func Apply(exec executor.Executor, cfg *ApplyConfig, log *logging.Logger) *ApplyResult {
	r := &ApplyResult{}

	// Step 1 — emergency SSH safety net MUST land before any mutation.
	log.Info("uninstall apply: step 1/12 — injecting emergency SSH safety net (port %d)", cfg.SSHPort)
	if err := switchop.InjectEmergencySSH(exec, cfg.SSHPort, log); err != nil {
		r.Steps = append(r.Steps, StepResult{Name: "inject_emergency_ssh", Success: false, Detail: err.Error()})
		r.State = state.StateFailedNoFirewall
		r.Reason = fmt.Sprintf("inject emergency SSH failed: %v — no kernel mutation performed", err)
		log.Error("uninstall apply: step 1 FAILED; aborting before any mutation")
		return r
	}
	r.EmergencyInjected = true
	r.Steps = append(r.Steps, StepResult{Name: "inject_emergency_ssh", Success: true, Detail: "emergency SSH table injected (priority -1, policy accept)"})

	// Step 2 — stop the daemon so it can't fight the kernel mutation.
	// Stop-of-already-stopped returns success on most systemctl
	// implementations; a hard failure here is tolerated (logged) and
	// we push through because the subsequent flush+delete IS the
	// authority release, and the daemon without its kernel tables has
	// no firewall job to do.
	log.Info("uninstall apply: step 2/12 — stopping nftband.service")
	if err := exec.ServiceStop("nftband.service"); err != nil {
		log.Warn("stop nftband.service: %v (continuing; daemon may already be stopped)", err)
		r.Steps = append(r.Steps, StepResult{Name: "stop_nftband", Success: false, Detail: err.Error()})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "stop_nftband", Success: true})
	}

	// Step 3 — flush ip nftban.
	log.Info("uninstall apply: step 3/12 — flushing ip nftban table")
	if res := exec.Run("nft", "flush", "table", "ip", "nftban"); res.ExitCode != 0 {
		r.Steps = append(r.Steps, StepResult{Name: "flush_ip_nftban", Success: false, Detail: res.Stderr})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "flush ip nftban table failed: " + res.Stderr
		log.Error("uninstall apply: step 3 FAILED; emergency SSH still in place, operator must resolve")
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "flush_ip_nftban", Success: true})

	// Step 4 — flush ip6 nftban (may legitimately not exist).
	log.Info("uninstall apply: step 4/12 — flushing ip6 nftban table (if present)")
	if exec.NftTableExists("ip6", "nftban") {
		if res := exec.Run("nft", "flush", "table", "ip6", "nftban"); res.ExitCode != 0 {
			r.Steps = append(r.Steps, StepResult{Name: "flush_ip6_nftban", Success: false, Detail: res.Stderr})
			r.State = state.StateUninstallFailedRelease
			r.Reason = "flush ip6 nftban table failed: " + res.Stderr
			return r
		}
		r.Steps = append(r.Steps, StepResult{Name: "flush_ip6_nftban", Success: true})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "flush_ip6_nftban", Success: true, Detail: "skipped — no ip6 nftban table"})
	}

	// Step 5 — delete ip nftban.
	log.Info("uninstall apply: step 5/12 — deleting ip nftban table")
	if err := exec.NftDeleteTable("ip", "nftban"); err != nil {
		r.Steps = append(r.Steps, StepResult{Name: "delete_ip_nftban", Success: false, Detail: err.Error()})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "delete ip nftban table failed: " + err.Error()
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "delete_ip_nftban", Success: true})

	// Step 6 — delete ip6 nftban (may legitimately not exist).
	log.Info("uninstall apply: step 6/12 — deleting ip6 nftban table (if present)")
	if exec.NftTableExists("ip6", "nftban") {
		if err := exec.NftDeleteTable("ip6", "nftban"); err != nil {
			r.Steps = append(r.Steps, StepResult{Name: "delete_ip6_nftban", Success: false, Detail: err.Error()})
			r.State = state.StateUninstallFailedRelease
			r.Reason = "delete ip6 nftban table failed: " + err.Error()
			return r
		}
		r.Steps = append(r.Steps, StepResult{Name: "delete_ip6_nftban", Success: true})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "delete_ip6_nftban", Success: true, Detail: "skipped — no ip6 nftban table"})
	}

	// Step 7 — NFTBan SYNPROXY notrack rules in the FOREIGN raw tables.
	// Warn-only: the step result carries the truth (Success=false with
	// NOT_OBSERVED / remaining=N) and the release continues.
	sr := removeSynproxyRaw(exec, log)
	if !sr.Success {
		log.Warn("uninstall apply: step 7 incomplete — %s (continuing; nftban authority already released)", sr.Detail)
	}
	r.Steps = append(r.Steps, sr)

	// Step 8 — disable nftband.service.
	log.Info("uninstall apply: step 8/12 — disabling nftband.service")
	if err := exec.ServiceDisable("nftband.service"); err != nil {
		r.Steps = append(r.Steps, StepResult{Name: "disable_nftband", Success: false, Detail: err.Error()})
		// Kernel is released (steps 3-6 succeeded). Service teardown
		// incomplete → partial success → Degraded.
		r.State = state.StateDegraded
		r.Reason = "authority released but nftband.service disable failed: " + err.Error()
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "disable_nftband", Success: true})

	// Step 9 — remove staged payload artifacts per cfg.Mode. Best-effort:
	// failure here is logged but does not fail the release (kernel is
	// already down). Defaults to ModeRemove if cfg.Mode is the zero
	// value — symmetric with the operator default of `nftban-installer
	// --mode=uninstall --confirm-mutation` (no --purge).
	mode := cfg.Mode
	if mode == "" {
		mode = ModeRemove
	}
	log.Info("uninstall apply: step 9/12 — removing payload artifacts (mode=%s)", mode)
	rr := RemoveArtifacts(exec, mode, cfg.Distro, log)
	r.Steps = append(r.Steps, StepResult{
		Name:    "remove_artifacts",
		Success: true,
		Detail:  fmt.Sprintf("removed=%d preserved=%d failed=%d unit_removed=%t mode=%s", rr.Removed, rr.Preserved, rr.Failed, rr.UnitFileRemoved, mode),
	})

	// Step 10 — mask nftband.service ONLY if its unit file still exists.
	// Masking a removed unit recreates the /etc/systemd/system/nftband.service
	// -> /dev/null phantom symlink that triggers the
	// UPSTREAM-UNINSTALL-INCOMPLETE-001 reinstall failure.
	log.Info("uninstall apply: step 10/12 — masking nftband.service (if unit file remains)")
	if exec.FileExists("/usr/lib/systemd/system/nftband.service") {
		if err := exec.ServiceMask("nftband.service"); err != nil {
			r.Steps = append(r.Steps, StepResult{Name: "mask_nftband", Success: false, Detail: err.Error()})
			r.State = state.StateDegraded
			r.Reason = "authority released but nftband.service mask failed: " + err.Error()
			return r
		}
		r.Steps = append(r.Steps, StepResult{Name: "mask_nftband", Success: true})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "mask_nftband", Success: true, Detail: "skipped — unit file removed by step 9"})
	}

	// Step 11 — end-state validation. Proves the release claim directly
	// rather than trusting step return codes. Emergency SSH table must
	// STILL be present; step 12 removes it.
	log.Info("uninstall apply: step 11/12 — validating end-state")
	if exec.NftTableExists("ip", "nftban") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "ip nftban table still present after delete"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: ip nftban table still exists"
		return r
	}
	if exec.NftTableExists("ip6", "nftban") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "ip6 nftban table still present after delete"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: ip6 nftban table still exists"
		return r
	}
	if exec.ServiceActive("nftband.service") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "nftband.service still active after stop+disable+mask"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: nftband.service still active"
		return r
	}
	// Correction 2 locked 2026-04-20: validation MUST assert emergency
	// SSH is STILL PRESENT here. Step 12 is what removes it.
	if !exec.NftTableExists("inet", "nftban_install_emergency") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "emergency SSH table unexpectedly missing at step 11"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: emergency SSH table disappeared unexpectedly before step 12"
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: true, Detail: "nftban kernel + service released; emergency SSH still intact pending step 12"})

	// Step 12 — remove emergency SSH. Failure is warn-only: leaving an
	// over-permissive SSH rule in place is safer than risking lockout.
	// RemoveEmergencySSH logs its own warning internally if it fails.
	log.Info("uninstall apply: step 12/12 — removing emergency SSH safety net")
	switchop.RemoveEmergencySSH(exec, log)
	r.Steps = append(r.Steps, StepResult{Name: "remove_emergency_ssh", Success: true, Detail: "warn-only on failure per PR-23 safety policy"})

	// All 12 steps green — authority released.
	r.State = state.StateUninstallReleased
	r.Reason = "nftban authority released: kernel tables deleted, nftband.service stopped+disabled+masked, emergency SSH cleaned up"
	log.Result("[NFTBan] uninstall complete — nftban authority released")
	return r
}

// synproxyRawStepName is the Apply step that removes NFTBan's SYNPROXY
// notrack rules from the foreign raw tables.
const synproxyRawStepName = "remove_synproxy_raw"

// synproxyRawHandles returns the handles of NFTBan SYNPROXY rules in the
// prerouting chain of an `nft -a list table <family> raw` listing.
//
// The scope is the comment scope of _nft_cleanup_synproxy_raw
// (cli/lib/nftban/lib/nft_fragment.sh): a rule qualifies when, compared
// case-insensitively, it has `comment` followed by `"SYNPROXY:`. The handle is
// taken ONLY from the trailing `# handle N` that `nft -a` prints. Rules in any
// other chain are never returned. Semantic twin of the awk program in
// _nftban_uninstall_synproxy_raw (packaging/deb/postrm, RPM postun,
// uninstall.sh); the two are pinned against the same fixtures.
func synproxyRawHandles(listing string) []string {
	var out []string
	inChain := false
	for _, line := range strings.Split(listing, "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[0] == "chain" && f[1] == "prerouting" {
			inChain = true
			continue
		}
		if inChain && len(f) >= 1 && f[0] == "}" {
			inChain = false
			continue
		}
		if !inChain || !synproxyCommentRe.MatchString(strings.ToLower(line)) {
			continue
		}
		n := len(f)
		if n >= 3 && f[n-3] == "#" && f[n-2] == "handle" && digitsRe.MatchString(f[n-1]) {
			out = append(out, f[n-1])
		}
	}
	return out
}

var (
	synproxyCommentRe = regexp.MustCompile(`comment.*"synproxy:`)
	digitsRe          = regexp.MustCompile(`^[0-9]+$`)
)

// removeSynproxyRaw deletes NFTBan's SYNPROXY notrack rules from the FOREIGN
// tables ip/ip6 raw (chain prerouting), by handle, after a successful listing.
//
// v1.233.1 BUG-UNINSTALL-DOES-NOT-REMOVE-SYNPROXY-RAW-NOTRACK-RULES: these rules
// sit outside the nftban tables that steps 3-6 delete. Until v1.233.0 they were
// removed only as a side effect of the daemon Stop() re-running the DDoS
// reconcile; Stop() no longer does that.
//
// Authority is strictly NFTBan-owned: only rules carrying the SYNPROXY comment
// marker are deleted. The raw tables, their chains and every other rule are
// never touched (no flush, no table/chain delete).
//
// Observation discipline: `nft list tables` must succeed AND must show the
// emergency SSH table that step 1 installed (it is still present here; step 12
// removes it). A listing that does not show a table this run just created is
// not trusted, so an empty or foreign answer can never read as "no raw rules".
// Any failure to observe, any failed delete and any residue after the re-list
// yields Success=false with the reason in Detail. It never changes Apply's
// terminal state.
func removeSynproxyRaw(exec executor.Executor, log *logging.Logger) StepResult {
	log.Info("uninstall apply: step 7/12 — removing NFTBan SYNPROXY notrack rules from ip/ip6 raw prerouting (comment-scoped)")
	res := exec.Run("nft", "list", "tables")
	if res.ExitCode != 0 {
		return StepResult{Name: synproxyRawStepName, Success: false,
			Detail: fmt.Sprintf("NOT_OBSERVED: nft list tables rc=%d: %s", res.ExitCode, strings.TrimSpace(res.Stderr))}
	}
	tables := map[string]bool{}
	for _, line := range strings.Split(res.Stdout, "\n") {
		tables[strings.TrimSpace(line)] = true
	}
	if !tables["table inet nftban_install_emergency"] {
		return StepResult{Name: synproxyRawStepName, Success: false,
			Detail: "NOT_OBSERVED: nft list tables does not show the emergency SSH table installed by step 1; the table inventory is not trusted"}
	}

	ok := true
	var parts []string
	for _, fam := range []string{"ip", "ip6"} {
		if !tables["table "+fam+" raw"] {
			parts = append(parts, fam+": no raw table")
			continue
		}
		lr := exec.Run("nft", "-a", "list", "table", fam, "raw")
		if lr.ExitCode != 0 {
			ok = false
			parts = append(parts, fmt.Sprintf("%s: NOT_OBSERVED (nft -a list table %s raw rc=%d: %s)", fam, fam, lr.ExitCode, strings.TrimSpace(lr.Stderr)))
			continue
		}
		handles := synproxyRawHandles(lr.Stdout)
		if len(handles) == 0 {
			parts = append(parts, fam+": no NFTBan SYNPROXY rules")
			continue
		}
		removed, failed := 0, 0
		for _, h := range handles {
			if dr := exec.Run("nft", "delete", "rule", fam, "raw", "prerouting", "handle", h); dr.ExitCode != 0 {
				failed++
				log.Warn("could not delete NFTBan SYNPROXY rule (%s raw prerouting handle %s): %s", fam, h, strings.TrimSpace(dr.Stderr))
				continue
			}
			removed++
		}
		vr := exec.Run("nft", "-a", "list", "table", fam, "raw")
		if vr.ExitCode != 0 {
			ok = false
			parts = append(parts, fmt.Sprintf("%s: removed=%d failed=%d remaining=NOT_OBSERVED", fam, removed, failed))
			continue
		}
		left := len(synproxyRawHandles(vr.Stdout))
		if failed > 0 || left > 0 {
			ok = false
		}
		parts = append(parts, fmt.Sprintf("%s: removed=%d failed=%d remaining=%d", fam, removed, failed, left))
	}
	return StepResult{Name: synproxyRawStepName, Success: ok, Detail: strings.Join(parts, "; ")}
}
