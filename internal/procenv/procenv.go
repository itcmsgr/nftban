// =============================================================================
// NFTBan - procenv - child process environment sanitization
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="procenv"
// meta:type="internal"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Sanitized environment for spawned child processes: strips systemd sd_notify/watchdog variables from children that do not participate in the daemon's systemd notification contract"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NOTIFY_SOCKET, WATCHDOG_USEC, WATCHDOG_PID"
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Under systemd Type=notify, the daemon inherits NOTIFY_SOCKET (and WATCHDOG_USEC/
// WATCHDOG_PID). Go's exec.Command inherits the FULL parent environment by default
// (cmd.Env == nil), so every helper the daemon spawns also inherits these. Only the
// main daemon process legitimately participates in the notification contract
// (NotifyAccess=main), so a child that touches the inherited NOTIFY_SOCKET produces
// spurious "notification from PID … reception only permitted for main PID" warnings.
//
// SanitizedSystemdEnv returns the parent environment with exactly those three
// variables removed, so spawned helpers cannot emit notifications on the daemon's
// behalf. It is deliberately narrow: everything else is preserved, and it never
// unsets the variables in the daemon's own process (the main process still needs
// them for READY=1 and the watchdog heartbeat).
// =============================================================================

package procenv

import (
	"context"
	"os"
	"os/exec"
	"strings"
)

// systemdNotifyVars are the environment variables that only the main daemon
// process should carry. Children that are not systemd-notify-aware must not
// inherit them.
var systemdNotifyVars = []string{
	"NOTIFY_SOCKET",
	"WATCHDOG_USEC",
	"WATCHDOG_PID",
}

// SanitizedSystemdEnv returns a copy of the current process environment with the
// systemd notification variables removed. Assign the result to exec.Cmd.Env for
// child processes that do not participate in the daemon's systemd notification
// contract. The returned slice is safe to mutate by the caller.
func SanitizedSystemdEnv() []string {
	return StripSystemdVars(os.Environ())
}

// StripSystemdVars returns a NEW slice: a copy of env with exactly the three
// systemd notification variables removed. Exposed separately so it can be
// unit-tested without touching the real process environment.
//
// Contract:
//   - the input slice is never mutated (a fresh slice is returned);
//   - only exact-name matches of NOTIFY_SOCKET / WATCHDOG_USEC / WATCHDOG_PID are
//     removed — a variable that merely contains the substring is preserved;
//   - EVERY occurrence of a blocked key is removed (duplicate keys handled);
//   - every other entry passes through verbatim and in order, including any
//     malformed entry that lacks '=' (we do not editorialize non-target entries;
//     os.Environ never produces such entries, so this is a defensive guarantee).
func StripSystemdVars(env []string) []string {
	out := make([]string, 0, len(env))
	for _, kv := range env {
		if isSystemdNotifyVar(kv) {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// Command wraps exec.Command and pre-sets a sanitized environment (systemd notify
// variables stripped). Use it for daemon-spawned helpers that do not participate
// in the systemd notification contract, so they cannot emit notifications on the
// daemon's behalf. Everything else in the environment is preserved.
//
// Security boundary: this is a thin, general-purpose wrapper — it introduces no
// command/argument itself and adds no injection surface beyond stdlib exec.Command.
// The command name and args come entirely from the caller; every caller in this
// repo passes a static/validated command (the callers previously carried the
// per-site `#nosec G204 -- trusted constants` annotations). Input-safety therefore
// lives at the call sites, identical to using exec.Command directly. The Semgrep
// dangerous-exec-command finding on the pass-through below is a wrapper false
// positive (gosec G204 does not flag it); suppressed with justification.
func Command(name string, arg ...string) *exec.Cmd {
	// nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	c := exec.Command(name, arg...) // #nosec G204 -- trusted caller-supplied command; wrapper adds no injection surface
	c.Env = SanitizedSystemdEnv()
	return c
}

// CommandContext is the context-aware counterpart of Command. Same security
// boundary as Command: input-safety lives at the call sites.
func CommandContext(ctx context.Context, name string, arg ...string) *exec.Cmd {
	// nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	c := exec.CommandContext(ctx, name, arg...) // #nosec G204 -- trusted caller-supplied command; wrapper adds no injection surface
	c.Env = SanitizedSystemdEnv()
	return c
}

func isSystemdNotifyVar(kv string) bool {
	eq := strings.IndexByte(kv, '=')
	if eq < 0 {
		return false
	}
	name := kv[:eq]
	for _, v := range systemdNotifyVars {
		if name == v {
			return true
		}
	}
	return false
}
