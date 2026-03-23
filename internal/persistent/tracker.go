// =============================================================================
// NFTBan v1.0 - Persistent Offender Tracker
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="tracker"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Tracks persistent offenders from ban log entries"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package persistent

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

// BanEntry represents a ban logged in bans.log (v1.0: removed fail2ban prefix)
type BanEntry struct {
	Timestamp time.Time
	IP        string
	Jail      string
	Reason    string
}

// LogTempBan logs a temporary ban to the tracking file for escalation tracking
// This tracks temp bans to detect persistent offenders who should be escalated
func LogTempBan(logPath, ip, jail, reason string) error {
	// TOCTOU-safe file open with O_NOFOLLOW
	f, err := safety.SafeOpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open ban log: %w", err)
	}
	defer f.Close()

	timestamp := time.Now().Format(time.RFC3339)
	logLine := fmt.Sprintf("%s %s %s %s\n", timestamp, ip, jail, reason)

	if _, err := f.WriteString(logLine); err != nil {
		return fmt.Errorf("failed to write to ban log: %w", err)
	}

	return nil
}

// CountRecentBans counts how many times an IP was banned in the given period
func CountRecentBans(logPath, ip string, period time.Duration) (int, error) {
	f, err := os.Open(logPath)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil // Log doesn't exist yet = 0 bans
		}
		return 0, fmt.Errorf("failed to open ban log: %w", err)
	}
	defer f.Close()

	cutoff := time.Now().Add(-period)
	count := 0

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		entry, err := parseBanEntry(line)
		if err != nil {
			continue // Skip malformed lines
		}

		// Count only bans for this IP after the cutoff time
		if entry.IP == ip && entry.Timestamp.After(cutoff) {
			count++
		}
	}

	if err := scanner.Err(); err != nil {
		return 0, fmt.Errorf("failed to read ban log: %w", err)
	}

	return count, nil
}

// parseBanEntry parses a log line into a BanEntry
// Format: "2025-11-27T10:00:00Z 1.2.3.4 nftban-sshd SSH brute force"
func parseBanEntry(line string) (*BanEntry, error) {
	parts := strings.Fields(line)
	if len(parts) < 3 {
		return nil, fmt.Errorf("invalid log line: %s", line)
	}

	timestamp, err := time.Parse(time.RFC3339, parts[0])
	if err != nil {
		return nil, fmt.Errorf("invalid timestamp: %w", err)
	}

	reason := ""
	if len(parts) > 3 {
		reason = strings.Join(parts[3:], " ")
	}

	return &BanEntry{
		Timestamp: timestamp,
		IP:        parts[1],
		Jail:      parts[2],
		Reason:    reason,
	}, nil
}

// AddToPersistentOffenders adds an IP to the persistent offenders config file
func AddToPersistentOffenders(confPath, ip, reason string) error {
	// Check if already in file
	exists, err := isInFile(confPath, ip)
	if err != nil {
		return err
	}
	if exists {
		return nil // Already persistent
	}

	// Append to file (TOCTOU-safe)
	f, err := safety.SafeOpenFile(confPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open persistent offenders file: %w", err)
	}
	defer f.Close()

	line := fmt.Sprintf("%s  # persistent offender: %s\n", ip, reason)
	if _, err := f.WriteString(line); err != nil {
		return fmt.Errorf("failed to write to persistent offenders file: %w", err)
	}

	return nil
}

// LogPersistentOffender logs to persistent-offenders.log
func LogPersistentOffender(logPath, ip, jail string, banCount int) error {
	// TOCTOU-safe file open
	f, err := safety.SafeOpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("failed to open offenders log: %w", err)
	}
	defer f.Close()

	timestamp := time.Now().Format(time.RFC3339)
	logLine := fmt.Sprintf("%s %s %s %d bans - escalated to permanent\n",
		timestamp, ip, jail, banCount)

	if _, err := f.WriteString(logLine); err != nil {
		return fmt.Errorf("failed to write to offenders log: %w", err)
	}

	return nil
}

// isInFile checks if an IP already exists in a file
func isInFile(path, ip string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Extract IP (first field)
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == ip {
			return true, nil
		}
	}

	return false, scanner.Err()
}
