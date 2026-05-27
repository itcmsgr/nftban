// =============================================================================
// NFTBan - Ruleset fingerprint baseline + verify (SEC-RULEFP, v1.138 PR-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rulefp_baseline"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Capture/verify the canonical nftban ruleset fingerprint baseline. CaptureBaseline writes the expected digest (atomic temp+rename, 0640) after a successful apply/rebuild; Verify recomputes the live digest and reports OK / MISMATCH / BASELINE_MISSING / NFT_UNAVAILABLE without mutating any rules. LiveRuleset fetches the nftban ip/ip6 table text via nft."
// meta:input="baseline file path; live nftban ruleset text"
// meta:output="VerifyStatus + expected/actual digests"
// meta:depends="context,encoding/json,os,os/exec,path/filepath,time"
// meta:inventory.files="/var/lib/nftban/state/ruleset_fingerprint.json"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="CAP_NET_ADMIN (nft read)"
// =============================================================================

package rulefp

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

// VerifyStatus is the outcome of a verify-rules check.
type VerifyStatus string

const (
	// StatusOK — live digest matches the baseline.
	StatusOK VerifyStatus = "OK"
	// StatusMismatch — live digest differs (possible rule injection / chain-policy flip).
	StatusMismatch VerifyStatus = "MISMATCH"
	// StatusBaselineMissing — no baseline captured yet.
	StatusBaselineMissing VerifyStatus = "BASELINE_MISSING"
	// StatusNFTUnavailable — nft / kernel ruleset not readable.
	StatusNFTUnavailable VerifyStatus = "NFT_UNAVAILABLE"
)

// baselineSchema is the on-disk baseline format (extensible).
// Fields: Schema="rulefp-1", Digest=hex sha256 of normalized ruleset, CapturedAt=RFC3339.
type baselineSchema struct {
	Schema     string `json:"schema"`
	Digest     string `json:"digest"`
	CapturedAt string `json:"captured_at"`
}

const baselineSchemaTag = "rulefp-1"

// BaselineFile is the canonical baseline location under the FHS state dir
// (/var/lib/nftban/state, 0750 nftban:nftban — see internal/installer/fhs/paths.go
// StateDir). Both the daemon apply hook and the verify-rules CLI use this one path
// so there is a single baseline format/location.
const BaselineFile = "/var/lib/nftban/state/ruleset_fingerprint.json"

// CaptureLive fetches the live nftban ruleset and writes its fingerprint baseline
// to path. Call this ONLY after a trusted, successful apply/rebuild — never from
// a verify path (otherwise an injected rule could become the new "truth").
func CaptureLive(ctx context.Context, path string) error {
	text, err := LiveRuleset(ctx)
	if err != nil {
		return err
	}
	return CaptureBaseline(path, text)
}

// CaptureBaseline writes the fingerprint of rulesetText to path atomically
// (temp + rename), mode 0640. Called after a successful apply/rebuild.
func CaptureBaseline(path, rulesetText string) error {
	b := baselineSchema{
		Schema:     baselineSchemaTag,
		Digest:     Digest(rulesetText),
		CapturedAt: time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.MarshalIndent(b, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal baseline: %w", err)
	}
	data = append(data, '\n')

	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o640); err != nil { // #nosec G306 -- 0640 group-readable by design
		return fmt.Errorf("write baseline tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename baseline: %w", err)
	}
	return nil
}

// Verify recomputes the live fingerprint and compares it to the baseline at
// path. It NEVER mutates rules. Returns the status plus the expected (baseline)
// and actual (live) digests for diagnostics.
func Verify(path, currentRulesetText string) (status VerifyStatus, expected, actual string) {
	actual = Digest(currentRulesetText)

	data, err := os.ReadFile(filepath.Clean(path))
	if err != nil {
		if os.IsNotExist(err) {
			return StatusBaselineMissing, "", actual
		}
		// Unreadable baseline is treated as missing (caller logs the error).
		return StatusBaselineMissing, "", actual
	}

	var b baselineSchema
	if err := json.Unmarshal(data, &b); err != nil || b.Digest == "" {
		return StatusBaselineMissing, "", actual
	}
	expected = b.Digest
	if expected == actual {
		return StatusOK, expected, actual
	}
	return StatusMismatch, expected, actual
}

// LiveRuleset returns the concatenated nftban table text for the ip and ip6
// families (whichever exist). It is the canonical input for Digest/Verify.
// Returns ("", error) only when neither family table can be read (→ caller maps
// to NFT_UNAVAILABLE). A missing ip6 table alone is not fatal.
func LiveRuleset(ctx context.Context) (string, error) {
	var combined string
	var firstErr error
	got := false
	for _, fam := range []string{"ip", "ip6"} {
		// #nosec G204 -- fam is a constant from the literal slice; table name fixed.
		out, err := exec.CommandContext(ctx, "nft", "list", "table", fam, "nftban").Output()
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		combined += "# family " + fam + "\n" + string(out) + "\n"
		got = true
	}
	if !got {
		return "", fmt.Errorf("nft list table failed for all families: %w", firstErr)
	}
	return combined, nil
}

// VerifyLive fetches the live ruleset and verifies it against the baseline at
// path, mapping an nft failure to NFT_UNAVAILABLE.
func VerifyLive(ctx context.Context, path string) (status VerifyStatus, expected, actual string, err error) {
	text, lerr := LiveRuleset(ctx)
	if lerr != nil {
		return StatusNFTUnavailable, "", "", lerr
	}
	status, expected, actual = Verify(path, text)
	return status, expected, actual, nil
}
