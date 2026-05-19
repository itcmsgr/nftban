// =============================================================================
// NFTBan v1.73 - Installer nftables.conf Rendering
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-nftables"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Template rendering + nft syntax validation for nftables.conf"
// meta:inventory.files="internal/installer/render/nftables.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftables.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package render

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const nftbanConf = "/etc/nftban/nftables.conf"

// placeholders that must be rendered before nft validation.
var placeholders = []string{
	"__SSH_PORT__",
	"__CT_LIMIT_SSH__",
	"__CT_LIMIT_HTTP__",
	"__CT_LIMIT_MAIL__",
}

// tcpPortsInElementsRe matches the `elements = { … }` line inside a
// `set tcp_ports_in { … }` block. Group 1 is "elements = {", group 2 is the
// inner comma-separated port list (possibly multi-line), group 3 is "}". Used
// by ensureSSHPortInTcpPortsIn to inject the detected SSH port when the
// template doesn't carry it via __SSH_PORT__ substitution. V121 fix for
// D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001.
var tcpPortsInElementsRe = regexp.MustCompile(`(?s)(set tcp_ports_in \{[^{}]*elements = \{)([^}]*)(\})`)

// RenderNftablesConf reads the nftables.conf template, substitutes placeholders,
// validates syntax, and writes back atomically.
func RenderNftablesConf(exec executor.Executor, sshPort int, ct detect.CTLimits, log *logging.Logger) error {
	data, err := exec.ReadFile(nftbanConf)
	if err != nil {
		return fmt.Errorf("read %s: %w", nftbanConf, err)
	}

	content := string(data)
	original := content

	// Substitute placeholders
	content = strings.ReplaceAll(content, "__SSH_PORT__", strconv.Itoa(sshPort))
	content = strings.ReplaceAll(content, "__CT_LIMIT_SSH__", strconv.Itoa(ct.SSH))
	content = strings.ReplaceAll(content, "__CT_LIMIT_HTTP__", strconv.Itoa(ct.HTTP))
	content = strings.ReplaceAll(content, "__CT_LIMIT_MAIL__", strconv.Itoa(ct.Mail))

	// Check for unrendered placeholders
	for _, ph := range placeholders {
		if strings.Contains(content, ph) {
			return fmt.Errorf("unrendered placeholder %s in %s", ph, nftbanConf)
		}
	}

	// V121 — D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001:
	// Ensure the SSH port reaches the rendered nftables.conf tcp_ports_in set.
	// Templates that lack a __SSH_PORT__ placeholder (older v1.x templates,
	// custom operator-edited templates) previously left the rendered config
	// without the SSH port — the kernel set still got the port from
	// downstream conf.d/ports.d merges, but the durable config drifted from
	// the kernel state. Hosts using non-default SSH ports could lose SSH
	// access on the next firewall reload/restart/reboot if the rebuild
	// ever read only the rendered config.
	//
	// Two durable mechanisms produce a correct outcome (per
	// SRV2_V120_PREFLIGHT_CLOSURE.md §4 and V121 schema-impact decision §4):
	//   Mechanism A — template has `tcp_ports_in = { 22, … }` with the
	//                 SSH port explicitly listed (monitor pattern).
	//   Mechanism B — template uses `__SSH_PORT__` placeholder, substituted
	//                 above (srv2/lab2/lab4 default pattern).
	// If neither produces a rendered file containing the SSH port, this
	// helper INJECTS the port into the tcp_ports_in elements list so the
	// rendered file is durable on its own.
	content = ensureSSHPortInTcpPortsIn(content, sshPort, log)

	// Final sanity check (warning only — injection above should have made
	// this pass, but a malformed template without any tcp_ports_in set
	// would still log a warning).
	portStr := strconv.Itoa(sshPort)
	if !strings.Contains(content, portStr) {
		log.Warn("SSH port %d still not present in rendered nftables.conf after V121 injection — template may lack a tcp_ports_in set entirely", sshPort)
	}

	// Skip write if content unchanged
	if content == original {
		log.Debug("nftables.conf unchanged after render (already rendered)")
		return nil
	}

	// Validate syntax with nft -c -f
	if err := exec.NftCheck(content); err != nil {
		return fmt.Errorf("nft syntax validation failed: %w", err)
	}

	// Atomic write
	if err := exec.WriteFileAtomic(nftbanConf, []byte(content), 0640); err != nil {
		return fmt.Errorf("write %s: %w", nftbanConf, err)
	}

	log.Info("rendered nftables.conf (SSH=%d, CT: ssh=%d http=%d mail=%d)", sshPort, ct.SSH, ct.HTTP, ct.Mail)
	return nil
}

// ensureSSHPortInTcpPortsIn guarantees the detected SSH port appears inside
// every `set tcp_ports_in { … elements = { … } … }` block in the rendered
// content. If the port is already present anywhere in the content, the
// function is a no-op (avoids duplicate injection). Otherwise, for each
// matched `tcp_ports_in` set block, it injects the port at the head of the
// elements list, preserving existing entries and formatting.
//
// V121 fix for D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001 — closes the gap where
// hosts using non-default SSH ports could end up with kernel-only safety
// (transient) instead of durable-config safety (survives reload/restart/
// reboot/update).
//
// Idempotent: calling on already-correct content returns content unchanged.
func ensureSSHPortInTcpPortsIn(content string, sshPort int, log *logging.Logger) string {
	portStr := strconv.Itoa(sshPort)

	// Fast-path exact-substring check — if the port number appears anywhere
	// in the content, assume it's already in the set(s) and skip injection.
	// This handles both Mechanism A (template hardcodes the port) and
	// Mechanism B (template uses __SSH_PORT__ which was substituted above).
	if strings.Contains(content, portStr) {
		return content
	}

	// Slow path: port is missing. Inject into every tcp_ports_in set.
	injections := 0
	out := tcpPortsInElementsRe.ReplaceAllStringFunc(content, func(match string) string {
		groups := tcpPortsInElementsRe.FindStringSubmatch(match)
		if len(groups) < 4 {
			return match
		}
		prefix, inner, suffix := groups[1], groups[2], groups[3]
		// Inject port at the head of the elements list.
		trimmedInner := strings.TrimSpace(inner)
		var newInner string
		if trimmedInner == "" {
			newInner = " " + portStr + " "
		} else {
			// Preserve original leading whitespace where possible.
			leadingWS := inner[:len(inner)-len(strings.TrimLeft(inner, " \t\n\r"))]
			if leadingWS == "" {
				leadingWS = " "
			}
			newInner = leadingWS + portStr + ", " + strings.TrimLeft(inner, " \t\n\r")
		}
		injections++
		return prefix + newInner + suffix
	})

	if injections > 0 {
		log.Info("V121 injected SSH port %d into %d tcp_ports_in set(s) in rendered nftables.conf (template did not carry the port via __SSH_PORT__ or hardcoded list)", sshPort, injections)
	}
	return out
}
