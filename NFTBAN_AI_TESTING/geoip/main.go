// NFTBan v0.30 - GeoIP Lookup (Go Binary)
// SPDX-License-Identifier: MPL-2.0
// Smart, fast, standalone GeoIP lookups

package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
)

const Version = "1.0.0"

type LookupResult struct {
	IP          string  `json:"ip"`
	Country     string  `json:"country"`
	CountryCode string  `json:"country_code"`
	City        string  `json:"city,omitempty"`
	Latitude    float64 `json:"latitude,omitempty"`
	Longitude   float64 `json:"longitude,omitempty"`
	Error       string  `json:"error,omitempty"`
	Method      string  `json:"method"` // "maxmind" or "builtin"
}

func main() {
	dbPath := flag.String("db", "/var/lib/nftban/geoip/GeoLite2-City.mmdb", "Path to GeoIP2 database")
	lookupIP := flag.String("lookup", "", "IP address to lookup")
	showVersion := flag.Bool("version", false, "Show version")
	jsonOutput := flag.Bool("json", true, "Output JSON format")

	flag.Parse()

	if *showVersion {
		fmt.Printf("nftban-geoip v%s\n", Version)
		os.Exit(0)
	}

	if *lookupIP == "" {
		fmt.Fprintln(os.Stderr, "Error: --lookup IP required")
		flag.Usage()
		os.Exit(1)
	}

	// Validate IP
	ip := net.ParseIP(*lookupIP)
	if ip == nil {
		result := LookupResult{
			IP:     *lookupIP,
			Error:  "Invalid IP address",
			Method: "none",
		}
		outputResult(result, *jsonOutput)
		os.Exit(1)
	}

	// Try MaxMind database first
	result, err := lookupMaxMind(*dbPath, *lookupIP)
	if err == nil {
		result.Method = "maxmind"
		outputResult(result, *jsonOutput)
		os.Exit(0)
	}

	// Fallback to built-in ranges (basic continent-level)
	result = lookupBuiltin(*lookupIP)
	result.Method = "builtin"
	outputResult(result, *jsonOutput)
	os.Exit(0)
}

func lookupMaxMind(dbPath, ipStr string) (LookupResult, error) {
	// Try to use MaxMind database
	// This requires: github.com/oschwald/geoip2-golang
	// If not available, will fail and fallback to builtin

	// Note: Import commented out to allow compilation without MaxMind library
	// Uncomment and add to imports if MaxMind library is available:
	// import "github.com/oschwald/geoip2-golang"

	/*
	db, err := geoip2.Open(dbPath)
	if err != nil {
		return LookupResult{}, err
	}
	defer db.Close()

	ip := net.ParseIP(ipStr)
	record, err := db.City(ip)
	if err != nil {
		return LookupResult{}, err
	}

	return LookupResult{
		IP:          ipStr,
		Country:     record.Country.Names["en"],
		CountryCode: record.Country.IsoCode,
		City:        record.City.Names["en"],
		Latitude:    record.Location.Latitude,
		Longitude:   record.Location.Longitude,
	}, nil
	*/

	return LookupResult{}, fmt.Errorf("MaxMind library not compiled")
}

func lookupBuiltin(ipStr string) LookupResult {
	// Built-in IP range detection (basic, fast, no dependencies)
	ip := net.ParseIP(ipStr)

	// Private IP ranges
	if isPrivateIP(ip) {
		return LookupResult{
			IP:          ipStr,
			Country:     "Private Network",
			CountryCode: "PRIVATE",
		}
	}

	// Loopback
	if ip.IsLoopback() {
		return LookupResult{
			IP:          ipStr,
			Country:     "Localhost",
			CountryCode: "LOCAL",
		}
	}

	// Basic continent-level detection by known ranges
	// This is VERY basic, but works without any database
	country, code := detectByRange(ip)

	return LookupResult{
		IP:          ipStr,
		Country:     country,
		CountryCode: code,
	}
}

func isPrivateIP(ip net.IP) bool {
	// RFC1918 private ranges
	private := []string{
		"10.0.0.0/8",
		"172.16.0.0/12",
		"192.168.0.0/16",
	}

	for _, cidr := range private {
		_, subnet, _ := net.ParseCIDR(cidr)
		if subnet.Contains(ip) {
			return true
		}
	}
	return false
}

func detectByRange(ip net.IP) (string, string) {
	// Very basic range detection (major providers/regions)
	// This is NOT accurate, just provides basic fallback

	ipv4 := ip.To4()
	if ipv4 == nil {
		return "Unknown (IPv6)", "XX"
	}

	first := ipv4[0]

	// Known major ranges (VERY simplified)
	switch {
	case first >= 1 && first <= 2:
		return "APNIC Region", "AP"
	case first >= 5 && first <= 50:
		return "ARIN Region (North America)", "US"
	case first >= 51 && first <= 100:
		return "RIPE Region (Europe)", "EU"
	case first >= 101 && first <= 150:
		return "APNIC Region (Asia)", "AS"
	case first >= 151 && first <= 200:
		return "LACNIC Region (Latin America)", "LA"
	case first >= 201 && first <= 223:
		return "APNIC Region", "AP"
	default:
		return "Unknown", "XX"
	}
}

func outputResult(result LookupResult, asJSON bool) {
	if asJSON {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		enc.Encode(result)
	} else {
		fmt.Printf("IP: %s\n", result.IP)
		if result.Error != "" {
			fmt.Printf("Error: %s\n", result.Error)
		} else {
			fmt.Printf("Country: %s (%s)\n", result.Country, result.CountryCode)
			if result.City != "" {
				fmt.Printf("City: %s\n", result.City)
			}
			if result.Latitude != 0 || result.Longitude != 0 {
				fmt.Printf("Location: %.4f, %.4f\n", result.Latitude, result.Longitude)
			}
			fmt.Printf("Method: %s\n", result.Method)
		}
	}
}
