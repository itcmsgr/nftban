package main

import (
	"fmt"
	"log"
	"os"

	"github.com/spf13/cobra"
	"github.com/itcmsgr/nftban/pkg/metrics"
)

var metricsCmd = &cobra.Command{
	Use:   "metrics",
	Short: "Prometheus metrics collection",
	Long:  `Efficiently collect and export NFTBan metrics in Prometheus format`,
}

var exportCmd = &cobra.Command{
	Use:   "export",
	Short: "Export metrics to Prometheus textfile",
	Long: `Export NFTBan metrics to Prometheus textfile collector format.
This is a high-performance replacement for the bash-based exporter.`,
	Run: runMetricsExport,
}

var (
	metricsOutputFile string
	metricsStateDir   string
	metricsLogDir     string
)

func init() {
	rootCmd.AddCommand(metricsCmd)
	metricsCmd.AddCommand(exportCmd)

	// Flags
	exportCmd.Flags().StringVarP(&metricsOutputFile, "output", "o",
		"/var/lib/node_exporter/textfile_collector/nftban.prom",
		"Output file for Prometheus metrics")
	exportCmd.Flags().StringVar(&metricsStateDir, "state-dir",
		"/var/lib/nftban",
		"NFTBan state directory")
	exportCmd.Flags().StringVar(&metricsLogDir, "log-dir",
		"/var/log/nftban",
		"NFTBan log directory")
}

func runMetricsExport(cmd *cobra.Command, args []string) {
	// Check environment variables (systemd may set these)
	if envOutput := os.Getenv("NFTBAN_METRICS_FILE"); envOutput != "" {
		metricsOutputFile = envOutput
	}
	if envState := os.Getenv("NFTBAN_DATA_DIR"); envState != "" {
		metricsStateDir = envState
	}
	if envLog := os.Getenv("NFTBAN_LOG_DIR"); envLog != "" {
		metricsLogDir = envLog
	}

	// Create collector
	collector := metrics.NewCollector(metricsOutputFile, metricsStateDir, metricsLogDir)

	// Collect metrics
	if err := collector.Collect(); err != nil {
		log.Printf("ERROR: Failed to collect metrics: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Metrics exported successfully to %s\n", metricsOutputFile)
}
