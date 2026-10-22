// =============================================================================
// NFTBan - Differential Sync Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="cmd_sync"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Synchronize whitelist and blacklist with nftables via daemon"
// meta:input="None"
// meta:output="Console output with sync results"
// meta:depends="github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network="unix:/var/run/nftban/nftband.sock"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/version"
)

// Exit codes of `nftban-core sync` (v1.236). The installer and the shell wrapper act on
// them, so they are part of the contract:
//
//	0   completed; effect applied or partial (partial is printed as a warning)
//	1   failed, or refused (completed with no effect), or a usage error
//	69  not delivered: the daemon was not reachable, nothing ran (safe to retry)
//	74  completion unknown: the request was sent but no answer was read
//	75  still running when --wait ran out; join it with --join <generation>
const (
	syncExitFailed       = 1
	syncExitNotDelivered = 69
	syncExitUnknown      = 74
	syncExitRunning      = 75
)

// syncExit carries a sync exit code to main.
type syncExit struct {
	code int
	msg  string
}

func (e *syncExit) Error() string { return e.msg }

// syncExitCode maps a cmdSync error to its exit code (1 for anything else).
func syncExitCode(err error) int {
	var se *syncExit
	if errors.As(err, &se) {
		return se.code
	}
	return syncExitFailed
}

// syncPerCallWait bounds one IPC wait, so progress is printed and a daemon restart
// during a long sync is noticed.
const syncPerCallWait = 60 * time.Second

func cmdSync(cfg *nftbanconf.Config) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	// --quick skips feeds/geoban (fast postinst sync). --wait N bounds the total wait
	// (default: 5 min full, 30 s quick, as before). --join G reports an earlier
	// generation without submitting new work.
	quickMode := false
	join := ""
	var total time.Duration
	args := os.Args[2:]
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--quick" || arg == "-q":
			quickMode = true
		case arg == "--dry-run":
			// BUG-SYNC-DRY-RUN-AND-VALIDATE-PERFORM-REAL-SYNC (D1): this flag used to be
			// ignored, so a "dry run" performed a real sync. The daemon has no dry-run
			// mode; refuse instead of mutating.
			return &syncExit{syncExitFailed, "--dry-run is not supported by the daemon sync; nothing was changed"}
		case arg == "--wait" || arg == "--join":
			if i+1 >= len(args) {
				return &syncExit{syncExitFailed, arg + " requires a value"}
			}
			i++
			if arg == "--join" {
				join = args[i]
				continue
			}
			secs, err := strconv.Atoi(args[i])
			if err != nil || secs <= 0 {
				return &syncExit{syncExitFailed, "--wait requires a positive number of seconds"}
			}
			total = time.Duration(secs) * time.Second
		}
	}
	if total == 0 {
		total = 5 * time.Minute
		if quickMode {
			total = 30 * time.Second
		}
	}

	if quickMode {
		fmt.Println(version.BannerWithEmoji("🔄", "Quick Sync (whitelist/blacklist only)"))
	} else {
		fmt.Println(version.BannerWithEmoji("🔄", "Differential Sync"))
	}
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Connect to daemon via IPC
	fmt.Println("Connecting to nftband daemon...")
	client := ipc.NewClient()

	// Check if daemon is running
	if err := client.Ping(); err != nil {
		code := syncExitFailed
		if errors.Is(err, ipc.ErrNotDelivered) {
			code = syncExitNotDelivered
		}
		return &syncExit{code, fmt.Sprintf("daemon not running: %v\nStart with: sudo systemctl start nftband", err)}
	}
	fmt.Println("  ✅ Connected to nftband daemon")
	fmt.Println()
	fmt.Printf("  ⏱️  Waiting up to %v for the sync to finish\n", total)
	fmt.Println()

	// Submit (or join), then keep joining the same generation until it finishes or
	// the wait runs out. A retry never submits new work: the daemon runs the sync off
	// the connection, so waiting longer is a join, not a second sync.
	if join == "" {
		fmt.Println("Performing differential sync via daemon...")
	} else {
		fmt.Printf("Joining sync generation %s...\n", join)
	}
	deadline := time.Now().Add(total)
	var resp *ipc.Response
	var exec ipc.Execution
	var effect ipc.Effect
	var gen string
	for {
		wait := time.Until(deadline)
		if wait > syncPerCallWait {
			wait = syncPerCallWait
		}
		if wait < time.Second {
			wait = time.Second
		}
		var err error
		resp, err = client.SyncWithin(quickMode, join, wait)
		if err != nil {
			if errors.Is(err, ipc.ErrNotDelivered) && join == "" {
				return &syncExit{syncExitNotDelivered, fmt.Sprintf("sync not delivered (nothing ran): %v", err)}
			}
			msg := fmt.Sprintf("sync completion unknown: %v", err)
			if gen != "" {
				msg += "\nJoin with: nftban-core sync --join " + gen
			}
			return &syncExit{syncExitUnknown, msg}
		}
		exec, effect, gen = ipc.ResultOf(resp)
		if exec != ipc.ExecRunning || gen == "" || time.Now().After(deadline) {
			break
		}
		join = gen
		fmt.Printf("  … still running (generation %s, %.0fs left)\n", gen, time.Until(deadline).Seconds())
	}

	switch exec {
	case ipc.ExecRunning:
		return &syncExit{syncExitRunning, fmt.Sprintf("sync still running after %v (generation %s); not reported as complete\nJoin with: nftban-core sync --join %s", total, gen, gen)}
	case ipc.ExecUnknown:
		return &syncExit{syncExitUnknown, resp.Error}
	case ipc.ExecFailed:
		return &syncExit{syncExitFailed, "sync failed: " + resp.Error}
	}
	if effect == ipc.EffectRefused || !resp.Success {
		return &syncExit{syncExitFailed, "sync refused, nothing changed: " + resp.Error}
	}

	// Extract results from response
	data, ok := resp.Data.(map[string]any)
	if !ok {
		return fmt.Errorf("unexpected response format")
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	if effect == ipc.EffectPartial {
		fmt.Println("⚠️  Sync finished PARTIALLY: some requested state was NOT committed")
		if reasons, ok := data["partial_reasons"].([]any); ok {
			for _, r := range reasons {
				fmt.Printf("   - %v\n", r)
			}
		}
	} else {
		fmt.Println("✅ Sync completed successfully!")
	}
	runSecs, _ := data["run_seconds"].(float64)
	fmt.Printf("  generation %s (run %v, %.1fs, joined=%v)\n", gen, data["run"], runSecs, data["joined"])
	fmt.Println()

	// Print sync results
	fmt.Println("Sync Results:")
	fmt.Println(strings.Repeat("-", 70))

	if v, ok := data["whitelist_ipv4_added"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv4: +%.0f added\n", v)
	}
	if v, ok := data["whitelist_ipv4_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv4: -%.0f removed\n", v)
	}
	if v, ok := data["whitelist_ipv6_added"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv6: +%.0f added\n", v)
	}
	if v, ok := data["whitelist_ipv6_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv6: -%.0f removed\n", v)
	}
	if v, ok := data["blacklist_ipv4_added"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv4: +%.0f added\n", v)
	}
	if v, ok := data["blacklist_ipv4_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv4: -%.0f removed\n", v)
	}
	if v, ok := data["blacklist_ipv6_added"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv6: +%.0f added\n", v)
	}
	if v, ok := data["blacklist_ipv6_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv6: -%.0f removed\n", v)
	}
	if v, ok := data["blacklist_manual_added"].(float64); ok && v > 0 {
		fmt.Printf("  blacklist.d IPs: +%.0f added\n", v)
	}
	if v, ok := data["blacklist_manual_replaced"].(float64); ok && v > 0 {
		fmt.Printf("  blacklist.d IPs: %.0f timed -> permanent\n", v)
	}

	// Feeds loaded (if any)
	if v, ok := data["feeds_ipv4_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Feeds IPv4: %.0f ranges loaded\n", v)
	}
	if v, ok := data["feeds_ipv6_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Feeds IPv6: %.0f ranges loaded\n", v)
	}

	// Geoban loaded (if any)
	if v, ok := data["geoban_ipv4_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Geoban IPv4: %.0f ranges loaded\n", v)
	}
	if v, ok := data["geoban_ipv6_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Geoban IPv6: %.0f ranges loaded\n", v)
	}

	if tcp, ok := data["tcp_ports_in"].(float64); ok && tcp > 0 {
		fmt.Printf("  TCP Ports (In): %.0f loaded\n", tcp)
	}
	if udp, ok := data["udp_ports_in"].(float64); ok && udp > 0 {
		fmt.Printf("  UDP Ports (In): %.0f loaded\n", udp)
	}

	// Show directional port counts if present
	tcpIn, _ := data["tcp_ports_in"].(float64)
	tcpOut, _ := data["tcp_ports_out"].(float64)
	udpIn, _ := data["udp_ports_in"].(float64)
	udpOut, _ := data["udp_ports_out"].(float64)
	if tcpIn > 0 || tcpOut > 0 || udpIn > 0 || udpOut > 0 {
		fmt.Println("  Directional ports:")
		if tcpIn > 0 {
			fmt.Printf("    TCP Input:  %.0f\n", tcpIn)
		}
		if tcpOut > 0 {
			fmt.Printf("    TCP Output: %.0f\n", tcpOut)
		}
		if udpIn > 0 {
			fmt.Printf("    UDP Input:  %.0f\n", udpIn)
		}
		if udpOut > 0 {
			fmt.Printf("    UDP Output: %.0f\n", udpOut)
		}
	}

	fmt.Println()
	fmt.Println("Firewall is now in sync with configuration files.")
	fmt.Println()

	return nil
}
