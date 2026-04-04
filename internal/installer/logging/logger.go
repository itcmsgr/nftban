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
	"time"
)

// DefaultLogPath is the standard installer log location.
const DefaultLogPath = "/var/log/nftban/installer.log"

// Logger writes to both console and a persistent log file.
type Logger struct {
	console io.Writer
	logFile *os.File
	verbose bool
}

// New creates a Logger. logPath may be empty to use DefaultLogPath.
// If the log file cannot be opened, logging continues to console only.
func New(logPath string, verbose bool) *Logger {
	if logPath == "" {
		logPath = DefaultLogPath
	}

	l := &Logger{
		console: os.Stdout,
		verbose: verbose,
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

// Info logs an informational message to both console and file.
func (l *Logger) Info(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	ts := time.Now().Format("15:04:05")

	fmt.Fprintf(l.console, "[NFTBan] %s %s\n", ts, msg)
	l.writeFile("INFO", msg)
}

// Warn logs a warning to both console and file.
func (l *Logger) Warn(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	ts := time.Now().Format("15:04:05")

	fmt.Fprintf(l.console, "[NFTBan WARN] %s %s\n", ts, msg)
	l.writeFile("WARN", msg)
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

// Phase prints a phase separator banner.
func (l *Logger) Phase(name string) {
	sep := strings.Repeat("=", 60)
	l.Info("%s", sep)
	l.Info("Phase: %s", name)
	l.Info("%s", sep)
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
	fmt.Fprintf(l.logFile, "%s [%s] %s\n", ts, level, msg)
}
