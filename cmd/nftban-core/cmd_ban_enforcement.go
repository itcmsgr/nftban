// =============================================================================
// NFTBan - cmd_ban_enforcement (v1.228.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_ban_enforcement"
// meta:type="package"
// meta:version="1.228.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Ban outcome contract: ENFORCED / RECORDED_NOT_ENFORCED / VERIFICATION_FAILED. Only ENFORCED permits a success banner"
// meta:inventory.files=""
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/nftenforce"
	"github.com/itcmsgr/nftban/internal/procenv"
)

// banResultClass is the outcome contract for `nftban ban`.
//
// Before this existed, the command verified set membership and then printed
// "The IP is now blocked by the firewall" unconditionally. On a host whose
// filter chains never loaded, both happened together: the address really was in
// the set, and it really was not blocked. Membership is not enforcement.
//
// Exactly one class permits a success banner.
type banResultClass int

const (
	// banEnforced: member of the set AND the set is enforced. rc=0.
	banEnforced banResultClass = iota
	// banRecordedNotEnforced: the record exists but no packet is filtered by it.
	banRecordedNotEnforced
	// banVerificationFailed: enforcement could not be established either way.
	banVerificationFailed
)

// nftbanTable is the product table name in both the ip and ip6 families.
const nftbanTable = "nftban"

// evaluateBanEnforcement answers whether the ban is actually in force.
//
// It deliberately fails closed: any error reading or interpreting the ruleset
// yields banVerificationFailed, never an enforcement claim. Telling an operator
// "could not verify" is always safer than telling them "protected" and being
// wrong.
func evaluateBanEnforcement(setName string, isIPv4 bool) (banResultClass, string) {
	family := "ip"
	if !isIPv4 {
		family = "ip6"
	}

	out, err := procenv.Command("nft", "-j", "list", "ruleset").Output() // #nosec G204 -- fixed args
	if err != nil {
		return banVerificationFailed, fmt.Sprintf("cannot read the nftables ruleset: %v", err)
	}

	res := nftenforce.Evaluate(out, family, nftbanTable, setName)
	switch res.Outcome {
	case nftenforce.ReachableEnforcingPath:
		return banEnforced, res.Detail
	case nftenforce.NoSetReference, nftenforce.SetReferenceUnreachable, nftenforce.ReachableNonEnforcingPath:
		return banRecordedNotEnforced, res.Detail
	default: // AmbiguousRuleset, ParserFailure, and anything added later
		return banVerificationFailed, res.Detail
	}
}

// reportBanNotEnforced prints the honest outcome for a ban that was recorded but
// is not in force, and returns the error the caller must propagate.
//
// No success banner, and no "blocked"/"protected" wording, appears on this path.
// A warning followed by a success banner is exactly the defect this replaces.
func reportBanNotEnforced(ip, setName, detail string, class banResultClass) error {
	fmt.Println(strings.Repeat("=", 70))
	switch class {
	case banRecordedNotEnforced:
		fmt.Printf("⚠️  IP %s was RECORDED but is NOT ENFORCED\n", ip)
		fmt.Println()
		fmt.Printf("  The address is present in %s, but that set is not applied to traffic:\n", setName)
		fmt.Printf("  %s\n", detail)
		fmt.Println()
		fmt.Println("  The firewall chain is inactive or unhooked. Packets from this address")
		fmt.Println("  are NOT being filtered. Run 'nftban validate' and 'nftban health' to")
		fmt.Println("  see why the firewall is not active.")
		fmt.Println()
		return fmt.Errorf("ban recorded in %s but not enforced: %s", setName, detail)
	default:
		fmt.Printf("⚠️  IP %s: ENFORCEMENT COULD NOT BE VERIFIED\n", ip)
		fmt.Println()
		fmt.Printf("  %s\n", detail)
		fmt.Println()
		fmt.Println("  The ban may or may not be in force. Do not rely on it until")
		fmt.Println("  'nftban validate' reports the firewall as active.")
		fmt.Println()
		return fmt.Errorf("ban enforcement verification failed for %s: %s", ip, detail)
	}
}
