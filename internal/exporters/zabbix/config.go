// =============================================================================
// NFTBan v1.0 - Zabbix Exporter Configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="config"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Configuration for Zabbix trapper exporter"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package zabbix

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
)

// =============================================================================
// Configuration
// =============================================================================

// Config holds the Zabbix exporter configuration
type Config struct {
	// Enable/disable the exporter
	Enabled bool `yaml:"enabled" json:"enabled"`

	// Targets defines Zabbix server targets
	// Multiple targets supported for redundancy
	Targets []TargetConfig `yaml:"targets" json:"targets"`

	// Hostname as registered in Zabbix (if empty, uses os.Hostname)
	Hostname string `yaml:"hostname" json:"hostname"`

	// Collection interval
	Interval time.Duration `yaml:"interval" json:"interval"`

	// Batch settings
	BatchSize    int           `yaml:"batch_size" json:"batch_size"`
	BatchTimeout time.Duration `yaml:"batch_timeout" json:"batch_timeout"`

	// Connection settings
	ConnectTimeout time.Duration `yaml:"connect_timeout" json:"connect_timeout"`
	SendTimeout    time.Duration `yaml:"send_timeout" json:"send_timeout"`

	// Retry settings
	RetryCount    int           `yaml:"retry_count" json:"retry_count"`
	RetryInterval time.Duration `yaml:"retry_interval" json:"retry_interval"`

	// Buffer settings (for offline buffering)
	BufferEnabled bool   `yaml:"buffer_enabled" json:"buffer_enabled"`
	BufferPath    string `yaml:"buffer_path" json:"buffer_path"`
	BufferMaxSize int64  `yaml:"buffer_max_size" json:"buffer_max_size"` // bytes

	// Metrics filtering
	MetricsInclude []string `yaml:"metrics_include" json:"metrics_include"` // glob patterns
	MetricsExclude []string `yaml:"metrics_exclude" json:"metrics_exclude"` // glob patterns

	// Discovery settings
	DiscoveryEnabled  bool          `yaml:"discovery_enabled" json:"discovery_enabled"`
	DiscoveryInterval time.Duration `yaml:"discovery_interval" json:"discovery_interval"`

	// Logging
	LogLevel string `yaml:"log_level" json:"log_level"` // debug, info, warn, error
}

// TargetConfig defines a single Zabbix server target
type TargetConfig struct {
	// Name for identification
	Name string `yaml:"name" json:"name"`

	// Server address (hostname or IP)
	Address string `yaml:"address" json:"address"`

	// Server port (default: 10051)
	Port int `yaml:"port" json:"port"`

	// Override hostname for this target (optional)
	Hostname string `yaml:"hostname,omitempty" json:"hostname,omitempty"`

	// TLS configuration
	TLS TLSTargetConfig `yaml:"tls" json:"tls"`

	// Enable/disable this target
	Enabled bool `yaml:"enabled" json:"enabled"`

	// Priority (lower = higher priority, used for failover)
	Priority int `yaml:"priority" json:"priority"`
}

// TLSTargetConfig holds TLS settings for a target
type TLSTargetConfig struct {
	Enabled    bool   `yaml:"enabled" json:"enabled"`
	CertFile   string `yaml:"cert_file,omitempty" json:"cert_file,omitempty"`
	KeyFile    string `yaml:"key_file,omitempty" json:"key_file,omitempty"`
	CAFile     string `yaml:"ca_file,omitempty" json:"ca_file,omitempty"`
	SkipVerify bool   `yaml:"skip_verify" json:"skip_verify"`
	ServerName string `yaml:"server_name,omitempty" json:"server_name,omitempty"`
	DevMode    bool   `yaml:"dev_mode" json:"dev_mode"` // Development mode - allows SkipVerify
}

// =============================================================================
// Default Configuration
// =============================================================================

// DefaultConfig returns configuration with safe defaults
func DefaultConfig() *Config {
	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "localhost"
	}

	return &Config{
		Enabled:  false, // disabled by default, must be explicitly enabled
		Hostname: hostname,

		Targets: []TargetConfig{}, // no targets by default

		Interval:     constants.ZabbixCollectInterval,
		BatchSize:    100,
		BatchTimeout: constants.ZabbixBatchTimeout,

		ConnectTimeout: constants.ZabbixConnectTimeout,
		SendTimeout:    constants.ZabbixSendTimeout,

		RetryCount:    3,
		RetryInterval: constants.ZabbixRetryInterval,

		BufferEnabled: true,
		BufferPath:    "/var/lib/nftban/zabbix/buffer",
		BufferMaxSize: 100 * 1024 * 1024, // 100MB

		MetricsInclude: []string{"*"}, // include all by default
		MetricsExclude: []string{},

		DiscoveryEnabled:  true,
		DiscoveryInterval: constants.ZabbixDiscoveryInterval,

		LogLevel: "info",
	}
}

// DefaultTargetConfig returns default settings for a target
func DefaultTargetConfig(name, address string) TargetConfig {
	return TargetConfig{
		Name:     name,
		Address:  address,
		Port:     DefaultPort,
		Enabled:  true,
		Priority: 1,
		TLS: TLSTargetConfig{
			Enabled:    false,
			SkipVerify: false,
		},
	}
}

// =============================================================================
// Validation
// =============================================================================

// Validate checks the configuration and returns errors
func (c *Config) Validate() error {
	var errs []string

	// If not enabled, skip most validation
	if !c.Enabled {
		return nil
	}

	// Must have at least one target
	if len(c.Targets) == 0 {
		errs = append(errs, "at least one target is required when enabled")
	}

	// Validate hostname
	if c.Hostname == "" {
		errs = append(errs, "hostname is required")
	}

	// Validate intervals
	if c.Interval < 10*time.Second {
		errs = append(errs, "interval must be at least 10 seconds")
	}
	if c.Interval > 3600*time.Second {
		errs = append(errs, "interval must not exceed 1 hour")
	}

	// Validate batch settings
	if c.BatchSize < 1 {
		errs = append(errs, "batch_size must be at least 1")
	}
	if c.BatchSize > 10000 {
		errs = append(errs, "batch_size must not exceed 10000")
	}

	// Validate timeouts
	if c.ConnectTimeout < time.Second {
		errs = append(errs, "connect_timeout must be at least 1 second")
	}
	if c.SendTimeout < time.Second {
		errs = append(errs, "send_timeout must be at least 1 second")
	}

	// Validate retry settings
	if c.RetryCount < 0 {
		errs = append(errs, "retry_count must be non-negative")
	}
	if c.RetryCount > 10 {
		errs = append(errs, "retry_count must not exceed 10")
	}

	// Validate buffer settings
	if c.BufferEnabled {
		if c.BufferPath == "" {
			errs = append(errs, "buffer_path is required when buffer is enabled")
		}
		if c.BufferMaxSize < 1024*1024 {
			errs = append(errs, "buffer_max_size must be at least 1MB")
		}
	}

	// Validate each target
	for i, target := range c.Targets {
		if err := target.Validate(); err != nil {
			errs = append(errs, fmt.Sprintf("target[%d] (%s): %v", i, target.Name, err))
		}
	}

	// Validate log level
	switch c.LogLevel {
	case "debug", "info", "warn", "error":
		// valid
	default:
		errs = append(errs, fmt.Sprintf("invalid log_level: %s (must be debug, info, warn, or error)", c.LogLevel))
	}

	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}

	return nil
}

// Validate checks target configuration
func (t *TargetConfig) Validate() error {
	var errs []string

	if t.Name == "" {
		errs = append(errs, "name is required")
	}

	if t.Address == "" {
		errs = append(errs, "address is required")
	} else {
		// Validate address is a valid hostname or IP
		if ip := net.ParseIP(t.Address); ip == nil {
			// Not an IP, check if it's a valid hostname
			if !isValidHostname(t.Address) {
				errs = append(errs, fmt.Sprintf("invalid address: %s", t.Address))
			}
		}
	}

	if t.Port < 1 || t.Port > 65535 {
		errs = append(errs, fmt.Sprintf("invalid port: %d", t.Port))
	}

	// Validate TLS settings
	if t.TLS.Enabled {
		if t.TLS.CertFile != "" {
			if _, err := os.Stat(t.TLS.CertFile); err != nil {
				errs = append(errs, fmt.Sprintf("cert_file not found: %s", t.TLS.CertFile))
			}
		}
		if t.TLS.KeyFile != "" {
			if _, err := os.Stat(t.TLS.KeyFile); err != nil {
				errs = append(errs, fmt.Sprintf("key_file not found: %s", t.TLS.KeyFile))
			}
		}
		if t.TLS.CAFile != "" {
			if _, err := os.Stat(t.TLS.CAFile); err != nil {
				errs = append(errs, fmt.Sprintf("ca_file not found: %s", t.TLS.CAFile))
			}
		}
	}

	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}

	return nil
}

// =============================================================================
// Configuration Helpers
// =============================================================================

// ToTarget converts TargetConfig to Target
func (t *TargetConfig) ToTarget() *Target {
	var tlsConfig *TLSConfig
	if t.TLS.Enabled {
		tlsConfig = &TLSConfig{
			Enabled:    true,
			CertFile:   t.TLS.CertFile,
			KeyFile:    t.TLS.KeyFile,
			CAFile:     t.TLS.CAFile,
			SkipVerify: t.TLS.SkipVerify,
			DevMode:    t.TLS.DevMode,
		}
	}

	return &Target{
		Name:     t.Name,
		Address:  t.Address,
		Port:     t.Port,
		Hostname: t.Hostname,
		TLS:      tlsConfig,
		Timeout:  DefaultTimeout,
		Enabled:  t.Enabled,
	}
}

// GetEnabledTargets returns only enabled targets sorted by priority
func (c *Config) GetEnabledTargets() []TargetConfig {
	var enabled []TargetConfig
	for _, t := range c.Targets {
		if t.Enabled {
			enabled = append(enabled, t)
		}
	}

	// Sort by priority (lower = higher priority)
	for i := 0; i < len(enabled)-1; i++ {
		for j := i + 1; j < len(enabled); j++ {
			if enabled[j].Priority < enabled[i].Priority {
				enabled[i], enabled[j] = enabled[j], enabled[i]
			}
		}
	}

	return enabled
}

// ApplyDefaults fills in missing values with defaults
func (c *Config) ApplyDefaults() {
	defaults := DefaultConfig()

	if c.Hostname == "" {
		c.Hostname = defaults.Hostname
	}
	if c.Interval == 0 {
		c.Interval = defaults.Interval
	}
	if c.BatchSize == 0 {
		c.BatchSize = defaults.BatchSize
	}
	if c.BatchTimeout == 0 {
		c.BatchTimeout = defaults.BatchTimeout
	}
	if c.ConnectTimeout == 0 {
		c.ConnectTimeout = defaults.ConnectTimeout
	}
	if c.SendTimeout == 0 {
		c.SendTimeout = defaults.SendTimeout
	}
	if c.RetryInterval == 0 {
		c.RetryInterval = defaults.RetryInterval
	}
	if c.BufferPath == "" {
		c.BufferPath = defaults.BufferPath
	}
	if c.BufferMaxSize == 0 {
		c.BufferMaxSize = defaults.BufferMaxSize
	}
	if len(c.MetricsInclude) == 0 {
		c.MetricsInclude = defaults.MetricsInclude
	}
	if c.DiscoveryInterval == 0 {
		c.DiscoveryInterval = defaults.DiscoveryInterval
	}
	if c.LogLevel == "" {
		c.LogLevel = defaults.LogLevel
	}

	// Apply defaults to targets
	for i := range c.Targets {
		if c.Targets[i].Port == 0 {
			c.Targets[i].Port = DefaultPort
		}
		if c.Targets[i].Priority == 0 {
			c.Targets[i].Priority = i + 1
		}
	}
}

// =============================================================================
// Helper Functions
// =============================================================================

// isValidHostname checks if a string is a valid hostname
func isValidHostname(hostname string) bool {
	if len(hostname) == 0 || len(hostname) > 253 {
		return false
	}

	parts := strings.Split(hostname, ".")
	for _, part := range parts {
		if len(part) == 0 || len(part) > 63 {
			return false
		}
		// First and last character must be alphanumeric
		if !isAlphanumeric(part[0]) || !isAlphanumeric(part[len(part)-1]) {
			return false
		}
		// Middle characters can be alphanumeric or hyphen
		for i := 1; i < len(part)-1; i++ {
			if !isAlphanumeric(part[i]) && part[i] != '-' {
				return false
			}
		}
	}

	return true
}

func isAlphanumeric(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// =============================================================================
// YAML Configuration Example
// =============================================================================

/*
Example YAML configuration:

zabbix:
  enabled: true
  hostname: "web1.example.com"
  interval: 60s
  batch_size: 100
  batch_timeout: 5s
  connect_timeout: 10s
  send_timeout: 30s
  retry_count: 3
  retry_interval: 5s
  buffer_enabled: true
  buffer_path: "/var/lib/nftban/zabbix/buffer"
  buffer_max_size: 104857600  # 100MB
  discovery_enabled: true
  discovery_interval: 3600s
  log_level: "info"

  targets:
    - name: "primary"
      address: "zabbix.example.com"
      port: 10051
      enabled: true
      priority: 1
      tls:
        enabled: false

    - name: "secondary"
      address: "zabbix-dr.example.com"
      port: 10051
      enabled: true
      priority: 2
      tls:
        enabled: true
        cert_file: "/etc/nftban/certs/zabbix.crt"
        key_file: "/etc/nftban/certs/zabbix.key"
        ca_file: "/etc/nftban/certs/ca.crt"
        skip_verify: false

  metrics_include:
    - "nftban.*"
  metrics_exclude:
    - "nftban.debug.*"
*/
