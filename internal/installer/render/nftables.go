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

// portSetElementsRe holds the compiled `elements = { … }` matchers for the
// named port sets the renderer injects SSH ports into. Group 1 is
// "set <name> { … elements = {", group 2 is the inner comma-separated element
// list (possibly multi-line), group 3 is "}". Used by ensureSSHPortsInSet to
// inject a detected SSH port when the template does not already carry it.
//
// V121 introduced this for tcp_ports_in only (D-NONDEFAULT-SSH-PORT-CONFIG-
// DRIFT-001). v1.145 PR-A generalized it to any named port set so the SAME
// idempotent injector seeds BOTH tcp_ports_in (the allow-set) and ssh_ports
// (the set-driven brute-force rate-limit set, `tcp dport @ssh_ports ct count`)
// from the detected SSH listener ports — no duplicate placeholder machinery.
// The map is built once at init and only read afterwards (no concurrent
// writes), so it is safe for parallel renders/tests.
var portSetElementsRe = map[string]*regexp.Regexp{
	"tcp_ports_in": regexp.MustCompile(`(?s)(set tcp_ports_in \{[^{}]*elements = \{)([^}]*)(\})`),
	"ssh_ports":    regexp.MustCompile(`(?s)(set ssh_ports \{[^{}]*elements = \{)([^}]*)(\})`),
}

// portSetElementsReFor returns the compiled elements matcher for setName.
// Known sets (tcp_ports_in, ssh_ports) are precompiled; any other name is
// compiled on demand (QuoteMeta-guarded). Read-only access to the precompiled
// map keeps the common path race-free.
func portSetElementsReFor(setName string) *regexp.Regexp {
	if re, ok := portSetElementsRe[setName]; ok {
		return re
	}
	return regexp.MustCompile(`(?s)(set ` + regexp.QuoteMeta(setName) + ` \{[^{}]*elements = \{)([^}]*)(\})`)
}

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
	// hosts. For multi-port hosts, both port sets carry every port (via
	// ensureSSHPortsInSet below).
	//
	// v1.145 PR-A: the SSH ct-count brute-force rate-limit rule reads its
	// dport from @ssh_ports (set-driven) instead of the previously-hardcoded
	// __SSH_PORT__ literal. The templates seed `set ssh_ports` with
	// __SSH_PORT__ (the primary), and the ensureSSHPortsInSet loop below
	// injects every additional detected port into ssh_ports alongside
	// tcp_ports_in. This closes Gap 2 from the V1.145 audit: per-port
	// rate-limit semantics now cover every detected SSH port, and an atomic
	// set update can move the rate-limit dport without a full ruleset reload.
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
	// a firewall reload.
	//
	// v1.145 PR-A — set-driven SSH rate-limit: inject the SAME ports into the
	// ssh_ports set, which the input chain's brute-force ct-count rule reads
	// via `tcp dport @ssh_ports`. This keeps the rate-limit dport in parity
	// with the allow-set for every detected SSH port (the primary arrives via
	// the __SSH_PORT__ substitution above; additional ports are injected
	// here). ensureSSHPortsInSet is idempotent and safe-to-call-repeatedly:
	// if a port is already present in the target set, the helper is a no-op.
	for _, port := range sshPorts {
		content = ensureSSHPortsInSet(content, "tcp_ports_in", port, log)
		content = ensureSSHPortsInSet(content, "ssh_ports", port, log)
	}

	// v1.145 PR-A — normalize: guarantee each port set's elements list holds
	// every whole numeric token at most once. The strict presence check in
	// ensureSSHPortsInSet prevents the injector from ADDING a duplicate, but it
	// does NOT remove a duplicate introduced by __SSH_PORT__ substitution when a
	// detected SSH port coincides with a hardcoded service port in the template
	// (e.g. sshPorts=[80] → `elements = { 80, 80, 443 }`). nftables sets cannot
	// hold duplicate elements, so this pass collapses any such collision. It is
	// a no-op for the common case (SSH port distinct from 80/443/25/465/587).
	content = dedupePortSetElements(content, "tcp_ports_in", log)
	content = dedupePortSetElements(content, "ssh_ports", log)

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

// ensureSSHPortsInSet guarantees the detected SSH port appears as a whole
// numeric token inside at least one `set <setName> { … elements = { … } … }`
// block in the rendered content. If the port is already present (as a comma-
// separated element token in any matching elements list), the function is a
// no-op. Otherwise, for each matched set block, it injects the port at the
// head of the elements list, preserving existing entries and formatting.
//
// V121 introduced this as ensureSSHPortInTcpPortsIn (hardcoded to
// tcp_ports_in) to fix D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001 — closing the
// gap where hosts using non-default SSH ports could end up with kernel-only
// safety (transient) instead of durable-config safety (survives reload/
// restart/reboot/update).
//
// v1.145 PR-A generalized it to any named port set so the same idempotent
// injector seeds both tcp_ports_in (allow-set) and ssh_ports (set-driven
// brute-force rate-limit, `tcp dport @ssh_ports ct count`) without a second
// placeholder mechanism. setName MUST be one of the known port sets; the
// matcher is selected via portSetElementsReFor.
//
// v1.125 R-1 hardening (preserved): presence check is strict (exact numeric
// token inside the parsed elements list), not a loose strings.Contains
// substring match. The pre-v1.125 substring check incorrectly treated port
// 22 as "present" when only 2222 (DirectAdmin control port) appeared anywhere
// in the content; on DA-class multi-port hosts this caused port 22 to
// silently not get injected. The check parses the elements regex-match,
// splits on commas, and compares each trimmed token against the port literal
// — eliminating false-positive presence detection.
//
// Idempotent: calling on already-correct content returns content unchanged.
func ensureSSHPortsInSet(content string, setName string, sshPort int, log *logging.Logger) string {
	portStr := strconv.Itoa(sshPort)
	re := portSetElementsReFor(setName)

	// Strict presence check (v1.125 R-1 hardening): parse every match's
	// elements list and compare port as a whole numeric token. Avoids
	// substring false positives (22 vs 2222, 80 vs 8080, etc.).
	for _, match := range re.FindAllStringSubmatch(content, -1) {
		if len(match) < 4 {
			continue
		}
		for _, tok := range strings.Split(match[2], ",") {
			if strings.TrimSpace(tok) == portStr {
				return content
			}
		}
	}

	// Slow path: port is missing. Inject into every matching set block.
	injections := 0
	out := re.ReplaceAllStringFunc(content, func(match string) string {
		groups := re.FindStringSubmatch(match)
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
		log.Info("v1.145 injected SSH port %d into %d %s set(s) in rendered nftables.conf (template did not carry the port via __SSH_PORT__)", sshPort, injections, setName)
	}
	return out
}

// dedupePortSetElements rewrites the elements list of every
// `set <setName> { … elements = { … } … }` block so each whole numeric token
// appears at most once (first occurrence wins, order preserved). It only
// rewrites a block that actually contains a duplicate, so the common no-dup
// case is byte-preserving (original formatting/whitespace untouched).
//
// nftables sets cannot hold duplicate elements. The strict presence check in
// ensureSSHPortsInSet stops the injector from ADDING a duplicate, but it does
// not remove one created by __SSH_PORT__ substitution when a detected SSH port
// coincides with a hardcoded service port in the template (e.g. sshPorts=[80]
// renders tcp_ports_in `{ 80, 80, 443 }`). This pass is the backstop that
// guarantees no duplicate token reaches nft, independent of operational
// plausibility (we do not rely on "an SSH port is never 80/443").
func dedupePortSetElements(content string, setName string, log *logging.Logger) string {
	re := portSetElementsReFor(setName)
	removed := 0
	out := re.ReplaceAllStringFunc(content, func(match string) string {
		groups := re.FindStringSubmatch(match)
		if len(groups) < 4 {
			return match
		}
		prefix, inner, suffix := groups[1], groups[2], groups[3]
		seen := make(map[string]bool)
		kept := make([]string, 0)
		dup := false
		for _, tok := range strings.Split(inner, ",") {
			t := strings.TrimSpace(tok)
			if t == "" {
				continue
			}
			if seen[t] {
				dup = true
				removed++
				continue
			}
			seen[t] = true
			kept = append(kept, t)
		}
		if !dup {
			// No duplicate — preserve the original block byte-for-byte.
			return match
		}
		return prefix + " " + strings.Join(kept, ", ") + " " + suffix
	})
	if removed > 0 {
		log.Info("v1.145 removed %d duplicate element token(s) from %s set(s) in rendered nftables.conf", removed, setName)
	}
	return out
}
