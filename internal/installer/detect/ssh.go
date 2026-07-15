// =============================================================================
// NFTBan v1.73 - Installer SSH Port Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-ssh"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="4-source SSH port detection chain for installer"
// meta:inventory.files="internal/installer/detect/ssh.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/ssh/sshd_config"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package detect

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// SSHPort detects the active SSH port using a 4-source priority chain.
// Returns the port number (1-65535) or an error if no source yields a valid port.
//
// Priority:
//  1. ss listener (most authoritative — reflects actual running sshd)
//  2. sshd_config + drop-in dirs (config-declared)
//  3. State file from previous install (/var/lib/nftban/state/ssh_port_active.state)
//  4. nftban.conf.local override (/etc/nftban/nftban.conf.local SSH_PORT=)
//
// Backward-compat shim around DetectSSHPorts (v1.125 R-1). Returns the
// primary port; callers that need the full multi-port list (e.g., to render
// the nftables allow-set) should call DetectSSHPorts directly.
func SSHPort(exec executor.Executor, log *logging.Logger) (int, error) {
	_, primary, err := DetectSSHPorts(exec, log)
	return primary, err
}

// SSHPortWithSource returns the resolved SSH port AND a short string
// identifying which source yielded it: "ss" / "sshd_config" /
// "state" / "config" — matching the schema enum required by the
// PR-26-code-D restore evidence record (§39.1 / §48.6 lock).
//
// Same priority chain as SSHPort. Read-only typed introspection;
// no mutation. Per §51.5-A2 invariant, this is OUTSIDE the bounded
// mutation surface cap. Added in PR-26-code-D.
func SSHPortWithSource(exec executor.Executor, log *logging.Logger) (port int, source string, err error) {
	// v1.125 R-1: keep per-source resolution for the schema-enum return,
	// but route the listener path through sshAllListeners so multi-port
	// hosts are not silently truncated. Other sources are single-port by
	// file format and remain byte-identical.
	if ports := sshAllListeners(exec); len(ports) > 0 {
		primary := selectPrimarySSHPort(ports, sshClientLocalPort())
		log.Detect("ssh", "source", "ss-listener")
		log.Detect("ssh", "port", strconv.Itoa(primary))
		return primary, "ss", nil
	}
	if p := sshFromConfig(exec); p > 0 {
		log.Detect("ssh", "source", "sshd_config")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return p, "sshd_config", nil
	}
	if p := sshFromStateFile(exec); p > 0 {
		log.Detect("ssh", "source", "state-file")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return p, "state", nil
	}
	if p := sshFromConfLocal(exec); p > 0 {
		log.Detect("ssh", "source", "conf.local")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return p, "config", nil
	}
	return 0, "", fmt.Errorf("cannot determine SSH port from any source (ss, sshd_config, state file, conf.local)")
}

// portRe matches a trailing port number after a colon.
var portRe = regexp.MustCompile(`:(\d+)\s*$`)

// sshAllListeners parses `ss -tlnp` and returns ALL sshd listening ports
// found in the output, deduplicated and ordered by first-occurrence in the
// `ss` output. v1.125 R-1: closes the multi-port-class lockout vector where a
// host listens on multiple ports (e.g. :22 internal + :50000 external) but
// the installer rendered only the first detected port into the firewall
// allow-set.
func sshAllListeners(exec executor.Executor) []int {
	res := exec.Run("ss", "-tlnp")
	if res.ExitCode != 0 {
		return nil
	}
	seen := make(map[int]bool)
	var ports []int
	for _, line := range strings.Split(res.Stdout, "\n") {
		if !strings.Contains(line, "sshd") {
			continue
		}
		// Extract port from LISTEN address column (e.g., *:22 or 0.0.0.0:50000)
		m := portRe.FindStringSubmatch(safeField(line, 3))
		if m == nil {
			continue
		}
		port := validatePort(m[1])
		if port == 0 || seen[port] {
			continue
		}
		seen[port] = true
		ports = append(ports, port)
	}
	return ports
}

// sshClientLocalPort returns the LOCAL (destination) port from the
// SSH_CLIENT environment variable, or 0 if absent or unparseable.
//
// SSH_CLIENT format: "<peer-ip> <peer-port> <local-port>" — the 3rd field
// is the port the operator is connected to on this host. v1.125 R-1 uses
// this to pick the multi-port primary so the rendered firewall allow-set
// and the operator's session port stay aligned.
func sshClientLocalPort() int {
	v := os.Getenv("SSH_CLIENT")
	if v == "" {
		return 0
	}
	fields := strings.Fields(v)
	if len(fields) < 3 {
		return 0
	}
	return validatePort(fields[2])
}

// selectPrimarySSHPort picks the primary SSH port from a list of detected
// listeners, preferring (1) the port the operator's SSH_CLIENT session is
// connected on if it is in the listener list, else (2) the first detected
// listener (which is typically the lowest-numbered well-known port). The
// primary is used for the `__SSH_PORT__` template substitution and for
// install_state SSH_PORT (single-int backward-compat field).
func selectPrimarySSHPort(ports []int, sshClientPort int) int {
	if len(ports) == 0 {
		return 0
	}
	if sshClientPort > 0 {
		for _, p := range ports {
			if p == sshClientPort {
				return p
			}
		}
	}
	return ports[0]
}

// primaryFirstPorts returns a new slice with primary at index 0 followed by
// every other port from `ports` in original detection order. If primary is
// already at index 0 (or primary is 0, or ports is empty), the input slice
// is returned unchanged.
//
// v1.125 R-1 contract enforcement: DetectSSHPorts callers (and through the
// phaseData.sshPorts field, RenderNftablesConfMultiPort) rely on sshPorts[0]
// being the SSH_CLIENT-aware primary so the rendered `__SSH_PORT__` template
// substitution applies to the right port for the per-IP SSH rate-limit rule.
// Without this reorder, a multi-port-class host with sshd on :22+:50000 and
// SSH_CLIENT=50000 would render the rate-limit rule against :22 because
// selectPrimarySSHPort returns 50000 but ports[0] is still 22.
func primaryFirstPorts(ports []int, primary int) []int {
	if len(ports) == 0 || primary == 0 || ports[0] == primary {
		return ports
	}
	out := make([]int, 0, len(ports))
	out = append(out, primary)
	for _, p := range ports {
		if p != primary {
			out = append(out, p)
		}
	}
	return out
}

// DetectSSHPorts is the v1.125 R-1 multi-port-aware entry point. It returns
// the full list of detected sshd listener ports (or a single-element slice
// when the host has only one listener), AND the primary port chosen by
// selectPrimarySSHPort (SSH_CLIENT-aware). Error is returned only when no
// source yields any valid port.
//
// Source-chain semantics match SSHPort's existing priority: ss listener →
// sshd_config → state file → conf.local. Multi-port discovery is only
// available from the ss listener source (the other three sources are
// single-port by file format). When the primary comes from a non-listener
// source, the ports slice contains just that single primary.
//
// Backward compatibility: SSHPort() and SSHPortWithSource() now delegate
// to DetectSSHPorts and return the primary, so all existing callers
// continue to receive a single int with unchanged semantics.
func DetectSSHPorts(exec executor.Executor, log *logging.Logger) (ports []int, primary int, err error) {
	// Source 1: ss listener (multi-port-aware)
	if ports = sshAllListeners(exec); len(ports) > 0 {
		primary = selectPrimarySSHPort(ports, sshClientLocalPort())
		// v1.125 R-1 contract: sshPorts[0] MUST be the primary. Without
		// this reorder, callers reading sshPorts[0] (e.g.,
		// RenderNftablesConfMultiPort which uses sshPorts[0] for the
		// __SSH_PORT__ template substitution) would diverge from the
		// SSH_CLIENT-aware primary on multi-port hosts. multi-port-class
		// regression: ports=[22,50000] + SSH_CLIENT=50000 → primary=50000
		// but ports[0]=22 → rate-limit rule applied to wrong port.
		ports = primaryFirstPorts(ports, primary)
		log.Detect("ssh", "source", "ss-listener")
		log.Detect("ssh", "port", strconv.Itoa(primary))
		if len(ports) > 1 {
			parts := make([]string, len(ports))
			for i, p := range ports {
				parts[i] = strconv.Itoa(p)
			}
			log.Detect("ssh", "ports_all", strings.Join(parts, ","))
			log.Warn("multi-port SSH detected: %s — primary=%d; rendering allow-set for all detected ports (V125 R-1)",
				strings.Join(parts, ","), primary)
		}
		return ports, primary, nil
	}
	// Sources 2-4 are single-port by file format; wrap in single-element slice.
	if p := sshFromConfig(exec); p > 0 {
		log.Detect("ssh", "source", "sshd_config")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return []int{p}, p, nil
	}
	if p := sshFromStateFile(exec); p > 0 {
		log.Detect("ssh", "source", "state-file")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return []int{p}, p, nil
	}
	if p := sshFromConfLocal(exec); p > 0 {
		log.Detect("ssh", "source", "conf.local")
		log.Detect("ssh", "port", strconv.Itoa(p))
		return []int{p}, p, nil
	}
	return nil, 0, fmt.Errorf("cannot determine SSH port from any source (ss, sshd_config, state file, conf.local)")
}

// sshFromConfig reads /etc/ssh/sshd_config and drop-in dirs.
func sshFromConfig(exec executor.Executor) int {
	// Main config
	if port := parseSSHConfig(exec, "/etc/ssh/sshd_config"); port > 0 {
		return port
	}
	// Drop-in directory
	res := exec.Run("ls", "/etc/ssh/sshd_config.d/")
	if res.ExitCode == 0 {
		for _, name := range strings.Fields(res.Stdout) {
			if !strings.HasSuffix(name, ".conf") {
				continue
			}
			path := filepath.Join("/etc/ssh/sshd_config.d", name)
			if port := parseSSHConfig(exec, path); port > 0 {
				return port
			}
		}
	}
	return 0
}

// portLineRe matches "Port NNN" lines in sshd_config.
var portLineRe = regexp.MustCompile(`(?i)^\s*Port\s+(\d+)`)

// listenAddrLineRe captures the address token of a `ListenAddress <token>`
// directive. listenAddrBracketRe captures the port of the IPv6 bracketed form
// `[addr]:port`. v1.145 PR-B: the historical detector parsed only `Port`
// lines; a sshd_config that declares ports solely via `ListenAddress`
// (`0.0.0.0:22`, `[::]:50000`, `192.0.2.10:22`, `[2001:db8::10]:50000`) was
// invisible to the config sources.
var listenAddrLineRe = regexp.MustCompile(`(?i)^\s*ListenAddress\s+(\S+)`)
var listenAddrBracketRe = regexp.MustCompile(`^\[.*\]:(\d+)$`)

// listenAddressPort extracts an explicit port from one `ListenAddress` line,
// or 0 when the line is not a ListenAddress or carries no explicit port.
// OpenSSH forms:
//
//	ListenAddress host             -> no port (0)
//	ListenAddress host:port        -> IPv4/hostname (exactly one colon)
//	ListenAddress [ipv6]:port      -> IPv6 with port (bracketed)
//	ListenAddress 2001:db8::10      -> bare IPv6, NO port (multiple colons, no brackets)
//
// The bare-IPv6 case is the trap: a naive `:(\d+)$` would mis-read `::10` as
// port 10, so a non-bracketed token is only treated as host:port when it has
// EXACTLY one colon.
func listenAddressPort(line string) int {
	m := listenAddrLineRe.FindStringSubmatch(line)
	if m == nil {
		return 0
	}
	tok := m[1]
	if bm := listenAddrBracketRe.FindStringSubmatch(tok); bm != nil {
		return validatePort(bm[1])
	}
	if strings.Count(tok, ":") == 1 {
		return validatePort(tok[strings.LastIndex(tok, ":")+1:])
	}
	return 0
}

// parseSSHConfig returns a single SSH port from one config file. A `Port`
// directive wins (first occurrence); when no `Port` line is present it falls
// back to the first `ListenAddress host:port` it finds (v1.145 PR-B — closes
// the ListenAddress-only blind spot in the single-port config source). Returns
// 0 when neither is present.
func parseSSHConfig(exec executor.Executor, path string) int {
	data, err := exec.ReadFile(path)
	if err != nil {
		return 0
	}
	listenPort := 0
	for _, line := range strings.Split(string(data), "\n") {
		if m := portLineRe.FindStringSubmatch(line); m != nil {
			if p := validatePort(m[1]); p > 0 {
				return p
			}
		}
		if listenPort == 0 {
			if p := listenAddressPort(line); p > 0 {
				listenPort = p
			}
		}
	}
	return listenPort
}

// parseSSHConfigPorts returns ALL SSH ports declared in one config file via
// `Port` and `ListenAddress` directives (deduped within the file is left to
// the caller's union). v1.145 PR-B: the runtime conservative-union detector
// must see every declared port, not just the first.
func parseSSHConfigPorts(exec executor.Executor, path string) []int {
	data, err := exec.ReadFile(path)
	if err != nil {
		return nil
	}
	var ports []int
	for _, line := range strings.Split(string(data), "\n") {
		if m := portLineRe.FindStringSubmatch(line); m != nil {
			if p := validatePort(m[1]); p > 0 {
				ports = append(ports, p)
			}
			continue
		}
		if p := listenAddressPort(line); p > 0 {
			ports = append(ports, p)
		}
	}
	return ports
}

// DetectSSHPortsForRender returns the FULL SSH-port union (primary-first) plus
// the SSH_CLIENT-aware primary, for the installer render path.
//
// v1.145 PR-B2: the render must seed EVERY detected SSH port into tcp_ports_in
// AND ssh_ports, not just the `ss`-listener subset that DetectSSHPorts returns.
// On a multi-port host where `ss` detection is partial/ordered, DetectSSHPorts
// could return a subset (observed: 22+50000 but not 2222), leaving the missing
// port out of the kernel sets → externally DROPPED → lockout for an operator
// using it. DetectSSHPortsUnion is the authoritative multi-source detector
// (ss + sshd_config Port + ListenAddress + state + conf.local); this wraps it
// primary-first for RenderNftablesConfMultiPort. Falls back to DetectSSHPorts'
// primary when the union is empty.
func DetectSSHPortsForRender(exec executor.Executor, log *logging.Logger) (ports []int, primary int, err error) {
	union := DetectSSHPortsUnion(exec, log)
	_, primary, err = DetectSSHPorts(exec, log)
	if len(union) == 0 {
		if err != nil {
			return nil, 0, err
		}
		return []int{primary}, primary, nil
	}
	if primary == 0 {
		primary = selectPrimarySSHPort(union, sshClientLocalPort())
	}
	return primaryFirstPorts(union, primary), primary, nil
}

// sshConfigAllPorts returns all Port + ListenAddress ports from the main
// sshd_config and every *.conf drop-in.
func sshConfigAllPorts(exec executor.Executor) []int {
	ports := parseSSHConfigPorts(exec, "/etc/ssh/sshd_config")
	res := exec.Run("ls", "/etc/ssh/sshd_config.d/")
	if res.ExitCode == 0 {
		for _, name := range strings.Fields(res.Stdout) {
			if !strings.HasSuffix(name, ".conf") {
				continue
			}
			path := filepath.Join("/etc/ssh/sshd_config.d", name)
			ports = append(ports, parseSSHConfigPorts(exec, path)...)
		}
	}
	return ports
}

// DetectSSHPortsUnion returns the sorted, de-duplicated union of every SSH port
// nftban can observe: live `ss` listeners + sshd_config/drop-in `Port` and
// `ListenAddress` directives + the install state file + conf.local `SSH_PORT`.
//
// v1.145 PR-B runtime hardening: runtime/timer paths must protect EVERY real
// SSH listener port (lockout-safe), so they consume this conservative union
// rather than scalar `head -1` detection. The union is intentionally over-broad
// across address families — it is applied to BOTH ip and ip6 sets; per-family
// (ipv4_ports/ipv6_ports) precision is a deferred stronger variant. Blocking
// rule: missing a real listener port is a lockout blocker; over-broad is not.
func DetectSSHPortsUnion(exec executor.Executor, log *logging.Logger) []int {
	seen := make(map[int]bool)
	var union []int
	add := func(p int) {
		if p > 0 && !seen[p] {
			seen[p] = true
			union = append(union, p)
		}
	}
	for _, p := range sshAllListeners(exec) {
		add(p)
	}
	for _, p := range sshConfigAllPorts(exec) {
		add(p)
	}
	add(sshFromStateFile(exec))
	add(sshFromConfLocal(exec))
	sort.Ints(union)
	if log != nil && len(union) > 0 {
		parts := make([]string, len(union))
		for i, p := range union {
			parts[i] = strconv.Itoa(p)
		}
		log.Detect("ssh", "union", strings.Join(parts, ","))
	}
	return union
}

// sshFromStateFile reads /var/lib/nftban/state/ssh_port_active.state.
func sshFromStateFile(exec executor.Executor) int {
	data, err := exec.ReadFile("/var/lib/nftban/state/ssh_port_active.state")
	if err != nil {
		return 0
	}
	return validatePort(strings.TrimSpace(string(data)))
}

// sshFromConfLocal reads SSH_PORT= from /etc/nftban/nftban.conf.local.
func sshFromConfLocal(exec executor.Executor) int {
	data, err := exec.ReadFile("/etc/nftban/nftban.conf.local")
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "SSH_PORT=") {
			val := strings.TrimPrefix(line, "SSH_PORT=")
			return validatePort(strings.TrimSpace(val))
		}
	}
	return 0
}

// validatePort returns the port if it's a valid number in 1-65535, else 0.
func validatePort(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 || n > 65535 {
		return 0
	}
	return n
}

// safeField returns the nth whitespace-separated field, or empty string.
func safeField(line string, n int) string {
	fields := strings.Fields(line)
	if n < len(fields) {
		return fields[n]
	}
	return ""
}
