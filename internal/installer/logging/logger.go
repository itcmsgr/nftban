// =============================================================================
// NFTBan v1.73 - Installer Dual Logger
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-logger"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Dual console+file logger for installer output"
// meta:inventory.files="internal/installer/logging/logger.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/var/log/nftban/installer.log"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package logging

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// DefaultLogPath is the standard installer log location.
const DefaultLogPath = "/var/log/nftban/installer.log"

// Logger writes to both console and a persistent log file.
// The log file is append-only — every install/update/repair run is preserved
// as a contiguous block delimited by RunHeader/RunFooter for post-mortem analysis.
type Logger struct {
	console    io.Writer
	logFile    *os.File
	verbose    bool
	runStart   time.Time
	phaseStart time.Time
	logPath    string

	// v1.160 PR-A (warning truth-accounting): tally non-fatal warnings so the
	// final operator summary can report them honestly. Before v1.160, Warn()
	// only printed + appended to the logfile and incremented nothing, so the
	// COMMITTED summary said "no warnings" even when WARN lines were emitted
	// (e.g. systemd-tmpfiles exit 73, permissions enforce failed). The summary
	// COMMITTED/DEGRADED selection is decided by validate assertions, not by
	// warnings — so the count is the only honest source for the warning clause.
	//
	// Guarded by mu because Warn() is reachable from the SIGINT/SIGTERM signal
	// handler goroutine (main.go) concurrently with the main phase loop.
	mu        sync.Mutex
	warnCount int
	warnings  []string
}

// New creates a Logger. logPath may be empty to use DefaultLogPath.
// If the log file cannot be opened, logging continues to console only.
func New(logPath string, verbose bool) *Logger {
	if logPath == "" {
		logPath = DefaultLogPath
	}

	l := &Logger{
		console:  os.Stdout,
		verbose:  verbose,
		runStart: time.Now(),
		logPath:  logPath,
	}

	// Ensure parent directory exists
	if err := os.MkdirAll(filepath.Dir(logPath), 0750); err == nil {
		f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
		if err == nil {
			l.logFile = f
		}
	}

	return l
}

// Close flushes and closes the log file.
func (l *Logger) Close() {
	if l.logFile != nil {
		l.logFile.Close()
	}
}

// LogPath returns the path to the log file being written.
func (l *Logger) LogPath() string {
	return l.logPath
}

// FileWriter returns the open log-file handle as an io.Writer, or nil if no log
// file could be opened (console-only mode). v1.160 PR-B: the lifecycle bridge
// uses this to route structured lifecycle JSON to the same persistent installer
// log instead of the operator console. Returns the *os.File directly; writes to
// it are appended at the current file offset (the file is opened O_APPEND), so
// lifecycle JSON interleaves cleanly with the dual-logger's own file lines.
//
// Note: the returned handle is the same one Logger writes to; both write paths
// are line-oriented appends and the lifecycle logger emits whole-line JSON, so
// no additional locking is introduced here (the historical Logger file writes
// were already unsynchronized).
func (l *Logger) FileWriter() io.Writer {
	if l.logFile == nil {
		return nil
	}
	return l.logFile
}

// RunHeader writes a clear delimiter block marking the start of an installer run.
// This is essential for finding where a specific install/update begins in the log.
func (l *Logger) RunHeader(version, mode, hostname, osInfo string) {
	sep := strings.Repeat("=", 72)
	blank := ""
	l.writeFile("", blank)
	l.writeFile("", sep)
	l.writeFile("RUN", fmt.Sprintf("nftban-installer %s — %s", version, mode))
	l.writeFile("RUN", fmt.Sprintf("host=%s os=%s", hostname, osInfo))
	l.writeFile("RUN", fmt.Sprintf("started=%s pid=%d", l.runStart.Format(time.RFC3339), os.Getpid()))
	l.writeFile("", sep)
}

// RunFooter writes the closing delimiter with elapsed time and final state.
func (l *Logger) RunFooter(finalState string, exitCode int) {
	elapsed := time.Since(l.runStart)
	sep := strings.Repeat("-", 72)
	l.writeFile("", sep)
	l.writeFile("END", fmt.Sprintf("state=%s exit=%d elapsed=%s", finalState, exitCode, elapsed.Round(time.Millisecond)))
	l.writeFile("", sep)
}

// Info logs an informational message to both console and file.
func (l *Logger) Info(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	ts := time.Now().Format("15:04:05")

	fmt.Fprintf(l.console, "[NFTBan] %s %s\n", ts, msg)
	l.writeFile("INFO", msg)
}

// Warn logs a warning to both console and file. The warning is also tallied
// (count + captured message) so the final summary can report it honestly.
// Warnings remain NON-FATAL — printing/file-writing behavior is unchanged from
// before v1.160; only the accounting (v1.160 PR-A) is added.
func (l *Logger) Warn(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	ts := time.Now().Format("15:04:05")

	fmt.Fprintf(l.console, "[NFTBan WARN] %s %s\n", ts, msg)
	l.writeFile("WARN", msg)

	// v1.160 PR-A: tally the warning under the mutex (Warn is reachable from
	// the signal-handler goroutine).
	l.mu.Lock()
	l.warnCount++
	l.warnings = append(l.warnings, msg)
	l.mu.Unlock()
}

// WarnCount returns the number of non-fatal warnings emitted via Warn() so far.
// v1.160 PR-A: the final operator summary uses this to decide whether the
// COMMITTED line should mention warnings.
func (l *Logger) WarnCount() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.warnCount
}

// Warnings returns a copy of the warning messages emitted via Warn() so far.
// v1.160 PR-A: returns a copy so callers cannot mutate the logger's slice and
// so the read is consistent under the mutex.
func (l *Logger) Warnings() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]string, len(l.warnings))
	copy(out, l.warnings)
	return out
}

// ErrorLogOnly writes an error to the log file ONLY, NOT to console.
// Use when the operator-facing console output is handled by a different code
// path (e.g., V126.2 FAILED_AUTHORITY_ABORT operator-friendly block emitted
// by main.go report()) but the log file should still preserve the error for
// audit/diagnosis. This keeps the machine-readable log unchanged while letting
// the console show a calmer message.
//
// Scope: AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md (REV 4)
func (l *Logger) ErrorLogOnly(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	l.writeFile("ERROR", msg)
}

// Error logs an error to both console and file.
func (l *Logger) Error(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)

	fmt.Fprintf(l.console, "[NFTBan ERROR] %s\n", msg)
	l.writeFile("ERROR", msg)
}

// Debug logs a debug message to file always, and to console only if verbose.
func (l *Logger) Debug(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	l.writeFile("DEBUG", msg)

	if l.verbose {
		fmt.Fprintf(l.console, "[NFTBan] [debug] %s\n", msg)
	}
}

// Phase prints a phase separator banner and records the phase start time.
func (l *Logger) Phase(name string) {
	// Log elapsed time from previous phase if there was one
	if !l.phaseStart.IsZero() {
		elapsed := time.Since(l.phaseStart)
		l.writeFile("PHASE", fmt.Sprintf("previous phase completed in %s", elapsed.Round(time.Millisecond)))
	}
	l.phaseStart = time.Now()

	sep := strings.Repeat("=", 60)
	l.Info("%s", sep)
	l.Info("Phase: %s", name)
	l.Info("%s", sep)
}

// PhaseEnd records the elapsed time for the current phase. Called automatically
// by Phase() for the previous phase, but should also be called for the final phase.
func (l *Logger) PhaseEnd(name string) {
	if l.phaseStart.IsZero() {
		return
	}
	elapsed := time.Since(l.phaseStart)
	l.writeFile("PHASE", fmt.Sprintf("%s completed in %s", name, elapsed.Round(time.Millisecond)))
	l.phaseStart = time.Time{}
}

// CmdResult logs the result of a command execution. This captures every
// external command's exit code and stderr for root cause analysis.
// Only writes to file (not console) unless verbose or non-zero exit.
func (l *Logger) CmdResult(name string, exitCode int, stderr string) {
	stderr = strings.TrimSpace(stderr)
	if exitCode == 0 {
		l.writeFile("CMD", fmt.Sprintf("OK  %s (exit=0)", name))
		if stderr != "" && l.verbose {
			l.writeFile("CMD", fmt.Sprintf("    stderr: %s", truncate(stderr, 200)))
		}
	} else {
		msg := fmt.Sprintf("FAIL %s (exit=%d)", name, exitCode)
		if stderr != "" {
			msg += fmt.Sprintf(" stderr=%s", truncate(stderr, 300))
		}
		l.writeFile("CMD", msg)
		if l.verbose {
			fmt.Fprintf(l.console, "[NFTBan] [cmd] %s\n", msg)
		}
	}
}

// Detect logs a detection result (SSH, panel, conflicts, authority).
// These are the key facts needed for root cause analysis.
func (l *Logger) Detect(category, key, value string) {
	msg := fmt.Sprintf("[%s] %s=%s", category, key, value)
	l.writeFile("DETECT", msg)
	if l.verbose {
		ts := time.Now().Format("15:04:05")
		fmt.Fprintf(l.console, "[NFTBan] %s detect: %s\n", ts, msg)
	}
}

// StateChange logs a state machine transition to file.
func (l *Logger) StateChange(from, to, reason string) {
	msg := fmt.Sprintf("%s -> %s", from, to)
	if reason != "" {
		msg += fmt.Sprintf(" reason=%s", reason)
	}
	l.writeFile("STATE", msg)
}

// Result prints a final result line (no timestamp on console for cleaner output).
func (l *Logger) Result(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintf(l.console, "%s\n", msg)
	l.writeFile("RESULT", msg)
}

func (l *Logger) writeFile(level, msg string) {
	if l.logFile == nil {
		return
	}
	ts := time.Now().Format(time.RFC3339)
	if level == "" {
		// Bare line (separators, blank lines)
		fmt.Fprintf(l.logFile, "%s\n", msg)
	} else {
		fmt.Fprintf(l.logFile, "%s [%s] %s\n", ts, level, msg)
	}
}

// truncate limits a string to maxLen characters, appending "..." if truncated.
func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
