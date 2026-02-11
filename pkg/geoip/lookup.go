// =============================================================================
// NFTBan v1.0 - GeoIP Lookup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lookup"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="GeoIP lookup using MaxMind database"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package geoip

import (
	"net"
	"os"
	"sync"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/oschwald/maxminddb-golang"
)

var (
	db     *maxminddb.Reader
	dbOnce sync.Once
	dbErr  error
)

// getGeoIPDBPath returns the GeoIP database path from central config
// Checks for databases in order of preference:
// 1. dbip-country-lite.mmdb (Default: DB-IP Lite)
// 2. GeoLite2-City.mmdb (Legacy: MaxMind City)
// 3. GeoLite2-Country.mmdb (Legacy: MaxMind Country)
func getGeoIPDBPath() string {
	var geoipDir string
	paths := nftbanconf.MustLoadPaths()
	if paths.GeoIPDir != "" {
		geoipDir = paths.GeoIPDir
	} else {
		cfg := nftbanconf.MustLoad()
		geoipDir = cfg.DataDir + "/geoip"
	}

	// Check for databases in order of preference
	dbFiles := []string{
		geoipDir + "/dbip-country-lite.mmdb",  // Default: DB-IP Country
		geoipDir + "/GeoLite2-City.mmdb",      // Legacy: MaxMind City
		geoipDir + "/GeoLite2-Country.mmdb",   // Legacy: MaxMind Country
	}

	for _, f := range dbFiles {
		if _, err := os.Stat(f); err == nil {
			return f
		}
	}

	// Return default (will error on open if not exists)
	return dbFiles[0]
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
