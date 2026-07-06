// =============================================================================
// NFTBan v1.8.0 - nftbackend Package (Netlink Implementation)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftbackend"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Serialized nftables write operations via netlink"
// meta:depends="github.com/google/nftables,github.com/itcmsgr/nftban/internal/setsync"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// ARCHITECTURE: This is the ONLY authorized location for nftables WRITE operations.
// All nft add/delete/flush/insert commands MUST go through this package.
// The nftband daemon is the ONLY consumer of this package.
//
// v1.8.0: Refactored from CLI (exec.Command) to netlink (google/nftables) via
// internal/setsync.NFTManager. Single point of truth for all nftables operations.
// Performance: ~50x faster (syscall vs fork+exec per operation).
//
// See: ARCHITECTURE-NFT-POLICY.md
// =============================================================================

package nftbackend

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/nftables"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	nftsync "github.com/itcmsgr/nftban/internal/setsync"
)

// familyInitStatus tracks whether each address family initialized successfully.
// 0 = ok, 1 = failed. Exposed as nftban_family_init_status{family="ipv4|ipv6"}.
var familyInitStatus = promauto.NewGaugeVec(prometheus.GaugeOpts{
	Namespace: "nftban",
	Name:      "family_init_status",
	Help:      "Address family initialization status (0=ok, 1=failed)",
}, []string{"family"})

// Backend provides serialized access to nftables write operations.
// All operations are thread-safe and atomic where possible.
// Uses netlink (google/nftables) for performance instead of CLI.
type Backend struct {
	mu sync.Mutex

	// NFTManager for netlink operations
	nft *nftsync.NFTManager

	// Cached tables and sets for performance
	tableIPv4 *nftables.Table
	tableIPv6 *nftables.Table
	setBlacklistIPv4       *nftables.Set // interval set for feeds/geoban
	setBlacklistIPv6       *nftables.Set
	setBlacklistManualIPv4 *nftables.Set // hash set for manual/auto-detect (v1.33.0)
	setBlacklistManualIPv6 *nftables.Set
	setWhitelistIPv4       *nftables.Set
	setWhitelistIPv6       *nftables.Set

	// Configuration (string form for legacy compatibility)
	tableIPv4Str string
	tableIPv6Str string

	// v1.209.x F2: authoritative never-ban exemption guard (admin/management/whitelist/
	// system/live-SSH). Consulted by Ban() before any drop-set write. nil = disabled
	// (guard not wired) → bans proceed unguarded (pre-existing rule-order behavior).
	exempt *exemptResolver

	// Statistics
	stats Stats
}

// Stats tracks operation counts
type Stats struct {
	Bans        int64
	Unbans      int64
	Syncs       int64
	Errors      int64
	ExemptSkips int64 // bans refused because the IP is never-ban exempt (F2 guard)
	// L3a: add_element requests refused because a single exempt IP targeted an
	// enforcement set (never-ban invariant enforced on the generic add path too).
	AddElementExemptSkips int64
	LastError             string
}

// EnableExemptionGuard wires the authoritative never-ban exemption guard. configDir is
// the nftban config dir (for whitelist.d); scannerFile is the path the resolved exempt
// list is published to for the unprivileged BotScan scanner ("" to skip publishing).
// Safe to call once at daemon init. Idempotent.
func (b *Backend) EnableExemptionGuard(configDir, scannerFile string) {
	r := newExemptResolver(configDir, scannerFile)
	b.mu.Lock()
	b.exempt = r
	b.mu.Unlock()
	// Warm the snapshot OFF the caller's (daemon startup) path. Refresh must never
	// block the daemon reaching READY; IsExempt lazily refreshes too.
	go r.Refresh()
}

// New creates a new nftables backend with netlink connection
func New() *Backend {
	b := &Backend{
		tableIPv4Str: "ip nftban",
		tableIPv6Str: "ip6 nftban",
	}

	// Initialize NFTManager - if this fails, fall back to CLI on first operation
	if nft, err := nftsync.NewNFTManager(); err == nil {
		b.nft = nft
		// Pre-cache tables and sets (best effort, will retry on demand)
		b.initCachedObjects()
	}

	return b
}

// initCachedObjects pre-caches tables and sets for performance
func (b *Backend) initCachedObjects() {
	if b.nft == nil {
		return
	}

	// Get/create IPv4 table and sets
	if table, err := b.nft.GetOrCreateTable(nftables.TableFamilyIPv4); err == nil {
		b.tableIPv4 = table
		if set, err := b.nft.GetOrCreateIntervalSet(table, "blacklist_ipv4", true); err == nil {
			b.setBlacklistIPv4 = set
		}
		if set, err := b.nft.GetOrCreateHashSet(table, "blacklist_manual_ipv4", true); err == nil {
			b.setBlacklistManualIPv4 = set
		}
		if set, err := b.nft.GetOrCreateIntervalSet(table, "whitelist_ipv4", true); err == nil {
			b.setWhitelistIPv4 = set
		}
	} else {
		log.Printf("ERROR: IPv4 table init failed: %v — IPv4 bans will NOT work", err)
		familyInitStatus.WithLabelValues("ipv4").Set(1)
	}

	// Get/create IPv6 table and sets
	if table, err := b.nft.GetOrCreateTable(nftables.TableFamilyIPv6); err == nil {
		b.tableIPv6 = table
		if set, err := b.nft.GetOrCreateIntervalSet(table, "blacklist_ipv6", false); err == nil {
			b.setBlacklistIPv6 = set
		}
		if set, err := b.nft.GetOrCreateHashSet(table, "blacklist_manual_ipv6", false); err == nil {
			b.setBlacklistManualIPv6 = set
		}
		if set, err := b.nft.GetOrCreateIntervalSet(table, "whitelist_ipv6", false); err == nil {
			b.setWhitelistIPv6 = set
		}
	} else {
		log.Printf("ERROR: IPv6 table init failed: %v — IPv6 bans will NOT work", err)
		familyInitStatus.WithLabelValues("ipv6").Set(1)
	}

	// Initialize port sets (v1.15.0 - directional architecture)
	// These must exist before any port operations can succeed
	portSets := []string{"tcp_ports_in", "tcp_ports_out", "udp_ports_in", "udp_ports_out"}
	for _, setName := range portSets {
		// IPv4
		if _, err := b.nft.GetOrCreatePortSet(b.tableIPv4, setName); err != nil {
			log.Printf("Warning: failed to create IPv4 port set %s: %v", setName, err)
		}
		// IPv6
		if _, err := b.nft.GetOrCreatePortSet(b.tableIPv6, setName); err != nil {
			log.Printf("Warning: failed to create IPv6 port set %s: %v", setName, err)
		}
	}
	log.Printf("Port sets initialized: %v", portSets)
}

// ensureNetlink ensures NFTManager is initialized
func (b *Backend) ensureNetlink() error {
	if b.nft != nil {
		return nil
	}

	nft, err := nftsync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to create netlink connection: %w", err)
	}
	b.nft = nft
	b.initCachedObjects()
	return nil
}

// isManualSource returns true if the source routes to hash sets (manual/auto-detect)
func isManualSource(source string) bool {
	switch source {
	case "manual", "cli", "login", "portscan", "portscan-classic", "portscan-suricata",
		"ddos", "ddos-classic", "ddos-suricata", "suricata", "persistent":
		return true
	default:
		return false
	}
}

// getBlacklistSetForSource returns the appropriate set based on source + IP family
// v1.33.0: Manual/auto-detect sources → hash set, feeds/geoban → interval set
// v1.39.0: CIDRs always route to interval set (hash sets don't support ranges)
func (b *Backend) getBlacklistSetForSource(ipStr, source string) (*nftables.Set, string, bool, error) {
	ip := net.ParseIP(ipStr)
	isIPv6 := false
	isCIDR := strings.Contains(ipStr, "/")

	if ip != nil {
		isIPv6 = ip.To4() == nil
	} else {
		isIPv6 = strings.Contains(ipStr, ":")
	}

	// v1.39.0: CIDRs must use interval sets (hash sets don't support ranges)
	manual := isManualSource(source) && !isCIDR

	if isIPv6 {
		if manual {
			if b.setBlacklistManualIPv6 == nil {
				return nil, "", true, fmt.Errorf("blacklist_manual_ipv6 set not initialized")
			}
			return b.setBlacklistManualIPv6, "blacklist_manual_ipv6", true, nil
		}
		if b.setBlacklistIPv6 == nil {
			return nil, "", true, fmt.Errorf("blacklist_ipv6 set not initialized")
		}
		return b.setBlacklistIPv6, "blacklist_ipv6", true, nil
	}

	if manual {
		if b.setBlacklistManualIPv4 == nil {
			return nil, "", false, fmt.Errorf("blacklist_manual_ipv4 set not initialized")
		}
		return b.setBlacklistManualIPv4, "blacklist_manual_ipv4", false, nil
	}

	if b.setBlacklistIPv4 == nil {
		return nil, "", false, fmt.Errorf("blacklist_ipv4 set not initialized")
	}
	return b.setBlacklistIPv4, "blacklist_ipv4", false, nil
}

// BanRequest contains parameters for banning an IP
type BanRequest struct {
	IP      string
	Timeout int    // seconds, 0 = permanent
	Reason  string
	Source  string
}

// BanResult contains the result of a ban operation
type BanResult struct {
	Success bool
	IP      string
	Set     string
	Message string
	Exempt  bool // true if the ban was REFUSED because the IP is never-ban exempt (F2 guard)
}

// Ban adds an IP to the appropriate blacklist set
// This is the ONLY authorized ban implementation
// Uses netlink for ~50x faster performance vs CLI
func (b *Backend) Ban(ctx context.Context, req BanRequest) (*BanResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Validate IP
	ip := net.ParseIP(req.IP)
	if ip == nil {
		// Check if it's a CIDR
		_, _, err := net.ParseCIDR(req.IP)
		if err != nil {
			b.stats.Errors++
			b.stats.LastError = "invalid IP: " + req.IP
			return nil, fmt.Errorf("invalid IP address: %s", req.IP)
		}
	}

	// v1.209.x F2 — AUTHORITATIVE never-ban exemption guard. This is the durable apply
	// boundary: EVERY ban path (BotScan batch-signal consumer, EventBus module bans,
	// persistent escalation, manual CLI, BotGuard enforcer) funnels through Ban(), so
	// enforcing the exemption HERE establishes the never-ban invariant universally —
	// admin/management/whitelist/system/live-SSH IPs are never written to a drop set,
	// instead of relying on firewall rule order (the pre-v1.209.x ordering-only model).
	// Range-aware, v4+v6. Fail-safe: a nil/empty resolver never blocks a legitimate ban.
	// Exemption ≠ accept: this only prevents a DROP of protected IPs; it adds no allow.
	if b.exempt != nil {
		if ok, reason := b.exempt.IsExempt(req.IP); ok {
			b.stats.ExemptSkips++
			log.Printf("[BAN] REFUSED (never-ban exempt: %s) ip=%s source=%s — protected admin/management/whitelist/system/live-SSH IP NOT added to blacklist", reason, req.IP, req.Source)
			return &BanResult{
				Success: true,
				IP:      req.IP,
				Exempt:  true,
				Message: fmt.Sprintf("not banned: never-ban exempt (%s)", reason),
			}, nil
		}
	}

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return nil, err
	}

	// Get appropriate set based on source (v1.33.0: hash vs interval routing)
	source := req.Source
	if source == "" {
		source = "manual"
	}
	set, setName, isIPv6, err := b.getBlacklistSetForSource(req.IP, source)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return nil, err
	}

	// Add IP with optional timeout
	timeout := time.Duration(req.Timeout) * time.Second
	if err := b.nft.AddIPWithTimeout(set, req.IP, timeout); err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("netlink error: %v", err)
		return nil, fmt.Errorf("nft add element failed: %w", err)
	}

	b.stats.Bans++

	tableName := b.tableIPv4Str
	if isIPv6 {
		tableName = b.tableIPv6Str
	}

	return &BanResult{
		Success: true,
		IP:      req.IP,
		Set:     setName,
		Message: fmt.Sprintf("added to %s %s", tableName, setName),
	}, nil
}

// UnbanRequest contains parameters for unbanning an IP
type UnbanRequest struct {
	IP string
}

// UnbanResult contains the result of an unban operation
type UnbanResult struct {
	Success bool
	IP      string
	Set     string
	Message string
}

// Unban removes an IP from all blacklist sets (hash + interval)
// This is the ONLY authorized unban implementation
// v1.33.0: Tries hash set first (fast), then interval set
func (b *Backend) Unban(ctx context.Context, req UnbanRequest) (*UnbanResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Validate IP
	ip := net.ParseIP(req.IP)
	if ip == nil {
		_, _, err := net.ParseCIDR(req.IP)
		if err != nil {
			b.stats.Errors++
			b.stats.LastError = "invalid IP: " + req.IP
			return nil, fmt.Errorf("invalid IP address: %s", req.IP)
		}
	}

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return nil, err
	}

	isIPv6 := false
	if ip != nil {
		isIPv6 = ip.To4() == nil
	} else {
		isIPv6 = strings.Contains(req.IP, ":")
	}

	// v1.33.0: Try removing from both sets (hash first, then interval)
	// We don't know which set the IP is in, so try both
	var removedFrom string
	tableName := b.tableIPv4Str
	if isIPv6 {
		tableName = b.tableIPv6Str
	}

	// Try hash set first (O(1), fast)
	var manualSet *nftables.Set
	if isIPv6 {
		manualSet = b.setBlacklistManualIPv6
	} else {
		manualSet = b.setBlacklistManualIPv4
	}
	if manualSet != nil {
		err := b.nft.DeleteSetElements(manualSet, []string{req.IP})
		if err == nil {
			if isIPv6 {
				removedFrom = "blacklist_manual_ipv6"
			} else {
				removedFrom = "blacklist_manual_ipv4"
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("netlink error: %v", err)
			return nil, fmt.Errorf("nft delete element failed: %w", err)
		}
	}

	// Try interval set
	var intervalSet *nftables.Set
	if isIPv6 {
		intervalSet = b.setBlacklistIPv6
	} else {
		intervalSet = b.setBlacklistIPv4
	}
	if intervalSet != nil {
		err := b.nft.DeleteSetElements(intervalSet, []string{req.IP})
		if err == nil {
			if removedFrom == "" {
				if isIPv6 {
					removedFrom = "blacklist_ipv6"
				} else {
					removedFrom = "blacklist_ipv4"
				}
			} else {
				removedFrom += " + blacklist_ipv4"
				if isIPv6 {
					removedFrom = removedFrom[:len(removedFrom)-len("blacklist_ipv4")] + "blacklist_ipv6"
				}
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("netlink error: %v", err)
			return nil, fmt.Errorf("nft delete element failed: %w", err)
		}
	}

	if removedFrom == "" {
		setName := "blacklist_ipv4"
		if isIPv6 {
			setName = "blacklist_ipv6"
		}
		return &UnbanResult{
			Success: true,
			IP:      req.IP,
			Set:     setName,
			Message: "IP was not in blocklist",
		}, nil
	}

	b.stats.Unbans++

	return &UnbanResult{
		Success: true,
		IP:      req.IP,
		Set:     removedFrom,
		Message: fmt.Sprintf("removed from %s %s", tableName, removedFrom),
	}, nil
}

// AddElementRequest for generic set element operations
type AddElementRequest struct {
	Table   string // e.g., "ip nftban", "ip6 nftban"
	Set     string // e.g., "whitelist_ipv4", "tcp_ports_in"
	Element string // e.g., "1.2.3.4", "8080"
	Timeout int    // seconds, 0 = permanent
}

// portSets enumerates the named nftables sets whose key type is inet_service
// (uint16 port numbers) rather than an IP/CIDR. Generic element add/delete must
// route these through the port-aware path; the IP interval-set path would try to
// net.ParseIP the element and fail with "invalid IP or CIDR: <port>".
//
// v1.145 PR-B2: ssh_ports joined this list. It is the set-driven SSH brute-force
// rate-limit set (`tcp dport @ssh_ports ct count`). Runtime union reconciliation
// (maintenance/health/cmd_port) writes detected SSH ports into ssh_ports AND
// tcp_ports_in via nft_ipc_add_element; both are inet_service sets, so both must
// route here. Before this, the generic add path treated the port as an IP and
// silently failed (callers swallow errors with `|| true`), so multi-port hosts
// could not self-heal missing SSH ports.
var portSets = map[string]bool{
	"tcp_ports_in": true, "tcp_ports_out": true,
	"udp_ports_in": true, "udp_ports_out": true,
	"ssh_ports": true,
}

// isPortSet reports whether setName is an inet_service (port) set.
func isPortSet(setName string) bool { return portSets[setName] }

// AddElement adds an element to any set
// This is the ONLY authorized add element implementation
// ErrNeverBanExempt is returned by AddElement when a single exempt IP is refused entry
// into an enforcement (drop) set. Callers can errors.Is() it to give a clear message.
var ErrNeverBanExempt = errors.New("never-ban exempt: refused add to enforcement set")

// enforcementSets are the drop/block sets where inserting a single exempt IP would
// violate the never-ban invariant. Never-ban is a target-set + element property, so this
// must cover EVERY add_element-reachable enforcement/drop set — not only the sets named in
// the original L3a scope. Whitelist/port/metadata sets are intentionally excluded (adding
// an admin IP to whitelist/ssh_ports is correct).
//
// add_element-reachable (validNFTBanSet) drop sets: blacklist_ipv4/6, geoban_ipv4/6,
// persistent_offenders_ipv4/6, bogon_ipv4/6, and the BotGuard drop states
// http_bot_ban{,6}/http_bot_emergency{,6}. blacklist_manual_* and ddos_blocked are NOT
// add_element-reachable today but are kept as backend defense-in-depth. The live opqueue
// EnqueueBan path that writes the BotGuard sets is a separate lane (L3b).
var enforcementSets = map[string]bool{
	"blacklist_ipv4":            true,
	"blacklist_ipv6":            true,
	"geoban_ipv4":               true,
	"geoban_ipv6":               true,
	"persistent_offenders_ipv4": true,
	"persistent_offenders_ipv6": true,
	"bogon_ipv4":                true,
	"bogon_ipv6":                true,
	"http_bot_ban":              true,
	"http_bot_ban6":             true,
	"http_bot_emergency":        true,
	"http_bot_emergency6":       true,
	// defense-in-depth (not add_element-reachable via validNFTBanSet today):
	"blacklist_manual_ipv4": true,
	"blacklist_manual_ipv6": true,
	"ddos_blocked":          true,
}

// IsEnforcementSet reports whether set is a drop/block set subject to the never-ban
// invariant on element add. Never-ban is a target-set + element property, not a verb
// property — so the generic add path must consult this, not only the ban verb.
func IsEnforcementSet(set string) bool { return enforcementSets[set] }

// IsExempt reports whether ip must never be banned (admin/management/whitelist/system/
// live-SSH), delegating to the authoritative resolver. Nil-safe: no resolver → not exempt
// (fail-safe; never blocks a legitimate operation). Exposed so handlers can pre-check.
func (b *Backend) IsExempt(ip string) (bool, string) {
	if b.exempt == nil {
		return false, ""
	}
	return b.exempt.IsExempt(ip)
}

// exemptAddRejection reports whether adding element to set must be refused by the
// never-ban invariant: enforcement set AND a single exempt IP. Pure (no nft I/O), so the
// decision is unit-testable without netlink/root. IsExempt returns false for CIDR/range
// and non-single-IP inputs, so feed/interval CIDR adds are naturally unaffected.
func (b *Backend) exemptAddRejection(set, element string) (bool, string) {
	if b.exempt == nil || !IsEnforcementSet(set) {
		return false, ""
	}
	return b.exempt.IsExempt(element)
}

func (b *Backend) AddElement(ctx context.Context, req AddElementRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	// L3a — AUTHORITATIVE never-ban guard on the GENERIC add path (defense-in-depth).
	// backend.Ban guards its verb; without this an exempt admin/session/system/live-SSH
	// IP could be inserted into a drop set via add_element, bypassing the F2 invariant.
	// Enforcement sets + single exempt IP only; CIDR/whitelist/port adds pass. Fail-safe.
	if reject, reason := b.exemptAddRejection(req.Set, req.Element); reject {
		b.stats.AddElementExemptSkips++
		log.Printf("[ADDELEMENT] REFUSED (never-ban exempt: %s) set=%s ip=%s — protected admin/management/whitelist/system/live-SSH IP NOT added to enforcement set", reason, req.Set, req.Element)
		return fmt.Errorf("%w: %s (%s)", ErrNeverBanExempt, req.Element, reason)
	}

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return err
	}

	// Determine table family from string
	var family nftables.TableFamily
	if strings.HasPrefix(req.Table, "ip6") {
		family = nftables.TableFamilyIPv6
	} else {
		family = nftables.TableFamilyIPv4
	}

	// Get table
	table, err := b.nft.GetOrCreateTable(family)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get table: %v", err)
		return fmt.Errorf("failed to get table: %w", err)
	}

	// v1.145 PR-B2: port sets (inet_service / uint16) must NOT go through the
	// IP interval-set path — AddIPWithTimeout would net.ParseIP the element and
	// fail with "invalid IP or CIDR: <port>". Route named port sets to the
	// port-aware path. Timeout is not applicable to port sets (they are
	// permanent allow/rate-limit sets), so req.Timeout is ignored here.
	if isPortSet(req.Set) {
		port, perr := strconv.Atoi(strings.TrimSpace(req.Element))
		if perr != nil {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("invalid port: %v", perr)
			return fmt.Errorf("invalid port %q for set %s: %w", req.Element, req.Set, perr)
		}
		set, serr := b.nft.GetOrCreatePortSet(table, req.Set)
		if serr != nil {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("get port set: %v", serr)
			return fmt.Errorf("failed to get port set: %w", serr)
		}
		if aerr := b.nft.AddPortElements(set, []int{port}); aerr != nil {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("add port element: %v", aerr)
			return fmt.Errorf("nft add port element failed: %w", aerr)
		}
		return nil
	}

	// Get or create set (assume interval set for IP sets)
	isIPv4 := family == nftables.TableFamilyIPv4
	set, err := b.nft.GetOrCreateIntervalSet(table, req.Set, isIPv4)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get set: %v", err)
		return fmt.Errorf("failed to get set: %w", err)
	}

	// Add element with optional timeout
	timeout := time.Duration(req.Timeout) * time.Second
	if err := b.nft.AddIPWithTimeout(set, req.Element, timeout); err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("add element: %v", err)
		return fmt.Errorf("nft add element failed: %w", err)
	}

	return nil
}

// DeleteElementRequest for removing set elements
type DeleteElementRequest struct {
	Table   string
	Set     string
	Element string
}

// DeleteElement removes an element from any set
// This is the ONLY authorized delete element implementation
func (b *Backend) DeleteElement(ctx context.Context, req DeleteElementRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return err
	}

	// Determine table family from string
	var family nftables.TableFamily
	if strings.HasPrefix(req.Table, "ip6") {
		family = nftables.TableFamilyIPv6
	} else {
		family = nftables.TableFamilyIPv4
	}

	// Get table
	table, err := b.nft.GetOrCreateTable(family)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get table: %v", err)
		return fmt.Errorf("failed to get table: %w", err)
	}

	// v1.145 PR-B2: route port sets to the port-aware delete path (see AddElement).
	if isPortSet(req.Set) {
		port, perr := strconv.Atoi(strings.TrimSpace(req.Element))
		if perr != nil {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("invalid port: %v", perr)
			return fmt.Errorf("invalid port %q for set %s: %w", req.Element, req.Set, perr)
		}
		set, serr := b.nft.GetOrCreatePortSet(table, req.Set)
		if serr != nil {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("get port set: %v", serr)
			return fmt.Errorf("failed to get port set: %w", serr)
		}
		if derr := b.nft.DeletePortElements(set, []int{port}); derr != nil {
			if !errors.Is(derr, os.ErrNotExist) {
				b.stats.Errors++
				b.stats.LastError = fmt.Sprintf("delete port element: %v", derr)
				return fmt.Errorf("nft delete port element failed: %w", derr)
			}
		}
		return nil
	}

	// Get set
	isIPv4 := family == nftables.TableFamilyIPv4
	set, err := b.nft.GetOrCreateIntervalSet(table, req.Set, isIPv4)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get set: %v", err)
		return fmt.Errorf("failed to get set: %w", err)
	}

	// Delete element
	if err := b.nft.DeleteSetElements(set, []string{req.Element}); err != nil {
		// Ignore "not found" errors
		if !errors.Is(err, os.ErrNotExist) {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("delete element: %v", err)
			return fmt.Errorf("nft delete element failed: %w", err)
		}
	}

	return nil
}

// FlushSetRequest for flushing sets
type FlushSetRequest struct {
	Table string
	Set   string
}

// FlushSet flushes all elements from a set
// This is the ONLY authorized flush set implementation
func (b *Backend) FlushSet(ctx context.Context, req FlushSetRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return err
	}

	// Determine table family from string
	var family nftables.TableFamily
	if strings.HasPrefix(req.Table, "ip6") {
		family = nftables.TableFamilyIPv6
	} else {
		family = nftables.TableFamilyIPv4
	}

	// Get table
	table, err := b.nft.GetOrCreateTable(family)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get table: %v", err)
		return fmt.Errorf("failed to get table: %w", err)
	}

	// Get set
	isIPv4 := family == nftables.TableFamilyIPv4
	set, err := b.nft.GetOrCreateIntervalSet(table, req.Set, isIPv4)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get set: %v", err)
		return fmt.Errorf("failed to get set: %w", err)
	}

	// Flush set
	if err := b.nft.FlushSet(set); err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("flush set: %v", err)
		return fmt.Errorf("nft flush set failed: %w", err)
	}

	return nil
}

// ApplyRulesetRequest for applying complete rulesets
type ApplyRulesetRequest struct {
	FilePath string // path to .nft file
	Check    bool   // if true, validate only (nft -c)
}

// ApplyRuleset applies a ruleset from a file
// This is the ONLY authorized apply ruleset implementation
// NOTE: This still uses CLI as netlink doesn't support loading .nft files
func (b *Backend) ApplyRuleset(ctx context.Context, req ApplyRulesetRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	var cmd *exec.Cmd
	if req.Check {
		cmd = exec.CommandContext(ctx, "nft", "-c", "-f", req.FilePath)
	} else {
		cmd = exec.CommandContext(ctx, "nft", "-f", req.FilePath)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("apply ruleset: %v: %s", err, string(output))
		return fmt.Errorf("nft apply ruleset failed: %w: %s", err, string(output))
	}

	// Invalidate cached objects after ruleset apply (may have changed structure)
	if b.nft != nil {
		b.nft.InvalidateTableCache()
		b.initCachedObjects()
	}

	b.stats.Syncs++
	return nil
}

// GetStats returns current statistics
func (b *Backend) GetStats() Stats {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.stats
}

// CheckIP checks if an IP is in a specific set (read operation)
func (b *Backend) CheckIP(ctx context.Context, ip string) (bool, string, error) {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false, "", fmt.Errorf("invalid IP: %s", ip)
	}

	// Determine family using To4() - handles IPv4-mapped IPv6 addresses correctly
	ipv4 := parsed.To4()
	isIPv6 := ipv4 == nil

	// Normalize IP string for consistent comparison
	normalizedIP := parsed.String()
	if !isIPv6 {
		normalizedIP = ipv4.String()
	}

	// Ensure netlink
	if err := b.ensureNetlink(); err != nil {
		// Fall back to CLI
		return b.checkIPCLI(ctx, normalizedIP, isIPv6)
	}

	// v1.33.0: Check hash set first (O(1), fast), then interval set
	type setCheck struct {
		set  *nftables.Set
		name string
	}
	var setsToCheck []setCheck
	if isIPv6 {
		setsToCheck = []setCheck{
			{b.setBlacklistManualIPv6, "blacklist_manual_ipv6"},
			{b.setBlacklistIPv6, "blacklist_ipv6"},
		}
	} else {
		setsToCheck = []setCheck{
			{b.setBlacklistManualIPv4, "blacklist_manual_ipv4"},
			{b.setBlacklistIPv4, "blacklist_ipv4"},
		}
	}

	for _, sc := range setsToCheck {
		if sc.set == nil {
			continue
		}
		elements, err := b.nft.GetSetElements(sc.set)
		if err != nil {
			continue
		}
		for _, elem := range elements {
			if elem == normalizedIP || strings.HasPrefix(elem, normalizedIP+"/") {
				return true, sc.name, nil
			}
		}
	}

	// Fall back to CLI if netlink had issues
	if b.setBlacklistIPv4 == nil && b.setBlacklistManualIPv4 == nil {
		return b.checkIPCLI(ctx, normalizedIP, isIPv6)
	}

	return false, "", nil
}

// checkIPCLI is a fallback for CheckIP using CLI
func (b *Backend) checkIPCLI(ctx context.Context, ip string, isIPv6 bool) (bool, string, error) {
	var table, set string
	if isIPv6 {
		table = b.tableIPv6Str
		set = "blacklist_ipv6"
	} else {
		table = b.tableIPv4Str
		set = "blacklist_ipv4"
	}

	cmd := exec.CommandContext(ctx, "nft", "list", "set", table, set)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return false, "", fmt.Errorf("nft list set failed: %w", err)
	}

	outputStr := string(output)
	if strings.Contains(outputStr, ip+" ") || strings.Contains(outputStr, ip+",") ||
		strings.Contains(outputStr, ip+"\n") || strings.Contains(outputStr, ip+"}") {
		return true, set, nil
	}

	return false, "", nil
}

// HealthCheck verifies nftables is operational
func (b *Backend) HealthCheck(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// Try netlink first
	if b.nft != nil {
		if _, err := b.nft.GetOrCreateTable(nftables.TableFamilyIPv4); err == nil {
			return nil
		}
	}

	// Fall back to CLI
	cmd := exec.CommandContext(ctx, "nft", "list", "tables")
	_, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nftables not operational: %w", err)
	}
	return nil
}

// GetNFTManager returns the underlying NFTManager for advanced operations
// This allows the daemon to use the same connection for sync operations
func (b *Backend) GetNFTManager() *nftsync.NFTManager {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.nft
}

// InvalidateCache invalidates cached tables and sets
// Call this after external nftables modifications
func (b *Backend) InvalidateCache() {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.nft != nil {
		b.nft.InvalidateTableCache()
	}
	b.tableIPv4 = nil
	b.tableIPv6 = nil
	b.setBlacklistIPv4 = nil
	b.setBlacklistIPv6 = nil
	b.setBlacklistManualIPv4 = nil
	b.setBlacklistManualIPv6 = nil
	b.setWhitelistIPv4 = nil
	b.setWhitelistIPv6 = nil

	// Re-initialize
	b.initCachedObjects()
}
