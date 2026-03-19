// =============================================================================
// NFTBan v1.0 - nftband Daemon - Signal handling, graceful shutdown, and reload
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Signal handling, graceful shutdown, and reload"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="8080/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// handleSignals is the unified signal handler that runs as a goroutine.
// It handles all signals throughout the daemon lifecycle:
// - During startup (startupComplete=false): minimal cleanup and exit
// - After startup (startupComplete=true): graceful shutdown with full cleanup
func (d *Daemon) handleSignals(pidFile string) {
	for sig := range d.sigCh {
		d.sigMu.Lock()
		complete := d.startupComplete
		d.sigMu.Unlock()

		switch sig {
		case syscall.SIGHUP:
			if !complete {
				// Ignore SIGHUP during startup
				log.Println("Ignoring SIGHUP during startup")
				continue
			}
			// Handle config reload
			log.Println("Received SIGHUP, reloading configuration...")
			if err := d.reloadConfig(); err != nil {
				log.Printf("Config reload failed: %v", err)
			} else {
				log.Printf("Config reloaded successfully (hash: %s)", d.configHash[:16])
			}
			continue // Keep waiting for signals

		case syscall.SIGTERM, syscall.SIGINT:
			if !complete {
				// During startup: minimal cleanup and exit
				log.Printf("Received %v during startup, cleaning up PID file...", sig)
				os.Remove(pidFile)
				os.Exit(1)
			}
			// After startup: graceful shutdown
			log.Printf("Received %v, shutting down...", sig)
			d.gracefulShutdown()
			return
		}
	}
}

// gracefulShutdown performs orderly shutdown of all daemon components
func (d *Daemon) gracefulShutdown() {
	// Close socket listener first to stop accepting new IPC connections
	if d.socketLn != nil {
		_ = d.socketLn.Close()
	}

	// Publish shutdown event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, "nftband").
		WithMessage("NFTBan daemon shutting down").
		WithSeverity(eventbus.SeverityInfo))

	// Shutdown HTTP server
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := d.httpSrv.Shutdown(ctx); err != nil {
		log.Printf("HTTP shutdown error: %v", err)
	}

	// Stop all modules
	if err := d.registry.StopAll(); err != nil {
		log.Printf("Module stop error: %v", err)
	}

	// Stop OpQueue and save SourceIndex (v1.13.0)
	if d.opQueue != nil {
		log.Println("Stopping OpQueue...")
		d.opQueue.Stop()
	}
	if d.sourceIndex != nil {
		log.Println("Saving SourceIndex...")
		d.sourceIndex.Stop()
	}

	// Close event bus
	d.bus.Close()

	// Cancel context
	d.cancel()

	log.Println("nftband stopped")
}

// waitForShutdown blocks until the signal handler completes shutdown
func (d *Daemon) waitForShutdown() {
	// Mark startup as complete so signal handler does graceful shutdown
	d.sigMu.Lock()
	d.startupComplete = true
	d.sigMu.Unlock()

	log.Println("Startup complete, waiting for shutdown signal...")

	// Block until gracefulShutdown() is called by handleSignals
	// We wait on the context which is cancelled during gracefulShutdown
	<-d.ctx.Done()
}

// =============================================================================
// CONFIG RELOAD (v1.13.12)
// =============================================================================

// computeConfigHash computes SHA256 hash of config files for change detection
func (d *Daemon) computeConfigHash() (string, error) {
	configDir := "/etc/nftban"
	h := sha256.New()

	// Hash main config files
	files := []string{
		filepath.Join(configDir, "nftban.conf"),
		filepath.Join(configDir, "nftban.conf.local"),
	}

	for _, f := range files {
		if data, err := os.ReadFile(f); err == nil {
			h.Write([]byte(f + ":"))
			h.Write(data)
		}
	}

	// Hash module configs in conf.d/
	confD := filepath.Join(configDir, "conf.d")
	if entries, err := os.ReadDir(confD); err == nil {
		for _, entry := range entries {
			if entry.IsDir() {
				// Module directory - hash main.conf and main.conf.local
				for _, name := range []string{"main.conf", "main.conf.local"} {
					f := filepath.Join(confD, entry.Name(), name)
					if data, err := os.ReadFile(f); err == nil {
						h.Write([]byte(f + ":"))
						h.Write(data)
					}
				}
			} else if strings.HasSuffix(entry.Name(), ".conf") {
				// Top-level conf file
				f := filepath.Join(confD, entry.Name())
				if data, err := os.ReadFile(f); err == nil {
					h.Write([]byte(f + ":"))
					h.Write(data)
				}
			}
		}
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

// reloadConfig reloads configuration from disk
// This is called on SIGHUP or via IPC reload request
func (d *Daemon) reloadConfig() error {
	d.reloadMu.Lock()
	defer d.reloadMu.Unlock()

	// Compute new hash before reload
	newHash, err := d.computeConfigHash()
	if err != nil {
		return fmt.Errorf("failed to compute config hash: %w", err)
	}

	// Check if config actually changed
	if newHash == d.configHash {
		log.Println("Config unchanged, skipping reload")
		return nil
	}

	// Reload config via nftbanconf package
	if err := nftbanconf.Reload(); err != nil {
		return fmt.Errorf("failed to reload config: %w", err)
	}

	// Update daemon state
	oldHash := d.configHash
	d.configHash = newHash
	d.lastReloadTs = time.Now()

	// Publish reload event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventConfigReload, "nftband").
		WithMessage(fmt.Sprintf("Config reloaded (hash: %s -> %s)", oldHash[:8], newHash[:8])).
		WithSeverity(eventbus.SeverityInfo))

	return nil
}

// initConfigHash initializes config hash on startup
func (d *Daemon) initConfigHash() {
	hash, err := d.computeConfigHash()
	if err != nil {
		log.Printf("Warning: failed to compute initial config hash: %v", err)
		return
	}
	d.configHash = hash
	d.lastReloadTs = time.Now()
	log.Printf("Config hash initialized: %s", hash[:16])
}
