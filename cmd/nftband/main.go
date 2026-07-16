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

	"github.com/coreos/go-systemd/v22/daemon"
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
	_, configDir, dataDir, _ := getDaemonPaths()
	d := &Daemon{
		bus:       eventbus.New(),
		registry:  module.NewRegistry(),
		backend:   nftbackend.New(), // AUTHORITATIVE nft backend
		stats:     stats.NewCollector(stats.DefaultConfig()),
		configDir: configDir,
		connSem:   make(chan struct{}, MaxConcurrentIPCConns),
		startedAt: time.Now(),
		lifecycle: newStartupLifecycle(os.Getpid()),
	}

	// Wire the canonical lifecycle to systemd sd_notify (READY=1 / STATUS=). Only
	// the main process participates in the notification contract (NotifyAccess=main).
	// NFTBAN_DEBUG_FAIL_READY is a bounded, test-only seam (empty/unset in
	// production; no unit/package sets it): with a real NOTIFY_SOCKET present it
	// forces the READY=1 delivery to fail so the fatal systemd-mode path can be
	// proven WITHOUT touching the real /run/systemd/notify socket.
	failReady := os.Getenv("NFTBAN_DEBUG_FAIL_READY") != ""
	d.lifecycle.setNotifier(func(state string) (bool, error) {
		if failReady && state == "READY=1" {
			return false, fmt.Errorf("debug: forced READY failure (NFTBAN_DEBUG_FAIL_READY)")
		}
		return daemon.SdNotify(false, state)
	})

	// v1.209.x F2: wire the AUTHORITATIVE never-ban exemption guard at the durable apply
	// boundary (Backend.Ban). Establishes the never-ban invariant for admin/management/
	// whitelist/system/live-SSH IPs across ALL ban paths, and publishes the resolved
	// exempt list for the unprivileged BotScan scanner to suppress signals cheaply.
	d.backend.EnableExemptionGuard(configDir, dataDir+"/botscan/exempt.list")

	// Initialize dynamic watchdog
	if err := d.initWatchdog(); err != nil {
		log.Printf("Warning: watchdog init failed: %v (continuing without watchdog)", err)
	}

	// Run
	if err := d.Run(); err != nil {
		log.Fatalf("Daemon error: %v", err)
	}
}
