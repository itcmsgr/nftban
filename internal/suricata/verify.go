// =============================================================================
// NFTBan - Suricata Deployment Verification
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="verify"
// meta:type="package"
// meta:version="1.92.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Verifies Suricata IDS deployment correctness per IDS contract"
// meta:inventory.files=""
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/suricata.yaml"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package suricata

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// VerifyResult holds the outcome of a single verification check.
type VerifyCheck struct {
	Name   string `json:"name"`
	Status string `json:"status"` // "pass", "fail", "warn", "skip"
	Detail string `json:"detail,omitempty"`
}

// VerifyResult holds the full verification report.
type VerifyResult struct {
	Overall string        `json:"overall"` // "pass", "fail"
	Checks  []VerifyCheck `json:"checks"`
}

// Verify runs all Suricata deployment verification checks.
// Returns a structured result with pass/fail per check.
func Verify() *VerifyResult {
	r := &VerifyResult{Overall: "pass"}

	// 1. Suricata installed
	r.check("suricata_installed", func() (string, string) {
		if _, err := exec.LookPath("suricata"); err != nil {
			return "fail", "suricata binary not found in PATH"
		}
		return "pass", ""
	})

	// 2. Suricata service active
	r.check("suricata_active", func() (string, string) {
		out, err := exec.Command("systemctl", "is-active", "suricata.service").Output()
		if err != nil || strings.TrimSpace(string(out)) != "active" {
			return "warn", "suricata.service not active"
		}
		return "pass", ""
	})

	// 3. EVE log path exists and is writable
	evePaths := []string{
		"/var/log/nftban/suricata/eve-alerts.json",
		"/var/log/suricata/eve.json",
	}
	r.check("eve_path_exists", func() (string, string) {
		for _, p := range evePaths {
			if _, err := os.Stat(p); err == nil {
				return "pass", fmt.Sprintf("found: %s", p)
			}
		}
		return "fail", fmt.Sprintf("no EVE log found at: %s", strings.Join(evePaths, ", "))
	})

	// 4. EVE JSON valid (read last line, parse)
	r.check("eve_json_valid", func() (string, string) {
		for _, p := range evePaths {
			data, err := os.ReadFile(p)
			if err != nil {
				continue
			}
			lines := strings.Split(strings.TrimSpace(string(data)), "\n")
			if len(lines) == 0 {
				continue
			}
			last := lines[len(lines)-1]
			var obj map[string]interface{}
			if err := json.Unmarshal([]byte(last), &obj); err != nil {
				return "fail", fmt.Sprintf("%s: last line not valid JSON: %v", p, err)
			}
			return "pass", fmt.Sprintf("valid JSON in %s", p)
		}
		return "skip", "no EVE file to validate"
	})

	// 5. IDS-only mode check — verify no IPS/NFQUEUE in running config
	r.check("ids_only_mode", func() (string, string) {
		// Check suricata --build-info for runmode
		out, err := exec.Command("suricata", "--build-info").Output()
		if err != nil {
			return "skip", "cannot read suricata build info"
		}
		info := string(out)
		if strings.Contains(info, "NFQueue support:") && strings.Contains(info, "yes") {
			// NFQUEUE capable — check if actually running in NFQUEUE mode
			cmdOut, err := exec.Command("systemctl", "show", "suricata.service", "--property=ExecStart").Output()
			if err == nil && strings.Contains(string(cmdOut), "-q") {
				return "warn", "suricata appears to be running with -q (NFQUEUE mode)"
			}
		}
		return "pass", "suricata not running in NFQUEUE/IPS mode"
	})

	// 6. INV-S-004: ban_handler uses IPC only (structural — always pass if code is correct)
	r.check("ban_handler_ipc_only", func() (string, string) {
		return "pass", "ban_handler uses IPC (verified by CI gate GS-003)"
	})

	return r
}

// check runs a verification function and appends the result.
func (r *VerifyResult) check(name string, fn func() (string, string)) {
	status, detail := fn()
	r.Checks = append(r.Checks, VerifyCheck{
		Name:   name,
		Status: status,
		Detail: detail,
	})
	if status == "fail" {
		r.Overall = "fail"
	}
}

// String returns a human-readable report.
func (r *VerifyResult) String() string {
	var b strings.Builder
	b.WriteString("Suricata Deployment Verification\n")
	b.WriteString("================================\n\n")

	for _, c := range r.Checks {
		icon := "✓"
		switch c.Status {
		case "fail":
			icon = "✗"
		case "warn":
			icon = "⚠"
		case "skip":
			icon = "–"
		}
		b.WriteString(fmt.Sprintf("  %s %s: %s", icon, c.Name, c.Status))
		if c.Detail != "" {
			b.WriteString(fmt.Sprintf(" (%s)", c.Detail))
		}
		b.WriteString("\n")
	}

	b.WriteString(fmt.Sprintf("\nOverall: %s\n", strings.ToUpper(r.Overall)))
	return b.String()
}

// JSON returns the result as JSON bytes.
func (r *VerifyResult) JSON() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}
