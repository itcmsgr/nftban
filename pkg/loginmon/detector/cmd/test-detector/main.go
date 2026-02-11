// =============================================================================
// NFTBan v1.0.30 - Detector Test Tool
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Purpose: Test detector against real log lines from stdin
//
// meta:name="test-detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="CLI tool to test detector against real log lines"
//
// Usage: journalctl ... | go run main.go
//
// meta:inventory.files="main.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/pkg/loginmon/detector"
)

func main() {
	r := detector.NewRegistry()

	fmt.Printf("Registered detectors: %v\n", r.Detectors())
	fmt.Println("---")

	scanner := bufio.NewScanner(os.Stdin)
	lineCount := 0
	matchCount := 0

	for scanner.Scan() {
		line := scanner.Bytes()
		lineCount++

		if v, ok := r.Detect(line); ok {
			matchCount++
			reasonName := detector.ReasonName[v.Reason]
			fmt.Printf("[MATCH] IP=%s User=%q Reason=%s Score=%d Service=%s\n",
				v.IP, v.User, reasonName, v.ScoreDelta, v.Service)
			fmt.Printf("        Line: %s\n", string(line))
		}
	}

	fmt.Println("---")
	fmt.Printf("Processed %d lines, %d matches (%.2f%%)\n",
		lineCount, matchCount, float64(matchCount)/float64(lineCount)*100)
}
