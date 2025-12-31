package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// Config holds the application configuration
type Config struct {
	Port              int
	TLSCert           string
	TLSKey            string
	JWTSecret         string
	SessionTimeout    int    // minutes
	IPWhitelistFile   string
	AuditLogFile      string
	RequiredGroup     string
	BlockRootLogin    bool
	MaxLoginAttempts  int
	LockoutDuration   int // minutes
}

// getDefaultPaths returns default paths from central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getDefaultPaths() (configDir, logDir string) {
	globalCfg := nftbanconf.MustLoad()
	return globalCfg.ConfigDir, globalCfg.LogDir
}

// Load reads configuration from file
func Load(path string) (*Config, error) {
	// Get paths from central config
	configDir, logDir := getDefaultPaths()

	// Default configuration - use central config paths
	cfg := &Config{
		Port:             3940,
		TLSCert:          configDir + "/ssl/cert.pem",
		TLSKey:           configDir + "/ssl/key.pem",
		JWTSecret:        generateJWTSecret(),
		SessionTimeout:   60,
		IPWhitelistFile:  configDir + "/whitelist.d/ui-access.conf",
		AuditLogFile:     logDir + "/ui-access.log",
		RequiredGroup:    "nftban-cli", // Web GUI users must be in nftban-cli group
		BlockRootLogin:   true,
		MaxLoginAttempts: 5,
		LockoutDuration:  15,
	}

	// Try to load from file
	file, err := os.Open(path)
	if err != nil {
		// If file doesn't exist, use defaults
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return nil, fmt.Errorf("failed to open config file: %w", err)
	}
	defer file.Close()

	// Parse configuration file
	scanner := bufio.NewScanner(file)
	lineNum := 0
	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())

		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse key=value (supports both KEY=value and key = "value" formats)
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		// Remove surrounding quotes (single or double)
		value = strings.Trim(value, "\"'")

		// Normalize key to uppercase for case-insensitive matching
		keyUpper := strings.ToUpper(key)

		// Set configuration values (case-insensitive key matching)
		switch keyUpper {
		case "PORT":
			if port, err := strconv.Atoi(value); err == nil {
				cfg.Port = port
			}
		case "TLS_CERT", "CERT":
			cfg.TLSCert = value
		case "TLS_KEY", "KEY":
			cfg.TLSKey = value
		case "JWT_SECRET":
			if value != "" {
				cfg.JWTSecret = value
			}
		case "JWT_SECRET_FILE":
			// Load JWT secret from file (preferred for security)
			if value != "" {
				secretData, err := os.ReadFile(value)
				if err == nil {
					// Trim whitespace/newlines from secret
					cfg.JWTSecret = strings.TrimSpace(string(secretData))
				}
			}
		case "SESSION_TIMEOUT":
			if timeout, err := strconv.Atoi(value); err == nil {
				cfg.SessionTimeout = timeout
			}
		case "IP_WHITELIST_FILE", "IP_WHITELIST":
			cfg.IPWhitelistFile = value
		case "AUDIT_LOG_FILE", "LOG_FILE":
			cfg.AuditLogFile = value
		case "REQUIRED_GROUP":
			cfg.RequiredGroup = value
		case "BLOCK_ROOT_LOGIN":
			cfg.BlockRootLogin = (value == "true" || value == "yes" || value == "1")
		case "MAX_LOGIN_ATTEMPTS", "RATE_LIMIT_REQUESTS":
			if attempts, err := strconv.Atoi(value); err == nil {
				cfg.MaxLoginAttempts = attempts
			}
		case "LOCKOUT_DURATION", "RATE_LIMIT_WINDOW":
			if duration, err := strconv.Atoi(value); err == nil {
				cfg.LockoutDuration = duration
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading config file: %w", err)
	}

	return cfg, nil
}

// generateJWTSecret creates a random JWT secret if none is provided
func generateJWTSecret() string {
	// In production, this should be read from a secure source
	// For now, generate a random string
	// This will be replaced with proper secret management
	return "CHANGE_ME_IN_PRODUCTION_CONFIG"
}

// Save writes configuration to file
func (c *Config) Save(path string) error {
	file, err := os.Create(path)
	if err != nil {
		return fmt.Errorf("failed to create config file: %w", err)
	}
	defer file.Close()

	// Write configuration
	fmt.Fprintf(file, "# NFTBan Web GUI Configuration\n")
	fmt.Fprintf(file, "# Generated: %s\n\n", "2025-11-10")

	fmt.Fprintf(file, "PORT=%d\n", c.Port)
	fmt.Fprintf(file, "TLS_CERT=%s\n", c.TLSCert)
	fmt.Fprintf(file, "TLS_KEY=%s\n", c.TLSKey)
	fmt.Fprintf(file, "JWT_SECRET=%s\n", c.JWTSecret)
	fmt.Fprintf(file, "SESSION_TIMEOUT=%d\n", c.SessionTimeout)
	fmt.Fprintf(file, "IP_WHITELIST_FILE=%s\n", c.IPWhitelistFile)
	fmt.Fprintf(file, "AUDIT_LOG_FILE=%s\n", c.AuditLogFile)
	fmt.Fprintf(file, "REQUIRED_GROUP=%s\n", c.RequiredGroup)
	fmt.Fprintf(file, "BLOCK_ROOT_LOGIN=%t\n", c.BlockRootLogin)
	fmt.Fprintf(file, "MAX_LOGIN_ATTEMPTS=%d\n", c.MaxLoginAttempts)
	fmt.Fprintf(file, "LOCKOUT_DURATION=%d\n", c.LockoutDuration)

	return nil
}
