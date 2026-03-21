// =============================================================================
// NFTBan v1.20.0 - HTTP Bot Guard: Kernel Suspect Set Reader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Read kernel-populated http_bot_suspect nft sets (IPv4 + IPv6)
//
// meta:name="botguard_suspect"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="Read nftables suspect sets populated by kernel meter rules"
//
// The kernel meter rule automatically adds IPs exceeding rate threshold:
//
//   tcp dport {80,443} ct state new meter http_bot_meter {
//       ip saddr limit rate over 30/second
//   } add @http_bot_suspect { ip saddr timeout 5m }
//
// This reader fetches the set contents (typically 20-100 IPs) in microseconds.
// No conntrack scanning required — kernel handles detection per-packet.
//
// meta:inventory.files="suspect.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"context"
	"fmt"
	"log"
	"net/netip"
	"os/exec"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftlock"
)

// SuspectReader reads kernel-populated suspect sets.
type SuspectReader struct {
	// nft set identifiers
	ipv4Table string // "ip nftban"
	ipv6Table string // "ip6 nftban"
	ipv4Set   string // "http_bot_suspect"
	ipv6Set   string // "http_bot_suspect6"

	// Timeout for nft commands
	cmdTimeout time.Duration
}

// NewSuspectReader creates a reader for the kernel suspect sets.
func NewSuspectReader() *SuspectReader {
	return &SuspectReader{
		ipv4Table:  "ip nftban",
		ipv6Table:  "ip6 nftban",
		ipv4Set:    "http_bot_suspect",
		ipv6Set:    "http_bot_suspect6",
		cmdTimeout: 5 * time.Second,
	}
}

// ReadSuspects reads both IPv4 and IPv6 suspect sets.
// Returns a combined list of suspect IPs (typically 20-100 entries).
// This operation completes in microseconds since the sets are small.
func (r *SuspectReader) ReadSuspects(ctx context.Context) ([]netip.Addr, error) {
	var all []netip.Addr

	// Read IPv4 suspects
	ipv4, err := r.readSet(ctx, r.ipv4Table, r.ipv4Set)
	if err != nil {
		return nil, fmt.Errorf("read ipv4 suspect set: %w", err)
	}
	all = append(all, ipv4...)

	// Read IPv6 suspects
	ipv6, err := r.readSet(ctx, r.ipv6Table, r.ipv6Set)
	if err != nil {
		return nil, fmt.Errorf("read ipv6 suspect set: %w", err)
	}
	all = append(all, ipv6...)

	return all, nil
}

// readSet executes "nft list set <table> <setName>" and parses the elements.
func (r *SuspectReader) readSet(ctx context.Context, table, setName string) ([]netip.Addr, error) {
	ctx, cancel := context.WithTimeout(ctx, r.cmdTimeout)
	defer cancel()

	// Acquire shared nft lock — prevents reads during bulk writes (v1.32.0 P0-3 fix)
	lock, lockErr := nftlock.AcquireShared(5 * time.Second)
	if lockErr != nil {
		log.Printf("[botguard] nft read lock timeout, proceeding unlocked: %v", lockErr)
	}

	// nft list set "ip nftban" http_bot_suspect
	args := append([]string{"list", "set"}, strings.Fields(table)...)
	args = append(args, setName)

	cmd := exec.CommandContext(ctx, "nft", args...) // #nosec G204 -- args built from trusted constants (table name + set name)
	output, err := cmd.CombinedOutput()

	// Release lock immediately after kernel read
	if lock != nil {
		lock.Release()
	}
	if err != nil {
		outputStr := strings.TrimSpace(string(output))
		// Set might not exist yet (module not enabled) — not an error
		if strings.Contains(outputStr, "No such") ||
			strings.Contains(outputStr, "does not exist") {
			return nil, nil
		}
		return nil, fmt.Errorf("nft list set %s %s: %w: %s", table, setName, err, outputStr)
	}

	return parseSetIPs(string(output)), nil
}

// parseSetIPs extracts IP addresses from nft list set output.
// Example output:
//
//	table ip nftban {
//	    set http_bot_suspect {
//	        type ipv4_addr
//	        flags timeout
//	        timeout 5m
//	        elements = { 1.2.3.4 timeout 4m59s, 5.6.7.8 timeout 3m20s }
//	    }
//	}
func parseSetIPs(output string) []netip.Addr {
	var ips []netip.Addr

	lines := strings.Split(output, "\n")
	inElements := false

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		if strings.HasPrefix(trimmed, "elements = {") {
			inElements = true
			content := strings.TrimPrefix(trimmed, "elements = {")
			content = strings.TrimSuffix(content, "}")
			ips = append(ips, extractIPs(content)...)
			// Check if elements close on same line
			if strings.Contains(trimmed, "}") && !strings.HasPrefix(trimmed, "elements") {
				inElements = false
			}
			continue
		}

		if inElements {
			if strings.Contains(trimmed, "}") {
				content := strings.Split(trimmed, "}")[0]
				ips = append(ips, extractIPs(content)...)
				inElements = false
				continue
			}
			ips = append(ips, extractIPs(trimmed)...)
		}
	}

	return ips
}

// extractIPs extracts IP addresses from a comma-separated element list.
// Each element may have "timeout Xs" suffix which we strip.
// Example: "1.2.3.4 timeout 4m59s, 5.6.7.8 timeout 3m20s"
func extractIPs(s string) []netip.Addr {
	var ips []netip.Addr
	parts := strings.Split(s, ",")
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		// Take only the IP part (before "timeout", "expires", etc.)
		fields := strings.Fields(part)
		if len(fields) == 0 {
			continue
		}
		ipStr := fields[0]
		addr, err := netip.ParseAddr(ipStr)
		if err != nil {
			continue
		}
		ips = append(ips, addr)
	}
	return ips
}
