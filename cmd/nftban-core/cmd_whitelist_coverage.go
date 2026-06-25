// =============================================================================
// NFTBan core — whitelist-coverage (range-aware verify oracle)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_whitelist_coverage"
// meta:type="cli-subcommand"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="Range-aware whitelist coverage diff. Reads JSON {baseline,kernel,sessions} of IP/CIDR/interval tokens on stdin, emits JSON {missing_from_kernel,extra_in_kernel,bad_baseline,bad_kernel} using netutil.CoverageDiff (coverage, not strings — so coalesced kernel intervals do not read as drift). CLI-only (cmd/nftban-core); does NOT touch the nftband daemon."
// meta:input="stdin JSON: {baseline:[],kernel:[],sessions:[]}"
// meta:output="stdout JSON: {missing_from_kernel:[],extra_in_kernel:[],bad_baseline:[],bad_kernel:[]}; exit 0=clean, 1=real anomalies, 2=input error"
// meta:depends="internal/netutil"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"github.com/itcmsgr/nftban/internal/netutil"
)

type coverageInput struct {
	Baseline []string `json:"baseline"`
	Kernel   []string `json:"kernel"`
	Sessions []string `json:"sessions"`
}

type coverageOutput struct {
	MissingFromKernel []string `json:"missing_from_kernel"`
	ExtraInKernel     []string `json:"extra_in_kernel"`
	BadBaseline       []string `json:"bad_baseline"`
	BadKernel         []string `json:"bad_kernel"`
}

func nilToEmpty(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// cmdWhitelistCoverage reads a coverage request on stdin and prints the
// range-aware diff. Exit: 0 = no real drift, 1 = real anomalies, 2 = input error.
func cmdWhitelistCoverage(_ []string) int {
	raw, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "whitelist-coverage: read stdin: %v\n", err)
		return 2
	}
	var in coverageInput
	if err := json.Unmarshal(raw, &in); err != nil {
		fmt.Fprintf(os.Stderr, "whitelist-coverage: parse json: %v\n", err)
		return 2
	}
	res := netutil.CoverageDiff(in.Baseline, in.Kernel, in.Sessions)
	out := coverageOutput{
		MissingFromKernel: nilToEmpty(res.MissingFromKernel),
		ExtraInKernel:     nilToEmpty(res.ExtraInKernel),
		BadBaseline:       nilToEmpty(res.BadBaseline),
		BadKernel:         nilToEmpty(res.BadKernel),
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		fmt.Fprintf(os.Stderr, "whitelist-coverage: encode: %v\n", err)
		return 2
	}
	if len(out.MissingFromKernel) > 0 || len(out.ExtraInKernel) > 0 {
		return 1
	}
	return 0
}
