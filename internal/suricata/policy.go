// =============================================================================
// NFTBan - Suricata User Policy Layer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="policy"
// meta:type="package"
// meta:version="1.92.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Loads detection.conf + actions.conf user policy for Suricata alerts"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/modules/detection.conf,/etc/nftban/modules/actions.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import (
	"bufio"
	"os"
	"strings"
	"time"
)

// Policy holds the user-defined detection and action settings.
// Loaded from detection.conf + actions.conf (INV-S-006: user owns policy).
type Policy struct {
	// Detection toggles — which categories NFTBan processes
	Detection map[string]bool

	// Action mapping — what NFTBan does per category
	Actions map[string]string

	// Ban durations
	BanShortDuration  time.Duration
	BanLongDuration   time.Duration
}

// DefaultPolicy returns sensible defaults matching the shipped config files.
func DefaultPolicy() *Policy {
	return &Policy{
		Detection: map[string]bool{
			"ssh_bruteforce": true,
			"auth_bypass":    true,
			"portscan":       true,
			"ddos":           true,
			"web_attacks":    true,
			"sqli":           true,
			"xss":            false,
			"exploit":        true,
			"rce":            true,
			"malware":        false,
			"c2":             false,
			"info_leak":      false,
			"policy":         false,
		},
		Actions: map[string]string{
			"ssh_bruteforce": "ban_long",
			"auth_bypass":    "ban_permanent",
			"portscan":       "ban_short",
			"ddos":           "ban_long",
			"web_attacks":    "ban_short",
			"sqli":           "ban_long",
			"xss":            "observe",
			"exploit":        "ban_long",
			"rce":            "ban_permanent",
			"malware":        "ban_permanent",
			"c2":             "ban_permanent",
			"info_leak":      "observe",
			"policy":         "observe",
		},
		BanShortDuration: 1 * time.Hour,
		BanLongDuration:  24 * time.Hour,
	}
}

// LoadPolicy reads detection.conf and actions.conf from the given directory.
// Falls back to defaults for any missing values.
func LoadPolicy(configDir string) *Policy {
	p := DefaultPolicy()

	// Load detection.conf (then .local override)
	loadConfFile(configDir+"/detection.conf", func(key, val string) {
		cat := strings.TrimPrefix(strings.ToLower(key), "detect_")
		p.Detection[cat] = (val == "true")
	})
	loadConfFile(configDir+"/detection.conf.local", func(key, val string) {
		cat := strings.TrimPrefix(strings.ToLower(key), "detect_")
		p.Detection[cat] = (val == "true")
	})

	// Load actions.conf (then .local override)
	loadConfFile(configDir+"/actions.conf", func(key, val string) {
		lower := strings.ToLower(key)
		if strings.HasPrefix(lower, "action_") {
			cat := strings.TrimPrefix(lower, "action_")
			p.Actions[cat] = val
		}
	})
	loadConfFile(configDir+"/actions.conf.local", func(key, val string) {
		lower := strings.ToLower(key)
		if strings.HasPrefix(lower, "action_") {
			cat := strings.TrimPrefix(lower, "action_")
			p.Actions[cat] = val
		}
	})

	return p
}

// IsDetectionEnabled checks if a category is enabled for processing.
func (p *Policy) IsDetectionEnabled(category string) bool {
	enabled, ok := p.Detection[strings.ToLower(category)]
	return ok && enabled
}

// GetAction returns the configured action for a category.
// Returns "observe" if category not found.
func (p *Policy) GetAction(category string) string {
	action, ok := p.Actions[strings.ToLower(category)]
	if !ok {
		return "observe"
	}
	return action
}

// GetBanDuration returns the duration for a ban action type.
func (p *Policy) GetBanDuration(action string) time.Duration {
	switch action {
	case "ban_short":
		return p.BanShortDuration
	case "ban_long":
		return p.BanLongDuration
	case "ban_permanent":
		return 0 // no TTL
	default:
		return 0
	}
}

// loadConfFile reads a bash-style KEY="value" config file.
func loadConfFile(path string, handler func(key, val string)) {
	f, err := os.Open(path)
	if err != nil {
		return // file doesn't exist — use defaults
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.TrimSpace(parts[0])
		val := strings.Trim(strings.TrimSpace(parts[1]), "\"")
		handler(key, val)
	}
}
