// =============================================================================
// NFTBan - Effective service-port authority (v1.192.1)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="effective"
// meta:type="package"
// meta:version="1.192.1"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Single effective service-port authority shared by daemon sync and the atomic rebuild render"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/ports.d/*.conf, /etc/nftban/conf.d/panels/*/main.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// v1.192.1 / D-V192-RESIDUAL-REBUILD-DROP — Increment 1.
//
// THE problem this closes: the rebuild render emitted SKELETAL service-port sets
// (template literal `{ SSH, 80, 443 }`) and the daemon repopulated the full set
// (panel/custom ports like 993/995/10051) asynchronously AFTER the atomic load —
// a ~1.85s window where new service-port connections were dropped.
//
// THE invariant: render and daemon-sync must consume ONE authority so the atomic
// `nft -f` installs the COMPLETE set. The authority for the dynamic ports is
// already `LoadAllPorts` (ports.d + enabled-panel profiles) — the exact function
// daemon sync calls (`cmd/nftband/daemon_handlers_sync.go`). This file adds the
// thin completion layer (baseline floor + SSH-detection ports) on top of that
// same authority, so equivalence with daemon sync is by construction.
//
// IPv4/IPv6 parity: daemon sync applies the SAME PortConfig directional slice to
// both `tcp_ports_in` (ip) and (ip6) — so the effective set is family-identical.
// This authority returns one slice per direction; the render applies it to both.

package ports

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Service-port baseline floor. MUST stay byte-equivalent to the elements in
// install/nftables/nftables.conf.tpl (guarded by TestEffectiveBaselineMatchesTemplate).
// SSH ports are NOT hardcoded here — they come from the SSH-detection authority
// and are injected via the sshPorts argument (single source of truth for SSH).
var (
	baselineTCPIn  = []int{80, 443}
	baselineTCPOut = []int{53, 80, 443}
	baselineUDPIn  = []int{}
	baselineUDPOut = []int{53, 123}
)

// EffectivePortSets is the complete effective service-port set per direction.
// It is family-identical (applied to both ip and ip6), matching daemon sync.
type EffectivePortSets struct {
	TCPIn  []int
	TCPOut []int
	UDPIn  []int
	UDPOut []int
}

// ComputeEffective unions the documented baseline floor + SSH ports (the
// SSH-detection authority) + the loaded PortConfig directional ports (the
// ports.d + enabled-panel authority that daemon sync applies via LoadAllPorts).
//
// Pure (no I/O): hermetically testable. Output is deduplicated, validated
// (1..65535), and sorted so the render and the daemon agree byte-for-byte and a
// re-render is idempotent.
func ComputeEffective(all *PortConfig, sshPorts []int) *EffectivePortSets {
	var tcpIn, tcpOut, udpIn, udpOut []int

	tcpIn = append(tcpIn, baselineTCPIn...)
	tcpIn = append(tcpIn, sshPorts...)
	tcpOut = append(tcpOut, baselineTCPOut...)
	udpIn = append(udpIn, baselineUDPIn...)
	udpOut = append(udpOut, baselineUDPOut...)

	if all != nil {
		tcpIn = append(tcpIn, all.TCPPortsIn...)
		tcpOut = append(tcpOut, all.TCPPortsOut...)
		udpIn = append(udpIn, all.UDPPortsIn...)
		udpOut = append(udpOut, all.UDPPortsOut...)
	}

	return &EffectivePortSets{
		TCPIn:  normalizePortList(tcpIn),
		TCPOut: normalizePortList(tcpOut),
		UDPIn:  normalizePortList(udpIn),
		UDPOut: normalizePortList(udpOut),
	}
}

// EffectiveServicePorts loads the SAME config authority daemon sync uses
// (LoadAllPorts = ports.d + enabled-panel profiles) and returns the complete
// effective sets. This is the entry point the atomic rebuild render will consume
// (Increment 3) so it installs the complete sets inside the single `nft -f`.
func EffectiveServicePorts(configDir string, sshPorts []int) (*EffectivePortSets, error) {
	all, err := LoadAllPorts(configDir)
	if err != nil {
		return nil, err
	}
	return ComputeEffective(all, sshPorts), nil
}

// renderEffectiveFragment emits an `nft -f` fragment that makes the four
// service-port sets COMPLETE in the same transaction as the table load: for each
// set, `flush set` (clears the template's skeletal defaults) followed by
// `add element` with the complete effective ports. Applied to BOTH ip and ip6
// (family-identical, matching daemon sync). The caller appends this to the
// rendered nftables config AFTER the table definition and BEFORE the single
// `nft -f`, so the atomic commit installs complete sets and the durable config
// is complete before any post-load daemon sync.
//
// Emitting flush+add (rather than rewriting the template set blocks) keeps the
// template untouched and mirrors the blacklist single-transaction replace.
// SSH ports MUST already be folded into sets.TCPIn by the caller (lockout guard)
// — the flush would otherwise drop the template's SSH allow.
func renderEffectiveFragment(sets *EffectivePortSets) string {
	if sets == nil {
		return ""
	}
	var b strings.Builder
	emit := func(name string, portList []int) {
		for _, fam := range []string{"ip", "ip6"} {
			fmt.Fprintf(&b, "flush set %s nftban %s\n", fam, name)
			if len(portList) > 0 {
				toks := make([]string, len(portList))
				for i, p := range portList {
					toks[i] = strconv.Itoa(p)
				}
				fmt.Fprintf(&b, "add element %s nftban %s { %s }\n", fam, name, strings.Join(toks, ", "))
			}
		}
	}
	emit("tcp_ports_in", sets.TCPIn)
	emit("tcp_ports_out", sets.TCPOut)
	emit("udp_ports_in", sets.UDPIn)
	emit("udp_ports_out", sets.UDPOut)
	return b.String()
}

// RenderEffectiveFragment loads the config authority (same as daemon sync) and
// returns the nft -f fragment of complete service-port sets. sshPorts is the
// SSH-detection authority's output (required — empty would risk an SSH-less
// flush). This is what the rebuild render appends to load_conf.
func RenderEffectiveFragment(configDir string, sshPorts []int) (string, error) {
	sets, err := EffectiveServicePorts(configDir, sshPorts)
	if err != nil {
		return "", err
	}
	return renderEffectiveFragment(sets), nil
}

// normalizePortList deduplicates, drops out-of-range ports (validate), and sorts
// ascending. Deterministic — same input always yields the same output.
func normalizePortList(in []int) []int {
	seen := make(map[int]struct{}, len(in))
	out := make([]int, 0, len(in))
	for _, p := range in {
		if p < 1 || p > 65535 {
			continue
		}
		if _, dup := seen[p]; dup {
			continue
		}
		seen[p] = struct{}{}
		out = append(out, p)
	}
	sort.Ints(out)
	return out
}
