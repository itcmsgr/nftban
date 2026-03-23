// =============================================================================
// NFTBan v1.5.0 - Report Generator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="report_generator"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-25"
// meta:description="Generates daily reports from stats history"
// meta:inventory.files="/var/lib/nftban/reports/"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package reports

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// Config holds report generator configuration
type Config struct {
	ReportsDir    string // Output directory for reports
	HistoryDir    string // Input: stats history directory
	BansLogPath   string // Input: bans.log path
	RetentionDays int    // Days to keep reports
	TopN          int    // Number of items in top lists (default 10)
}

// DefaultConfig returns default configuration
func DefaultConfig() *Config {
	return &Config{
		ReportsDir:    "/var/lib/nftban/reports",
		HistoryDir:    "/var/lib/nftban/stats/history",
		BansLogPath:   "/var/log/nftban/bans.log",
		RetentionDays: 14,
		TopN:          10,
	}
}

// Generator creates daily reports
type Generator struct {
	config *Config
}

// NewGenerator creates a new report generator
func NewGenerator(config *Config) *Generator {
	if config == nil {
		config = DefaultConfig()
	}
	return &Generator{config: config}
}

// GenerateDaily generates summary and top reports for a specific date
func (g *Generator) GenerateDaily(date string) error {
	// Ensure output directories exist
	dailyDir := filepath.Join(g.config.ReportsDir, "daily")
	if err := os.MkdirAll(dailyDir, 0755); err != nil {
		return fmt.Errorf("create reports dir: %w", err)
	}

	// Generate summary
	summary, err := g.generateSummary(date)
	if err != nil {
		return fmt.Errorf("generate summary: %w", err)
	}

	// Generate top lists
	top, err := g.generateTop(date)
	if err != nil {
		return fmt.Errorf("generate top: %w", err)
	}

	// Write reports atomically
	summaryPath := filepath.Join(dailyDir, date+".summary.json")
	if err := writeJSONAtomic(summaryPath, summary); err != nil {
		return fmt.Errorf("write summary: %w", err)
	}

	topPath := filepath.Join(dailyDir, date+".top.json")
	if err := writeJSONAtomic(topPath, top); err != nil {
		return fmt.Errorf("write top: %w", err)
	}

	// Append to index
	if err := g.appendIndex(summary, top); err != nil {
		return fmt.Errorf("append index: %w", err)
	}

	return nil
}

// generateSummary creates a DailySummary from history data
func (g *Generator) generateSummary(date string) (*DailySummary, error) {
	hostname, _ := os.Hostname()

	summary := &DailySummary{
		Date:          date,
		Host:          hostname,
		GeneratedAt:   time.Now().UTC(),
		BansBySource:  make(map[string]int),
		BansByCountry: make(map[string]int),
		Feeds:         make(map[string]FeedState),
	}

	// Try to read existing history file for the date
	historyPath := filepath.Join(g.config.HistoryDir, date+".json")
	if data, err := os.ReadFile(historyPath); err == nil {
		var history map[string]interface{}
		if json.Unmarshal(data, &history) == nil {
			// Extract values from history
			if bans, ok := history["total_bans"].(float64); ok {
				summary.Totals.BansAdded = int(bans)
			}
			if unbans, ok := history["total_unbans"].(float64); ok {
				summary.Totals.BansRemoved = int(unbans)
			}
		}
	}

	return summary, nil
}

// generateTop creates a DailyTop from bans.log data
func (g *Generator) generateTop(date string) (*DailyTop, error) {
	top := &DailyTop{
		Date:          date,
		TopBannedIPs:  []TopIP{},
		TopCountries:  []TopCountry{},
		TopSources:    []TopSource{},
		RecidivistIPs: []RecidivistIP{},
	}

	// Note: Full implementation would parse bans.log
	// For now return empty structure that can be populated

	return top, nil
}

// appendIndex adds an entry to the reports index
func (g *Generator) appendIndex(summary *DailySummary, top *DailyTop) error {
	indexPath := filepath.Join(g.config.ReportsDir, "index.jsonl")

	entry := IndexEntry{
		Date:   summary.Date,
		Bans:   summary.Totals.BansAdded,
		Unbans: summary.Totals.BansRemoved,
		Active: summary.Totals.BansActiveEnd,
	}

	// Find top country and source
	if len(top.TopCountries) > 0 {
		entry.TopCountry = top.TopCountries[0].Country
	}
	if len(top.TopSources) > 0 {
		entry.TopSource = top.TopSources[0].Source
	}

	// Append to index file
	f, err := os.OpenFile(indexPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	defer f.Close()

	encoder := json.NewEncoder(f)
	return encoder.Encode(entry)
}

// writeJSONAtomic writes JSON atomically (temp + rename)
func writeJSONAtomic(path string, v interface{}) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}

	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return err
	}

	return os.Rename(tmpPath, path)
}

// Cleanup removes reports older than retention days
func (g *Generator) Cleanup() error {
	dailyDir := filepath.Join(g.config.ReportsDir, "daily")

	entries, err := os.ReadDir(dailyDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}

	cutoff := time.Now().AddDate(0, 0, -g.config.RetentionDays)

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		if info.ModTime().Before(cutoff) {
			path := filepath.Join(dailyDir, entry.Name())
			os.Remove(path)
		}
	}

	return nil
}
