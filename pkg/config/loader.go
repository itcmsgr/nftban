// =============================================================================
// NFTBan - Configuration Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Loads FHS spec, distro config, and service configuration"
// meta:input="Configuration files"
// meta:output="Parsed configuration structures"
// meta:depends="github.com/itcmsgr/nftban/pkg/nftbanconf"
// meta:inventory.files="/etc/nftban/distros/*.conf"
// meta:inventory.binaries="bash"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/services.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package config

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// FHSDirectory represents an FHS directory specification
type FHSDirectory struct {
	Path    string
	Perms   string
	Owner   string
	Group   string
	Purpose string
}

// DistroConfig represents distribution-specific configuration
type DistroConfig struct {
	Name     string
	Family   string
	Version  string
	Services map[string]string
	Packages map[string]string
	Paths    map[string]string
}

// LoadFHSSpec reads the bash FHS specification file
// Returns: map[path]FHSDirectory
func LoadFHSSpec() (map[string]FHSDirectory, error) {
	fhsMap := make(map[string]FHSDirectory)

	// Get lib dir from central config
	// NO FALLBACK - path must come from /etc/nftban/nftban.conf
	cfg := nftbanconf.MustLoad()
	libDir := cfg.LibDir

	// Execute bash to source FHS spec and output data
	cmd := exec.Command("bash", "-c", fmt.Sprintf(`
		source %s/core/nftban_fhs_spec.sh 2>/dev/null
		for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
			echo "$path|${NFTBAN_FHS_DIRECTORIES[$path]}"
		done
	`, libDir))

	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("failed to load FHS spec: %w", err)
	}

	// Parse output: path|perms|owner|group|purpose
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		parts := strings.Split(line, "|")
		if len(parts) != 5 {
			continue
		}

		fhsMap[parts[0]] = FHSDirectory{
			Path:    parts[0],
			Perms:   parts[1],
			Owner:   parts[2],
			Group:   parts[3],
			Purpose: parts[4],
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error parsing FHS spec: %w", err)
	}

	return fhsMap, nil
}

// LoadDistroConfig reads distribution-specific configuration
// Detects current distro and loads appropriate config file
func LoadDistroConfig() (*DistroConfig, error) {
	// Detect distro
	distro, err := detectDistro()
	if err != nil {
		return nil, fmt.Errorf("failed to detect distro: %w", err)
	}

	// Get config dir from central config
	// NO FALLBACK - path must come from /etc/nftban/nftban.conf
	distroCfg := nftbanconf.MustLoad()
	configDir := distroCfg.ConfigDir

	// Try to load distro-specific config
	configFile := fmt.Sprintf("%s/distros/%s.conf", configDir, distro)
	if _, err := os.Stat(configFile); os.IsNotExist(err) {
		// Fallback to generic detection
		return &DistroConfig{
			Name:     distro,
			Services: make(map[string]string),
			Packages: make(map[string]string),
			Paths:    make(map[string]string),
		}, nil
	}

	// Parse INI-style config file
	cfg, err := parseDistroConfig(configFile)
	if err != nil {
		return nil, fmt.Errorf("failed to parse distro config: %w", err)
	}

	return cfg, nil
}

// detectDistro detects the current Linux distribution
func detectDistro() (string, error) {
	// Read /etc/os-release (systemd standard)
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return "", fmt.Errorf("cannot read /etc/os-release: %w", err)
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "ID=") {
			distro := strings.TrimPrefix(line, "ID=")
			distro = strings.Trim(distro, `"'`)
			return normalizeDistroID(distro), nil
		}
	}

	return "unknown", fmt.Errorf("cannot determine distro from /etc/os-release")
}

// normalizeDistroID normalizes distribution IDs
func normalizeDistroID(id string) string {
	switch id {
	case "centos", "centos-stream":
		return "centos"
	case "rhel", "redhat":
		return "rhel"
	case "rocky":
		return "rocky"
	case "almalinux", "alma":
		return "almalinux"
	case "debian":
		return "debian"
	case "ubuntu":
		return "ubuntu"
	case "fedora":
		return "fedora"
	default:
		return id
	}
}

// parseDistroConfig parses INI-style distro configuration file
func parseDistroConfig(filename string) (*DistroConfig, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	cfg := &DistroConfig{
		Services: make(map[string]string),
		Packages: make(map[string]string),
		Paths:    make(map[string]string),
	}

	var currentSection string
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Section headers: [section]
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			currentSection = strings.Trim(line, "[]")
			continue
		}

		// Key-value pairs: key = value
		if strings.Contains(line, "=") {
			parts := strings.SplitN(line, "=", 2)
			if len(parts) != 2 {
				continue
			}

			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			value = strings.Trim(value, `"'`)

			switch currentSection {
			case "distro":
				switch key {
				case "name":
					cfg.Name = value
				case "family":
					cfg.Family = value
				case "version":
					cfg.Version = value
				}
			case "services":
				cfg.Services[key] = value
			case "packages":
				cfg.Packages[key] = value
			case "paths":
				cfg.Paths[key] = value
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// LoadServicesConfig reads service enable/disable configuration.
// Override chain: conf.d/services.conf → conf.d/services.conf.local → nftban.conf.local
// Each layer is partial — only values present in the file override previous layers.
func LoadServicesConfig() (map[string]bool, error) {
	// Defaults (all enabled)
	services := map[string]bool{
		"nftban":        true,
		"nftables":      true,
		// Removed: "fail2ban" (v1.0 migration to Suricata)
		"login_monitor": true,
	}

	// Get config dir from central config
	// NO FALLBACK - path must come from /etc/nftban/nftban.conf
	svcCfg := nftbanconf.MustLoad()
	configDir := svcCfg.ConfigDir

	// Override chain: .conf → .conf.local → nftban.conf.local
	configFiles := []string{
		configDir + "/conf.d/services.conf",
		configDir + "/conf.d/services.conf.local",
		configDir + "/nftban.conf.local",
	}

	for _, file := range configFiles {
		data, err := os.ReadFile(file)
		if err != nil {
			continue
		}

		lines := strings.Split(string(data), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}

			// Parse KEY="value" format
			if strings.Contains(line, "=") {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}

				key := strings.TrimSpace(parts[0])
				value := strings.TrimSpace(parts[1])
				value = strings.Trim(value, `"'`)

				// Convert to boolean
				enabled := strings.ToLower(value) == "true"

				// Map to service names
				switch key {
				case "NFTBAN_ENABLED":
					services["nftban"] = enabled
				case "NFTABLES_ENABLED":
					services["nftables"] = enabled
				case "FAIL2BAN_ENABLED":
					// Removed: fail2ban enabled setting (v1.0 migration to Suricata)
				case "LOGIN_MONITOR_ENABLED":
					services["login_monitor"] = enabled
				}
			}
		}
	}

	return services, nil
}

// GetFHSPath returns the FHS path for a given name
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func GetFHSPath(name string) string {
	// Get paths from central config
	cfg := nftbanconf.MustLoad()

	// All paths from central config
	configDir := cfg.ConfigDir
	dataDir := cfg.DataDir
	logDir := cfg.LogDir
	cacheDir := cfg.CacheDir
	runDir := cfg.RunDir
	shareDir := "/usr/share/nftban" // Note: ShareDir has no NFTBAN_SHARE in config
	libDir := cfg.LibDir

	paths := map[string]string{
		"config":    configDir,
		"lib":       dataDir,
		"log":       logDir,
		"cache":     cacheDir,
		"run":       runDir,
		"share":     shareDir,
		"bin":       libDir + "/bin",
		"core":      libDir + "/core",
		"cli":       libDir + "/cli",
		"sbin":      "/usr/sbin",
		"geoip":     dataDir + "/geoip",
		"geoban":    dataDir + "/geoban",
		"feeds":     dataDir + "/feeds",
		"metrics":   dataDir + "/metrics",
		"snapshots": dataDir + "/snapshots",
		"reports":   dataDir + "/reports",
	}

	if path, ok := paths[name]; ok {
		return path
	}

	return ""
}
