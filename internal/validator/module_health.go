// =============================================================================
// NFTBan v1.81 - Module Health Evaluator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module_health"
// meta:type="lib"
// meta:version="1.81.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Per-module 4-axis health evaluation per M81-4 HEALTH_METRIC_DERIVATION_v1.81.md"
// meta:inventory.files="internal/validator/module_health.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="conf.d/botguard/main.conf,conf.d/ddos/main.conf,conf.d/portscan/main.conf,conf.d/login_alert.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// This evaluator implements the truth tables from HEALTH_METRIC_DERIVATION_v1.81.md.
// It MUST NOT invent derivation logic outside that specification.
// All state values are vocabulary-approved terms from NFTBAN_VOCABULARY_REFERENCE_v1.81.md.
// =============================================================================
package validator

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ConfigDir is the base config directory. Overridable for testing.
var ConfigDir = "/etc/nftban"

// DataDir is the base data directory (project NFTBAN_DATA_DIR). Resolved from the
// environment with the project-canonical default; overridable for testing.
// Mirrors the shell rule `${NFTBAN_DATA_DIR:-/var/lib/nftban}` used by
// cmd_geoip.sh / cmd_selftest.sh so the validator looks for the GeoIP DB in the
// same place the geoip sync writes it (instead of a hardcoded /var/lib/nftban).
var DataDir = resolveDataDir()

// resolveDataDir honors NFTBAN_DATA_DIR when set, else the canonical default.
func resolveDataDir() string {
	if d := os.Getenv("NFTBAN_DATA_DIR"); d != "" {
		return d
	}
	return "/var/lib/nftban"
}

// evaluateModuleHealth evaluates all modules and returns the health map.
// Called from ValidateKernel after structural + runtime checks.
// evaluateModuleHealth evaluates all modules and returns the health map.
// Also populates moduleFindings with any module-specific findings.
// The caller MUST append moduleFindings to result.Findings after this call.
func evaluateModuleHealth(doc *RulesetDocument, svcState ServiceState) ModuleHealthMap {
	moduleFindings = nil // reset for this evaluation cycle
	m := ModuleHealthMap{}

	m.BotGuard = evaluateBotGuard(doc, svcState)
	m.DDoS = evaluateDDoS(doc)
	m.Portscan = evaluatePortscan(doc)
	m.LoginMon = evaluateLoginMon(svcState)
	m.Blacklist = evaluateBlacklist(doc)

	return m
}

// =============================================================================
// BotGuard — daemon-dependent, set-based evidence
// =============================================================================

func evaluateBotGuard(doc *RulesetDocument, svcState ServiceState) *ModuleHealth {
	h := &ModuleHealth{}

	// Config axis
	h.Config = readConfigBool("conf.d/botguard/main.conf.local", "conf.d/botguard/main.conf", "HTTP_BOTGUARD_ENABLED")
	if h.Config == ConfigDisabled {
		return h // disabled → skip all other axes
	}

	// Structural axis: 6 sets + chain per family.
	// Per M81 Rule 9 (per-family aggregation): check each active family.
	// IPv4 is always checked. IPv6 checked only if ip6 nftban table exists.
	bgSetsV4 := []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency"}
	bgSetsV6 := []string{"http_bot_suspect6", "http_bot_pending6", "http_bot_allow6",
		"http_bot_grey6", "http_bot_ban6", "http_bot_emergency6"}

	v4Present := true
	for _, s := range bgSetsV4 {
		if !doc.SetExists("ip", "nftban", s) {
			v4Present = false
			break
		}
	}
	v4Present = v4Present && doc.ChainExists("ip", "nftban", "http_bot_guard")

	// IPv6: only required if ip6 nftban table exists
	v6Required := doc.TableExists("ip6", "nftban")
	v6Present := true
	if v6Required {
		for _, s := range bgSetsV6 {
			if !doc.SetExists("ip6", "nftban", s) {
				v6Present = false
				break
			}
		}
		v6Present = v6Present && doc.ChainExists("ip6", "nftban", "http_bot_guard")
	}

	if v4Present && (!v6Required || v6Present) {
		h.Structural = StructuralPresent
	} else {
		h.Structural = StructuralMissing
	}

	// Runtime axis: daemon required for BotGuard.
	// A1-2: Refine with journal evidence — daemon running is necessary but
	// not sufficient. Check journal for BotGuard module registration.
	// If daemon is running but no BotGuard startup evidence in journal,
	// runtime is still RUNNING (daemon is up), but we emit an informational
	// finding. This does NOT downgrade runtime — it adds visibility.
	if svcState.Nftband == RuntimeRunning {
		h.Runtime = RuntimeRunning
		// Check for BotGuard module registration in recent journal
		evidence := queryJournal(context.Background(), JournalQuery{
			Patterns: []string{"module_start: botguard", "[botguard] loaded"},
			Since:    15 * time.Minute,
		})
		if evidence.ErrKind == ErrNone && !evidence.Found {
			// Daemon running but no recent BotGuard startup evidence.
			// This may indicate the module hasn't restarted recently (normal)
			// or the module failed to register (abnormal). Not a downgrade.
			// Only emit finding if structural objects exist (module should be active).
			if h.Structural == StructuralPresent {
				moduleFindings = append(moduleFindings, Finding{
					Code:      CodeBotGuardNoEvidence,
					Severity:  SeverityInfo,
					Component: "module",
					Message:   "no recent BotGuard runtime evidence in journal (last 15m)",
				})
			}
		}
	} else {
		h.Runtime = svcState.Nftband
	}

	// Effective axis: set population as evidence
	if h.Structural == StructuralMissing || h.Runtime != RuntimeRunning {
		// Cannot determine effective state without structure + runtime
		h.Effective = EffectiveIdle
		return h
	}

	// v1.211 HEALTH-FALSE-ZERO: read enforcement-relevant sets with the 3-valued
	// reader. A FAILED read (unknown) must NOT collapse to a false "idle"/"enforcing":
	// a populated/empty set proves state, but a failed query proves nothing.
	readUnknown := false

	// Check enforcement sets (ban, grey, emergency)
	enforcementSets := []string{"http_bot_ban", "http_bot_grey", "http_bot_emergency"}
	for _, s := range enforcementSets {
		count, _, unknown := countSetElementsState("ip", s)
		if unknown {
			readUnknown = true
			continue
		}
		if count > 0 {
			h.Effective = EffectiveEnforcing
			return h
		}
	}

	// Check observation sets (suspect, pending)
	observationSets := []string{"http_bot_suspect", "http_bot_pending"}
	for _, s := range observationSets {
		count, _, unknown := countSetElementsState("ip", s)
		if unknown {
			readUnknown = true
			continue
		}
		if count > 0 {
			h.Effective = EffectiveObserving
			return h
		}
	}

	// A set read FAILED and no live set proved enforcing/observing → we cannot
	// prove "empty". Degrade (WARN) instead of rendering a false idle/clean.
	if readUnknown {
		markEnforcementUnknown(h, "botguard")
		return h
	}

	// All sets confirmed empty/absent → idle (valid per BUG-3 lesson; empty set on
	// an enabled module is NEUTRAL, not noisy).
	h.Effective = EffectiveIdle
	return h
}

// =============================================================================
// DDoS — kernel-only enforcement, daemon NOT required
// =============================================================================

func evaluateDDoS(doc *RulesetDocument) *ModuleHealth {
	h := &ModuleHealth{}

	// Config axis
	h.Config = readConfigBool("conf.d/ddos/main.conf.local", "conf.d/ddos/main.conf", "DDOS_ENABLED")

	// Structural axis: 4 required chains in IPv4.
	// GAP-D1: Also check IPv6 if ip6 table exists — DDoS chains should
	// be present in both families for full dual-stack protection.
	ddosChains := []string{"ddos_sanity", "ddos_penalty", "ddos_prefix", "ddos_protection"}
	allPresent := true
	for _, c := range ddosChains {
		if !doc.ChainExists("ip", "nftban", c) {
			allPresent = false
			break
		}
	}
	// Check IPv6 if table exists
	if allPresent && doc.TableExists("ip6", "nftban") {
		for _, c := range ddosChains {
			if !doc.ChainExists("ip6", "nftban", c) {
				allPresent = false
				break
			}
		}
	}
	if allPresent {
		h.Structural = StructuralPresent
	} else {
		h.Structural = StructuralMissing
	}

	// Runtime: not required for DDoS (kernel-only enforcement)
	// Omit from output

	// Effective axis: check DDoS enforcement counters from kernel.
	// Per M81-3 DDoS contract: each counter is PRIMARY ENFORCEMENT evidence.
	// Any counter > 0 = ENFORCING. All zero = IDLE (neutral).
	if h.Structural == StructuralPresent {
		ddosCounters := []string{
			"input_ct_ssh_drop",
			"input_ct_http_drop",
			"input_ct_mail_drop",
			"input_syn_rate_exceeded",
		}
		enforcing := false
		for _, name := range ddosCounters {
			if doc.GetCounter("ip", "nftban", name) > 0 {
				enforcing = true
				break
			}
		}
		// Also check IPv6 SYN prefix counter
		if !enforcing && doc.GetCounter("ip6", "nftban", "input_syn_prefix_drop") > 0 {
			enforcing = true
		}

		if enforcing {
			h.Effective = EffectiveEnforcing
		} else {
			h.Effective = EffectiveIdle // zero = NEUTRAL per vocabulary Rule 1
		}
	}

	return h
}

// =============================================================================
// Portscan — kernel-only, no counter evidence available
// =============================================================================

func evaluatePortscan(doc *RulesetDocument) *ModuleHealth {
	h := &ModuleHealth{}

	h.Config = readConfigBool("conf.d/portscan/main.conf.local", "conf.d/portscan/main.conf", "PORTSCAN_ENABLED")

	// GAP-P1: Check both IPv4 and IPv6 (if ip6 table exists).
	if doc.ChainExists("ip", "nftban", "portscan_detection") {
		if doc.TableExists("ip6", "nftban") && !doc.ChainExists("ip6", "nftban", "portscan_detection") {
			h.Structural = StructuralMissing // IPv4 present but IPv6 missing
		} else {
			h.Structural = StructuralPresent
		}
	} else {
		h.Structural = StructuralMissing
	}

	// Portscan has no dedicated counter — effective state is always IDLE
	// from the validator's perspective. Real enforcement evidence requires
	// kernel log parsing which is outside the validator's scope (M81-7 gap).
	h.Effective = EffectiveIdle

	return h
}

// =============================================================================
// LoginMon — daemon-dependent, no dedicated kernel objects
// =============================================================================

func evaluateLoginMon(svcState ServiceState) *ModuleHealth {
	h := &ModuleHealth{}

	h.Config = readConfigBool("conf.d/login_alert.conf.local", "conf.d/login_alert.conf", "NFTBAN_LOGIN_ALERT_ENABLED")
	if h.Config == ConfigDisabled {
		return h
	}

	// Structural: LoginMon has no dedicated kernel objects.
	// Its presence is proven by runtime evidence (daemon + bindings).
	// Base blacklist sets are always present (required by base schema).
	h.Structural = StructuralPresent

	// Runtime: daemon required.
	// A1-3: Refine with journal evidence — check for module registration
	// AND source binding. LoginMon runtime is meaningful only when sources
	// are actually bound (path resolution succeeded).
	if svcState.Nftband == RuntimeRunning {
		h.Runtime = RuntimeRunning
		// Check for LoginMon module registration AND source binding.
		// Both must be present — module_start alone proves the module loaded,
		// but sources must be bound for LoginMon to actually process events.
		// Two separate queries with AND semantics (not OR).
		// v1.216.2 health-truth: also accept the periodic source-binding heartbeat
		// ("loginmon_source_binding_heartbeat", emitted every 5m while running) as
		// registration evidence. The one-shot "module_start: loginmon" line ages out
		// of this bounded 15m window on quiet/long-running (and volatile-journald)
		// hosts; the heartbeat keeps a healthy running+bound module from tripping a
		// false VAL-LOGINMON-001. When sources are bound the heartbeat also carries
		// "resolved_by=", so the binding query below refreshes from the same line.
		regEvidence := queryJournal(context.Background(), JournalQuery{
			Patterns: []string{"module_start: loginmon", "loginmon_source_binding_heartbeat"},
			Since:    15 * time.Minute,
		})
		bindEvidence := queryJournal(context.Background(), JournalQuery{
			Patterns: []string{"resolved_by="},
			Since:    15 * time.Minute,
		})
		// Only emit finding when both queries succeeded (no error) and
		// at least one required evidence is missing.
		regOK := regEvidence.ErrKind == ErrNone
		bindOK := bindEvidence.ErrKind == ErrNone
		if regOK && bindOK && (!regEvidence.Found || !bindEvidence.Found) {
			moduleFindings = append(moduleFindings, Finding{
				Code:      CodeLoginMonNoEvidence,
				Severity:  SeverityInfo,
				Component: "module",
				Message:   "no recent LoginMon runtime + source-binding evidence in journal (last 15m)",
			})
		}
	} else {
		h.Runtime = svcState.Nftband
	}

	// Effective: LoginMon enforcement is through shared blacklist sets.
	// Journal-based evidence (login_failed/banned events) could prove
	// activity but counter attribution is not possible (shared set).
	// Default to idle from validator perspective.
	h.Effective = EffectiveIdle

	// Input axis (v1.183 HEALTH-NO-INPUT-AXIS increment 2): derive input-readability
	// from the daemon's "[LOGINMON] <src>: state=..." startup lines (v1.179 webauth +
	// v1.180 ftpauth). The daemon is the authority on its own watchers; the kernel-truth
	// validator reads it from the journal it already queries. An enabled-but-starved
	// source now surfaces in `nftban health` instead of reading healthy.
	// VAL-LOGINMON-002-UX: classify per-source, distinguishing a benign absent
	// input (no stack/source on this host) from real starvation (stack present
	// but no readable logs). The daemon already separates these — NO_LOGS carries
	// reason=no_<stack> (absent), WARN_NO_LOGS carries reason=<stack>_present_...
	// (starved). Collapsing both into one WARN made every non-web/non-FTP host
	// read as a warning; now an absent source is INFO (no action) while a starved
	// source stays WARN (actionable), and the source + reason are preserved.
	srcs := loginMonSourceStates(context.Background())
	h.Input = InputUnknown
	for _, s := range srcs {
		h.Input = worseInputState(h.Input, s.State)
	}
	if h.Config == ConfigEnabled {
		for _, s := range srcs {
			switch s.State {
			case InputWarnNoLogs:
				// Stack/source present but produced no readable logs → actionable.
				if loginMonSourceAcked(s.Name) {
					moduleFindings = append(moduleFindings, Finding{
						Code:      CodeLoginMonNoInput,
						Severity:  SeverityInfo,
						Component: "module",
						Message:   "LoginMon " + s.Name + " source present but produced no readable logs" + loginMonReasonSuffix(s.Reason) + " — operator-acked via LOGINMON_SOURCE_ACK (starved by design); no action needed",
					})
				} else {
					moduleFindings = append(moduleFindings, Finding{
						Code:        CodeLoginMonNoInput,
						Severity:    SeverityWarn,
						Component:   "module",
						Message:     "LoginMon " + s.Name + " source present but produced no readable logs" + loginMonReasonSuffix(s.Reason),
						Remediation: loginMonRemediation(s.Name),
					})
				}
			case InputNoLogs:
				// Source/stack structurally absent on this host → benign, no action.
				moduleFindings = append(moduleFindings, Finding{
					Code:      CodeLoginMonNoInput,
					Severity:  SeverityInfo,
					Component: "module",
					Message:   "LoginMon " + s.Name + " source not present on this host" + loginMonReasonSuffix(s.Reason) + "; no action needed",
				})
			}
		}
	}

	return h
}

// loginMonSource is a per-source input-state observation parsed from a daemon
// "[LOGINMON] <src>: state=<TOK> ... reason=<reason>" journal line.
type loginMonSource struct {
	Name   string
	State  InputState
	Reason string
}

// loginMonSourceStates returns the per-source input-state observations for
// LoginMon's discovered sources from the daemon's "[LOGINMON] <src>: state=..."
// journal lines. The daemon is the authority on its own watchers; the validator
// only reads what it already emits. Sources with no journal evidence are omitted.
func loginMonSourceStates(ctx context.Context) []loginMonSource {
	var out []loginMonSource
	for _, name := range []string{"webauth", "ftpauth", "roundcube"} {
		ev := queryJournal(ctx, JournalQuery{
			Patterns: []string{"[LOGINMON] " + name + ": state="},
			Since:    15 * time.Minute,
		})
		if ev.ErrKind != ErrNone || !ev.Found {
			continue
		}
		out = append(out, loginMonSource{
			Name:   name,
			State:  parseLoginMonState(ev.MatchedLine),
			Reason: parseLoginMonReason(ev.MatchedLine),
		})
	}
	return out
}

// loginMonReasonSuffix renders a " (reason=<r>)" suffix, or empty when absent.
func loginMonReasonSuffix(reason string) string {
	if reason == "" {
		return ""
	}
	return " (reason=" + reason + ")"
}

// loginMonSourceAcked reports whether the operator has acknowledged a
// starved-by-design LoginMon source via LOGINMON_SOURCE_ACK in the login module
// config (.local override first). An acked starved source is reported as INFO
// (still visible in findings), never silently hidden. v1.200 (VAL-LOGINMON-002).
func loginMonSourceAcked(name string) bool {
	ack := readKeyFromFile(filepath.Join(ConfigDir, "conf.d/login/main.conf.local"), "LOGINMON_SOURCE_ACK")
	if ack == "" {
		ack = readKeyFromFile(filepath.Join(ConfigDir, "conf.d/login/main.conf"), "LOGINMON_SOURCE_ACK")
	}
	for _, f := range strings.Fields(ack) {
		if strings.EqualFold(strings.TrimSpace(f), name) {
			return true
		}
	}
	return false
}

// loginMonRemediation returns the EXACT remediation for a starved LoginMon source,
// keyed by source name. v1.200 (VAL-LOGINMON-002): turns an actionable WARN into a
// step the operator can follow, and points at the ack knob for starved-by-design hosts.
func loginMonRemediation(name string) string {
	switch name {
	case "roundcube":
		return "Roundcube is present but login logging is off: set $config['log_logins'] = true; in the Roundcube config (config.inc.php) so credential failures are logged, then reload the webmail PHP worker. If this host intentionally does not collect Roundcube login logs, ack it: add 'roundcube' to LOGINMON_SOURCE_ACK in conf.d/login/main.conf.local."
	case "webauth":
		return "The web stack is present but NFTBan reads no auth logs: confirm the web/panel access or auth log exists and is readable and that login attempts are logged there. If web login monitoring is not wanted on this host, ack it: add 'webauth' to LOGINMON_SOURCE_ACK in conf.d/login/main.conf.local."
	case "ftpauth":
		return "The FTP stack is present but NFTBan reads no auth logs: confirm the FTP daemon auth log path exists and is readable and that login attempts are logged. If FTP login monitoring is not wanted on this host, ack it: add 'ftpauth' to LOGINMON_SOURCE_ACK in conf.d/login/main.conf.local."
	default:
		return "Confirm the " + name + " log path is present and readable and that the application logs auth events; or ack it via LOGINMON_SOURCE_ACK in conf.d/login/main.conf.local if starved by design."
	}
}

// parseLoginMonState extracts the input-state token from a "[LOGINMON] <src>: state=<TOK> ..."
// line and maps it to the InputState vocabulary.
func parseLoginMonState(line string) InputState {
	const marker = "state="
	i := strings.Index(line, marker)
	if i < 0 {
		return InputUnknown
	}
	tok := line[i+len(marker):]
	if j := strings.IndexAny(tok, " \t\r\n"); j >= 0 {
		tok = tok[:j]
	}
	switch tok {
	case "OK":
		return InputOK
	case "WARN_NO_LOGS":
		return InputWarnNoLogs
	case "NO_LOGS":
		return InputNoLogs
	default:
		return InputUnknown
	}
}

// parseLoginMonReason extracts the reason token from a
// "[LOGINMON] <src>: state=<TOK> ... reason=<reason>" line, or "" if absent.
// The reason (e.g. no_web_stack vs web_stack_present_no_access_logs) is what
// lets an operator tell "not installed here" from "installed but unreadable".
func parseLoginMonReason(line string) string {
	const marker = "reason="
	i := strings.Index(line, marker)
	if i < 0 {
		return ""
	}
	tok := line[i+len(marker):]
	if j := strings.IndexAny(tok, " \t\r\n"); j >= 0 {
		tok = tok[:j]
	}
	return tok
}

// worseInputState returns the higher-severity of two input states
// (no_logs > warn_no_logs > ok > unknown).
func worseInputState(a, b InputState) InputState {
	rank := map[InputState]int{InputUnknown: 0, InputOK: 1, InputWarnNoLogs: 2, InputNoLogs: 3}
	if rank[b] > rank[a] {
		return b
	}
	return a
}

// =============================================================================
// Blacklist — unified: manual + feeds + geoban
// =============================================================================

// ModuleFindings collects findings from module health evaluation.
// These are appended to the main ValidationResult.Findings by the caller.
var moduleFindings []Finding

func evaluateBlacklist(doc *RulesetDocument) *BlacklistHealth {
	bh := &BlacklistHealth{}

	// Manual blacklist
	// GAP-BL1 fix: Read dedicated counter to distinguish ENFORCING from PRIMED.
	// input_blacklist_manual_drop is a dedicated counter for manual bans
	// (shared with LoginMon + portscan bans that land in the same set).
	// elements > 0 + drops > 0 = ENFORCING (traffic is being blocked)
	// elements > 0 + drops = 0 = PRIMED (rules loaded, no matches yet)
	// elements = 0 = IDLE
	// v1.85 GAP-185-9: Count both IPv4 and IPv6 manual blacklist elements.
	// v1.211 HEALTH-FALSE-ZERO: blacklist_manual is THE enforcement set. Read it with
	// the 3-valued reader (countSetElementsState) so a FAILED read (permission/timeout/
	// malformed) degrades to "unknown" instead of collapsing to a false "idle" ("no
	// bans"). Sum counts ONLY from successful reads; a confirmed-empty set on both
	// families stays neutral (idle), exactly as before.
	mv4, _, unknownV4 := countSetElementsState("ip", "blacklist_manual_ipv4")
	mv6, _, unknownV6 := countSetElementsState("ip6", "blacklist_manual_ipv6")
	manualElements := 0
	if !unknownV4 {
		manualElements += mv4
	}
	if !unknownV6 {
		manualElements += mv6
	}
	// Counter: check both families
	manualDrops := doc.GetCounter("ip", "nftban", "input_blacklist_manual_drop")
	manualDrops += doc.GetCounter("ip6", "nftban", "input_blacklist_manual_drop")
	if unknownV4 || unknownV6 {
		// EITHER family read FAILED on THE enforcement set: we cannot prove "no bans".
		// Degrade (WARN) instead of rendering a false idle/primed/enforcing. Mirrors the
		// markEnforcementUnknown mechanism used for BotGuard (CodeModuleDegraded /
		// SeverityWarn finding is the schema-safe surface; State carries "unknown").
		bh.Manual = BlacklistSubHealth{State: "unknown", Entries: manualElements}
		moduleFindings = append(moduleFindings, Finding{
			Code:      CodeModuleDegraded,
			Severity:  SeverityWarn,
			Component: "module",
			Message:   "blacklist_manual set read failed — enforcement state unknown (kernel set query failed; cannot confirm bans loaded vs empty)",
		})
	} else if manualElements > 0 && manualDrops > 0 {
		bh.Manual = BlacklistSubHealth{State: "enforcing", Entries: manualElements, Drops: manualDrops}
	} else if manualElements > 0 {
		bh.Manual = BlacklistSubHealth{State: "primed", Entries: manualElements}
	} else {
		bh.Manual = BlacklistSubHealth{State: "idle", Entries: 0}
	}

	// Feeds: per M81-3 contract, feeds configured + data available = LOADED
	// (not ACTIVE — feeds are data pipeline, not traffic processing).
	// Feeds share blacklist_ipv4 with geoban so element count is shared.
	feedsConfigured := feedsExist()
	if !feedsConfigured {
		bh.Feeds = BlacklistSubHealth{State: "disabled"}
	} else {
		// Feed config exists → check data freshness.
		// GAP-BL5: Check feed data directory for actual downloaded data.
		// If no data files or all data > 7 days old → stale sync.
		feedDataDir := "/var/lib/nftban/feeds"
		feedFresh := feedDataIsFresh(feedDataDir, 7*24*time.Hour)
		if feedFresh {
			bh.Feeds = BlacklistSubHealth{State: "loaded"}
		} else {
			bh.Feeds = BlacklistSubHealth{State: "stale"}
		}
	}

	// Geoban
	geoEnabled := readConfigBool("conf.d/geoban/main.conf.local", "conf.d/geoban/main.conf", "GEOBAN_ENABLED")
	if geoEnabled == ConfigDisabled {
		bh.Geoban = BlacklistSubHealth{State: "disabled"}
	} else {
		// Check if geoip database exists.
		// Per M81-3 contract: enabled + DB missing = DEGRADED (not just stale).
		// Stale = DB exists but older than 45 days (future: check mtime).
		// Per CF-2 resolution: geoban DB missing uses "stale" (in allowed enum)
		// and emits a finding for visibility. "degraded" is not in the blacklist
		// sub-state enum (enforcing|primed|idle|loaded|stale|disabled).
		// Canonical path: ${NFTBAN_DATA_DIR}/geoip/dbip-country-lite.mmdb
		// Downloaded by nftban-core-geoip.timer → nftban geoip sync.
		// Honor NFTBAN_DATA_DIR (via DataDir) instead of hardcoding /var/lib/nftban,
		// matching the shell sync writer; DataDir falls back to the canonical default.
		dbPath := filepath.Join(DataDir, "geoip", "dbip-country-lite.mmdb")
		info, err := os.Stat(dbPath)
		if err != nil || info.Size() == 0 {
			bh.Geoban = BlacklistSubHealth{State: "stale"} // missing DB = stale data
			moduleFindings = append(moduleFindings, Finding{
				Code:        CodeGeobanDBMissing,
				Severity:    SeverityWarn,
				Component:   "module",
				Message:     "GeoIP database missing or empty — geoban enforcement unavailable",
				Remediation: "Run: nftban geoban sync",
			})
		} else if time.Since(info.ModTime()) > 45*24*time.Hour {
			// GAP-BL3: DB exists but older than 45 days → stale data
			bh.Geoban = BlacklistSubHealth{State: "stale"}
			moduleFindings = append(moduleFindings, Finding{
				Code:        CodeGeobanDBMissing,
				Severity:    SeverityWarn,
				Component:   "module",
				Message:     "GeoIP database older than 45 days — data may be inaccurate",
				Remediation: "Run: nftban geoban sync",
			})
		} else {
			bh.Geoban = BlacklistSubHealth{State: "loaded"}
		}
	}

	return bh
}

// =============================================================================
// Config helpers
// =============================================================================

// readConfigBool reads a boolean config key from .local then base conf.
// Returns ConfigEnabled if key="true", ConfigDisabled otherwise.
func readConfigBool(localPath, basePath, key string) ConfigState {
	// Try .local first
	if val := readKeyFromFile(filepath.Join(ConfigDir, localPath), key); val != "" {
		if val == "true" {
			return ConfigEnabled
		}
		return ConfigDisabled
	}
	// Fallback to base
	if val := readKeyFromFile(filepath.Join(ConfigDir, basePath), key); val != "" {
		if val == "true" {
			return ConfigEnabled
		}
	}
	return ConfigDisabled
}

// readKeyFromFile reads a KEY="value" line from a shell config file.
func readKeyFromFile(path, key string) string {
	data, err := os.ReadFile(path) // #nosec G304 — path is constructed from hardcoded ConfigDir + known config filenames, not user input
	if err != nil {
		return ""
	}
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, prefix) {
			val := strings.TrimPrefix(line, prefix)
			val = strings.Trim(val, "\"'")
			return val
		}
	}
	return ""
}

// feedDataIsFresh checks if the feed data directory has files newer than maxAge.
// GAP-BL5: detects stale feed sync (no data or old data = sync not working).
func feedDataIsFresh(dir string, maxAge time.Duration) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false // no data directory = not fresh
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if time.Since(info.ModTime()) < maxAge {
			return true // at least one recent file
		}
	}
	return false // no recent files
}

// feedsExist checks if any feed config files exist.
func feedsExist() bool {
	feedDir := filepath.Join(ConfigDir, "conf.d/feeds")
	entries, err := os.ReadDir(feedDir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".conf") {
			return true
		}
	}
	return false
}

// collectEvidenceSetElements queries element counts for all evidence-relevant sets.
// v1.89 INV-M-001: Validator is the sole kernel-query authority.
// Evidence layer reads from ValidationResult.SetElementCounts instead of
// making its own nft -j list set calls.
func collectEvidenceSetElements() map[string]int {
	result := make(map[string]int)
	evidenceSets := map[string][]string{
		"ip": {
			"blacklist_manual_ipv4", "blacklist_ipv4",
			"http_bot_suspect", "http_bot_pending", "http_bot_allow",
			"http_bot_grey", "http_bot_ban", "http_bot_emergency",
		},
		"ip6": {
			"blacklist_manual_ipv6", "blacklist_ipv6",
			"http_bot_suspect6", "http_bot_pending6", "http_bot_allow6",
			"http_bot_grey6", "http_bot_ban6", "http_bot_emergency6",
		},
	}
	for family, sets := range evidenceSets {
		for _, name := range sets {
			key := family + ":" + name
			result[key] = countSetElements(family, name)
		}
	}
	return result
}

// countSetElements returns the number of elements in a kernel set.
//
// countSetElementsFunc is the default implementation for set element queries.
// Tests override this via the function variable (same pattern as
// defaultServiceChecker in validator.go:70).
var countSetElementsFunc = countSetElementsReal

// countSetElements delegates to countSetElementsFunc for testability.
func countSetElements(family, setName string) int {
	return countSetElementsFunc(family, setName)
}

// countSetElementsReal queries the kernel for actual element count in a set.
// v1.82 CF-4: replaces the v1.81 stub that always returned 0.
//
// Uses `nft -j list set <family> <table> <name>` which returns the full
// set including an "elem" array when elements exist. The "elem" key is
// absent when the set is empty (returns 0 in that case).
//
// This is called for enforcement-critical sets only (BotGuard ban/suspect,
// manual blacklist). The cost is one nft command per set query.
func countSetElementsReal(family, setName string) int {
	table := "nftban"
	out, err := exec.Command("nft", "-j", "list", "set", family, table, setName).Output()
	if err != nil {
		return 0
	}

	// Parse JSON: {"nftables": [{"metainfo":...}, {"set": {..., "elem": [...]}}]}
	var result struct {
		Nftables []struct {
			Set *struct {
				Elem []interface{} `json:"elem"`
			} `json:"set,omitempty"`
		} `json:"nftables"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return 0
	}

	for _, obj := range result.Nftables {
		if obj.Set != nil {
			return len(obj.Set.Elem)
		}
	}
	return 0
}

// countSetElementsState is the 3-valued sibling of countSetElements (v1.211
// HEALTH-FALSE-ZERO). It distinguishes a FAILED read (unknown — cannot prove
// state) from a genuinely EMPTY set and from a CONFIRMED-ABSENT set, so a set
// read failure on an enforcement-relevant set degrades the verdict instead of
// rendering a false idle/clean. It mirrors internal/metrics
// evidence_sets.go:countSetElementsJSON's contract WITHOUT importing
// internal/metrics (that would create a package cycle).
//
// Returns (count, exists, unknown):
//
//	count>0, exists=true,  unknown=false → set present with elements
//	count=0, exists=true,  unknown=false → set present, empty (NEUTRAL — idle ok)
//	count=0, exists=false, unknown=false → set confirmed absent (NEUTRAL — idle ok)
//	count=0, exists=false, unknown=true  → read failed (enforcement state UNKNOWN)
//
// countSetElementsStateFunc is the test seam (same indirection pattern as
// countSetElementsFunc above).
var countSetElementsStateFunc = countSetElementsStateReal

func countSetElementsState(family, setName string) (count int, exists bool, unknown bool) {
	return countSetElementsStateFunc(family, setName)
}

func countSetElementsStateReal(family, setName string) (count int, exists bool, unknown bool) {
	table := "nftban"
	out, err := exec.Command("nft", "-j", "list", "set", family, table, setName).Output()
	if err != nil {
		// Command failure: could be a missing set, but also a timeout/permission/
		// exec error. Mark unknown so callers never treat failure as confirmed empty.
		return 0, false, true
	}

	// Parse JSON: {"nftables": [{"metainfo":...}, {"set": {..., "elem": [...]}}]}
	var result struct {
		Nftables []struct {
			Set *struct {
				Elem []interface{} `json:"elem"`
			} `json:"set,omitempty"`
		} `json:"nftables"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return 0, false, true
	}

	for _, obj := range result.Nftables {
		if obj.Set != nil {
			return len(obj.Set.Elem), true, false
		}
	}
	// Valid JSON, no set object for this name → confirmed absent (NEUTRAL).
	return 0, false, false
}

// markEnforcementUnknown records that a set read FAILED for an enforcement-relevant
// module (v1.211 HEALTH-FALSE-ZERO). The verdict MUST NOT render idle/enforcing as
// if the set were empty, so the module's Effective axis is left UNSET (omitted from
// the frozen M81-6 JSON via omitempty — never the false-idle "idle" token) and a
// SeverityWarn finding is appended. The finding is the schema-safe surface that
// makes the degraded state visible in `--json` (result.Findings) and the human
// verdict, the same mechanism used for CodeLoginMonNoInput (see the ModuleHealth
// note in types.go). This avoids extending the frozen ModuleHealth JSON schema.
func markEnforcementUnknown(h *ModuleHealth, module string) {
	h.Effective = "" // never false-idle / false-enforcing on a failed read
	moduleFindings = append(moduleFindings, Finding{
		Code:      CodeModuleDegraded,
		Severity:  SeverityWarn,
		Component: "module",
		Message:   module + ": set read failed — enforcement state unknown (kernel set query failed; cannot confirm enforcing vs empty)",
	})
}
