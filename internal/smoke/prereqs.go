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
	"encoding/json"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
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
	case PrereqBinary, PrereqNFTBinary:
		_, err := exec.LookPath(p.Name)
		return err == nil

	case PrereqValidatorBin:
		// Validator binary is at a fixed path (not in PATH).
		// Check file existence instead of LookPath.
		_, err := os.Stat(p.Name)
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

// =============================================================================
// Module-enabled detection — validator-backed with config fallback
// =============================================================================
// Primary: ask validator (single source of truth for module config state).
// Fallback: parse config files directly (only when validator binary is missing).
// This ensures smoke prerequisites agree with `nftban health --json` exactly.

var (
	validatorModuleStates    map[string]string
	validatorModuleStatesErr error
	validatorModuleOnce      sync.Once
)

// loadModuleStatesFromValidator calls the validator binary once and caches
// the module config states. Called at most once via sync.Once.
func loadModuleStatesFromValidator() {
	out, err := exec.Command(constants.ValidatorBinPath, "--json").Output() //lint:ignore G204 fixed binary path from constants
	if err != nil {
		validatorModuleStatesErr = err
		return
	}

	var result struct {
		Modules map[string]struct {
			Config string `json:"config"`
		} `json:"modules"`
	}

	if err := json.Unmarshal(out, &result); err != nil {
		validatorModuleStatesErr = err
		return
	}

	validatorModuleStates = make(map[string]string, len(result.Modules))
	for k, v := range result.Modules {
		validatorModuleStates[k] = v.Config
	}
}

// normalizeModuleName maps CLI module names to validator module names.
func normalizeModuleName(module string) string {
	switch module {
	case "login":
		return "loginmon"
	default:
		return module
	}
}

func isModuleEnabled(module string) bool {
	validatorModuleOnce.Do(loadModuleStatesFromValidator)

	if validatorModuleStatesErr != nil {
		// Validator unavailable — fall back to config file parsing
		return isModuleEnabledFromConfig(module)
	}

	moduleKey := normalizeModuleName(module)
	state, ok := validatorModuleStates[moduleKey]
	if !ok {
		return false
	}
	return state == "enabled"
}

// isModuleEnabledFromConfig is the fallback when validator binary is missing.
// Config keys and paths MUST match validator/module_health.go exactly.
// Source of truth: internal/validator/module_health.go
type moduleConfig struct {
	key   string   // config key name (e.g. "HTTP_BOTGUARD_ENABLED")
	paths []string // config file paths, .local first (higher priority)
}

var moduleConfigs = map[string]moduleConfig{
	// module_health.go:173
	"ddos": {key: "DDOS_ENABLED", paths: []string{
		"/etc/nftban/conf.d/ddos/main.conf.local",
		"/etc/nftban/conf.d/ddos/main.conf",
	}},
	// module_health.go:243
	"portscan": {key: "PORTSCAN_ENABLED", paths: []string{
		"/etc/nftban/conf.d/portscan/main.conf.local",
		"/etc/nftban/conf.d/portscan/main.conf",
	}},
	// module_health.go:63
	"botguard": {key: "HTTP_BOTGUARD_ENABLED", paths: []string{
		"/etc/nftban/conf.d/botguard/main.conf.local",
		"/etc/nftban/conf.d/botguard/main.conf",
	}},
	// module_health.go:271
	"loginmon": {key: "NFTBAN_LOGIN_ALERT_ENABLED", paths: []string{
		"/etc/nftban/conf.d/login_alert.conf.local",
		"/etc/nftban/conf.d/login_alert.conf",
	}},
	"login": {key: "NFTBAN_LOGIN_ALERT_ENABLED", paths: []string{
		"/etc/nftban/conf.d/login_alert.conf.local",
		"/etc/nftban/conf.d/login_alert.conf",
	}},
	"suricata": {key: "SURICATA_ENABLED", paths: []string{
		"/etc/nftban/conf.d/suricata/main.conf.local",
		"/etc/nftban/conf.d/suricata/main.conf",
	}},
}

func isModuleEnabledFromConfig(module string) bool {
	cfg, ok := moduleConfigs[normalizeModuleName(module)]
	if !ok {
		// Also try the original name (covers direct matches like "ddos")
		cfg, ok = moduleConfigs[module]
		if !ok {
			return false
		}
	}

	for _, p := range cfg.paths {
		val := readConfigValue(p, cfg.key)
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
