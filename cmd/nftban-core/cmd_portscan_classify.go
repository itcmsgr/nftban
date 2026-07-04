// SPDX-License-Identifier: MPL-2.0
//
// meta:name="cmd_portscan_classify"
// meta:type="cli-subcommand"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="v1.204 PORTSCAN GO-CLASSIFIER: reads a per-source-IP classification request as JSON on stdin (events + known-open ports + thresholds), runs internal/portscan.Classify (scores only unexpected/closed ports; known-open service ports never accrue scan score), emits the Verdict JSON on stdout. Pure decision function — does NOT read logs or write nft sets; fed pre-parsed events by the existing root log reader (input-authority identity unchanged). CLI-only (nftban-core); does NOT touch the nftband daemon."
// meta:input="stdin JSON: {ip,family,events:[{port,target,ts}],known_open_ports:[],block_range,vertical_ports,horizontal_targets,strobe_ports,strobe_window_sec}"
// meta:output="stdout JSON Verdict {scan_type,known_open_count,unexpected_count,target_count,action,family,src_ip}; exit 0=classified, 2=input error"
// meta:depends="internal/portscan"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/itcmsgr/nftban/internal/portscan"
)

type portscanClassifyRequest struct {
	IP                string           `json:"ip"`
	Family            string           `json:"family"`
	Events            []portscan.Event `json:"events"`
	KnownOpenPorts    []int            `json:"known_open_ports"`
	BlockRange        int              `json:"block_range"`
	VerticalPorts     int              `json:"vertical_ports"`
	HorizontalTargets int              `json:"horizontal_targets"`
	StrobePorts       int              `json:"strobe_ports"`
	StrobeWindowSec   int64            `json:"strobe_window_sec"`
}

// cmdPortscanClassify reads a JSON classification request on stdin and writes the
// Verdict JSON to stdout. Used by the shell classic/suricata classifier to obtain
// the typed scan verdict (known-open-aware) instead of the old shell scoring.
func cmdPortscanClassify(args []string) int {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "portscan-classify: read stdin: %v\n", err)
		return 2
	}
	var req portscanClassifyRequest
	if err := json.Unmarshal(raw, &req); err != nil {
		fmt.Fprintf(os.Stderr, "portscan-classify: bad JSON input: %v\n", err)
		return 2
	}
	v := portscan.Classify(portscan.Input{
		IP:                req.IP,
		Family:            req.Family,
		Events:            req.Events,
		KnownOpenPorts:    req.KnownOpenPorts,
		BlockRange:        req.BlockRange,
		VerticalPorts:     req.VerticalPorts,
		HorizontalTargets: req.HorizontalTargets,
		StrobePorts:       req.StrobePorts,
		StrobeWindowSec:   req.StrobeWindowSec,
	})
	out, err := json.Marshal(v)
	if err != nil {
		fmt.Fprintf(os.Stderr, "portscan-classify: marshal verdict: %v\n", err)
		return 2
	}
	fmt.Println(string(out))
	return 0
}
