// =============================================================================
// NFTBan - GeoIP Database Management Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_geoip"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Manage GeoIP database for country-based IP lookups"
// meta:input="Subcommand (update, status, lookup)"
// meta:output="Console output with GeoIP status and lookup results"
// meta:depends="github.com/itcmsgr/nftban/internal/nftbanconf,github.com/oschwald/maxminddb-golang"
// meta:inventory.files="/var/lib/nftban/geoip/*.mmdb"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/geoip/main.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network="http"
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/safeconv"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/oschwald/maxminddb-golang"
)

// GeoIP provider configuration
type geoipConfig struct {
	Source     string // "dbip" or "maxmind"
	LicenseKey string // MaxMind license key
}

// loadGeoIPConfig reads GeoIP settings from config files
func loadGeoIPConfig(cfg *nftbanconf.Config) geoipConfig {
	config := geoipConfig{
		Source: "dbip", // Default
	}

	// Read from config files (shell variable format)
	// Module configs first, then central override last (highest priority)
	configFiles := []string{
		cfg.ConfigDir + "/conf.d/geoip/main.conf",
		cfg.ConfigDir + "/conf.d/geoip/main.conf.local",
		cfg.ConfigDir + "/conf.d/nftban-go.conf",       // Legacy (deprecated)
		cfg.ConfigDir + "/conf.d/nftban-go.conf.local", // Legacy (deprecated)
		cfg.ConfigDir + "/nftban.conf.local",           // Central override (highest priority)
	}

	for _, configFile := range configFiles {
		if file, err := os.Open(configFile); err == nil {
			scanner := bufio.NewScanner(file)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if strings.HasPrefix(line, "#") || line == "" {
					continue
				}
				if strings.HasPrefix(line, "GEOIP_DB_SOURCE=") {
					val := strings.TrimPrefix(line, "GEOIP_DB_SOURCE=")
					config.Source = strings.Trim(val, "\"'")
				}
				if strings.HasPrefix(line, "GEOIP_MAXMIND_LICENSE_KEY=") {
					val := strings.TrimPrefix(line, "GEOIP_MAXMIND_LICENSE_KEY=")
					config.LicenseKey = strings.Trim(val, "\"'")
				}
			}
			file.Close()
		}
	}

	return config
}

// getGeoipDir returns the GeoIP database directory from passed config
func getGeoipDir(cfg *nftbanconf.Config) string {
	return cfg.DataDir + "/geoip"
}

func cmdGeoip(action string, cfg *nftbanconf.Config) error {
	switch action {
	case "update":
		return cmdGeoipUpdate(cfg)
	case "status":
		return cmdGeoipStatus(cfg)
	case "lookup":
		if len(os.Args) < 4 {
			return fmt.Errorf("lookup requires IP address\nUsage: nftban-core geoip lookup <IP> [--json]")
		}
		// Check for --json flag
		jsonOutput := false
		if len(os.Args) > 4 && os.Args[4] == "--json" {
			jsonOutput = true
		}
		return cmdGeoipLookup(cfg, os.Args[3], jsonOutput)
	default:
		return fmt.Errorf("unknown geoip action: %s\nUsage: nftban-core geoip [update|status|lookup]", action)
	}
}

// cmdGeoipUpdate downloads the latest GeoIP Country database
// Default: DB-IP Lite (free, no registration required, CC BY 4.0)
// Alternative: MaxMind GeoLite2 (requires free account + license key)
func cmdGeoipUpdate(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🌍", "GeoIP Database Update"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Load GeoIP configuration
	geoipCfg := loadGeoIPConfig(cfg)

	dbDir := getGeoipDir(cfg)
	var dbFile, dbBackup, dbURL, providerName string
	var useMaxMind bool

	if geoipCfg.Source == "maxmind" && geoipCfg.LicenseKey != "" {
		// MaxMind GeoLite2
		useMaxMind = true
		dbFile = filepath.Join(dbDir, "GeoLite2-Country.mmdb")
		dbBackup = filepath.Join(dbDir, "GeoLite2-Country.mmdb.backup")
		dbURL = fmt.Sprintf("https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=%s&suffix=tar.gz", geoipCfg.LicenseKey)
		providerName = "MaxMind GeoLite2-Country"
	} else {
		// DB-IP Lite (default)
		dbFile = filepath.Join(dbDir, "dbip-country-lite.mmdb")
		dbBackup = filepath.Join(dbDir, "dbip-country-lite.mmdb.backup")
		currentMonth := time.Now().Format("2006-01")
		dbURL = fmt.Sprintf("https://download.db-ip.com/free/dbip-country-lite-%s.mmdb.gz", currentMonth)
		providerName = "DB-IP Country Lite"
	}

	fmt.Printf("Provider: %s\n", providerName)
	if geoipCfg.Source == "maxmind" && geoipCfg.LicenseKey == "" {
		fmt.Println("  ⚠️  MaxMind selected but no license key configured")
		fmt.Println("  Falling back to DB-IP Lite")
	}
	fmt.Println()

	// Step 1: Ensure directory exists
	fmt.Println("Step 1: Preparing database directory...")
	if err := os.MkdirAll(dbDir, 0755); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", dbDir, err)
	}
	fmt.Printf("  ✅ Directory ready: %s\n", dbDir)
	fmt.Println()

	// Step 2: Backup existing database
	if _, err := os.Stat(dbFile); err == nil {
		fmt.Println("Step 2: Backing up existing database...")
		if err := copyFile(dbFile, dbBackup); err != nil {
			return fmt.Errorf("failed to create backup: %w", err)
		}
		fmt.Printf("  ✅ Backup created: %s\n", dbBackup)
	} else {
		fmt.Println("Step 2: No existing database (first install)")
	}
	fmt.Println()

	// Step 3: Download new database
	fmt.Printf("Step 3: Downloading %s database...\n", providerName)
	fmt.Printf("  Source: %s\n", strings.Split(dbURL, "?")[0]+"...")
	if useMaxMind {
		fmt.Println("  This may take a moment (~6MB download)...")
	} else {
		fmt.Println("  This may take a moment (~7MB download)...")
	}
	fmt.Println()

	var downloadErr error
	if useMaxMind {
		downloadErr = downloadMaxMindTarGz(dbURL, dbFile)
	} else {
		downloadErr = downloadAndDecompressGzip(dbURL, dbFile)
	}

	if downloadErr != nil {
		// Restore backup if exists
		if _, statErr := os.Stat(dbBackup); statErr == nil {
			fmt.Println("  ❌ Download failed, restoring backup...")
			os.Rename(dbBackup, dbFile)
		}
		return fmt.Errorf("download failed: %w", downloadErr)
	}
	fmt.Println("  ✅ Download complete")
	fmt.Println()

	// Step 4: Verify database
	fmt.Println("Step 4: Verifying database integrity...")
	db, err := maxminddb.Open(dbFile)
	if err != nil {
		// Restore backup if exists
		if _, statErr := os.Stat(dbBackup); statErr == nil {
			fmt.Println("  ❌ Verification failed, restoring backup...")
			os.Rename(dbBackup, dbFile)
		}
		return fmt.Errorf("database verification failed: %w", err)
	}
	defer db.Close()

	metadata := db.Metadata
	fmt.Printf("  ✅ Database Type: %s\n", metadata.DatabaseType)
	fmt.Printf("  ✅ Build Date: %s\n", time.Unix(safeconv.UintToInt64OrMax(metadata.BuildEpoch), 0).Format("2006-01-02"))
	fmt.Printf("  ✅ Description: %s\n", metadata.Description["en"])
	fmt.Println()

	// Step 5: Test lookup
	fmt.Println("Step 5: Testing lookup functionality...")
	testIP := "8.8.8.8"
	var record struct {
		Country struct {
			ISOCode string `maxminddb:"iso_code"`
		} `maxminddb:"country"`
	}

	// Parse IP
	ipAddr := []byte{8, 8, 8, 8}
	err = db.Lookup(ipAddr, &record)
	if err != nil {
		return fmt.Errorf("test lookup failed: %w", err)
	}

	if record.Country.ISOCode != "" {
		fmt.Printf("  ✅ Test lookup (%s): %s\n", testIP, record.Country.ISOCode)
	} else {
		fmt.Printf("  ⚠️  Test lookup returned no country code\n")
	}
	fmt.Println()

	// Step 6: Cleanup backup
	if _, err := os.Stat(dbBackup); err == nil {
		if err := os.Remove(dbBackup); err != nil {
			fmt.Printf("Warning: failed to remove backup: %v\n", err)
		}
	}

	// Success!
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("✅ GeoIP database updated successfully!")
	fmt.Println()
	fmt.Printf("Database: %s\n", dbFile)
	if fileInfo, err := os.Stat(dbFile); err == nil {
		fmt.Printf("Size: %.1f MB\n", float64(fileInfo.Size())/1024/1024)
	}
	fmt.Println()
	fmt.Println("The database is now ready for IP lookups.")
	fmt.Println("Use: nftban-geoip lookup <IP>")
	fmt.Println()

	return nil
}

// cmdGeoipStatus shows the current status of the GeoIP database
// Supports both DB-IP Country Lite and MaxMind GeoLite2-City databases
func cmdGeoipStatus(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🌍", "GeoIP Database Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	dbDir := getGeoipDir(cfg)

	// Try databases in order of preference
	dbFiles := []string{
		dbDir + "/dbip-country-lite.mmdb", // Default: DB-IP Country
		dbDir + "/GeoLite2-City.mmdb",     // Legacy: MaxMind City
		dbDir + "/GeoLite2-Country.mmdb",  // Legacy: MaxMind Country
	}

	var dbFile string
	var fileInfo os.FileInfo
	var err error

	for _, f := range dbFiles {
		fileInfo, err = os.Stat(f)
		if err == nil {
			dbFile = f
			break
		}
	}

	if dbFile == "" {
		fmt.Println("❌ Database: NOT FOUND")
		fmt.Printf("   Checked: %v\n", dbFiles)
		fmt.Println()
		fmt.Println("To install the database:")
		fmt.Println("  nftban-core geoip update")
		fmt.Println()
		return fmt.Errorf("database not found")
	}

	fmt.Println("✅ Database: FOUND")
	fmt.Printf("   Path: %s\n", dbFile)
	fmt.Printf("   Size: %.1f MB\n", float64(fileInfo.Size())/1024/1024)
	fmt.Printf("   Modified: %s\n", fileInfo.ModTime().Format("2006-01-02 15:04:05"))
	fmt.Println()

	// Try to open and verify database
	fmt.Println("Opening database...")
	db, err := maxminddb.Open(dbFile)
	if err != nil {
		fmt.Println("❌ Failed to open database")
		return fmt.Errorf("failed to open database: %w", err)
	}
	defer db.Close()

	metadata := db.Metadata
	fmt.Println("✅ Database opened successfully")
	fmt.Println()
	fmt.Println("Database Information:")
	fmt.Printf("  Type: %s\n", metadata.DatabaseType)
	fmt.Printf("  Build Date: %s\n", time.Unix(safeconv.UintToInt64OrMax(metadata.BuildEpoch), 0).Format("2006-01-02"))
	fmt.Printf("  Description: %s\n", metadata.Description["en"])
	fmt.Printf("  IP Version: %d\n", metadata.IPVersion)
	fmt.Printf("  Node Count: %d\n", metadata.NodeCount)
	fmt.Println()

	// Performance test
	fmt.Println("Performance Test (10 lookups):")
	testIPs := [][]byte{
		{8, 8, 8, 8},        // Google DNS
		{1, 1, 1, 1},        // Cloudflare DNS
		{208, 67, 222, 222}, // OpenDNS
	}

	var totalDuration time.Duration
	var record struct {
		Country struct {
			ISOCode string `maxminddb:"iso_code"`
		} `maxminddb:"country"`
	}

	for i := 0; i < 10; i++ {
		start := time.Now()
		db.Lookup(testIPs[i%3], &record)
		totalDuration += time.Since(start)
	}

	avgMicroseconds := totalDuration.Microseconds() / 10
	fmt.Printf("  Average lookup time: %d microseconds\n", avgMicroseconds)

	if avgMicroseconds < 1000 {
		fmt.Println("  Performance: ✅ EXCELLENT (<1ms)")
	} else if avgMicroseconds < 5000 {
		fmt.Println("  Performance: ✅ GOOD (<5ms)")
	} else {
		fmt.Println("  Performance: ⚠️  SLOW (>5ms)")
	}
	fmt.Println()

	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("Status: ✅ OK")
	fmt.Println()

	return nil
}

// cmdGeoipLookup performs IP→Country lookup
// Supports both DB-IP Country Lite and MaxMind GeoLite2-City databases
func cmdGeoipLookup(cfg *nftbanconf.Config, ipStr string, jsonOutput bool) error {
	dbDir := getGeoipDir(cfg)

	// Try databases in order of preference
	dbFiles := []string{
		dbDir + "/dbip-country-lite.mmdb", // Default: DB-IP Country
		dbDir + "/GeoLite2-City.mmdb",     // Legacy: MaxMind City
		dbDir + "/GeoLite2-Country.mmdb",  // Legacy: MaxMind Country
	}

	var db *maxminddb.Reader
	var dbFile string
	var err error

	for _, f := range dbFiles {
		db, err = maxminddb.Open(f)
		if err == nil {
			dbFile = f
			break
		}
	}

	if db == nil {
		return fmt.Errorf("failed to open GeoIP database\nTried: %v\nRun: nftban-core geoip update", dbFiles)
	}
	defer db.Close()

	// Check database type to determine available fields
	dbType := db.Metadata.DatabaseType
	hasCity := strings.Contains(dbType, "City")

	// Lookup IP with full record structure (works for both Country and City)
	var record struct {
		Country struct {
			ISOCode string            `maxminddb:"iso_code"`
			Names   map[string]string `maxminddb:"names"`
		} `maxminddb:"country"`
		City struct {
			Names map[string]string `maxminddb:"names"`
		} `maxminddb:"city"`
		Location struct {
			Latitude  float64 `maxminddb:"latitude"`
			Longitude float64 `maxminddb:"longitude"`
			TimeZone  string  `maxminddb:"time_zone"`
		} `maxminddb:"location"`
	}

	// Parse IP string to net.IP
	parsedIP := net.ParseIP(ipStr)
	if parsedIP == nil {
		return fmt.Errorf("invalid IP address: %s", ipStr)
	}

	err = db.Lookup(parsedIP, &record)
	if err != nil {
		return fmt.Errorf("lookup failed: %w", err)
	}

	// Extract data with defaults
	countryCode := record.Country.ISOCode
	if countryCode == "" {
		countryCode = "Unknown"
	}

	countryName := record.Country.Names["en"]
	if countryName == "" {
		countryName = "Unknown"
	}

	// Output format
	if jsonOutput {
		// JSON format for GUI/API
		if hasCity {
			cityName := record.City.Names["en"]
			if cityName == "" {
				cityName = "Unknown"
			}
			timezone := record.Location.TimeZone
			if timezone == "" {
				timezone = "Unknown"
			}
			fmt.Printf(`{"ip":"%s","country_code":"%s","country_name":"%s","city":"%s","timezone":"%s","latitude":%f,"longitude":%f,"database":"%s"}`,
				ipStr, countryCode, countryName, cityName, timezone,
				record.Location.Latitude, record.Location.Longitude, filepath.Base(dbFile))
		} else {
			fmt.Printf(`{"ip":"%s","country_code":"%s","country_name":"%s","database":"%s"}`,
				ipStr, countryCode, countryName, filepath.Base(dbFile))
		}
		fmt.Println()
	} else {
		// Compact format for shell scripts
		if hasCity {
			cityName := record.City.Names["en"]
			if cityName == "" {
				cityName = "Unknown"
			}
			fmt.Printf("%s/%s/%s\n", countryCode, cityName, record.Location.TimeZone)
		} else {
			fmt.Printf("%s/%s\n", countryCode, countryName)
		}
	}

	return nil
}

// copyFile copies a file from src to dst
func copyFile(src, dst string) error {
	sourceFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sourceFile.Close()

	destFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destFile.Close()

	_, err = io.Copy(destFile, sourceFile)
	return err
}

// downloadAndDecompressGzip downloads a .gz file and decompresses it
func downloadAndDecompressGzip(url, destPath string) error {
	tmpFile := destPath + ".tmp"

	// Create HTTP client with timeout
	client := &http.Client{
		Timeout: 5 * time.Minute,
	}

	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("download failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("bad status: %s", resp.Status)
	}

	// Show download progress
	totalSize := resp.ContentLength
	downloaded := int64(0)
	lastProgress := 0

	// Create a progress reader
	progressReader := &progressReader{
		reader:       resp.Body,
		total:        totalSize,
		downloaded:   &downloaded,
		lastProgress: &lastProgress,
	}

	// Decompress gzip stream
	gzReader, err := gzip.NewReader(progressReader)
	if err != nil {
		return fmt.Errorf("gzip open failed: %w", err)
	}
	defer gzReader.Close()

	// Write decompressed data to temp file
	out, err := os.Create(tmpFile)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, gzReader)
	if err != nil {
		os.Remove(tmpFile)
		return fmt.Errorf("decompress failed: %w", err)
	}

	// Move temp file to final location
	if err := os.Rename(tmpFile, destPath); err != nil {
		os.Remove(tmpFile)
		return err
	}

	return nil
}

// progressReader wraps an io.Reader to show download progress
type progressReader struct {
	reader       io.Reader
	total        int64
	downloaded   *int64
	lastProgress *int
}

func (pr *progressReader) Read(p []byte) (int, error) {
	n, err := pr.reader.Read(p)
	if n > 0 {
		*pr.downloaded += int64(n)

		// Print progress every 10%
		if pr.total > 0 {
			progress := int(float64(*pr.downloaded) / float64(pr.total) * 100)
			if progress >= *pr.lastProgress+10 {
				fmt.Printf("  Progress: %d%% (%.1f MB / %.1f MB)\n",
					progress,
					float64(*pr.downloaded)/1024/1024,
					float64(pr.total)/1024/1024)
				*pr.lastProgress = progress
			}
		}
	}
	return n, err
}

// downloadMaxMindTarGz downloads and extracts MaxMind tar.gz format
func downloadMaxMindTarGz(url, destPath string) error {
	tmpFile := destPath + ".tmp"

	// Create HTTP client with timeout
	client := &http.Client{
		Timeout: 5 * time.Minute,
	}

	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("download failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("bad status: %s", resp.Status)
	}

	// Show download progress
	totalSize := resp.ContentLength
	downloaded := int64(0)
	lastProgress := 0

	progressReader := &progressReader{
		reader:       resp.Body,
		total:        totalSize,
		downloaded:   &downloaded,
		lastProgress: &lastProgress,
	}

	// Open gzip reader
	gzReader, err := gzip.NewReader(progressReader)
	if err != nil {
		return fmt.Errorf("gzip open failed: %w", err)
	}
	defer gzReader.Close()

	// Open tar reader
	tarReader := tar.NewReader(gzReader)

	// Find .mmdb file in tar archive
	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			return fmt.Errorf("no .mmdb file found in archive")
		}
		if err != nil {
			return fmt.Errorf("tar read failed: %w", err)
		}

		// Look for .mmdb file
		if strings.HasSuffix(header.Name, ".mmdb") {
			// Write to temp file
			out, err := os.Create(tmpFile)
			if err != nil {
				return err
			}

			_, err = io.Copy(out, tarReader)
			out.Close()
			if err != nil {
				os.Remove(tmpFile)
				return fmt.Errorf("extract failed: %w", err)
			}

			// Move temp file to final location
			if err := os.Rename(tmpFile, destPath); err != nil {
				os.Remove(tmpFile)
				return err
			}

			return nil
		}
	}
}
