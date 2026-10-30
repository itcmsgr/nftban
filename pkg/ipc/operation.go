// =============================================================================
// NFTBan - IPC operation result (execution state + effect)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ipc_operation"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="Two-part operation result shared by the daemon and its IPC clients (v1.236 plan §11.1)"
// meta:input=""
// meta:output=""
// meta:depends=""
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
//
// v1.236 plan §11.1 (owner correction 1, 2026-10-20): one operation result, defined
// once, with TWO parts. EXECUTION says whether the work ran to the end; EFFECT says
// what it changed. A request can complete with no effect (refused, exempt,
// unchanged), so a caller that counts or reports success follows the EFFECT, never
// the bare Success flag. Shared with the count audit
// (COUNT-MECH-REFUSED-OPERATION-REPORTED-AS-SUCCESS).
// =============================================================================

package ipc

// Execution is the first part of an operation result: did the work run to the end?
type Execution string

const (
	// ExecCompleted: the daemon finished the work; the Effect says what it changed.
	ExecCompleted Execution = "completed"
	// ExecRunning: the daemon confirms the work is still in progress. Join it by its
	// generation instead of submitting it again.
	ExecRunning Execution = "running"
	// ExecFailed: the daemon ran the work and it failed.
	ExecFailed Execution = "failed"
	// ExecUnknown: completion cannot be established (no answer, a daemon restart,
	// or a generation the daemon no longer holds). Never read as completed.
	ExecUnknown Execution = "unknown"
)

// Effect is the second part: what a completed operation changed.
type Effect string

const (
	// EffectApplied: the requested state was committed.
	EffectApplied Effect = "applied"
	// EffectUnchanged: the kernel already held the requested state; nothing written.
	EffectUnchanged Effect = "unchanged"
	// EffectPartial: some of the requested state was committed and some was not
	// (a component failed, was skipped under memory pressure, or did not converge).
	EffectPartial Effect = "partial"
	// EffectExempt: refused by the never-ban exemption authority.
	EffectExempt Effect = "exempt"
	// EffectRefused: refused before any write (no firewall authority).
	EffectRefused Effect = "refused"
)

// Response data keys carrying the result (Response.Data map).
const (
	KeyExecution  = "execution"
	KeyEffect     = "effect"
	KeyGeneration = "generation"
)

// Sync request parameters (method "sync").
const (
	// ParamQuick: skip feeds/geoban (unchanged meaning).
	ParamQuick = "quick"
	// ParamWaitSeconds: how long the daemon may hold the connection waiting for the
	// covering run. When it elapses the answer is ExecRunning + the generation.
	ParamWaitSeconds = "wait_seconds"
	// ParamJoin: a generation from an earlier answer. The daemon submits nothing and
	// reports (waiting up to ParamWaitSeconds) the run that covers that generation.
	ParamJoin = "join"
)

// ResultOf reads the two-part result from a response. A response without the keys
// (an older daemon) maps Success to completed/applied and a failure to failed, so
// an old daemon is never read as "running".
func ResultOf(resp *Response) (Execution, Effect, string) {
	if resp == nil {
		return ExecUnknown, "", ""
	}
	data, _ := resp.Data.(map[string]any)
	exec, _ := data[KeyExecution].(string)
	eff, _ := data[KeyEffect].(string)
	gen, _ := data[KeyGeneration].(string)
	if exec == "" {
		if resp.Success {
			return ExecCompleted, EffectApplied, gen
		}
		return ExecFailed, "", gen
	}
	return Execution(exec), Effect(eff), gen
}
