// =============================================================================
// NFTBan - Portscan classifier (typed; known-open service-port aware)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="portscan"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="v1.204 PORTSCAN GO-CLASSIFIER: typed portscan scan-type classifier that scores ONLY unexpected/closed destination ports — configured known-open service ports (tcp_ports_in) are allowed context and never accrue scan score. Fixes the false-positive class where a legitimate multi-service client (panel+mail+web+SSH) was classified strobe/vertical. Pure decision function fed pre-parsed per-IP events by the existing root log reader (input-authority identity unchanged); IPv4+IPv6 equivalent."
// meta:input="Input (per-IP events + known-open port set + thresholds)"
// meta:output="Verdict (scan type, known_open_count, unexpected_count, action)"
// meta:depends="none"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package portscan

// Event is one observed connection attempt (one parsed kernel nft-log line),
// already extracted by the root log reader. Port is the destination port;
// Target is the destination IP (the protected host, usually one); TS is the
// event's unix timestamp (seconds).
type Event struct {
	Port   int
	Target string
	TS     int64
}

// Input is the per-source-IP classification request. KnownOpenPorts is the
// configured open-service set (tcp_ports_in / udp_ports_in) — these ports are
// allowed CONTEXT and never accrue scan score. Family is "ipv4"/"ipv6"; the
// scoring is identical for both (known-open exclusion is by port number).
type Input struct {
	IP             string
	Family         string
	Events         []Event
	KnownOpenPorts []int
	// Thresholds (from portscan/classic.conf). A threshold <= 0 disables that rule.
	BlockRange        int   // PORTSCAN_CLASSIC_BLOCK_RANGE
	VerticalPorts     int   // PORTSCAN_CLASSIC_VERTICAL_PORTS
	HorizontalTargets int   // PORTSCAN_CLASSIC_HORIZONTAL_TARGETS
	StrobePorts       int   // PORTSCAN_CLASSIC_STROBE_PORTS
	StrobeWindowSec   int64 // strobe window (default 10s if <= 0)
}

// Verdict is the classification result. Action is "allow" or "ban".
// KnownOpenCount/UnexpectedCount are the distinct-port tallies used for the
// old-vs-new shadow comparison.
type Verdict struct {
	ScanType        string `json:"scan_type"` // "" | block | vertical | horizontal | strobe
	KnownOpenCount  int    `json:"known_open_count"`
	UnexpectedCount int    `json:"unexpected_count"`
	TargetCount     int    `json:"target_count"`
	Action          string `json:"action"` // allow | ban
	Family          string `json:"family"`
	IP              string `json:"src_ip"`
}

// Classify scores ONLY unexpected (non-known-open) destination ports. Known-open
// service ports are tallied (for visibility) but never drive a scan verdict, so a
// legitimate client touching only known-open services yields UnexpectedCount==0 →
// allow. Genuine diversity across unexpected/closed ports remains ban-capable.
// IPv4 and IPv6 are treated identically.
func Classify(in Input) Verdict {
	known := make(map[int]bool, len(in.KnownOpenPorts))
	for _, p := range in.KnownOpenPorts {
		known[p] = true
	}

	distinctUnexpected := make(map[int]bool)
	distinctKnown := make(map[int]bool)
	targets := make(map[string]bool)
	var minUnexpTS, maxUnexpTS int64
	haveUnexpTS := false

	for _, e := range in.Events {
		if known[e.Port] {
			distinctKnown[e.Port] = true
			continue // known-open service port → allowed context, NOT scan score
		}
		distinctUnexpected[e.Port] = true
		if e.Target != "" {
			targets[e.Target] = true
		}
		if !haveUnexpTS || e.TS < minUnexpTS {
			minUnexpTS = e.TS
		}
		if !haveUnexpTS || e.TS > maxUnexpTS {
			maxUnexpTS = e.TS
		}
		haveUnexpTS = true
	}

	v := Verdict{
		KnownOpenCount:  len(distinctKnown),
		UnexpectedCount: len(distinctUnexpected),
		TargetCount:     len(targets),
		Action:          "allow",
		Family:          in.Family,
		IP:              in.IP,
	}
	uc := v.UnexpectedCount
	tc := v.TargetCount

	window := in.StrobeWindowSec
	if window <= 0 {
		window = 10
	}

	switch {
	case in.BlockRange > 0 && uc >= in.BlockRange:
		v.ScanType = "block"
	case in.VerticalPorts > 0 && uc >= in.VerticalPorts && tc <= 1:
		v.ScanType = "vertical"
	case in.HorizontalTargets > 0 && tc >= in.HorizontalTargets && uc <= 3 && uc > 0:
		v.ScanType = "horizontal"
	case in.StrobePorts > 0 && uc >= in.StrobePorts && (maxUnexpTS-minUnexpTS) < window:
		v.ScanType = "strobe"
	}
	if v.ScanType != "" {
		v.Action = "ban"
	}
	return v
}
