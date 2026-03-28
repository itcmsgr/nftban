// =============================================================================
// NFTBan v1.0 - nftband Daemon - Stats, profiling, and snapshot handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Stats, profiling, and snapshot handlers"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	goruntime "runtime"
	"runtime/pprof"
	"time"

	"github.com/itcmsgr/nftban/internal/stats"
	"github.com/itcmsgr/nftban/pkg/version"
)

// =============================================================================
// STATS IPC HANDLERS
// =============================================================================

// handleStatsRequest returns current daemon runtime stats
func (d *Daemon) handleStatsRequest() SocketResponse {
	if d.stats == nil {
		return SocketResponse{
			Success: false,
			Error:   "stats collector not initialized",
		}
	}

	snapshot := d.stats.Collect()
	// Set version from const
	snapshot.Daemon.Version = version.Version

	return SocketResponse{
		Success: true,
		Data:    snapshot,
	}
}

// handleSetCountsRequest returns in-memory set element counters (v1.32.0)
// Replaces expensive nft list set kernel calls for monitoring/metrics
func (d *Daemon) handleSetCountsRequest() SocketResponse {
	if d.setCounters == nil {
		return SocketResponse{
			Success: false,
			Error:   "set counters not initialized",
		}
	}

	snap := d.setCounters.Snapshot()
	return SocketResponse{
		Success: true,
		Data:    snap,
	}
}

// handleStatsHistoryRequest returns historical stats for specified days
func (d *Daemon) handleStatsHistoryRequest(params map[string]any) SocketResponse {
	if d.stats == nil {
		return SocketResponse{
			Success: false,
			Error:   "stats collector not initialized",
		}
	}

	days := 1
	if d, ok := params["days"].(float64); ok {
		days = int(d)
	}
	if days < 1 {
		days = 1
	}
	if days > 30 {
		days = 30
	}

	config := d.stats.GetConfig()
	historyDir := config.HistoryDir

	// Read history files
	var history []stats.DailyStats
	for i := 0; i < days; i++ {
		date := time.Now().AddDate(0, 0, -i).Format("2006-01-02")
		filePath := historyDir + "/" + date + ".json"

		var daily stats.DailyStats
		if err := stats.ReadJSON(filePath, &daily); err == nil && daily.Date != "" {
			history = append(history, daily)
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"days":    days,
			"history": history,
		},
	}
}

// handleSnapshotProfileRequest triggers a pprof capture
func (d *Daemon) handleSnapshotProfileRequest(params map[string]any) SocketResponse {
	if d.stats == nil {
		return SocketResponse{
			Success: false,
			Error:   "stats collector not initialized",
		}
	}

	config := d.stats.GetConfig()

	// Check if profiling is enabled
	if !config.IsProfileEnabled() {
		return SocketResponse{
			Success: false,
			Error:   "profiling is disabled in configuration (NFTBAN_WATCHDOG_PROFILE_ENABLED=false)",
		}
	}

	// Check if we can create a new profile (max count limit)
	if !stats.CanCreateProfile(config.ProfileDir, config.ProfileMaxCount) {
		return SocketResponse{
			Success: false,
			Error:   fmt.Sprintf("max profile count (%d) reached, cleanup required", config.ProfileMaxCount),
		}
	}

	profileType := "heap"
	if t, ok := params["type"].(string); ok && t != "" {
		profileType = t
	}

	duration := 0
	if d, ok := params["duration"].(float64); ok {
		duration = int(d)
	}

	// Create profile based on type
	timestamp := time.Now().Format("20060102_150405")
	var filename string
	var err error

	switch profileType {
	case "heap":
		filename = fmt.Sprintf("heap_%s.pprof", timestamp)
		err = d.captureHeapProfile(config.ProfileDir + "/" + filename)
	case "goroutine":
		filename = fmt.Sprintf("goroutine_%s.pprof", timestamp)
		err = d.captureGoroutineProfile(config.ProfileDir + "/" + filename)
	case "cpu":
		if duration < 1 {
			duration = 30 // Default 30 seconds
		}
		if duration > 120 {
			duration = 120 // Max 2 minutes
		}
		filename = fmt.Sprintf("cpu_%s_%ds.pprof", timestamp, duration)
		err = d.captureCPUProfile(config.ProfileDir+"/"+filename, duration)
	default:
		return SocketResponse{
			Success: false,
			Error:   "unsupported profile type: " + profileType + " (use: heap, goroutine, cpu)",
		}
	}

	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   "failed to capture profile: " + err.Error(),
		}
	}

	// Log the capture
	d.logProfileCapture(config.ProfileLog, profileType, filename)

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"type":     profileType,
			"filename": filename,
			"path":     config.ProfileDir + "/" + filename,
			"duration": duration,
		},
	}
}

// captureHeapProfile writes a heap profile to file
func (d *Daemon) captureHeapProfile(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	goruntime.GC() // Force GC for accurate heap stats
	return pprof.WriteHeapProfile(f)
}

// captureGoroutineProfile writes a goroutine profile to file
func (d *Daemon) captureGoroutineProfile(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	return pprof.Lookup("goroutine").WriteTo(f, 0)
}

// captureCPUProfile captures CPU profile for specified duration
func (d *Daemon) captureCPUProfile(path string, seconds int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}

	if err := pprof.StartCPUProfile(f); err != nil {
		f.Close()
		return err
	}

	// Run in goroutine so we don't block
	go func() {
		time.Sleep(time.Duration(seconds) * time.Second)
		pprof.StopCPUProfile()
		f.Close()
	}()

	return nil
}

// logProfileCapture logs profile capture to profiles.log
func (d *Daemon) logProfileCapture(logPath, profileType, filename string) {
	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(logPath), 0750); err != nil {
		log.Printf("stats: failed to create profile log directory: %v", err)
		return
	}

	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
	if err != nil {
		log.Printf("stats: failed to open profile log: %v", err)
		return
	}
	defer f.Close()

	line := fmt.Sprintf("%s captured %s profile: %s\n",
		time.Now().Format(time.RFC3339),
		profileType,
		filename,
	)
	f.WriteString(line)
}
