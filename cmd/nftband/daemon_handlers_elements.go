// =============================================================================
// NFTBan v1.0 - nftband Daemon - Set element add/delete/flush handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Set element add/delete/flush handlers"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/persistence"
	"github.com/itcmsgr/nftban/internal/rulefp"
	"github.com/itcmsgr/nftban/internal/safety"
)

// handleAddElementRequest adds an element to any set
func (d *Daemon) handleAddElementRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)
	element, _ := params["element"].(string)

	if table == "" || set == "" || element == "" {
		return SocketResponse{Success: false, Error: "missing table, set, or element parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	// L3a — never-ban invariant on the generic add path (handler-level reject for clear
	// operator/API feedback). The backend enforces the same as defense-in-depth, so this
	// is a UX layer, not the sole guard. Enforcement sets + single exempt IP only.
	if nftbackend.IsEnforcementSet(set) {
		if exempt, reason := d.backend.IsExempt(element); exempt {
			log.Printf("[ADD_ELEMENT] REFUSED (never-ban exempt: %s) set=%s ip=%s — protected IP NOT added to enforcement set", reason, set, element)
			return SocketResponse{Success: false, Error: fmt.Sprintf("refused: never-ban exempt (%s) — %s not added to enforcement set %s", reason, element, set)}
		}
	}

	timeout := 0
	if t, ok := params["timeout"].(float64); ok {
		timeout = int(t)
	}

	err := d.backend.AddElement(d.ctx, nftbackend.AddElementRequest{
		Table:   table,
		Set:     set,
		Element: element,
		Timeout: timeout,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":   table,
			"set":     set,
			"element": element,
		},
	}
}

// handleDeleteElementRequest removes an element from any set
func (d *Daemon) handleDeleteElementRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)
	element, _ := params["element"].(string)

	if table == "" || set == "" || element == "" {
		return SocketResponse{Success: false, Error: "missing table, set, or element parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	err := d.backend.DeleteElement(d.ctx, nftbackend.DeleteElementRequest{
		Table:   table,
		Set:     set,
		Element: element,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":   table,
			"set":     set,
			"element": element,
			"status":  "deleted",
		},
	}
}

// handleFlushSetRequest flushes all elements from a set
func (d *Daemon) handleFlushSetRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)

	if table == "" || set == "" {
		return SocketResponse{Success: false, Error: "missing table or set parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	err := d.backend.FlushSet(d.ctx, nftbackend.FlushSetRequest{
		Table: table,
		Set:   set,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":  table,
			"set":    set,
			"status": "flushed",
		},
	}
}

// handleApplyRulesetRequest applies a ruleset from file
func (d *Daemon) handleApplyRulesetRequest(params map[string]any) SocketResponse {
	filePath, _ := params["file"].(string)
	check, _ := params["check"].(bool)

	if filePath == "" {
		return SocketResponse{Success: false, Error: "missing file parameter"}
	}

	// Security: reject path traversal attempts before any further processing
	if strings.Contains(filePath, "..") {
		return SocketResponse{Success: false, Error: "path traversal not allowed"}
	}

	// Security: restrict ruleset paths to allowed directories
	absPath := filepath.Clean(filePath)
	var err error
	absPath, err = filepath.Abs(absPath)
	if err != nil {
		return SocketResponse{Success: false, Error: "invalid file path: " + err.Error()}
	}
	// Double-check after Clean/Abs (defense-in-depth)
	if strings.Contains(absPath, "..") {
		return SocketResponse{Success: false, Error: "path traversal not allowed"}
	}
	runDir, configDir, dataDir, _ := getDaemonPaths()
	if !strings.HasPrefix(absPath, dataDir+"/") &&
		!strings.HasPrefix(absPath, configDir+"/") &&
		!strings.HasPrefix(absPath, runDir+"/") {
		return SocketResponse{Success: false, Error: "file path must be within " + dataDir + "/, " + configDir + "/, or " + runDir + "/"}
	}

	// P1S-A — RETIRE THE ENFORCEMENT-SET ELEMENT-ADD FALLBACK (v1.231.0).
	//
	// apply_ruleset hands a file to `nft -f` and was restricted BY PATH ONLY. A
	// fragment containing "add element <table> blacklist_ipv4 { ... }" therefore
	// reached the kernel without passing ANY never-ban authority — not Ban's,
	// not AddElement's, not the sync path's new prefix subtraction. It was the
	// last writer of a drop set with no exemption check at all.
	//
	// The only shipped producer of such a fragment is the legacy additive fallback
	// in nft_ipc_sync_or_apply (lib/nft_ipc.sh), used by feeds and geoban when the
	// full-sync IPC fails. That fallback is retired here rather than guarded, and
	// retired AT THE AUTHORITY rather than at the caller, because:
	//   - it cannot do the job it was added for: it travels the SAME daemon socket
	//     as the sync it is meant to rescue, so a down daemon refuses both;
	//   - its stated purpose was mixed-version rollout safety for the v1.213.0
	//     single-writer change, and the fleet has since converged past it;
	//   - it is ADDITIVE, so it contradicts the unified flush-first replace it
	//     falls back from: it can add a prefix but never retract one;
	//   - the durable source (feeds/*.txt, geoban.d/*.conf) is written BEFORE the
	//     sync is requested, so refusing the fallback delays convergence to the
	//     next sync or timer — it never loses operator state.
	// Rewriting the fragment instead was rejected: splitting prefixes inside a file
	// the caller named means mutating an operator-visible artefact at the apply
	// boundary, and rejecting it whole would drop a legitimate feed load because one
	// admin IP sits inside it.
	//
	// Scoped to ADD into an ENFORCEMENT set: `delete element` on a blacklist
	// (cmd_flush) removes enforcement and can never lock anyone out, whitelist and
	// port element adds are untouched, and chain/rule/set-definition fragments
	// (cmd_port, cmd_nftables, ddos-suricata) contain no element adds at all.
	if set, found, scanErr := applyRulesetEnforcementElementAdd(absPath); scanErr != nil {
		// Unreadable input is not clearance to apply it unexamined.
		return SocketResponse{Success: false, Error: "cannot inspect ruleset file: " + scanErr.Error()}
	} else if found {
		log.Printf("[APPLY_RULESET] REFUSED: %s adds elements to enforcement set %q — the legacy additive element-add path is retired (never-ban exemption is not enforceable on a raw nft fragment); write the durable source and request a full sync instead", absPath, set)
		return SocketResponse{Success: false, Error: "refused: ruleset adds elements to enforcement set " + set + " (legacy additive element-add path retired; use a full sync)"}
	}

	err = d.backend.ApplyRuleset(d.ctx, nftbackend.ApplyRulesetRequest{
		FilePath: absPath,
		Check:    check,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	// SEC-RULEFP (v1.138): on a trusted successful apply (NOT a dry-run --check),
	// (re)capture the ruleset fingerprint baseline. Capture failure is logged but
	// MUST NOT fail the apply nor corrupt active firewall state — the ruleset is
	// already applied; verify-rules would just report BASELINE_MISSING until the
	// next successful capture. Never captured on a verify path (no self-heal).
	if !check {
		if cerr := rulefp.CaptureLive(d.ctx, rulefp.BaselineFile); cerr != nil {
			log.Printf("[RULEFP] baseline capture after apply failed (non-fatal): %v", cerr)
		}
	}

	action := "applied"
	if check {
		action = "validated"
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"file":   filePath,
			"status": action,
		},
	}
}

// handleCheckRequest checks if an IP is banned
func (d *Daemon) handleCheckRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)

	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	banned, set, err := d.backend.CheckIP(d.ctx, ip)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":     ip,
			"banned": banned,
			"set":    set,
		},
	}
}

// handlePersistBanRequest adds an IP to persistent blacklist files
func (d *Daemon) handlePersistBanRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	reason, _ := params["reason"].(string)
	source, _ := params["source"].(string)
	if source == "" {
		source = "manual"
	}

	// Get config directory
	_, configDir, _, _ := getDaemonPaths()

	// Persist the ban
	result, filename, err := persistence.PersistBan(configDir, ip, reason, source)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	// Track permanent ban for protect/evict functionality
	// This enables 'nftban protect' and 'nftban cleanup' commands to work
	if err := safety.TrackPermanentBan(ip, reason, source, false); err != nil {
		log.Printf("[PERSIST] Warning: failed to track permanent ban for %s: %v", ip, err)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":       ip,
			"result":   string(result),
			"filename": filename,
		},
	}
}

// handleUnpersistBanRequest removes an IP from all persistent blacklist files
func (d *Daemon) handleUnpersistBanRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// Get config directory
	_, configDir, _, _ := getDaemonPaths()

	// Remove from all blacklist files
	filesModified, err := persistence.UnpersistBan(configDir, ip)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	// Remove from permanent ban tracking
	if err := safety.RemovePermanentBan(ip); err != nil {
		log.Printf("[UNPERSIST] Warning: failed to remove permanent ban tracking for %s: %v", ip, err)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":             ip,
			"files_modified": filesModified,
		},
	}
}

// applyRulesetElementHeadLimit bounds how much of each statement is inspected. An
// `add element` statement's target is in its first few tokens; geoban writes an
// entire country's CIDR list on ONE line, so the tail of a line must be skippable
// without buffering it.
const applyRulesetElementHeadLimit = 512

// applyRulesetEnforcementElementAdd reports whether an nft fragment contains an
// "add element" statement targeting an enforcement (drop) set, and which set.
//
// Deliberately permissive on the REJECT side of "add element": it treats any of the
// statement's leading tokens matching an enforcement set name as a hit, rather than
// pinning a token position, so a family or table spelling it did not anticipate
// cannot slip an element add past it. That permissiveness is bounded to statements
// that begin with "add element" — no chain, rule or set-definition fragment can be
// caught by it, and "delete element" is explicitly not matched.
func applyRulesetEnforcementElementAdd(path string) (string, bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", false, err
	}
	defer func() { _ = f.Close() }()

	br := bufio.NewReaderSize(f, 64*1024)
	for {
		head, err := readStatementHead(br, applyRulesetElementHeadLimit)
		if len(head) > 0 {
			if set, ok := enforcementElementAddTarget(string(head)); ok {
				return set, true, nil
			}
		}
		if err != nil {
			if err == io.EOF {
				return "", false, nil
			}
			return "", false, err
		}
	}
}

// enforcementElementAddTarget inspects one statement head.
func enforcementElementAddTarget(head string) (string, bool) {
	fields := strings.Fields(strings.TrimSpace(head))
	if len(fields) < 3 || fields[0] != "add" || fields[1] != "element" {
		return "", false
	}
	// Target set sits among the tokens between "element" and the element brace.
	for _, tok := range fields[2:] {
		if strings.HasPrefix(tok, "{") {
			break
		}
		tok = strings.TrimSuffix(tok, "{")
		if nftbackend.IsEnforcementSet(tok) {
			return tok, true
		}
	}
	return "", false
}

// readStatementHead returns up to limit bytes of the next newline-terminated line,
// discarding the remainder of an over-long line without buffering it. The returned
// error is io.EOF once the final line has been delivered.
func readStatementHead(br *bufio.Reader, limit int) ([]byte, error) {
	var head []byte
	for {
		chunk, err := br.ReadSlice('\n')
		if n := limit - len(head); n > 0 {
			if n > len(chunk) {
				n = len(chunk)
			}
			head = append(head, chunk[:n]...)
		}
		if err == bufio.ErrBufferFull {
			continue // same line, keep draining
		}
		return head, err
	}
}
