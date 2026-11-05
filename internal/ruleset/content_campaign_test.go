// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package ruleset

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
)

// fakeAdmit adds the whole-prefix admission to fakeExempt (nftbackend AdmitPrefix stand-in).
type fakeAdmit struct {
	fakeExempt
	refuse map[string]bool
}

func (f fakeAdmit) AdmitPrefix(p string) (bool, string) { return !f.refuse[p], "fake" }

func campaignKernel() map[string][]Element {
	return map[string][]Element{
		"ip/" + constants.CampaignPrefixSetIPv4: {
			{Key: "45.33.32.0/24", HasTimeout: true, Remaining: 1800 * time.Second},    // carried, TTL kept
			{Key: "185.220.101.0/24", HasTimeout: true, Remaining: 9000 * time.Second}, // capped at 5400
			{Key: "45.33.33.0/24", HasTimeout: true, Remaining: 1800 * time.Second},    // not admitted
			{Key: "45.33.34.0/24", HasTimeout: true, Remaining: 3 * time.Second},       // expires within the margin
			{Key: "23.129.98.0/24"}, // untimed: never carried
			{Key: "45.33.35.0-45.33.35.9", HasTimeout: true, Remaining: time.Hour}, // range: not ours
		},
	}
}

func campaignOn(t *testing.T, opts Options) {
	t.Helper()
	write(t, filepath.Join(opts.DataDir, constants.CampaignEnabledMarker), "")
}

func TestRenderCampaignPrefixCarry(t *testing.T) {
	opts := fixture(t)
	campaignOn(t, opts)
	ex := fakeAdmit{fakeExempt: fakeExempt{}, refuse: map[string]bool{"45.33.33.0/24": true}}
	res, err := Render(opts, reader(campaignKernel()), ex)
	if err != nil {
		t.Fatal(err)
	}
	l := line(res.Script, constants.CampaignPrefixSetIPv4)
	if l == "" {
		t.Fatalf("campaign set not rendered:\n%s", res.Script)
	}
	for _, want := range []string{"45.33.32.0/24 timeout 1795s", "185.220.101.0/24 timeout 5395s"} {
		if !strings.Contains(l, want) {
			t.Errorf("missing %q in %s", want, l)
		}
	}
	for _, never := range []string{"45.33.33.0/24", "45.33.34.0/24", "23.129.98.0/24", "45.33.35.0"} {
		if strings.Contains(l, never) {
			t.Errorf("%s must not be carried: %s", never, l)
		}
	}
	if res.CampaignRefused != 3 {
		t.Errorf("CampaignRefused=%d, want 3 (not admitted, untimed, range)", res.CampaignRefused)
	}
	// Separate from the feed-owned interval set in both directions.
	if strings.Contains(line(res.Script, "blacklist_ipv4"), "45.33.32.0/24") {
		t.Error("a campaign prefix leaked into blacklist_ipv4")
	}
	if strings.Contains(l, "45.155.205.0/24") {
		t.Error("a feed prefix leaked into the campaign set")
	}
	if line(res.Script, "campaign_prefix_ipv6") != "" {
		t.Error("an IPv6 campaign set was rendered: campaign enforcement is IPv4 /24 only")
	}
}

// Disabled (marker absent): a reload/rebuild carries nothing, so the set ends up empty.
func TestRenderCampaignPrefixDisabledEmptiesSet(t *testing.T) {
	opts := fixture(t)
	ex := fakeAdmit{fakeExempt: fakeExempt{}, refuse: map[string]bool{}}
	res, err := Render(opts, reader(campaignKernel()), ex)
	if err != nil {
		t.Fatal(err)
	}
	if l := line(res.Script, constants.CampaignPrefixSetIPv4); l != "" {
		t.Fatalf("carried while disabled: %s", l)
	}
	if res.CampaignRefused != len(campaignKernel()["ip/"+constants.CampaignPrefixSetIPv4]) {
		t.Fatalf("CampaignRefused=%d, want every element", res.CampaignRefused)
	}
}

// An authority without whole-prefix admission carries no campaign prefix (fail closed).
func TestRenderCampaignPrefixWithoutAdmissionCarriesNothing(t *testing.T) {
	opts := fixture(t)
	campaignOn(t, opts)
	res, err := Render(opts, reader(campaignKernel()), fakeExempt{})
	if err != nil {
		t.Fatal(err)
	}
	if l := line(res.Script, constants.CampaignPrefixSetIPv4); l != "" {
		t.Fatalf("carried without admission: %s", l)
	}
}

func TestChainDropsFromSet(t *testing.T) {
	const drop = `{"nftables":[{"metainfo":{}},{"chain":{"family":"ip","table":"nftban","name":"input"}},
{"rule":{"family":"ip","table":"nftban","chain":"input","expr":[
 {"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":{"set":[80,443]}}},
 {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"@campaign_prefix_ipv4"}},
 {"counter":{"name":"input_campaign_prefix_drop"}},{"drop":null}]}}]}`
	const accept = `{"nftables":[{"rule":{"expr":[
 {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"@campaign_prefix_ipv4"}},
 {"accept":null}]}}]}`
	const other = `{"nftables":[{"rule":{"expr":[
 {"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"@blacklist_ipv4"}},
 {"drop":null}]}}]}`
	for name, c := range map[string]struct {
		doc  string
		want bool
	}{"drop rule": {drop, true}, "accept rule": {accept, false}, "other set": {other, false}} {
		got, err := chainDropsFromSet([]byte(c.doc), constants.CampaignPrefixSetIPv4)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if got != c.want {
			t.Errorf("%s: %v, want %v", name, got, c.want)
		}
	}
}
