// =============================================================================
// NFTBan v1.21.0 - HTTP Bot Guard: File Logger
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: File-based logging for classification decisions and verification events
//
// meta:name="botguard_logger"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="Structured file logger for HTTP Bot Guard events"
//
// Log files:
//   botguard.log    — Classification events, errors, module lifecycle
//   decisions.log   — Audit trail: every state transition with reason
//
// Format (pipe-delimited for grep/awk compatibility):
//   TIMESTAMP|IP|OLD_STATE|NEW_STATE|REASON|BOT_NAME|HIT_COUNT
//
// meta:inventory.files="logger.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Logger writes structured log entries for the bot guard module.
// Thread-safe: all writes are mutex-protected.
type Logger struct {
	mu            sync.Mutex
	mainFile      *os.File
	decisionsFile *os.File
	logDir        string
}

// NewLogger creates a new file logger for botguard.
// Creates the log directory if it doesn't exist.
func NewLogger(logDir string) (*Logger, error) {
	// Ensure log directory exists
	if err := os.MkdirAll(filepath.Clean(logDir), 0750); err != nil {
		return nil, fmt.Errorf("create botguard log dir %s: %w", logDir, err)
	}

	mainPath := filepath.Join(logDir, "botguard.log")
	mainFile, err := os.OpenFile(filepath.Clean(mainPath), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640) // #nosec G304 -- path from nftbanconf (trusted)
	if err != nil {
		return nil, fmt.Errorf("open botguard.log: %w", err)
	}

	decisionsPath := filepath.Join(logDir, "decisions.log")
	decisionsFile, err := os.OpenFile(filepath.Clean(decisionsPath), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0640) // #nosec G304 -- path from nftbanconf (trusted)
	if err != nil {
		mainFile.Close()
		return nil, fmt.Errorf("open decisions.log: %w", err)
	}

	return &Logger{
		mainFile:      mainFile,
		decisionsFile: decisionsFile,
		logDir:        logDir,
	}, nil
}

// Close closes both log files.
func (l *Logger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()

	var firstErr error
	if l.mainFile != nil {
		if err := l.mainFile.Close(); err != nil {
			firstErr = err
		}
	}
	if l.decisionsFile != nil {
		if err := l.decisionsFile.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// LogClassification logs a state transition to botguard.log.
// Format: TIMESTAMP|IP|OLD_STATE|NEW_STATE|REASON|BOT_NAME|HIT_COUNT
func (l *Logger) LogClassification(ip string, oldState, newState IPState, reason, botName string, hitCount int64) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.mainFile == nil {
		return
	}

	ts := time.Now().Format("2006-01-02 15:04:05")
	line := fmt.Sprintf("%s|%s|%s|%s|%s|%s|%d\n",
		ts, ip, oldState, newState, reason, botName, hitCount)

	_, _ = l.mainFile.WriteString(line)
	_ = l.mainFile.Sync()
}

// LogDecision logs a verification-based decision to decisions.log.
// Format: TIMESTAMP|IP|STATE|REASON|BOT_NAME|VERIFY_STATUS|HOSTNAME
func (l *Logger) LogDecision(ip string, state IPState, reason, botName string, verifyStatus VerifyStatus, hostname string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.decisionsFile == nil {
		return
	}

	ts := time.Now().Format("2006-01-02 15:04:05")
	line := fmt.Sprintf("%s|%s|%s|%s|%s|%s|%s\n",
		ts, ip, state, reason, botName, verifyStatus, hostname)

	_, _ = l.decisionsFile.WriteString(line)
	_ = l.decisionsFile.Sync()
}

// LogEvent logs a general event to botguard.log.
func (l *Logger) LogEvent(level, message string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.mainFile == nil {
		return
	}

	ts := time.Now().Format("2006-01-02 15:04:05")
	line := fmt.Sprintf("%s [%-7s] %s\n", ts, level, message)

	_, _ = l.mainFile.WriteString(line)
	_ = l.mainFile.Sync()
}

// LogError logs an error to botguard.log.
func (l *Logger) LogError(context string, err error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.mainFile == nil {
		return
	}

	ts := time.Now().Format("2006-01-02 15:04:05")
	line := fmt.Sprintf("%s [ERROR  ] %s: %v\n", ts, context, err)

	_, _ = l.mainFile.WriteString(line)
	_ = l.mainFile.Sync()
}
