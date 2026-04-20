// =============================================================================
// NFTBan v1.100 PR-P2-2 — External-Firewall Detection (Unified)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-extfw-detect"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="Single source of truth for external-firewall detection across install/update/uninstall"
// meta:inventory.files="internal/installer/extfw/detect.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Before PR-P2-2, external-firewall detection lived in two separate
// surfaces that disagreed on:
//
//   - which systemd unit name to probe for UFW (bare vs .service)
//   - whether to check /etc/csf/csf.conf (uninstall yes, install no)
//   - whether ghost nft tables and iptables-save rules count
//   - in what precedence order to report them
//
// This divergence is exactly the class of drift that makes PR-23
// (uninstall mutation) and PR-24 (restore enforcement) unsafe: two
// lifecycle modes could see different "ground truth" for the same
// host. PR-P2-2 unifies the detection layer so every caller gets the
// same answer from the same mocked or live host state.
//
// Locked precedence (frozen 2026-04-20): ufw → firewalld → iptables → csf.
// This order is used ONLY when collapsing to a single Authoritative
// answer; when multiple firewalls are observed active simultaneously,
// the result is Ambiguous and the caller is responsible for handling
// that state explicitly. No silent collapse to "whoever wins by
// precedence" is ever performed for multi-active hosts.
//
// Signal set (union of all previously-used signals — no new heuristics):
//
//   UFW:       ufw.service active
//   Firewalld: firewalld.service active, OR a ghost nft table whose
//              name contains "firewalld"
//   Iptables:  iptables.service active OR iptables-save reports ≥3
//              non-comment rule lines. A ghost nft table named
//              filter/nat/mangle is RECORDED as an observation but
//              does NOT classify iptables authority alone — it must
//              be corroborated by service or live rules. See
//              PR-P2-2A rationale in the iptables block below.
//   CSF:       csf.service active, OR lfd.service active, OR
//              /etc/csf/csf.conf present on disk
//
// No DNS checks, no process scraping, no heuristic expansion.
//
// =============================================================================
package extfw

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// Name identifies one of the recognized external firewalls. Values are
// deliberately lowercase so they can be used verbatim as JSON / plan-render
// strings; callers that need an operator-facing display name (e.g.
// "CSF" instead of "csf") use Observation.DisplayName().
type Name string

const (
	NameNone      Name = ""
	NameUFW       Name = "ufw"
	NameFirewalld Name = "firewalld"
	NameIptables  Name = "iptables"
	NameCSF       Name = "csf"
)

// Precedence is the frozen order used to pick a single authoritative
// external firewall when exactly ONE is observed active. When more
// than one is active, the detector returns Ambiguous and does NOT
// apply this precedence — the caller must handle ambiguity explicitly.
//
// Contract lock (PR-P2-2, 2026-04-20): this order is authoritative and
// changes to it require a new Phase 2 PR with explicit contract update.
var Precedence = []Name{NameUFW, NameFirewalld, NameIptables, NameCSF}

// Source enumerates why a given firewall was observed. Kept as an
// explicit type (not free-form string) so downstream consumers can
// match on the source without string parsing.
type Source string

const (
	SourceService       Source = "service"         // systemd unit is active
	SourceGhostTable    Source = "ghost_nft_table" // nft-owned table that is not an nftban-owned table
	SourceConfigFile    Source = "config_file"     // known config path is present
	SourceIptablesRules Source = "iptables_rules"  // iptables-save reports live rules
)

// Observation is one signal that a firewall was detected. A single
// firewall may produce multiple observations (e.g. CSF with both
// csf.service and /etc/csf/csf.conf). Callers that need the original
// unit name (e.g. DisableConflicts) read Observation.Unit.
type Observation struct {
	Name   Name   `json:"name"`
	Source Source `json:"source"`
	// Unit is the systemd unit name for SourceService observations,
	// empty for other sources.
	Unit string `json:"unit,omitempty"`
	// Detail carries a short human string for logs/notes. NEVER depended
	// on for program behavior.
	Detail string `json:"detail,omitempty"`
}

// DisplayName returns the operator-facing name for an observation,
// preserving the legacy display semantics of install-side detection:
//   - "UFW", "CSF" uppercase
//   - "firewalld", "iptables" lowercase
//   - ghost-nft-table iptables observations render as "iptables-nft"
//     so existing consumers that distinguished that source continue
//     to see the same string
func (o Observation) DisplayName() string {
	switch o.Name {
	case NameUFW:
		return "UFW"
	case NameCSF:
		return "CSF"
	case NameFirewalld:
		return "firewalld"
	case NameIptables:
		if o.Source == SourceGhostTable {
			return "iptables-nft"
		}
		return "iptables"
	}
	return string(o.Name)
}

// DetectionResult is the full observation picture. Consumers that need
// a single authoritative answer use Authoritative; consumers that need
// the complete conflict list (e.g. DisableConflicts) use Observations.
type DetectionResult struct {
	// Observations is every signal that fired during detection, in
	// detection order. Multiple observations for the same Name are
	// possible and expected (e.g. CSF service + config file).
	Observations []Observation `json:"observations,omitempty"`

	// Active is the deduplicated list of Names that were observed
	// active, in locked Precedence order.
	Active []Name `json:"active,omitempty"`

	// Authoritative is the single firewall considered to own external
	// authority. It is populated ONLY when exactly one Name appears in
	// Active. When zero or multiple are active, this is NameNone and
	// the caller must consult Ambiguous / Active directly.
	Authoritative Name `json:"authoritative,omitempty"`

	// Ambiguous is true when more than one distinct firewall was
	// observed active. The detector does NOT collapse this to the
	// precedence winner; callers must handle ambiguity explicitly per
	// the lifecycle-truth rule.
	Ambiguous bool `json:"ambiguous"`
}

// Detect is the CANONICAL shared external-firewall detection function.
// Install-side authority classification, uninstall-side plan building,
// and any future consumer must call this function rather than
// re-implementing detection.
//
// Read-only: no mutation, no writes, no service changes.
func Detect(exec executor.Executor, log *logging.Logger) *DetectionResult {
	res := &DetectionResult{}
	seen := make(map[Name]bool)

	// ── UFW ────────────────────────────────────────────────────────────
	// Signal: ufw.service is active.
	if exec.ServiceActive("ufw.service") {
		res.Observations = append(res.Observations, Observation{
			Name: NameUFW, Source: SourceService, Unit: "ufw.service",
			Detail: "ufw.service active",
		})
		seen[NameUFW] = true
	}

	// ── Firewalld ──────────────────────────────────────────────────────
	// Signal 1: firewalld.service is active.
	if exec.ServiceActive("firewalld.service") {
		res.Observations = append(res.Observations, Observation{
			Name: NameFirewalld, Source: SourceService, Unit: "firewalld.service",
			Detail: "firewalld.service active",
		})
		seen[NameFirewalld] = true
	}
	// Signal 2: ghost nft table whose name contains "firewalld".
	for _, t := range listGhostNftTables(exec) {
		if strings.Contains(t, "firewalld") {
			res.Observations = append(res.Observations, Observation{
				Name: NameFirewalld, Source: SourceGhostTable,
				Detail: "ghost nft table: " + t,
			})
			seen[NameFirewalld] = true
		}
	}

	// ── Iptables ───────────────────────────────────────────────────────
	//
	// PR-P2-2A (2026-04-20): iptables ghost-table signal alone is NOT
	// sufficient to classify external iptables authority. Stock Ubuntu
	// nftables packages ship a benign `table inet filter` with empty
	// accept-policy chains — it satisfied the pre-PR-P2-2A rule
	// (base ∈ {filter,nat,mangle}) and caused AuthorityAmbiguous on
	// every Ubuntu host with nftban installed. Surfaced by real-host
	// evidence on lab2.
	//
	// Post-PR-P2-2A rule: ghost-table is recorded as an observation
	// (for transparency in logs / plan rendering) but does NOT
	// contribute to the "is iptables active?" decision unless a
	// corroborating signal also fires:
	//   - iptables.service is active, OR
	//   - iptables-save reports live rules (≥3 non-comment lines)
	//
	// Paths: ghost-table-alone → informational, not counted.
	//         service OR rules → counted (with ghost-table observation
	//                              kept in the audit trail for context).
	var (
		iptablesService bool
		iptablesRules   bool
		iptablesGhost   bool
	)

	// Collect signal 1: iptables.service is active.
	if exec.ServiceActive("iptables.service") {
		res.Observations = append(res.Observations, Observation{
			Name: NameIptables, Source: SourceService, Unit: "iptables.service",
			Detail: "iptables.service active",
		})
		iptablesService = true
	}
	// Collect signal 2: ghost nft table named filter/nat/mangle
	// (iptables-nft compatibility tables). Recorded as an observation
	// even when it turns out to be stock-nftables noise — so plan
	// rendering can still surface "we saw this, but did not count it."
	for _, t := range listGhostNftTables(exec) {
		base := strings.TrimPrefix(t, "ip ")
		base = strings.TrimPrefix(base, "ip6 ")
		base = strings.TrimPrefix(base, "inet ")
		base = strings.TrimPrefix(base, "arp ")
		base = strings.TrimPrefix(base, "bridge ")
		if base == "filter" || base == "nat" || base == "mangle" {
			res.Observations = append(res.Observations, Observation{
				Name: NameIptables, Source: SourceGhostTable,
				Detail: "ghost nft table: " + t + " (informational — alone is not sufficient to classify iptables authority)",
			})
			iptablesGhost = true
		}
	}
	// Collect signal 3: iptables-save reports ≥3 non-comment rule lines.
	// Preserved from the uninstall-side heuristic — nftban itself does
	// not use legacy iptables, so live rules imply external authority.
	if hasActiveIptablesRules(exec) {
		res.Observations = append(res.Observations, Observation{
			Name: NameIptables, Source: SourceIptablesRules,
			Detail: "iptables-save: ≥3 non-comment rule lines present",
		})
		iptablesRules = true
	}
	// Apply the corroboration rule.
	//
	// Ghost-table contributes IFF another signal corroborates. This
	// avoids false-positive on stock nftables baselines (see above)
	// while keeping the legitimate iptables-nft detection path intact
	// for hosts that actually have service + ghost tables together.
	if iptablesService || iptablesRules {
		seen[NameIptables] = true
	}
	// Silence "declared and not used" — iptablesGhost is read above
	// only to register the observation; its role as a contributor is
	// intentionally gated on corroboration.
	_ = iptablesGhost

	// ── CSF ────────────────────────────────────────────────────────────
	// Signal 1: csf.service active.
	if exec.ServiceActive("csf.service") {
		res.Observations = append(res.Observations, Observation{
			Name: NameCSF, Source: SourceService, Unit: "csf.service",
			Detail: "csf.service active",
		})
		seen[NameCSF] = true
	}
	// Signal 2: lfd.service active — CSF ships two units; both are
	// taken over together.
	if exec.ServiceActive("lfd.service") {
		res.Observations = append(res.Observations, Observation{
			Name: NameCSF, Source: SourceService, Unit: "lfd.service",
			Detail: "lfd.service active",
		})
		seen[NameCSF] = true
	}
	// Signal 3: /etc/csf/csf.conf present. CSF is a shell-wrapper
	// around iptables and is not always systemd-managed, so the config
	// file alone is a legitimate observation. PR-P2-2 resolution
	// (Option A, 2026-04-20): this signal is used by all callers, not
	// just uninstall — it was the pre-unification drift.
	if exec.FileExists("/etc/csf/csf.conf") {
		res.Observations = append(res.Observations, Observation{
			Name: NameCSF, Source: SourceConfigFile,
			Detail: "/etc/csf/csf.conf present",
		})
		seen[NameCSF] = true
	}

	// ── Collapse active list in locked precedence order ────────────────
	for _, name := range Precedence {
		if seen[name] {
			res.Active = append(res.Active, name)
		}
	}

	// ── Authoritative / Ambiguous resolution ───────────────────────────
	switch len(res.Active) {
	case 0:
		res.Authoritative = NameNone
		res.Ambiguous = false
	case 1:
		res.Authoritative = res.Active[0]
		res.Ambiguous = false
	default:
		// Do NOT silently collapse via precedence. Callers must see
		// the multi-active ambiguity.
		res.Authoritative = NameNone
		res.Ambiguous = true
	}

	if log != nil {
		if res.Ambiguous {
			log.Debug("extfw/detect: AMBIGUOUS — multiple active: %v", res.Active)
		} else if res.Authoritative != NameNone {
			log.Debug("extfw/detect: authoritative=%s observations=%d", res.Authoritative, len(res.Observations))
		} else {
			log.Debug("extfw/detect: none active; observations=%d", len(res.Observations))
		}
	}

	return res
}

// nftbanOwnedTableNames lists the nft tables that belong to NFTBan and
// must NOT be counted as ghost tables. Pinned here so the install-side
// adapter and this unified detector share the same exclusion set.
var nftbanOwnedTableNames = map[string]bool{
	"ip nftban":                     true,
	"ip6 nftban":                    true,
	"ip raw":                        true,
	"ip6 raw":                       true,
	"inet nftban_install_emergency": true,
}

// listGhostNftTables returns every nft table present on the host that
// is NOT an nftban-owned table. Read-only; uses `nft list tables`.
func listGhostNftTables(exec executor.Executor) []string {
	if !exec.CommandExists("nft") {
		return nil
	}
	res := exec.Run("nft", "list", "tables")
	if res.ExitCode != 0 {
		return nil
	}
	var out []string
	for _, line := range strings.Split(res.Stdout, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		tableName := strings.TrimPrefix(line, "table ")
		if nftbanOwnedTableNames[tableName] {
			continue
		}
		out = append(out, tableName)
	}
	return out
}

// hasActiveIptablesRules reports whether iptables-save shows live
// rules. Preserved from the pre-unification uninstall-side heuristic:
// nftban does not use legacy iptables, so any rules here indicate
// external authority.
func hasActiveIptablesRules(exec executor.Executor) bool {
	r := exec.Run("iptables-save")
	if r.ExitCode != 0 {
		return false
	}
	return countNonCommentLines(r.Stdout) >= 3
}

// countNonCommentLines returns the number of non-empty, non-comment
// lines in s. iptables-save wraps its content in `#` / `*` / `:`
// preamble/section lines; only proper rule lines count.
func countNonCommentLines(s string) int {
	var n int
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == '\n' {
			line := s[start:i]
			start = i + 1
			j := 0
			for j < len(line) && (line[j] == ' ' || line[j] == '\t') {
				j++
			}
			if j >= len(line) {
				continue
			}
			if line[j] == '#' || line[j] == '*' || line[j] == ':' {
				continue
			}
			n++
		}
	}
	return n
}
