// =============================================================================
// NFTBan - Smoke Framework: Evidence-Aware Assertions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="smoke-assertions"
// meta:type="package"
// meta:version="1.95.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Contract-safe assertion helpers for smoke test evidence validation"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package smoke

import (
	"encoding/json"
	"strings"
)

// Assertion defines a named check on test output.
type Assertion struct {
	Name string
	Fn   func(TestOutput) bool
}

// AssertJSONValid checks that stdout is valid JSON.
func AssertJSONValid() Assertion {
	return Assertion{
		Name: "json_valid",
		Fn: func(o TestOutput) bool {
			var v interface{}
			return json.Unmarshal([]byte(o.Stdout), &v) == nil
		},
	}
}

// AssertJSONPathExists checks that a top-level key exists in JSON stdout.
func AssertJSONPathExists(key string) Assertion {
	return Assertion{
		Name: "json_path:" + key,
		Fn: func(o TestOutput) bool {
			var m map[string]interface{}
			if err := json.Unmarshal([]byte(o.Stdout), &m); err != nil {
				return false
			}
			_, ok := m[key]
			return ok
		},
	}
}

// AssertJSONPathEquals checks that a top-level JSON key has an expected string value.
func AssertJSONPathEquals(key, expected string) Assertion {
	return Assertion{
		Name: "json_equals:" + key + "=" + expected,
		Fn: func(o TestOutput) bool {
			var m map[string]interface{}
			if err := json.Unmarshal([]byte(o.Stdout), &m); err != nil {
				return false
			}
			val, ok := m[key]
			if !ok {
				return false
			}
			s, ok := val.(string)
			return ok && s == expected
		},
	}
}

// AssertOutputContains checks that stdout contains a substring.
func AssertOutputContains(s string) Assertion {
	return Assertion{
		Name: "contains:" + s,
		Fn: func(o TestOutput) bool {
			return strings.Contains(o.Stdout, s)
		},
	}
}

// AssertMetricFamiliesPresent checks that key metric families appear in /metrics output.
func AssertMetricFamiliesPresent(families []string) Assertion {
	return Assertion{
		Name: "metric_families_present",
		Fn: func(o TestOutput) bool {
			for _, f := range families {
				if !strings.Contains(o.Stdout, f) {
					return false
				}
			}
			return true
		},
	}
}

// AssertNoFatalPatterns checks output against fatal runtime patterns.
func AssertNoFatalPatterns(patterns []string) Assertion {
	return Assertion{
		Name: "no_fatal_patterns",
		Fn: func(o TestOutput) bool {
			combined := o.Stdout + o.Stderr
			for _, p := range patterns {
				if strings.Contains(combined, p) {
					return false
				}
			}
			return true
		},
	}
}

// RunAssertions evaluates a list of assertions against test output.
// Returns counts and the name of the first failed assertion (if any).
func RunAssertions(assertions []Assertion, output TestOutput) (passed, failed int, firstFailure string) {
	for _, a := range assertions {
		if a.Fn(output) {
			passed++
		} else {
			failed++
			if firstFailure == "" {
				firstFailure = a.Name
			}
		}
	}
	return
}
