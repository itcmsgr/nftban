// =============================================================================
// NFTBan - canonical ban-source classification (v1.229.13 LANE-BST)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="bansource"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-07"
// meta:description="THE canonical ban-source classification authority. A ban's STORAGE CLASS and LIFECYCLE OWNER derive from a Kind, never from the spelling of the raw source string. The raw string is preserved as PROVENANCE for telemetry, audit and the on-disk source index. Replaces a set of contradictory string predicates that gave different answers for the same source and silently routed detector bans into the feed-owned interval sets, where the next feed synchronisation erased them."
// meta:inventory.files="internal/bansource/bansource.go"
// meta:inventory.privileges="none"
// =============================================================================

// Package bansource is the single authority that maps a ban's producer context
// and raw source label to a storage/lifecycle Kind.
//
// ⛔ THE ARCHITECTURAL RULE THIS PACKAGE EXISTS TO ENFORCE:
//
//	RAW SOURCE STRING != STORAGE POLICY
//
// Before this package, at least four independent predicates interpreted the same
// source string and disagreed:
//
//	nftbackend.isManualSource   exact switch,  unknown -> INTERVAL (feed-owned)
//	opqueue.GetSourceConfig     map lookup,    unknown -> HASH     (manual)
//	daemon_init.go              strings.Contains chain, has a botguard arm
//	daemon_handlers_ban.go      strings.Contains chain, has NO botguard arm
//
// Opposite defaults for the same question. The measured consequence: `loginmon`,
// `botguard`, `botscan`, `botscan-404`, `portscan-aggregate` and the entire
// per-service login vocabulary (sshd, dovecot, exim, postfix, vsftpd, proftpd,
// pureftpd, directadmin, cpanel) all missed the exact-match table, landed in
// blacklist_ipv4/_ipv6, and were erased by the next feed sync — a detected
// attacker silently un-banned by an unrelated synchronisation mechanism.
package bansource

import "strings"

// Kind is the storage/lifecycle class of a ban. Routing consumes THIS, never the
// raw source string.
type Kind int

const (
	// Unclassified means the caller supplied neither a producer context nor a
	// recognised label. It is NOT a lifecycle. Callers must treat it as an error
	// rather than guessing — guessing is exactly the defect this package removes.
	Unclassified Kind = iota

	// DetectorEphemeral — produced by a detector as evidence of observed abuse.
	// Detector-owned/hash-like storage, timeout owned by the detector lifecycle.
	// ⛔ Feed/geoban synchronisation MUST NOT be able to replace or delete these.
	DetectorEphemeral

	// ManualPersistent — an operator decision. Hash-like storage. Not replaced by
	// feed synchronisation. The LABEL IS ARBITRARY: `--source customer-rule` is
	// ManualPersistent because an operator command produced it, not because the
	// string was recognised.
	ManualPersistent

	// ReplaceManaged — owned by a bulk synchronisation authority (feeds, geoban,
	// blacklist.d CIDRs). Interval storage. Replaced ONLY by its owning sync.
	ReplaceManaged
)

func (k Kind) String() string {
	switch k {
	case DetectorEphemeral:
		return "DetectorEphemeral"
	case ManualPersistent:
		return "ManualPersistent"
	case ReplaceManaged:
		return "ReplaceManaged"
	default:
		return "Unclassified"
	}
}

// Origin is the PRODUCER CONTEXT. It is the primary input, because the producer
// knows what it is; a string table can only guess.
type Origin int

const (
	// OriginUnspecified — a legacy boundary that carries only a source string.
	// Resolution then falls back to the known-label table below. New call sites
	// should supply a real Origin instead of relying on that fallback.
	OriginUnspecified Origin = iota
	// OriginOperator — an operator command or IPC ban request. ANY label.
	OriginOperator
	// OriginDetector — a detector module or classic detector script. ANY label.
	OriginDetector
	// OriginBulkSync — feeds, geoban, or a blacklist.d CIDR load.
	OriginBulkSync
)

// detectorLabels are labels known to originate from a detector, used ONLY when a
// caller cannot supply an Origin. Membership here is provenance evidence, not a
// storage policy: the Kind is what routes, and this table only helps infer the
// Kind at legacy boundaries.
//
// ⛔ This is deliberately NOT a storage table. Do not add a label here to change
// where something is stored — supply the correct Origin at the producer instead.
var detectorLabels = map[string]struct{}{
	// Go modules (ModuleName constants)
	"loginmon": {}, "botguard": {}, "ddos": {}, "portscan": {},
	// shell detector families
	"ddos-classic": {}, "ddos-suricata": {}, "portscan-classic": {},
	"portscan-suricata": {}, "portscan-aggregate": {},
	"botscan": {}, "botscan-404": {},
	"suricata": {}, "login": {}, "login-monitor": {}, "nftban-sshd": {},
	// per-service login vocabulary — the shell login monitor forwards the SERVICE
	// NAME as the source. These are PROVENANCE labels for one detector family;
	// they must never each imply their own storage class.
	"sshd": {}, "ssh": {}, "dovecot": {}, "exim": {}, "postfix": {},
	"vsftpd": {}, "proftpd": {}, "pureftpd": {}, "directadmin": {}, "cpanel": {},
}

// operatorLabels are labels that only an operator path produces.
var operatorLabels = map[string]struct{}{
	"manual": {}, "cli": {}, "user": {}, "persistent": {},
}

// bulkLabels are labels owned by a replace-managed synchronisation authority.
var bulkLabels = map[string]struct{}{
	"feeds": {}, "feed": {}, "geoban": {}, "blacklist": {}, "threat-intel": {},
}

// Resolve maps producer context + raw label to a Kind.
//
// Origin WINS. A recognised label only matters when the caller could not supply
// one, which is the legacy case this lane is narrowing rather than widening.
func Resolve(raw string, origin Origin) Kind {
	switch origin {
	case OriginOperator:
		// ⛔ Arbitrary labels included, by design. `--source customer-rule` is an
		// operator decision because an operator command made it.
		return ManualPersistent
	case OriginDetector:
		return DetectorEphemeral
	case OriginBulkSync:
		return ReplaceManaged
	}

	label := strings.ToLower(strings.TrimSpace(raw))
	// A shell producer may qualify a label, e.g. "ddos_suricata:<reason>". Classify
	// on the family, never on the free-text tail.
	if i := strings.IndexByte(label, ':'); i > 0 {
		label = label[:i]
	}
	if _, ok := bulkLabels[label]; ok {
		return ReplaceManaged
	}
	if _, ok := operatorLabels[label]; ok {
		return ManualPersistent
	}
	if _, ok := detectorLabels[label]; ok {
		return DetectorEphemeral
	}
	// ⛔ NO GUESS. An unrecognised label with no producer context has no lifecycle.
	// The caller decides what to do; it must not silently become hash or interval.
	return Unclassified
}

// UsesReplaceManagedStorage reports whether a Kind belongs in the interval sets
// that bulk synchronisation flushes and repopulates.
//
// ⛔ This is the ONLY predicate storage routing may consult. Everything else is
// provenance.
func UsesReplaceManagedStorage(k Kind) bool { return k == ReplaceManaged }
