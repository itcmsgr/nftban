// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftban-core"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Main entry point for nftban-core CLI binary"
// meta:input="Command line arguments"
// meta:output="CLI output, nftables operations"
// meta:depends="go,nftables"
//
// meta:inventory.files="cmd_*.go,privilege.go,usage.go"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="cap_net_admin"

package main

import (
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/itcmsgr/nftban/internal/analytics"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/version"
)

// Build-time variables — PR v1.100.4 H1.1: canonical names live in
// pkg/version. Aliases re-exported here for cmd-local readability;
// the build-time injection path is single-sourced through pkg/version.
var (
	GitCommit = version.GitCommit
	BuildDate = version.BuildDate
)

func main() {
	if len(os.Args) < 2 {
		printUsage()
		os.Exit(1)
	}

	command := os.Args[1]

	// PR v1.100.4 H1.1: handle --version / -v as a flag-style alias
	// of the existing `version` subcommand. Operators reach for
	// --version reflexively; rejecting it as "Unknown command" is a
	// poor UX. Keeps the legacy `version` subcommand for backwards
	// compatibility with any tooling that already invokes it.
	switch command {
	case "--version", "-v":
		fmt.Println(version.Line(version.CoreEngineName))
		return
	}

	// ════════════════════════════════════════════════════════════
	// LOAD CONFIG ONCE - Pass to all commands
	// ════════════════════════════════════════════════════════════
	cfg := nftbanconf.MustLoad()

	// ════════════════════════════════════════════════════════════
	// Analytics initialization for commands that need it
	// ════════════════════════════════════════════════════════════
	needsAnalytics := command == "ban" || command == "analytics"

	if needsAnalytics {
		// Get data dir from config (already loaded above)
		dataDir := cfg.DataDir
		// v1.228.5 FHS: reports are operational history, not state. They live under
		// /var/log/nftban/reports (nftban_log_t, logrotate-owned), not dataDir.
		// Deriving from dataDir kept a third writer on the old path.
		if err := analytics.Init(dataDir, cfg.LogDir+"/reports"); err != nil {
			log.Printf("Warning: Analytics disabled: %v", err)
		}

		// Ensure we save on exit
		defer func() {
			if st := analytics.StateOrNil(); st != nil {
				if err := st.Save(); err != nil {
					log.Printf("Warning: Failed to save analytics: %v", err)
				}
			}
		}()
	}
	// ════════════════════════════════════════════════════════════

	switch command {
	case "init":
		if err := cmdInit(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "status":
		if err := cmdStatus(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "sync":
		if err := cmdSync(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "ban":
		if len(os.Args) < 3 {
			errorWithUsage("ban", "ban command requires an IP address")
			os.Exit(1)
		}
		ip := os.Args[2]

		// Parse flags
		var timeout int = 0 // 0 = permanent
		var reason string = ""
		var source string = "manual"

		for i := 3; i < len(os.Args); i++ {
			arg := os.Args[i]
			if arg == "--timeout" && i+1 < len(os.Args) {
				fmt.Sscanf(os.Args[i+1], "%d", &timeout)
				i++
			} else if arg == "--reason" && i+1 < len(os.Args) {
				reason = os.Args[i+1]
				i++
			} else if arg == "--source" && i+1 < len(os.Args) {
				source = os.Args[i+1]
				i++
			} else if !strings.HasPrefix(arg, "--") {
				// Legacy: treat non-flag args as reason
				if reason == "" {
					reason = arg
				} else {
					reason = reason + " " + arg
				}
			}
		}

		if err := cmdBan(ip, reason, source, timeout, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "unban":
		if len(os.Args) < 3 {
			errorWithUsage("unban", "unban command requires an IP address")
			os.Exit(1)
		}
		ip := os.Args[2]
		if err := cmdUnban(ip, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "check":
		if len(os.Args) < 3 {
			errorWithUsage("check", "check command requires an IP address")
			os.Exit(1)
		}
		ip := os.Args[2]
		if err := cmdCheck(ip, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "verify-rules":
		// SEC-RULEFP (v1.138): recompute the canonical ruleset fingerprint and
		// compare to the captured baseline (--capture re-captures from the live
		// ruleset). Custom exit codes: OK/BASELINE_MISSING=0, MISMATCH=2, NFT_UNAVAILABLE=3.
		os.Exit(cmdVerifyRules(os.Args[2:]))
	case "whitelist-coverage":
		// WHITELIST_DURABLE_APPLY_RECONCILE: range-aware whitelist coverage diff
		// (reads {baseline,kernel,sessions} JSON on stdin). CLI-only oracle for
		// `nftban whitelist verify` + the `--static` add live read-back.
		os.Exit(cmdWhitelistCoverage(os.Args[2:]))
	case "portscan-classify":
		// v1.204 PORTSCAN GO-CLASSIFIER: typed scan-type classifier (reads per-IP
		// {events,known_open_ports,thresholds} JSON on stdin → Verdict JSON). Scores
		// only unexpected/closed ports; known-open service ports never accrue score.
		// CLI-only decision function (fed by the existing root log reader).
		os.Exit(cmdPortscanClassify(os.Args[2:]))
	case "feeds":
		if len(os.Args) < 3 {
			errorWithUsage("feeds", "feeds command requires an action")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdFeeds(action, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "trust":
		if len(os.Args) < 3 {
			errorWithUsage("trust", "trust command requires an action")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdTrust(action, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "country":
		if len(os.Args) < 3 {
			errorWithUsage("country", "country command requires an action")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdCountry(action, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "ports":
		if len(os.Args) < 3 {
			errorWithUsage("ports", "ports command requires an action")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdPorts(action, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "geoip":
		if len(os.Args) < 3 {
			errorWithUsage("geoip", "geoip command requires an action")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdGeoip(action, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "suricata":
		if len(os.Args) < 3 {
			errorWithUsage("suricata", "suricata command requires an action")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdSuricata(action, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "analytics":
		if len(os.Args) < 3 {
			errorWithUsage("analytics", "analytics command requires an action")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdAnalytics(action); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "metrics":
		if len(os.Args) < 3 {
			errorWithUsage("metrics", "metrics command requires an action (export)")
			os.Exit(1)
		}
		action := os.Args[2]
		if err := cmdMetrics(action, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "emulate":
		if len(os.Args) < 3 {
			errorWithUsage("emulate", "emulate command requires an IP address")
			os.Exit(1)
		}
		// Parse: emulate <ip> [protocol] [port] [direction]
		emulateArgs := os.Args[2:]
		if err := cmdEmulate(emulateArgs, cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "profile-sync":
		if err := runProfileSync(cfg); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "smoke":
		os.Exit(cmdSmoke(os.Args[2:]))
	case "lifecycle":
		os.Exit(cmdLifecycle(os.Args[2:]))
	case "logretention":
		os.Exit(cmdLogRetention(os.Args[2:]))
	case "resources":
		os.Exit(cmdResources(os.Args[2:]))
	case "version":
		fmt.Println(version.Line(version.CoreEngineName))
	case "help", "--help", "-h":
		printUsage()
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", command)
		printUsage()
		os.Exit(1)
	}
}

func printUsage() {
	fmt.Printf("%s - %s Core Engine\n", version.CoreEngineName, version.Banner(""))
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  nftban-core init                 Initialize NFTBan with safety checks")
	fmt.Println("  nftban-core status               Show current firewall status")
	fmt.Println("  nftban-core resources [--json]   Show hardware + effective health-service resource limits")
	fmt.Println("  nftban-core sync                 Sync config files to nftables (differential)")
	fmt.Println("  nftban-core ban <IP> [reason]    Ban an IP address")
	fmt.Println("  nftban-core unban <IP>           Unban an IP address")
	fmt.Println("  nftban-core check <IP>           Check IP status (whitelist/blacklist)")
	fmt.Println("  nftban-core feeds [list|load|stats] Manage threat feeds")
	fmt.Println("  nftban-core ports [list|load|status] Manage port rules (IPv4/IPv6 auto-detect)")
	fmt.Println("  nftban-core geoip [update|status|lookup] Manage GeoIP database and lookups")
	fmt.Println("  nftban-core suricata [status|filters|enable|disable] Manage Suricata IDS integration (v1.0)")
	fmt.Println("  nftban-core analytics [summary|countries|top|ip] Show ban analytics (use --json for GUI)")
	fmt.Println("  nftban-core metrics export       Export Prometheus metrics (high-performance Go exporter)")
	fmt.Println("  nftban-core emulate <IP> [proto] [port] [dir] Emulate packet evaluation (fast IP/CIDR matching)")
	fmt.Println("  nftban-core profile-sync         Run sync operations with profiling enabled (pprof on :6060)")
	fmt.Println("  nftban-core version              Show version information")
	fmt.Println("  nftban-core help                 Show this help message")
	fmt.Println()
}
