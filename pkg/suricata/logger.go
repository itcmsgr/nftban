package suricata

import (
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/itcmsgr/nftban-v1.0-dev/pkg/nftbanconf"
)

// EventLogger logs Suricata events and actions to file
type EventLogger struct {
	mu       sync.Mutex
	file     *os.File
	path     string
}

// NewEventLogger creates a new event logger
func NewEventLogger(logPath string) (*EventLogger, error) {
	// Get log directory from central config
	// NO FALLBACK - path must come from /etc/nftban/nftban.conf
	cfg := nftbanconf.MustLoad()
	logDir := cfg.LogDir

	// Ensure log directory exists
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create log directory: %w", err)
	}

	// Open log file (create if not exists, append mode)
	file, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return nil, fmt.Errorf("failed to open log file: %w", err)
	}

	return &EventLogger{
		file: file,
		path: logPath,
	}, nil
}

// Close closes the log file
func (l *EventLogger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.file != nil {
		return l.file.Close()
	}
	return nil
}

// LogEvent logs a Suricata event with calculated score
func (l *EventLogger) LogEvent(event *Event, score int, threshold int, action string, decision string) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	timestamp := event.Timestamp.Format("2006-01-02 15:04:05")

	// Format: 2025-11-29 12:00:00 [ACTION] IP=1.2.3.4 filter=ssh score=95/80 action=ban sig_id=2001219 msg="ET SCAN SSH BruteForce"
	logLine := fmt.Sprintf("%s [%-7s] IP=%-15s filter=%-10s score=%3d/%-3d action=%-7s sig_id=%d msg=\"%s\"\n",
		timestamp,
		decision,      // LOG, OBSERVE, BAN
		event.SrcIP,
		event.Filter,
		score,
		threshold,
		action,        // log, observe, ban
		event.SignatureID,
		event.Signature,
	)

	if _, err := l.file.WriteString(logLine); err != nil {
		return fmt.Errorf("failed to write log: %w", err)
	}

	// Force sync to disk
	return l.file.Sync()
}

// LogBanAction logs a Suricata-triggered ban action with score details
func (l *EventLogger) LogBanAction(ip string, filter string, score int, threshold int, banTime time.Duration, reason string) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	timestamp := time.Now().Format("2006-01-02 15:04:05")

	logLine := fmt.Sprintf("%s [BAN    ] IP=%-15s filter=%-10s score=%3d/%-3d ban_time=%-6s reason=\"%s\"\n",
		timestamp,
		ip,
		filter,
		score,
		threshold,
		formatDuration(banTime),
		reason,
	)

	if _, err := l.file.WriteString(logLine); err != nil {
		return fmt.Errorf("failed to write ban log: %w", err)
	}

	return l.file.Sync()
}

// LogError logs an error
func (l *EventLogger) LogError(context string, err error) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	timestamp := time.Now().Format("2006-01-02 15:04:05")

	logLine := fmt.Sprintf("%s [ERROR  ] %s: %v\n",
		timestamp,
		context,
		err,
	)

	if _, err := l.file.WriteString(logLine); err != nil {
		return fmt.Errorf("failed to write error log: %w", err)
	}

	return l.file.Sync()
}

// formatDuration formats duration for logging
func formatDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	} else if d < time.Hour {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	} else if d < 24*time.Hour {
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
	return fmt.Sprintf("%dd", int(d.Hours()/24))
}
