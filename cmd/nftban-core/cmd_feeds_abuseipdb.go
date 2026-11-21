// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 part B2: the AbuseIPDB key and the standalone key test. The `nftban feeds abuseipdb`
// menu (cli/lib/nftban/cli/cmd_feeds.sh) is thin and delegates here and to the generic feed
// handlers.
//
//   nftban-core feeds abuseipdb-key set      key on STDIN (never argv), stored root:root 0600
//   nftban-core feeds abuseipdb-key status   absent / ok / unsafe: <reason>; never the key
//   nftban-core feeds abuseipdb-key remove
//   nftban-core feeds abuseipdb-test [--json]  ONE GET /api/v2/check (check quota, not blacklist)
//
// The test never writes the snapshot or the refresh record: a passing test cannot make an old
// enforced list look fresh.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

func abuseIPDBKeyPath(cfg *nftbanconf.Config) string {
	return filepath.Join(cfg.ConfigDir, abuseIPDBKeyName)
}

func cmdFeedsAbuseIPDBKey(cfg *nftbanconf.Config, sub string) error {
	path := abuseIPDBKeyPath(cfg)
	switch sub {
	case "status":
		fmt.Printf("API key file: %s: %s\n", path, feeds.CredentialStatus(path))
		return nil
	case "set":
		if os.Geteuid() != 0 {
			return errors.New("storing the API key needs root")
		}
		b, err := io.ReadAll(io.LimitReader(os.Stdin, 1025))
		if err != nil {
			return errors.New("reading the key from stdin failed")
		}
		if len(b) > 1024 {
			return errors.New("the key on stdin is longer than 1024 bytes")
		}
		if err := feeds.WriteCredentialFile(path, string(b)); err != nil {
			return err
		}
		fmt.Printf("API key stored in %s (root:root 0600; not shown). Check it with: nftban feeds abuseipdb test\n", path)
		return nil
	case "remove":
		if os.Geteuid() != 0 {
			return errors.New("removing the API key needs root")
		}
		if err := feeds.RemoveCredentialFile(path); err != nil {
			return err
		}
		fmt.Printf("API key removed (%s). If the AbuseIPDB feed stays enabled, its next refresh fails and status shows it.\n", path)
		return nil
	default:
		return fmt.Errorf("usage: nftban-core feeds abuseipdb-key <set|status|remove> (set reads the key from stdin)")
	}
}

// keyTestReport is the --json output of the key test.
type keyTestReport struct {
	Endpoint  string `json:"endpoint"`
	Cost      string `json:"cost"`
	OK        bool   `json:"ok"`
	Status    int    `json:"http_status,omitempty"`
	ErrorKind string `json:"error_kind,omitempty"`
	Error     string `json:"error,omitempty"`
	Quota     string `json:"check_quota"`
	NotBefore string `json:"retry_not_before,omitempty"`
}

const keyTestCost = "one request against the check endpoint's daily limit; the separate blacklist download limit is not used"

func cmdFeedsAbuseIPDBTest(cfg *nftbanconf.Config) error {
	rep := keyTestReport{Endpoint: "GET " + feeds.AbuseIPDBCheckURL + "?ipAddress=127.0.0.1&maxAgeInDays=1", Cost: keyTestCost, Quota: "unknown"}
	key, err := feeds.ReadCredentialFile(abuseIPDBKeyPath(cfg))
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		var res *feeds.KeyTestResult
		res, err = feeds.TestAbuseIPDBKey(ctx, nil, "", key)
		if err == nil {
			rep.OK, rep.Status = true, res.Status
			rep.Quota = quotaText(res.RateLimit)
		}
	}
	if err != nil {
		rep.Error = err.Error()
		var pe *feeds.ProviderError
		if errors.As(err, &pe) {
			rep.ErrorKind, rep.Status = pe.Kind, pe.Status
			rep.Quota = quotaText(pe.RateLimit)
			if !pe.NotBefore.IsZero() {
				rep.NotBefore = pe.NotBefore.UTC().Format(time.RFC3339)
			}
		}
	}
	if hasFlag("--json") {
		data, jerr := json.Marshal(rep)
		if jerr != nil {
			return jerr
		}
		fmt.Println(string(data))
	} else {
		fmt.Println("AbuseIPDB key test")
		fmt.Printf("  Request: %s\n", rep.Endpoint)
		fmt.Printf("  Cost:    %s\n", rep.Cost)
		if rep.OK {
			fmt.Printf("  Result:  key accepted (HTTP %d)\n", rep.Status)
		} else {
			fmt.Printf("  Result:  FAILED: %s\n", rep.Error)
		}
		fmt.Printf("  Check-endpoint quota: %s\n", rep.Quota)
		fmt.Println("  The test downloads nothing: the feed snapshot and its last successful refresh are unchanged.")
	}
	if !rep.OK {
		return errors.New("AbuseIPDB key test failed")
	}
	return nil
}

func quotaText(rl feeds.RateLimitInfo) string {
	if !rl.Known {
		return "unknown (the provider did not state it)"
	}
	s := fmt.Sprintf("%d of %d left", rl.Remaining, rl.Limit)
	if !rl.ResetAt.IsZero() {
		s += ", resets " + rl.ResetAt.UTC().Format("2006-01-02 15:04 UTC")
	}
	return s
}
