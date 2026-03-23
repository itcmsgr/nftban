// =============================================================================
// NFTBan - Metrics Export Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_metrics"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Export Prometheus metrics for node_exporter textfile collector"
// meta:input="Subcommand (export)"
// meta:output="Prometheus metrics file"
// meta:depends="github.com/itcmsgr/nftban/internal/metrics,github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files="/var/lib/node_exporter/textfile_collector/nftban.prom"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_METRICS_FILE,NFTBAN_DATA_DIR,NFTBAN_LOG_DIR"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/internal/metrics"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// cmdMetrics handles the metrics export command
func cmdMetrics(action string, cfg *nftbanconf.Config) error {
	if action != "export" {
		return fmt.Errorf("unknown metrics action: %s (use 'export')", action)
	}

	// Get output file from environment or use default
	outputFile := os.Getenv("NFTBAN_METRICS_FILE")
	if outputFile == "" {
		outputFile = "/var/lib/node_exporter/textfile_collector/nftban.prom"
	}

	// Get state and log dirs from config
	stateDir := cfg.DataDir
	logDir := cfg.LogDir

	// Allow environment override
	if envState := os.Getenv("NFTBAN_DATA_DIR"); envState != "" {
		stateDir = envState
	}
	if envLog := os.Getenv("NFTBAN_LOG_DIR"); envLog != "" {
		logDir = envLog
	}

	// Parse flags for output file override
	for i := 0; i < len(os.Args); i++ {
		arg := os.Args[i]
		if (arg == "--output" || arg == "-o") && i+1 < len(os.Args) {
			outputFile = os.Args[i+1]
			i++
		} else if arg == "--state-dir" && i+1 < len(os.Args) {
			stateDir = os.Args[i+1]
			i++
		} else if arg == "--log-dir" && i+1 < len(os.Args) {
			logDir = os.Args[i+1]
			i++
		}
	}

	// Create collector
	collector := metrics.NewCollector(outputFile, stateDir, logDir)

	// Collect metrics
	if err := collector.Collect(); err != nil {
		return fmt.Errorf("failed to collect metrics: %w", err)
	}

	fmt.Printf("Metrics exported successfully to %s\n", outputFile)
	return nil
}
