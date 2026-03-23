// =============================================================================
// NFTBan - Internal Application Config
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="config"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Application configuration for nftban-ui server"
// meta:input="Configuration file"
// meta:output="Server configuration"
// meta:depends="github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package config

import (
	"bufio"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// SECURITY FIX: Minimum required length for JWT secret
const minJWTSecretLength = 32

// ErrJWTSecretNotConfigured is returned when JWT_SECRET is not set or too short
var ErrJWTSecretNotConfigured = errors.New("JWT_SECRET environment variable must be set with at least 32 bytes")

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
		RequiredGroup:    "nftban", // Web GUI admin users must be in nftban group
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

// generateJWTSecret returns empty string - JWT secret MUST be configured externally
// SECURITY FIX: Removed hardcoded placeholder to enforce proper secret management
func generateJWTSecret() string {
	// SECURITY: Return empty string to force configuration via JWT_SECRET env var
	// or JWT_SECRET_FILE in config. Do NOT use hardcoded defaults.
	return ""
}

// GenerateRandomSecret creates a cryptographically secure random secret
// This can be used by administrators to generate a secure JWT_SECRET value
func GenerateRandomSecret(length int) (string, error) {
	if length < minJWTSecretLength {
		length = minJWTSecretLength
	}
	bytes := make([]byte, length)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("failed to generate random secret: %w", err)
	}
	return base64.StdEncoding.EncodeToString(bytes), nil
}

// ValidateJWTSecret checks if the JWT secret meets security requirements
// SECURITY FIX: Validates that JWT secret is configured and meets minimum length
func ValidateJWTSecret(secret string) error {
	if secret == "" {
		return ErrJWTSecretNotConfigured
	}
	if len(secret) < minJWTSecretLength {
		return fmt.Errorf("JWT_SECRET must be at least %d bytes, got %d", minJWTSecretLength, len(secret))
	}
	// SECURITY: Reject known placeholder values
	knownPlaceholders := []string{
		"CHANGE_ME_IN_PRODUCTION_CONFIG",
		"changeme",
		"secret",
		"password",
		"jwt_secret",
	}
	secretLower := strings.ToLower(secret)
	for _, placeholder := range knownPlaceholders {
		if secretLower == strings.ToLower(placeholder) {
			return fmt.Errorf("JWT_SECRET contains insecure placeholder value")
		}
	}
	return nil
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
