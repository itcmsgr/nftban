package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban-v1.0-dev/pkg/nftbanconf"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/version"
	"github.com/oschwald/maxminddb-golang"
)

// getGeoipDir returns the GeoIP database directory from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getGeoipDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.DataDir + "/geoip"
}

func cmdGeoip(action string) error {
	switch action {
	case "update":
		return cmdGeoipUpdate()
	case "status":
		return cmdGeoipStatus()
	case "lookup":
		if len(os.Args) < 4 {
			return fmt.Errorf("lookup requires IP address\nUsage: nftban-core geoip lookup <IP> [--json]")
		}
		// Check for --json flag
		jsonOutput := false
		if len(os.Args) > 4 && os.Args[4] == "--json" {
			jsonOutput = true
		}
		return cmdGeoipLookup(os.Args[3], jsonOutput)
	default:
		return fmt.Errorf("unknown geoip action: %s\nUsage: nftban-core geoip [update|status|lookup]", action)
	}
}

// cmdGeoipUpdate downloads the latest GeoLite2-City database
func cmdGeoipUpdate() error {
	fmt.Println(version.BannerWithEmoji("🌍", "GeoIP Database Update"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	dbDir := getGeoipDir()
	dbFile := filepath.Join(dbDir, "GeoLite2-City.mmdb")
	dbBackup := filepath.Join(dbDir, "GeoLite2-City.mmdb.backup")
	dbURL := "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-City.mmdb"

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
	fmt.Println("Step 3: Downloading GeoLite2-City database...")
	fmt.Printf("  Source: %s\n", dbURL)
	fmt.Println("  This may take a minute (~61MB download)...")
	fmt.Println()

	if err := downloadFile(dbURL, dbFile); err != nil {
		// Restore backup if exists
		if _, statErr := os.Stat(dbBackup); statErr == nil {
			fmt.Println("  ❌ Download failed, restoring backup...")
			os.Rename(dbBackup, dbFile)
		}
		return fmt.Errorf("download failed: %w", err)
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
	fmt.Printf("  ✅ Build Date: %s\n", time.Unix(int64(metadata.BuildEpoch), 0).Format("2006-01-02"))
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
		os.Remove(dbBackup)
	}

	// Success!
	fileInfo, _ := os.Stat(dbFile)
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("✅ GeoIP database updated successfully!")
	fmt.Println()
	fmt.Printf("Database: %s\n", dbFile)
	fmt.Printf("Size: %.1f MB\n", float64(fileInfo.Size())/1024/1024)
	fmt.Println()
	fmt.Println("The database is now ready for IP lookups.")
	fmt.Println("Use: nftban-geoip lookup <IP>")
	fmt.Println()

	return nil
}

// cmdGeoipStatus shows the current status of the GeoIP database
func cmdGeoipStatus() error {
	fmt.Println(version.BannerWithEmoji("🌍", "GeoIP Database Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	dbFile := getGeoipDir() + "/GeoLite2-City.mmdb"

	// Check if database exists
	fileInfo, err := os.Stat(dbFile)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Println("❌ Database: NOT FOUND")
			fmt.Printf("   Path: %s\n", dbFile)
			fmt.Println()
			fmt.Println("To install the database:")
			fmt.Println("  nftban-core geoip update")
			fmt.Println()
			return fmt.Errorf("database not found")
		}
		return fmt.Errorf("failed to stat database: %w", err)
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
	fmt.Printf("  Build Date: %s\n", time.Unix(int64(metadata.BuildEpoch), 0).Format("2006-01-02"))
	fmt.Printf("  Description: %s\n", metadata.Description["en"])
	fmt.Printf("  IP Version: %d\n", metadata.IPVersion)
	fmt.Printf("  Node Count: %d\n", metadata.NodeCount)
	fmt.Println()

	// Performance test
	fmt.Println("Performance Test (10 lookups):")
	testIPs := [][]byte{
		{8, 8, 8, 8},       // Google DNS
		{1, 1, 1, 1},       // Cloudflare DNS
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

// downloadFile downloads a file from URL to the specified path with progress
func downloadFile(url, filepath string) error {
	// Create temp file
	tmpFile := filepath + ".tmp"
	out, err := os.Create(tmpFile)
	if err != nil {
		return err
	}
	defer out.Close()

	// Get the data
	client := &http.Client{
		Timeout: 5 * time.Minute,
	}

	resp, err := client.Get(url)
	if err != nil {
		os.Remove(tmpFile)
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		os.Remove(tmpFile)
		return fmt.Errorf("bad status: %s", resp.Status)
	}

	// Write the body to file with progress
	totalSize := resp.ContentLength
	downloaded := int64(0)
	lastProgress := 0

	buffer := make([]byte, 32*1024) // 32KB buffer
	for {
		n, err := resp.Body.Read(buffer)
		if n > 0 {
			_, writeErr := out.Write(buffer[:n])
			if writeErr != nil {
				os.Remove(tmpFile)
				return writeErr
			}
			downloaded += int64(n)

			// Print progress every 10%
			if totalSize > 0 {
				progress := int(float64(downloaded) / float64(totalSize) * 100)
				if progress >= lastProgress+10 {
					fmt.Printf("  Progress: %d%% (%.1f MB / %.1f MB)\n",
						progress,
						float64(downloaded)/1024/1024,
						float64(totalSize)/1024/1024)
					lastProgress = progress
				}
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			os.Remove(tmpFile)
			return err
		}
	}

	// Move temp file to final location
	if err := os.Rename(tmpFile, filepath); err != nil {
		os.Remove(tmpFile)
		return err
	}

	return nil
}

// cmdGeoipLookup performs IP→Country lookup
func cmdGeoipLookup(ipStr string, jsonOutput bool) error {
	dbFile := getGeoipDir() + "/GeoLite2-City.mmdb"

	// Open database
	db, err := maxminddb.Open(dbFile)
	if err != nil {
		return fmt.Errorf("failed to open GeoIP database: %w\nDatabase path: %s\nRun: nftban-core geoip update", err, dbFile)
	}
	defer db.Close()

	// Lookup IP
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

	err = db.Lookup([]byte(ipStr), &record)
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

	cityName := record.City.Names["en"]
	if cityName == "" {
		cityName = "Unknown"
	}

	timezone := record.Location.TimeZone
	if timezone == "" {
		timezone = "Unknown"
	}

	latitude := record.Location.Latitude
	longitude := record.Location.Longitude

	// Output format
	if jsonOutput {
		// JSON format for GUI/API
		fmt.Printf(`{"ip":"%s","country_code":"%s","country_name":"%s","city":"%s","timezone":"%s","latitude":%f,"longitude":%f}`,
			ipStr, countryCode, countryName, cityName, timezone, latitude, longitude)
		fmt.Println()
	} else {
		// Compact format for shell scripts: CC/City/Timezone
		fmt.Printf("%s/%s/%s\n", countryCode, cityName, timezone)
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
