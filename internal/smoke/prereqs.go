// =============================================================================
// NFTBan - Smoke Framework: Prerequisite Evaluators
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="smoke-prereqs"
// meta:type="package"
// meta:version="1.95.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Reusable prerequisite checks for module-gated smoke tests"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package smoke

import (
	"bufio"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Prerequisite types
const (
	PrereqBinary         = "binary"
	PrereqFile           = "file"
	PrereqSystemd        = "systemd"
	PrereqDaemonRunning  = "daemon_running"
	PrereqModuleEnabled  = "module_enabled"
	PrereqHTTPEndpoint   = "http_endpoint"
	PrereqValidatorBin   = "validator_present"
	PrereqConfigKey      = "config_key"
	PrereqNFTBinary      = "nft_binary"
)

// CheckPrerequisite evaluates a single prerequisite.
// Returns true if met, false if not (test should SKIP).
func CheckPrerequisite(p Prerequisite) bool {
	switch p.Type {
	case PrereqBinary, PrereqValidatorBin, PrereqNFTBinary:
		_, err := exec.LookPath(p.Name)
		return err == nil

	case PrereqFile:
		_, err := os.Stat(p.Name)
		return err == nil

	case PrereqSystemd:
		_, err := exec.LookPath("systemctl")
		return err == nil

	case PrereqDaemonRunning:
		out, err := exec.Command("systemctl", "is-active", p.Name).Output()
		return err == nil && strings.TrimSpace(string(out)) == "active"

	case PrereqModuleEnabled:
		return isModuleEnabled(p.Name)

	case PrereqHTTPEndpoint:
		return isHTTPReachable(p.Name)

	case PrereqConfigKey:
		return configKeyExists(p.Name)

	default:
		return true
	}
}

// CheckAllPrerequisites evaluates all prerequisites for a test.
// Returns the first unmet prerequisite name, or "" if all met.
func CheckAllPrerequisites(prereqs []Prerequisite) (bool, string) {
	for _, p := range prereqs {
		if !CheckPrerequisite(p) {
			return false, p.Type + ":" + p.Name
		}
	}
	return true, ""
}

func isModuleEnabled(module string) bool {
	// Check main module config files
	paths := []string{
		"/etc/nftban/conf.d/" + module + "/main.conf.local",
		"/etc/nftban/conf.d/" + module + "/main.conf",
		"/etc/nftban/modules/" + module + ".conf.local",
		"/etc/nftban/modules/" + module + ".conf",
	}

	enableKeys := map[string]string{
		"ddos":     "DDOS_ENABLED",
		"portscan": "PORTSCAN_ENABLED",
		"botguard": "BOTGUARD_ENABLED",
		"loginmon": "LOGINMON_ENABLED",
		"login":    "LOGINMON_ENABLED",
		"suricata": "SURICATA_ENABLED",
	}

	key, ok := enableKeys[module]
	if !ok {
		return false
	}

	for _, p := range paths {
		val := readConfigValue(p, key)
		if val == "true" {
			return true
		}
	}
	return false
}

func readConfigValue(path, key string) string {
	f, err := os.Open(filepath.Clean(path)) // #nosec G304 -- paths from /etc/nftban/ (trusted config dir)
	if err != nil {
		return ""
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, key+"=") {
			val := strings.TrimPrefix(line, key+"=")
			return strings.Trim(val, "\"")
		}
	}
	return ""
}

func isHTTPReachable(url string) bool {
	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get(url) //lint:ignore G107 URL from trusted smoke registry
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == 200
}

func configKeyExists(keyPath string) bool {
	// keyPath format: "file:key" e.g. "/etc/nftban/nftban.conf:NFTBAN_ENABLED"
	parts := strings.SplitN(keyPath, ":", 2)
	if len(parts) != 2 {
		return false
	}
	val := readConfigValue(parts[0], parts[1])
	return val != ""
}
