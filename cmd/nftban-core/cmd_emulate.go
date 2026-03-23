// =============================================================================
// NFTBan - Packet Emulation Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_emulate"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Emulate packet decisions through nftables firewall rules"
// meta:input="IP address, protocol, port, direction"
// meta:output="JSON result with firewall decision"
// meta:depends="github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"strings"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// EmulateQuery represents the query parameters
type EmulateQuery struct {
	IP        string `json:"ip"`
	Protocol  string `json:"protocol,omitempty"`
	Port      string `json:"port,omitempty"`
	Direction string `json:"direction"`
	Family    string `json:"family"`
}

// EmulateReason contains the reason for the decision
type EmulateReason struct {
	Module       string `json:"module"`
	Source       string `json:"source"`
	ListType     string `json:"list_type"`
	MatchingCIDR string `json:"matching_cidr,omitempty"`
}

// EmulateNftables contains nftables-specific info
type EmulateNftables struct {
	Family string `json:"family"`
	Table  string `json:"table"`
	Chain  string `json:"chain"`
	SetName string `json:"set_name,omitempty"`
}

// EmulateResult represents the emulation result
type EmulateResult struct {
	Query       EmulateQuery      `json:"query"`
	Result      EmulateDecision   `json:"result"`
}

// EmulateDecision contains the decision details
type EmulateDecision struct {
	Decision    string           `json:"decision"`
	Reason      EmulateReason    `json:"reason"`
	Nftables    EmulateNftables  `json:"nftables"`
	Explanation string           `json:"explanation"`
}

// cmdEmulate implements the emulate command
// Usage: nftban-core emulate <ip> [protocol] [port] [direction]
func cmdEmulate(args []string, cfg *nftbanconf.Config) error {
	if len(args) < 1 {
		return fmt.Errorf("emulate command requires an IP address")
	}

	ip := args[0]
	protocol := ""
	port := ""
	direction := "in"

	if len(args) > 1 {
		protocol = args[1]
	}
	if len(args) > 2 {
		port = args[2]
	}
	if len(args) > 3 {
		direction = args[3]
	}

	result, err := emulatePacket(ip, protocol, port, direction)
	if err != nil {
		return err
	}

	// Output JSON
	jsonBytes, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("failed to marshal JSON: %w", err)
	}

	fmt.Println(string(jsonBytes))
	return nil
}

// emulatePacket performs the packet emulation logic
func emulatePacket(ipStr, proto, port, direction string) (*EmulateResult, error) {
	// Validate and normalize IP
	parsedIP := net.ParseIP(ipStr)
	if parsedIP == nil {
		return nil, fmt.Errorf("invalid IP address: %s", ipStr)
	}

	// Determine IP family
	family := "ip"
	familyDisplay := "ipv4"
	if parsedIP.To4() == nil {
		family = "ip6"
		familyDisplay = "ipv6"
	}

	// Map direction to chain
	chain := "input"
	switch direction {
	case "in", "input":
		chain = "input"
	case "out", "output":
		chain = "output"
	case "fwd", "forward":
		chain = "forward"
	}

	result := &EmulateResult{
		Query: EmulateQuery{
			IP:        ipStr,
			Protocol:  proto,
			Port:      port,
			Direction: direction,
			Family:    familyDisplay,
		},
		Result: EmulateDecision{
			Decision: "allow",
			Reason: EmulateReason{
				Module:   "default_policy",
				Source:   "no_match",
				ListType: "none",
			},
			Nftables: EmulateNftables{
				Family: family,
				Table:  "nftban",
				Chain:  chain,
			},
			Explanation: "No blocking rules matched. Traffic allowed by default chain policy or established connection tracking.",
		},
	}

	// 1. Check whitelist first
	whitelistSet := "whitelist_ipv4"
	if family == "ip6" {
		whitelistSet = "whitelist_ipv6"
	}

	if match, matchedCIDR := checkIPInSet(family, "nftban", whitelistSet, ipStr); match {
		result.Result.Decision = "allow"
		result.Result.Reason.Module = "whitelist"
		result.Result.Reason.Source = "manual"
		result.Result.Reason.ListType = whitelistSet
		result.Result.Reason.MatchingCIDR = matchedCIDR
		result.Result.Nftables.SetName = whitelistSet
		result.Result.Explanation = fmt.Sprintf("The address %s is part of %s, which is in the whitelist (trusted IPs).", ipStr, matchedCIDR)
		return result, nil
	}

	// 2. Check blacklist
	blacklistSet := "blacklist_ipv4"
	if family == "ip6" {
		blacklistSet = "blacklist_ipv6"
	}

	if match, matchedCIDR := checkIPInSet(family, "nftban", blacklistSet, ipStr); match {
		result.Result.Decision = "block"
		result.Result.Reason.Module = "blacklist"
		result.Result.Reason.Source = "unified_blacklist"
		result.Result.Reason.ListType = blacklistSet
		result.Result.Reason.MatchingCIDR = matchedCIDR
		result.Result.Nftables.SetName = blacklistSet
		result.Result.Explanation = fmt.Sprintf("The address %s is part of %s, which is in the unified blacklist.", ipStr, matchedCIDR)
		return result, nil
	}

	// 3. Default: allow
	return result, nil
}

// nftListSet runs nft list set and returns the output
func nftListSet(family, table, setName string) (string, error) {
	tableSpec := family + " " + table
	cmd := exec.Command("nft", "list", "set", tableSpec, setName)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

// checkIPInSet checks if an IP is in a specific nft set
// Returns (match bool, matching_cidr string)
func checkIPInSet(family, table, setName, ipStr string) (bool, string) {
	// Query nftables set (READ operation via nft CLI)
	output, err := nftListSet(family, table, setName)
	if err != nil {
		// Set doesn't exist or error querying
		return false, ""
	}

	// Parse set elements
	elements := parseSetElements(output)

	// Parse the query IP
	queryIP := net.ParseIP(ipStr)
	if queryIP == nil {
		return false, ""
	}

	// Check each element for match
	// Track best (most specific) match
	var bestMatch string
	bestPrefix := -1

	for _, elem := range elements {
		// Clean element (remove timeout info, whitespace)
		elem = cleanElement(elem)
		if elem == "" {
			continue
		}

		// Check for exact IP match
		if elem == ipStr {
			return true, elem
		}

		// Check for CIDR match
		if strings.Contains(elem, "/") {
			_, cidrNet, err := net.ParseCIDR(elem)
			if err != nil {
				continue
			}

			if cidrNet.Contains(queryIP) {
				// Get prefix length
				prefixLen, _ := cidrNet.Mask.Size()

				// Keep most specific (largest prefix) match
				if prefixLen > bestPrefix {
					bestPrefix = prefixLen
					bestMatch = elem
				}
			}
		} else {
			// Single IP (no CIDR notation)
			elemIP := net.ParseIP(elem)
			if elemIP != nil && elemIP.Equal(queryIP) {
				return true, elem
			}
		}
	}

	if bestMatch != "" {
		return true, bestMatch
	}

	return false, ""
}

// parseSetElements extracts elements from nft list set output
// Example input:
//   table ip nftban {
//     set blacklist_ipv4 {
//       type ipv4_addr
//       flags interval
//       elements = { 1.2.3.4, 10.0.0.0/8, 192.168.1.100 timeout 3600s }
//     }
//   }
func parseSetElements(nftOutput string) []string {
	var elements []string

	// Find elements section
	lines := strings.Split(nftOutput, "\n")
	inElements := false

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)

		// Start of elements section
		if strings.HasPrefix(trimmed, "elements = {") {
			inElements = true
			// Extract any elements on the same line
			content := strings.TrimPrefix(trimmed, "elements = {")
			content = strings.TrimSuffix(content, "}")
			if content != "" {
				parseElementsLine(content, &elements)
			}
			continue
		}

		// Inside elements section
		if inElements {
			// End of elements section
			if strings.Contains(trimmed, "}") {
				// Get content before closing brace
				content := strings.Split(trimmed, "}")[0]
				if content != "" {
					parseElementsLine(content, &elements)
				}
				break
			}

			// Parse this line's elements
			parseElementsLine(trimmed, &elements)
		}
	}

	return elements
}

// parseElementsLine parses a single line of elements (comma-separated)
func parseElementsLine(line string, elements *[]string) {
	// Split by comma
	parts := strings.Split(line, ",")
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			*elements = append(*elements, part)
		}
	}
}

// cleanElement removes timeout info and whitespace from an element
// Example: "192.168.1.1 timeout 3600s" -> "192.168.1.1"
func cleanElement(elem string) string {
	// Remove timeout suffix
	if idx := strings.Index(elem, " timeout"); idx != -1 {
		elem = elem[:idx]
	}

	// Remove all whitespace
	elem = strings.TrimSpace(elem)
	elem = strings.ReplaceAll(elem, " ", "")
	elem = strings.ReplaceAll(elem, "\t", "")

	return elem
}
