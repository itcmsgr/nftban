// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package geoip

import (
	"net"
	"sync"

	"github.com/itcmsgr/nftban-v1.0-dev/pkg/nftbanconf"
	"github.com/oschwald/maxminddb-golang"
)

var (
	db     *maxminddb.Reader
	dbOnce sync.Once
	dbErr  error
)

// getGeoIPDBPath returns the GeoIP database path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getGeoIPDBPath() string {
	paths := nftbanconf.MustLoadPaths()
	if paths.GeoIPDir != "" {
		return paths.GeoIPDir + "/GeoLite2-City.mmdb"
	}
	cfg := nftbanconf.MustLoad()
	return cfg.DataDir + "/geoip/GeoLite2-City.mmdb"
}

// LookupIP performs a GeoIP lookup for an IP address.
// Returns country code and city name, or empty strings if not found/error.
// Safe to call concurrently from multiple goroutines.
func LookupIP(ip string) (countryCode string, cityName string) {
	// Lazy-load the database on first call
	dbOnce.Do(func() {
		dbPath := getGeoIPDBPath()
		db, dbErr = maxminddb.Open(dbPath)
	})

	// If database failed to open, return empty
	if dbErr != nil {
		return "", ""
	}

	// Parse IP address
	parsedIP := net.ParseIP(ip)
	if parsedIP == nil {
		return "", ""
	}

	// Lookup in database
	var record struct {
		Country struct {
			ISOCode string `maxminddb:"iso_code"`
		} `maxminddb:"country"`
		City struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"city"`
	}

	if err := db.Lookup(parsedIP, &record); err != nil {
		return "", ""
	}

	// Extract country code
	countryCode = record.Country.ISOCode

	// Extract city name (English)
	if record.City.Names != nil {
		cityName = record.City.Names["en"]
	}

	return countryCode, cityName
}

// Close closes the GeoIP database.
// Only call this on application shutdown.
func Close() {
	if db != nil {
		db.Close()
	}
}
