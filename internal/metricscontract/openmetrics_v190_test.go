// SPDX-License-Identifier: MPL-2.0
//
// meta:name="openmetrics_v190_test"
// meta:type="test"
// meta:version="1.190.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.190.0 SOS-4 OpenMetrics scrape-contract validation (hermetic). Gathers the default Prometheus registry (with the real metric registrants imported), encodes it to text exposition with expfmt, and re-parses it — proving: (1) the exposition is PARSER-VALID and round-trips (HELP/TYPE valid, no duplicate HELP/TYPE conflicts, no duplicate metric family — Gather() + TextToMetricFamilies enforce this); (2) anti-false-zero gate nftban_counters_population_phase exists, is a GAUGE, is NOT named _total, and equals 0 in the contract phase; (3) NO dedicated nftban_nft_anchor_* family is emitted (SOS-2 anchors only via nft_named_counter_*); (4) the existing nft_named_counter_* family, if present, keeps labels {family,counter} and family values stay raw ip/ip6 — NEVER ipv4/ipv6 (SOS-3 Prometheus compat preserved); (5) NO new v1.190 BotScan/BotGuard/Whitelist/FCrDNS counter series are registered (false-zero-free). Alias-mirror (firewall_rules_total==nft_rules_total) + suricata distinctness register lazily at runtime → covered by the lab-first promtool scrape, not this init-time gather."
// meta:inventory.files="internal/metricscontract/openmetrics_v190_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package metricscontract

import (
	"bytes"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
	"github.com/prometheus/common/expfmt"
	"github.com/prometheus/common/model"

	// Import the REAL metric registrants so their package-level promauto vars
	// register on the default registry before we gather (init-time registration).
	_ "github.com/itcmsgr/nftban/internal/metrics"
	_ "github.com/itcmsgr/nftban/internal/watchdog"
)

// gatherAndRoundTrip gathers the default registry, encodes every family to text
// exposition (expfmt), and re-parses it. A non-nil error from Gather() or from
// the parser means the scrape surface is NOT contract-valid (duplicate family,
// type conflict, bad HELP/TYPE, invalid label/sample). Returns the re-parsed
// family map (keyed by metric name) for invariant assertions.
func gatherAndRoundTrip(t *testing.T) map[string]*dto.MetricFamily {
	t.Helper()
	fams, err := prometheus.DefaultGatherer.Gather()
	if err != nil {
		t.Fatalf("SOS-4: registry Gather() failed — scrape surface inconsistent: %v", err)
	}
	var buf bytes.Buffer
	for _, mf := range fams {
		if _, err := expfmt.MetricFamilyToText(&buf, mf); err != nil {
			t.Fatalf("SOS-4: MetricFamilyToText(%s) failed: %v", mf.GetName(), err)
		}
	}
	// LegacyValidation = classic Prometheus metric/label names (all nftban_* metrics
	// satisfy it); the scheme must be set explicitly or the parser panics on "unset".
	p := expfmt.NewTextParser(model.LegacyValidation)
	parsed, err := p.TextToMetricFamilies(strings.NewReader(buf.String()))
	if err != nil {
		t.Fatalf("SOS-4: emitted /metrics text did NOT parse (format invalid): %v", err)
	}
	return parsed
}

// (1) The exposition must parse cleanly (format validity + no dup HELP/TYPE).
func TestOpenMetrics_ScrapeParsesClean(t *testing.T) {
	parsed := gatherAndRoundTrip(t)
	if len(parsed) == 0 {
		t.Fatalf("SOS-4: no metric families gathered — registrant import did not register")
	}
}

// (2) Anti-false-zero gate: counters_population_phase present, GAUGE, !_total, ==0.
func TestOpenMetrics_PhaseGaugeIsZeroContract(t *testing.T) {
	parsed := gatherAndRoundTrip(t)
	const name = "nftban_counters_population_phase"
	mf, ok := parsed[name]
	if !ok {
		t.Fatalf("SOS-4: %s MUST be present (anti-false-zero gate)", name)
	}
	if mf.GetType() != dto.MetricType_GAUGE {
		t.Errorf("%s must be a GAUGE; got %s", name, mf.GetType())
	}
	if strings.HasSuffix(name, "_total") {
		t.Errorf("%s must NOT be named _total (it is a phase gauge, not a counter)", name)
	}
	if len(mf.Metric) != 1 || mf.Metric[0].GetGauge().GetValue() != 0 {
		t.Errorf("%s must equal 0 in the v1.190.0 contract phase; got %+v", name, mf.Metric)
	}
}

// (3) Canonical rule-count present; (SOS-2) NO dedicated anchor metric family.
func TestOpenMetrics_RuleCountAndNoAnchorMetric(t *testing.T) {
	parsed := gatherAndRoundTrip(t)
	if _, ok := parsed["nftban_nft_rules_total"]; !ok {
		t.Errorf("SOS-4: canonical nftban_nft_rules_total missing from scrape")
	}
	for name := range parsed {
		if strings.Contains(name, "nft_anchor") {
			t.Errorf("SOS-2 violation: dedicated anchor metric emitted: %s (anchors must reuse nft_named_counter_*)", name)
		}
	}
}

// (4) SOS-3 Prometheus compat: named-counter family stays {family,counter} with
// raw ip/ip6 — never ipv4/ipv6 (no relabel of the existing shipped surface).
func TestOpenMetrics_NamedCounterFamilyLabelsCompat(t *testing.T) {
	parsed := gatherAndRoundTrip(t)
	for _, name := range []string{"nftban_nft_named_counter_packets_total", "nftban_nft_named_counter_bytes_total"} {
		mf, ok := parsed[name]
		if !ok {
			continue // empty GaugeVec (no children at init) → family absent; nothing to relabel
		}
		for _, m := range mf.Metric {
			var hasFamily, hasCounter bool
			for _, lp := range m.Label {
				switch lp.GetName() {
				case "family":
					hasFamily = true
					if v := lp.GetValue(); v == "ipv4" || v == "ipv6" {
						t.Errorf("SOS-3 violation: %s relabeled family to %q (must stay raw ip/ip6 for compat)", name, v)
					}
				case "counter":
					hasCounter = true
				}
			}
			if !hasFamily || !hasCounter {
				t.Errorf("%s must keep {family,counter} labels; got %+v", name, m.Label)
			}
		}
	}
}

// (5) False-zero-free: NO new v1.190 BotScan/BotGuard/Whitelist/FCrDNS counter
// series are registered (those are v1.191 population, not contract phase).
func TestOpenMetrics_NoNewCounterSeriesInContract(t *testing.T) {
	parsed := gatherAndRoundTrip(t)
	// substrings that would indicate a v1.191 population metric leaked into v1.190
	forbidden := []string{
		"botscan_scanned", "botscan_matched", "botscan_signals", "botscan_bans",
		"botscan_crawler_verify", "botguard_decisions", "botguard_eventbus",
		"whitelist_changes", "fcrdns_",
	}
	for name := range parsed {
		for _, f := range forbidden {
			if strings.Contains(name, f) {
				t.Errorf("false-zero risk: new v1.190 counter series registered before population: %s (matches %q)", name, f)
			}
		}
	}
}
