// meta:name="failed_unit_remediation.go"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 4: structured, per-unit DEGRADED remediation renderer for the Go installer. Consumes install_state SERVICES_FAILED + attribution (no FAILURE_REASON prose parsing, no hardcoded nftban-botscan.service). Renders the exact failed unit(s) with pre-existence attribution and reset-failed/start/status steps; a safe diagnostic fallback when the structured list is unexpectedly unavailable. Only injection-safe canonical nftban unit names are ever embedded in a command."
package main

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/validate"
)

func splitUnits(csv string) []string {
	var out []string
	for _, u := range strings.Split(csv, ",") {
		u = strings.TrimSpace(u)
		if u != "" && validate.SafeNftbanUnitName(u) {
			out = append(out, u)
		}
	}
	return out
}

// renderFailedUnitRemediation prints per-unit remediation from the structured
// install_state. NO hardcoded unit. Safe fallback if the list is unavailable.
func renderFailedUnitRemediation(sf *state.StateFile, log *logging.Logger) {
	units := splitUnits(sf.ServicesFailed)
	pre := splitUnits(sf.ServicesFailedPreexisting)

	if len(units) == 0 {
		// The assertion said a unit failed but the structured list is unavailable
		// (e.g. an old installer wrote no SERVICES_FAILED). Do NOT guess a unit.
		log.Result("[NFTBan] A failed NFTBan unit was detected, but the structured failed-unit list is unavailable.")
		log.Result("[NFTBan] Do not run a guessed reset command. Inspect:")
		log.Result("[NFTBan]   systemctl --failed 'nftban-*'")
		log.Result("[NFTBan]   nftban support")
		return
	}

	preSet := map[string]bool{}
	for _, p := range pre {
		preSet[p] = true
	}
	for _, u := range units {
		predates := "NO"
		class := validate.AttrNewFailed
		if preSet[u] {
			predates = "YES"
			class = validate.AttrPreexistingFailed
		}
		log.Result("[NFTBan] Failed unit: %s", u)
		log.Result("[NFTBan]   Failure classification: %s", class)
		log.Result("[NFTBan]   Failure predates this upgrade: %s", predates)
		if predates == "YES" {
			log.Result("[NFTBan]   To clear the confirmed stale latch:")
			log.Result("[NFTBan]     systemctl reset-failed %s", u)
		}
		log.Result("[NFTBan]   To execute and verify:")
		log.Result("[NFTBan]     systemctl start %s", u)
		log.Result("[NFTBan]     systemctl status %s --no-pager", u)
	}
}
