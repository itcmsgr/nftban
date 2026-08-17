// =============================================================================
// NFTBan v1.0 - Stats Cleanup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="stats_cleanup"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Retention enforcement for history, profile, and report files"
// meta:inventory.files="/var/lib/nftban/stats/"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Retention enforcement for history and profile files.
// Enforces BOTH retention days AND max count as HARD LIMITS.
// Resilient to clock changes and filename anomalies.
// =============================================================================

package stats

import (
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// CleanupHistory removes history files older than retention days.
// Also enforces a maximum file count to prevent unbounded growth.
func CleanupHistory(historyDir string, retentionDays int, maxCount int) error {
	if retentionDays < 1 {
		retentionDays = 1
	}
	if maxCount < 1 {
		maxCount = 10
	}

	files, err := os.ReadDir(historyDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // Directory doesn't exist yet
		}
		return err
	}

	// Filter to only .json files
	var jsonFiles []os.DirEntry
	for _, f := range files {
		if !f.IsDir() && strings.HasSuffix(f.Name(), ".json") {
			jsonFiles = append(jsonFiles, f)
		}
	}

	// Sort by name (date-based names sort chronologically)
	sort.Slice(jsonFiles, func(i, j int) bool {
		return jsonFiles[i].Name() < jsonFiles[j].Name()
	})

	cutoffTime := time.Now().AddDate(0, 0, -retentionDays)
	deleted := 0

	for i, f := range jsonFiles {
		filePath := filepath.Join(historyDir, f.Name())
		shouldDelete := false

		// Check if file is too old (by mod time, resilient to clock changes)
		info, err := f.Info()
		if err == nil && info.ModTime().Before(cutoffTime) {
			shouldDelete = true
		}

		// Also delete if we have too many files (keep newest maxCount)
		remaining := len(jsonFiles) - i
		if remaining > maxCount && !shouldDelete {
			// We have more than maxCount files remaining, delete older ones
			shouldDelete = true
		}

		if shouldDelete {
			if err := os.Remove(filePath); err != nil {
				log.Printf("stats: failed to remove old history file %s: %v", filePath, err)
			} else {
				deleted++
			}
		}
	}

	if deleted > 0 {
		log.Printf("stats: cleaned up %d old history files", deleted)
	}

	return nil
}

// CleanupProfiles removes profile files older than retention days.
// Also enforces maximum profile count as a HARD LIMIT.
func CleanupProfiles(profileDir string, retentionDays int, maxCount int) error {
	if retentionDays < 1 {
		retentionDays = 1
	}
	if maxCount < 1 {
		maxCount = 5
	}

	files, err := os.ReadDir(profileDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // Directory doesn't exist yet
		}
		return err
	}

	// Filter to only .pprof files
	var pprofFiles []os.DirEntry
	for _, f := range files {
		if !f.IsDir() && strings.HasSuffix(f.Name(), ".pprof") {
			pprofFiles = append(pprofFiles, f)
		}
	}

	// Sort by name (timestamp-based names sort chronologically)
	sort.Slice(pprofFiles, func(i, j int) bool {
		return pprofFiles[i].Name() < pprofFiles[j].Name()
	})

	cutoffTime := time.Now().AddDate(0, 0, -retentionDays)
	deleted := 0

	for i, f := range pprofFiles {
		filePath := filepath.Join(profileDir, f.Name())
		shouldDelete := false

		// Check if file is too old
		info, err := f.Info()
		if err == nil && info.ModTime().Before(cutoffTime) {
			shouldDelete = true
		}

		// Enforce max count (HARD LIMIT)
		remaining := len(pprofFiles) - i
		if remaining > maxCount {
			shouldDelete = true
		}

		if shouldDelete {
			if err := os.Remove(filePath); err != nil {
				log.Printf("stats: failed to remove old profile %s: %v", filePath, err)
			} else {
				deleted++
			}
		}
	}

	if deleted > 0 {
		log.Printf("stats: cleaned up %d old profile files", deleted)
	}

	return nil
}

// GetProfileCount returns the number of profile files in the directory
func GetProfileCount(profileDir string) int {
	files, err := os.ReadDir(profileDir)
	if err != nil {
		return 0
	}

	count := 0
	for _, f := range files {
		if !f.IsDir() && strings.HasSuffix(f.Name(), ".pprof") {
			count++
		}
	}
	return count
}

// CanCreateProfile checks if we can create a new profile without exceeding limits
func CanCreateProfile(profileDir string, maxCount int) bool {
	return GetProfileCount(profileDir) < maxCount
}

// CleanupReports was REMOVED in v1.229.3 (D-REPORTS-CLEANUP-STALE-AFTER-FHS-MOVE).
//
// Its subject was the daily operational report stream, which MOVED in v1.228.5:
//
//	before v1.228.5  /var/lib/nftban/reports/daily   <- this function's target
//	after  v1.228.5  /var/log/nftban/reports/daily   <- logrotate authority
//	                 (fhs-spec.yaml: artifact_class=log, retention_owner=logrotate;
//	                  logretention inventory key "reports-daily")
//
// The writer, the schema and the retention authority all moved; this
// implementation did not. It kept targeting the retired path, so os.ReadDir hit
// os.IsNotExist and it returned nil -- a permanent silent no-op. Wiring it into
// the collector (v1.229.3 P1-6B) therefore connected a function with no live
// subject, which is why the wiring was real but the coverage claim was not:
//
//	REACHABLE CLEANUP + RETENTION POLICY != EFFECTIVE RETENTION
//	    unless the target is the current writer-owned path.
//
// It is deliberately NOT retargeted at /var/lib/nftban/reports/* -- nothing
// establishes it as the canonical authority for baseline/watchdog/auditors/
// archive, and repurposing a stale implementation into a new retention authority
// is the defect class this release exists to remove. Those classes remain
// UNCLASSIFIED pending their own writer/lifecycle evidence.
