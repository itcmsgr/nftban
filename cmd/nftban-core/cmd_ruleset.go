// =============================================================================
// NFTBan - ruleset content (set elements for a one-transaction reload/rebuild)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="cmd_ruleset"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="nftban-core ruleset content: prints the add-element statements a firewall reload/rebuild appends to the rendered schema (v1.236 Stage 2); refuses an oversized replacement before anything is mutated"
// meta:input="none (reads the durable sources and the live NFTBan sets)"
// meta:output="nft statements on stdout; one RULESET_CONTENT summary line on stderr"
// meta:inventory.binaries="nft"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/ruleset"
)

// Exit codes of `nftban-core ruleset content` (the lane acts on them):
//
//	0  content printed
//	1  error (nothing printed; the lane must not apply a partial file)
//	3  refused before mutation: oversized, or not enough memory (design §9.4)
const rulesetExitRefused = 3

// Defaults (design §9.4): the largest size measured end to end on the smallest host
// class (lab2, 2 vCPU / 3.8 GB: 300k elements, ~470 MB nft), and the measured nft
// RSS slope of ~1.6 KB per element.
const (
	rulesetDefaultMaxElements = 300000
	rulesetBytesPerElement    = 1600
	rulesetMemReserve         = 256 << 20
)

type rulesetExit struct {
	code int
	msg  string
}

func (e *rulesetExit) Error() string { return e.msg }

func rulesetExitCode(err error) int {
	var re *rulesetExit
	if errors.As(err, &re) {
		return re.code
	}
	return 1
}

func cmdRuleset(cfg *nftbanconf.Config) error {
	args := os.Args[2:]
	if len(args) == 0 || args[0] != "content" {
		return fmt.Errorf("usage: nftban-core ruleset content [--max-elements N] [--commit-margin SECONDS]")
	}
	if err := checkPrivilege(); err != nil {
		return err
	}
	opts := ruleset.Options{
		ConfigDir:    cfg.ConfigDir,
		DataDir:      cfg.DataDir,
		CommitMargin: 5 * time.Second,
		MaxElements:  rulesetDefaultMaxElements,
		FeedsMaster:  cfg.FeedsEnabled,
	}
	if v := os.Getenv("NFTBAN_RULESET_MAX_ELEMENTS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			opts.MaxElements = n
		}
	}
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--max-elements", "--commit-margin":
			if i+1 >= len(args) {
				return fmt.Errorf("%s requires a value", args[i])
			}
			n, err := strconv.Atoi(args[i+1])
			if err != nil || n < 0 {
				return fmt.Errorf("%s requires a non-negative integer", args[i])
			}
			if args[i] == "--max-elements" {
				opts.MaxElements = n
			} else {
				opts.CommitMargin = time.Duration(n) * time.Second
			}
			i++
		default:
			return fmt.Errorf("unknown option %s", args[i])
		}
	}

	res, err := ruleset.Render(opts, ruleset.NftSetReader, nftbackend.NewExemption(cfg.ConfigDir))
	if errors.Is(err, ruleset.ErrOversized) {
		return &rulesetExit{rulesetExitRefused, "refused before any change: " + err.Error() + " (existing ruleset untouched; see NFTBAN_RULESET_MAX_ELEMENTS)"}
	}
	if err != nil {
		return err
	}
	if avail, ok := memAvailable(); ok {
		need := 2*int64(res.Elements)*rulesetBytesPerElement + rulesetMemReserve
		if avail < need {
			return &rulesetExit{rulesetExitRefused, fmt.Sprintf("refused before any change: %d elements need ~%d MB free memory, %d MB available (existing ruleset untouched)", res.Elements, need>>20, avail>>20)}
		}
	}

	w := bufio.NewWriter(os.Stdout)
	if _, err := w.WriteString(res.Script); err != nil {
		return err
	}
	if err := w.Flush(); err != nil {
		return err
	}
	parts := make([]string, 0, len(res.Counts))
	for k, v := range res.Counts {
		parts = append(parts, fmt.Sprintf("%s=%d", k, v))
	}
	fmt.Fprintf(os.Stderr, "RULESET_CONTENT elements=%d carried=%d expired=%d exempt=%d omitted=%d sets=[%s]\n",
		res.Elements, res.Carried, res.Expired, res.Exempt, len(res.Omitted), strings.Join(parts, " "))
	return nil
}

// memAvailable reads MemAvailable from /proc/meminfo (bytes).
func memAvailable() (int64, bool) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) >= 2 && fields[0] == "MemAvailable:" {
			kb, err := strconv.ParseInt(fields[1], 10, 64)
			return kb * 1024, err == nil
		}
	}
	return 0, false
}
