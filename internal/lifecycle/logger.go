// =============================================================================
// NFTBan v1.97 - Lifecycle Evidence Logger
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-logger"
// meta:type="lib"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Structured lifecycle event logging for detect/plan/result"
// meta:inventory.files="internal/lifecycle/logger.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V197_LIFECYCLE_CONTRACT.md §6 PR-06
// Logs describe PLANNING, not execution. No misleading "success" claims
// if only planning happened (INV-LC-001).
// =============================================================================

package lifecycle

import (
	"encoding/json"
	"fmt"
	"io"
	"time"
)

// EventType classifies lifecycle log events.
type EventType string

const (
	EventDetect EventType = "detect"
	EventPlan   EventType = "plan"
	EventResult EventType = "result"
)

// LogEvent is a structured lifecycle log entry.
type LogEvent struct {
	Timestamp time.Time `json:"timestamp"`
	Event     EventType `json:"event"`
	Mode      Mode      `json:"mode"`
	DryRun    bool      `json:"dry_run"`
	Data      any       `json:"data"`
}

// Logger writes structured lifecycle events.
type Logger struct {
	w    io.Writer
	mode Mode
	dry  bool
}

// NewLogger creates a lifecycle logger.
func NewLogger(w io.Writer, mode Mode, dryRun bool) *Logger {
	return &Logger{w: w, mode: mode, dry: dryRun}
}

// LogDetect records the DETECT stage observations.
func (l *Logger) LogDetect(authority AuthorityState, detection Detection) {
	l.emit(EventDetect, map[string]any{
		"authority": map[string]string{
			"owner":  string(authority.Owner),
			"health": string(authority.Health),
		},
		"detection": detection,
	})
}

// LogPlan records the PLAN stage decisions.
func (l *Logger) LogPlan(plan Plan, lastOp LastOperation) {
	actions := make([]string, len(plan.Actions))
	for i, a := range plan.Actions {
		actions[i] = string(a)
	}
	l.emit(EventPlan, map[string]any{
		"actions":        actions,
		"warnings":       plan.Warnings,
		"errors":         plan.Errors,
		"last_operation": lastOp,
	})
}

// LogResult records the final lifecycle outcome.
// Explicitly marks whether this was a plan-only or real execution.
func (l *Logger) LogResult(result RunResult) {
	label := "plan_completed"
	if !l.dry {
		label = "execution_completed"
	}
	l.emit(EventResult, map[string]any{
		"label":   label,
		"outcome": string(result.Outcome),
		"stage":   string(result.Stage),
		"authority_resulting": map[string]string{
			"owner":  string(result.Authority.Resulting.Owner),
			"health": string(result.Authority.Resulting.Health),
		},
	})
}

func (l *Logger) emit(event EventType, data any) {
	entry := LogEvent{
		Timestamp: time.Now(),
		Event:     event,
		Mode:      l.mode,
		DryRun:    l.dry,
		Data:      data,
	}

	out, err := json.Marshal(entry)
	if err != nil {
		fmt.Fprintf(l.w, `{"event":"%s","error":"marshal failed: %v"}`+"\n", event, err)
		return
	}

	l.w.Write(out)    //nolint:errcheck
	l.w.Write([]byte("\n")) //nolint:errcheck
}
