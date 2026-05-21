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
//
// Backward-compat single-port entry point. v1.125 R-1 multi-port-aware
// callers should use RenderNftablesConfMultiPort which renders all detected
// SSH listener ports into the tcp_ports_in allow-set (closes the
// dns2-class lockout vector for hosts with sshd on multiple ports).
func RenderNftablesConf(exec executor.Executor, sshPort int, ct detect.CTLimits, log *logging.Logger) error {
	return RenderNftablesConfMultiPort(exec, []int{sshPort}, ct, log)
}

// RenderNftablesConfMultiPort renders nftables.conf with multi-port SSH
// allow-set support (v1.125 R-1 — closes the dns2-class lockout vector
// where a host listens on multiple SSH ports, e.g. :22 + :55000, but the
// installer rendered only the first detected port into the firewall).
//
// sshPorts[0] is the PRIMARY port used for the `__SSH_PORT__` template
// substitution (per-IP rate-limit rule and other single-port references
// in the template stay byte-identical to the v1.124 behavior for
// single-port hosts). All ports in sshPorts (primary AND any additional)
// are injected into the rendered tcp_ports_in allow-set so the firewall
// admits SSH on every detected port.
//
// When len(sshPorts) == 1 this is semantically identical to the pre-v1.125
// single-port render path. The single-port RenderNftablesConf is preserved
// as a thin wrapper around this function for backward compatibility with
// existing callers.
func RenderNftablesConfMultiPort(exec executor.Executor, sshPorts []int, ct detect.CTLimits, log *logging.Logger) error {
	if len(sshPorts) == 0 {
		return fmt.Errorf("RenderNftablesConfMultiPort: sshPorts is empty (primary port required)")
	}
	primary := sshPorts[0]

	data, err := exec.ReadFile(nftbanConf)
	if err != nil {
		return fmt.Errorf("read %s: %w", nftbanConf, err)
	}

	content := string(data)
	original := content

	// Substitute placeholders. __SSH_PORT__ uses the PRIMARY port — the
	// per-IP rate-limit rule and other single-port references in the
	// template stay byte-identical to v1.124 behavior for single-port
	// hosts. For multi-port hosts, the allow-set carries every port (via
	// ensureSSHPortInTcpPortsIn below) but per-port rate-limit semantics
	// for additional ports are deferred to V125 stretch / V126+.
	content = strings.ReplaceAll(content, "__SSH_PORT__", strconv.Itoa(primary))
	content = strings.ReplaceAll(content, "__CT_LIMIT_SSH__", strconv.Itoa(ct.SSH))
	content = strings.ReplaceAll(content, "__CT_LIMIT_HTTP__", strconv.Itoa(ct.HTTP))
	content = strings.ReplaceAll(content, "__CT_LIMIT_MAIL__", strconv.Itoa(ct.Mail))

	// Check for unrendered placeholders
	for _, ph := range placeholders {
		if strings.Contains(content, ph) {
			return fmt.Errorf("unrendered placeholder %s in %s", ph, nftbanConf)
		}
	}

	// V121 — D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001 (single-port baseline):
	// Ensure the SSH port reaches the rendered nftables.conf tcp_ports_in set.
	// Templates that lack a __SSH_PORT__ placeholder (older v1.x templates,
	// custom operator-edited templates) previously left the rendered config
	// without the SSH port — the kernel set still got the port from
	// downstream conf.d/ports.d merges, but the durable config drifted from
	// the kernel state.
	//
	// V125 R-1 extension — multi-port: inject every detected SSH listener
	// port (primary AND additional) into the tcp_ports_in elements list, so
	// operators connecting on any of the host's sshd listener ports survive
	// a firewall reload. ensureSSHPortInTcpPortsIn is idempotent and
	// safe-to-call-repeatedly: if a port is already present (e.g., from
	// __SSH_PORT__ substitution above for the primary), the helper is a
	// no-op for that port.
	for _, port := range sshPorts {
		content = ensureSSHPortInTcpPortsIn(content, port, log)
	}

	// Final sanity check (warning only — injection above should have made
	// this pass, but a malformed template without any tcp_ports_in set
	// would still log a warning).
	for _, port := range sshPorts {
		portStr := strconv.Itoa(port)
		if !strings.Contains(content, portStr) {
			log.Warn("SSH port %d still not present in rendered nftables.conf after V121/V125-R1 injection — template may lack a tcp_ports_in set entirely", port)
		}
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

	if len(sshPorts) > 1 {
		extras := make([]string, 0, len(sshPorts)-1)
		for _, p := range sshPorts[1:] {
			extras = append(extras, strconv.Itoa(p))
		}
		log.Info("rendered nftables.conf (SSH primary=%d, additional=%s, CT: ssh=%d http=%d mail=%d) — V125 R-1 multi-port allow-set",
			primary, strings.Join(extras, ","), ct.SSH, ct.HTTP, ct.Mail)
	} else {
		log.Info("rendered nftables.conf (SSH=%d, CT: ssh=%d http=%d mail=%d)", primary, ct.SSH, ct.HTTP, ct.Mail)
	}
	return nil
}

// ensureSSHPortInTcpPortsIn guarantees the detected SSH port appears as a
// whole numeric token inside at least one `set tcp_ports_in { … elements = { … } … }`
// block in the rendered content. If the port is already present (as a comma-
// separated element token in any tcp_ports_in elements list), the function
// is a no-op. Otherwise, for each matched `tcp_ports_in` set block, it
// injects the port at the head of the elements list, preserving existing
// entries and formatting.
//
// V121 fix for D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001 — closes the gap where
// hosts using non-default SSH ports could end up with kernel-only safety
// (transient) instead of durable-config safety (survives reload/restart/
// reboot/update).
//
// v1.125 R-1 hardening: presence check is now strict (exact numeric token
// inside the parsed elements list), not a loose strings.Contains substring
// match. The pre-v1.125 substring check incorrectly treated port 22 as
// "present" when only 2222 (DirectAdmin control port) appeared anywhere in
// the content; on DA-class multi-port hosts this caused port 22 to silently
// not get injected. The new check parses the tcp_ports_in elements
// regex-match, splits on commas, and compares each trimmed token against
// the port literal — eliminating false-positive presence detection.
//
// Idempotent: calling on already-correct content returns content unchanged.
func ensureSSHPortInTcpPortsIn(content string, sshPort int, log *logging.Logger) string {
	portStr := strconv.Itoa(sshPort)

	// Strict presence check (v1.125 R-1 hardening): parse every
	// tcp_ports_in match's elements list and compare port as a whole
	// numeric token. Replaces the pre-v1.125 loose strings.Contains
	// check which was vulnerable to substring false positives (22 vs
	// 2222, 80 vs 8080, etc.).
	for _, match := range tcpPortsInElementsRe.FindAllStringSubmatch(content, -1) {
		if len(match) < 4 {
			continue
		}
		for _, tok := range strings.Split(match[2], ",") {
			if strings.TrimSpace(tok) == portStr {
				return content
			}
		}
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
