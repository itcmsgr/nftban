package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/oschwald/maxminddb-golang"
)

const (
	VERSION   = "1.0.0"
	MMDB_PATH = "/var/lib/nftban/geoip/GeoLite2-City.mmdb"
)

// GeoIPResult represents the JSON output structure
type GeoIPResult struct {
	IP           string  `json:"ip"`
	Country      string  `json:"country"`
	CountryCode  string  `json:"country_code"`
	Region       string  `json:"region"`
	City         string  `json:"city"`
	PostalCode   string  `json:"postal_code,omitempty"`
	Latitude     float64 `json:"latitude,omitempty"`
	Longitude    float64 `json:"longitude,omitempty"`
	TimeZone     string  `json:"timezone,omitempty"`
	ISP          string  `json:"isp,omitempty"`
	ASN          string  `json:"asn,omitempty"`
	Org          string  `json:"org,omitempty"`
	LookupTimeUs int64   `json:"lookup_time_us"`
	Cached       bool    `json:"cached"`
}

// MaxMind database record structure
type MaxMindRecord struct {
	Country struct {
		Names   map[string]string `maxminddb:"names"`
		IsoCode string            `maxminddb:"iso_code"`
	} `maxminddb:"country"`
	City struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"city"`
	Location struct {
		Latitude  float64 `maxminddb:"latitude"`
		Longitude float64 `maxminddb:"longitude"`
		TimeZone  string  `maxminddb:"time_zone"`
	} `maxminddb:"location"`
	Postal struct {
		Code string `maxminddb:"code"`
	} `maxminddb:"postal"`
	Subdivisions []struct {
		Names map[string]string `maxminddb:"names"`
	} `maxminddb:"subdivisions"`
}

var db *maxminddb.Reader

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	cmd := os.Args[1]

	// Handle commands that don't need DB
	switch cmd {
	case "version", "--version", "-v":
		fmt.Printf("nftban-geoip v%s\n", VERSION)
		os.Exit(0)
	case "help", "--help", "-h":
		usage()
		os.Exit(0)
	}

	// Open database once (stays in memory)
	var err error
	db, err = maxminddb.Open(MMDB_PATH)
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":"Cannot open MaxMind DB at %s: %v"}`+"\n", MMDB_PATH, err)
		os.Exit(1)
	}
	defer db.Close()

	// Handle commands
	switch cmd {
	case "lookup":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, `{"error":"IP address required"}`)
			os.Exit(1)
		}
		lookupIP(os.Args[2])
	case "bulk":
		bulkLookup()
	case "status":
		status()
	case "test":
		runTests()
	default:
		fmt.Fprintf(os.Stderr, `{"error":"Unknown command: %s"}`+"\n", cmd)
		usage()
		os.Exit(1)
	}
}

func lookupIP(ipStr string) {
	start := time.Now()

	ip := net.ParseIP(ipStr)
	if ip == nil {
		fmt.Fprintf(os.Stderr, `{"error":"Invalid IP address: %s"}`+"\n", ipStr)
		os.Exit(1)
	}

	var record MaxMindRecord

	err := db.Lookup(ip, &record)
	if err != nil {
		fmt.Fprintf(os.Stderr, `{"error":"Lookup failed: %v"}`+"\n", err)
		os.Exit(1)
	}

	elapsed := time.Since(start).Microseconds()

	result := GeoIPResult{
		IP:           ipStr,
		Country:      record.Country.Names["en"],
		CountryCode:  record.Country.IsoCode,
		City:         record.City.Names["en"],
		PostalCode:   record.Postal.Code,
		Latitude:     record.Location.Latitude,
		Longitude:    record.Location.Longitude,
		TimeZone:     record.Location.TimeZone,
		LookupTimeUs: elapsed,
		Cached:       false, // First lookup from DB
	}

	if len(record.Subdivisions) > 0 {
		result.Region = record.Subdivisions[0].Names["en"]
	}

	// Handle empty values
	if result.Country == "" {
		result.Country = "Unknown"
	}
	if result.City == "" {
		result.City = "Unknown"
	}
	if result.CountryCode == "" {
		result.CountryCode = "??"
	}

	jsonOut, _ := json.MarshalIndent(result, "", "  ")
	fmt.Println(string(jsonOut))
}

func bulkLookup() {
	scanner := bufio.NewScanner(os.Stdin)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		ipStr := scanner.Text()

		if ipStr == "" {
			continue
		}

		start := time.Now()
		ip := net.ParseIP(ipStr)

		if ip == nil {
			fmt.Fprintf(os.Stderr, `{"line":%d,"error":"Invalid IP: %s"}`+"\n", lineNum, ipStr)
			continue
		}

		var record MaxMindRecord
		err := db.Lookup(ip, &record)

		if err != nil {
			fmt.Fprintf(os.Stderr, `{"line":%d,"ip":"%s","error":"Lookup failed"}`+"\n", lineNum, ipStr)
			continue
		}

		elapsed := time.Since(start).Microseconds()

		result := GeoIPResult{
			IP:           ipStr,
			Country:      record.Country.Names["en"],
			CountryCode:  record.Country.IsoCode,
			City:         record.City.Names["en"],
			Latitude:     record.Location.Latitude,
			Longitude:    record.Location.Longitude,
			LookupTimeUs: elapsed,
			Cached:       false,
		}

		if len(record.Subdivisions) > 0 {
			result.Region = record.Subdivisions[0].Names["en"]
		}

		// Output as JSONL (one JSON per line)
		jsonOut, _ := json.Marshal(result)
		fmt.Println(string(jsonOut))
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":"Reading input: %v"}`+"\n", err)
		os.Exit(1)
	}
}

func status() {
	metadata := db.Metadata

	statusInfo := map[string]interface{}{
		"status":       "ok",
		"database":     "loaded",
		"path":         MMDB_PATH,
		"version":      VERSION,
		"db_type":      metadata.DatabaseType,
		"db_build":     time.Unix(int64(metadata.BuildEpoch), 0).Format(time.RFC3339),
		"record_count": metadata.NodeCount,
	}

	jsonOut, _ := json.MarshalIndent(statusInfo, "", "  ")
	fmt.Println(string(jsonOut))
}

func runTests() {
	testIPs := []string{
		"8.8.8.8",           // Google DNS - US
		"1.1.1.1",           // Cloudflare - US
		"94.130.0.1",        // Hetzner - Germany
		"185.125.190.56",    // Greece
		"203.0.113.1",       // TEST-NET-3 (should fail gracefully)
		"2001:4860:4860::8888", // Google IPv6
	}

	fmt.Println("Running GeoIP tests...")
	fmt.Println("======================\n")

	successCount := 0
	totalTime := int64(0)

	for _, ip := range testIPs {
		start := time.Now()
		parsedIP := net.ParseIP(ip)

		if parsedIP == nil {
			fmt.Printf("❌ FAIL: %s (invalid IP)\n", ip)
			continue
		}

		var record MaxMindRecord
		err := db.Lookup(parsedIP, &record)

		elapsed := time.Since(start).Microseconds()
		totalTime += elapsed

		if err != nil {
			fmt.Printf("❌ FAIL: %s (lookup error: %v)\n", ip, err)
			continue
		}

		country := record.Country.Names["en"]
		if country == "" {
			country = "Unknown"
		}

		city := record.City.Names["en"]
		if city == "" {
			city = "Unknown"
		}

		fmt.Printf("✅ OK: %s → %s/%s (%d μs)\n", ip, record.Country.IsoCode, city, elapsed)
		successCount++
	}

	avgTime := totalTime / int64(len(testIPs))

	fmt.Printf("\n======================\n")
	fmt.Printf("Tests passed: %d/%d\n", successCount, len(testIPs))
	fmt.Printf("Average lookup time: %d μs (%.2f ms)\n", avgTime, float64(avgTime)/1000.0)

	if successCount == len(testIPs) {
		fmt.Println("✅ All tests PASSED!")
		os.Exit(0)
	} else {
		fmt.Println("⚠️  Some tests FAILED")
		os.Exit(1)
	}
}

func usage() {
	fmt.Println("nftban-geoip - Fast modular GeoIP lookup (MaxMind)")
	fmt.Println("nftban — Simplifying Linux Firewall Management")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  nftban-geoip lookup <IP>     Lookup single IP address")
	fmt.Println("  nftban-geoip bulk            Bulk lookup from stdin (JSONL output)")
	fmt.Println("  nftban-geoip status          Show database status")
	fmt.Println("  nftban-geoip test            Run built-in tests")
	fmt.Println("  nftban-geoip version         Show version")
	fmt.Println("  nftban-geoip help            Show this help")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  nftban-geoip lookup 8.8.8.8")
	fmt.Println("  echo '8.8.8.8' | nftban-geoip bulk")
	fmt.Println("  cat ips.txt | nftban-geoip bulk")
	fmt.Println()
	fmt.Println("Output: JSON format")
	fmt.Println("Database: " + MMDB_PATH)
}
