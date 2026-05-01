// =============================================================================
// NFTBan v1.0 - nftband Daemon - Daemon entry point
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Daemon entry point"
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
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/internal/stats"
	"github.com/itcmsgr/nftban/pkg/version"
)

func main() {
	// Handle version/help and parse flags
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--version", "-v":
			fmt.Println(version.Line("nftband"))
			return
		case "--help", "-h":
			printHelp()
			return
		case "--profile":
			profileEnabled = true
		}
	}

	// Also check environment variable for pprof (useful for systemd/container deployments)
	if os.Getenv("NFTBAN_ENABLE_PPROF") == "true" {
		profileEnabled = true
	}

	// Initialize safety limits (dynamic based on server profile: CPU, RAM, panel)
	// This sets GOMEMLIMIT to prevent unbounded memory growth
	safetyLimits := safety.FromEnv()
	safety.InitMemory(safetyLimits)
	log.Printf("Safety: %s", safety.GetProfileDescription())

	// Create daemon
	_, configDir, _, _ := getDaemonPaths()
	d := &Daemon{
		bus:       eventbus.New(),
		registry:  module.NewRegistry(),
		backend:   nftbackend.New(), // AUTHORITATIVE nft backend
		stats:     stats.NewCollector(stats.DefaultConfig()),
		configDir: configDir,
		connSem:   make(chan struct{}, MaxConcurrentIPCConns),
		startedAt: time.Now(),
	}

	// Initialize dynamic watchdog
	if err := d.initWatchdog(); err != nil {
		log.Printf("Warning: watchdog init failed: %v (continuing without watchdog)", err)
	}

	// Run
	if err := d.Run(); err != nil {
		log.Fatalf("Daemon error: %v", err)
	}
}
