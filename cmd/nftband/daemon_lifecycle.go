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
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
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

	"github.com/coreos/go-systemd/v22/daemon"
	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
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
	// Record the shutdown phases in the canonical lifecycle (also cancels the
	// startup-pending diagnostic and pushes a STATUS= line).
	d.lifecycle.beginShutdown()

	// Notify systemd we are stopping (v1.29.1)
	_, _ = daemon.SdNotify(false, daemon.SdNotifyStopping)

	// Close socket listener first to stop accepting new IPC connections
	if d.socketLn != nil {
		_ = d.socketLn.Close()
	}

	// Publish shutdown event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, "nftband").
		WithMessage("NFTBan daemon shutting down").
		WithSeverity(eventbus.SeverityInfo))

	// Shutdown HTTP server.
	//
	// v1.229.2 TRACK A — the HTTP API is optional: when its port is owned by another
	// service httpSrv is never created. This call was unguarded, so on those hosts
	// SIGTERM panicked on a nil receiver INSIDE this goroutine. The only recover() is
	// deferred in the parent goroutine that spawned handleSignals and cannot catch a
	// panic raised here, so the process died and every step below was skipped:
	// module StopAll, OpQueue drain, the SourceIndex save, the event bus close, the
	// final cache flush, completeShutdown, and PID-file removal — after STOPPING=1
	// had already been sent to systemd. Guarded to match socketLn/opQueue/sourceIndex
	// below, which were already nil-checked.
	ctx, cancel := context.WithTimeout(context.Background(), constants.DaemonStartupWait)
	defer cancel()
	if d.httpSrv != nil {
		if err := d.httpSrv.Shutdown(ctx); err != nil {
			log.Printf("HTTP shutdown error: %v", err)
		}
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

	// Cancel context (signals CacheWriterLoop and other bg goroutines to stop)
	d.cancel()

	// Wait for background goroutines (cache writer) to finish final flush
	d.bgWg.Wait()

	log.Println("nftband stopped")
	d.lifecycle.completeShutdown()
}

// waitForShutdown evaluates the readiness contract, sends systemd READY=1 exactly
// once, then blocks until the signal handler completes shutdown. It returns a fatal
// error when a mandatory readiness prerequisite is unmet — in that case READY=1 is
// NOT sent and the caller (Run) propagates the error so startup fails cleanly.
func (d *Daemon) waitForShutdown() error {
	// Mark startup as complete so signal handler does graceful shutdown
	d.sigMu.Lock()
	d.startupComplete = true
	d.sigMu.Unlock()

	// Readiness gate + systemd READY=1 (exactly once, main process). A failed
	// SdNotify is material but non-fatal (handled inside SendReady, prior
	// semantics); a mandatory-prerequisite failure is fatal and returns here.
	if err := d.lifecycle.SendReady(); err != nil {
		return fmt.Errorf("daemon not ready: %w", err)
	}

	// Start watchdog heartbeat goroutine (WatchdogSec=120s, notify every 15s)
	go d.watchdogHeartbeat()

	d.lifecycle.enterRunning()
	log.Println("Startup complete, waiting for shutdown signal...")

	// Block until gracefulShutdown() is called by handleSignals
	// We wait on the context which is cancelled during gracefulShutdown
	<-d.ctx.Done()
	return nil
}

// watchdogHeartbeat sends sd_notify WATCHDOG=1 every 15s (half of WatchdogSec=30s).
// Stops when daemon context is cancelled.
func (d *Daemon) watchdogHeartbeat() {
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-ticker.C:
			_, _ = daemon.SdNotify(false, daemon.SdNotifyWatchdog)
		}
	}
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
