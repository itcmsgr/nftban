// SPDX-License-Identifier: MPL-2.0
// meta:name="failed_units.go"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 4: injection-safe canonical normalization of the FATAL failed-unit set for structured propagation into install_state SERVICES_FAILED. Accepts only approved nftban systemd unit names (IsNftbanUnit + a strict charset), dedupes, sorts deterministically, and buckets by pre-existence attribution. The result is the single source of truth for the installer + update remediation renderers — no FAILURE_REASON prose parsing, no hardcoded unit."
package validate

import (
	"regexp"
	"sort"
	"strings"
)

// safeUnitRe bounds a systemd unit name to a safe charset — no whitespace, no
// shell metacharacters, no path separators, no newlines. Combined with
// IsNftbanUnit this rejects arbitrary/malicious strings before any name can be
// embedded into an operator-facing command.
var safeUnitRe = regexp.MustCompile(`^[A-Za-z0-9@._-]+$`)

// SafeNftbanUnitName reports whether name is an approved, injection-safe nftban
// systemd unit name.
func SafeNftbanUnitName(name string) bool {
	name = strings.TrimSpace(name)
	return name != "" && len(name) <= 128 && safeUnitRe.MatchString(name) && IsNftbanUnit(name)
}

// Attribution classifications surfaced to operators (v1.222.1 Lane 4).
const (
	AttrNewFailed          = "NEW_FAILED_UNIT"
	AttrPreexistingFailed  = "PREEXISTING_STILL_FAILED"
	AttrFailureTimeUnknown = "FAILURE_TIME_UNKNOWN"
)

// NormalizeFailedUnits returns the canonical, deduplicated, deterministically
// sorted fatal nftban unit names, plus pre-existing and in-window buckets for
// attribution. Only approved nftban unit names survive (injection-safe); anything
// else is dropped. Classification "PRE_EXISTING_FATAL" → pre-existing; otherwise
// in-window (new). Order is preserved across multiple units.
func NormalizeFailedUnits(units []FailedUnitPostInstall) (all, preexisting, inWindow []string) {
	seen := map[string]bool{}
	for _, u := range units {
		name := strings.TrimSpace(u.Unit)
		if !SafeNftbanUnitName(name) || seen[name] {
			continue
		}
		seen[name] = true
		all = append(all, name)
		if u.Classification == "PRE_EXISTING_FATAL" {
			preexisting = append(preexisting, name)
		} else {
			inWindow = append(inWindow, name)
		}
	}
	sort.Strings(all)
	sort.Strings(preexisting)
	sort.Strings(inWindow)
	return all, preexisting, inWindow
}

// AttributionFor returns the operator-facing attribution label for a unit given
// the pre-existing set (from NormalizeFailedUnits).
func AttributionFor(unit string, preexisting []string) string {
	for _, p := range preexisting {
		if p == unit {
			return AttrPreexistingFailed
		}
	}
	return AttrNewFailed
}
