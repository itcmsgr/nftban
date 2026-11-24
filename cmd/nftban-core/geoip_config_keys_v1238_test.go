// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238: the shipped GeoIP key names (GEOIP_PROVIDER, GEOIP_MAXMIND_KEY) reach the consumer, the
// canonical names (GEOIP_DB_SOURCE, GEOIP_MAXMIND_LICENSE_KEY) win within one file, later files win,
// and existing configurations keep their meaning. Low-entropy placeholder values only.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

func geoipCfgDir(t *testing.T, files map[string]string) *nftbanconf.Config {
	t.Helper()
	d := t.TempDir()
	for name, body := range files {
		p := filepath.Join(d, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o750); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o640); err != nil {
			t.Fatal(err)
		}
	}
	return &nftbanconf.Config{ConfigDir: d}
}

func TestGeoipShippedKeyNamesReachConsumer(t *testing.T) {
	key := "placeholder" + strings.Repeat("0", 8)
	cases := []struct {
		name       string
		files      map[string]string
		wantSrc    string
		wantKeySet bool
	}{
		{"shipped default", map[string]string{"conf.d/geoip/main.conf": "GEOIP_PROVIDER=\"dbip\"\n"}, "dbip", false},
		{"shipped names in .local", map[string]string{
			"conf.d/geoip/main.conf":       "GEOIP_PROVIDER=\"dbip\"\n",
			"conf.d/geoip/main.conf.local": "GEOIP_PROVIDER=\"maxmind\"\nGEOIP_MAXMIND_KEY=\"" + key + "\"\n"}, "maxmind", true},
		{"canonical names written by the CLI (existing configs unchanged)", map[string]string{
			"conf.d/geoip/main.conf":       "GEOIP_PROVIDER=\"dbip\"\n",
			"conf.d/geoip/main.conf.local": "GEOIP_DB_SOURCE=\"maxmind\"\nGEOIP_MAXMIND_LICENSE_KEY=\"" + key + "\"\n"}, "maxmind", true},
		{"canonical wins within one file", map[string]string{
			"conf.d/geoip/main.conf.local": "GEOIP_DB_SOURCE=\"dbip\"\nGEOIP_PROVIDER=\"maxmind\"\n"}, "dbip", false},
		{"central override wins over module .local", map[string]string{
			"conf.d/geoip/main.conf.local": "GEOIP_DB_SOURCE=\"maxmind\"\n",
			"nftban.conf.local":            "GEOIP_PROVIDER=\"dbip\"\n"}, "dbip", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := loadGeoIPConfig(geoipCfgDir(t, tc.files))
			if got.Source != tc.wantSrc {
				t.Fatalf("Source = %q, want %q", got.Source, tc.wantSrc)
			}
			if (got.LicenseKey == key) != tc.wantKeySet {
				t.Fatalf("licence key set = %v, want %v", got.LicenseKey == key, tc.wantKeySet)
			}
		})
	}
}
