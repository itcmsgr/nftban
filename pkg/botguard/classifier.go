// =============================================================================
// NFTBan v1.21.0 - HTTP Bot Guard: Bot Classifier
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Classify suspect IPs using FCrDNS verification and crawler configs
//
// meta:name="botguard_classifier"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="Bot classification logic using FCrDNS and crawler config"
//
// Classification pipeline:
//   1. Check denied list → BAN immediately
//   2. Check verifier cache → if verified + allowed → ALLOW
//   3. First-time suspect → enqueue FCrDNS, set PENDING
//   4. Repeated suspect (no verification) → GREY (threshold escalation)
//   5. Persistent suspect → BAN
//
// ProcessVerification (called when FCrDNS completes):
//   - Verified + allowed → ALLOW
//   - Failed verification → GREY
//   - Denied bot identity → BAN
//
// meta:inventory.files="classifier.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="allowed_crawlers.conf,denied_crawlers.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"bufio"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
)

// Classifier performs bot classification using FCrDNS verification
// and allowed/denied crawler configuration.
type Classifier struct {
	verifier    *FCrDNSVerifier
	config      *Config
	allowedBots []BotConfig
	deniedBots  map[string]bool // bot name → enabled

	mu sync.RWMutex // protects allowedBots, deniedBots for hot reload
}

// NewClassifier creates a classifier with loaded crawler configs.
func NewClassifier(cfg *Config, verifier *FCrDNSVerifier) (*Classifier, error) {
	c := &Classifier{
		verifier:   verifier,
		config:     cfg,
		deniedBots: make(map[string]bool),
	}

	if err := c.loadConfigs(); err != nil {
		return nil, fmt.Errorf("load crawler configs: %w", err)
	}

	return c, nil
}

// Classify determines the classification for a suspect IP record.
// Returns a ClassifyResult with the target state and reason.
func (c *Classifier) Classify(r *IPRecord, cfg *Config) ClassifyResult {
	c.mu.RLock()
	defer c.mu.RUnlock()

	// Step 1: If already verified and allowed, keep ALLOW
	if r.VerifyStatus == VerifyVerified && r.BotName != "" {
		if !c.deniedBots[strings.ToUpper(r.BotName)] {
			return ClassifyResult{
				State:   StateAllow,
				Reason:  "fcrdns_verified",
				BotName: r.BotName,
				Verify:  VerifyVerified,
			}
		}
		// Verified but on denied list → ban
		return ClassifyResult{
			State:   StateBan,
			Reason:  "denied_bot_" + strings.ToLower(r.BotName),
			BotName: r.BotName,
			Verify:  VerifyVerified,
		}
	}

	// Step 2: First time suspect → enqueue for FCrDNS, set PENDING
	if r.State == StateUnknown {
		if c.verifier != nil {
			c.verifier.Enqueue(r.IP)
		}
		return ClassifyResult{
			State:  StatePending,
			Reason: "new_suspect_verify_enqueued",
		}
	}

	// Step 3: Threshold escalation for unverified IPs
	switch {
	case r.HitCount >= 10:
		return ClassifyResult{
			State:  StateBan,
			Reason: "persistent_suspect",
		}
	case r.HitCount >= 3:
		return ClassifyResult{
			State:  StateGrey,
			Reason: "repeated_suspect",
		}
	default:
		// Still pending, re-enqueue if not yet verifying
		if r.VerifyStatus == VerifyNone && c.verifier != nil {
			c.verifier.Enqueue(r.IP)
		}
		return ClassifyResult{
			State:  StatePending,
			Reason: "awaiting_verification",
		}
	}
}

// ProcessVerification processes a completed FCrDNS result and returns
// the classification decision for the verified IP.
func (c *Classifier) ProcessVerification(result VerifyResult) ClassifyResult {
	c.mu.RLock()
	defer c.mu.RUnlock()

	switch result.Status {
	case VerifyVerified:
		// Check if the verified bot is on the denied list
		if c.deniedBots[strings.ToUpper(result.BotName)] {
			return ClassifyResult{
				State:   StateBan,
				Reason:  "denied_bot_" + strings.ToLower(result.BotName),
				BotName: result.BotName,
				Verify:  VerifyVerified,
			}
		}
		return ClassifyResult{
			State:   StateAllow,
			Reason:  "fcrdns_verified",
			BotName: result.BotName,
			Verify:  VerifyVerified,
		}

	case VerifyFailed:
		return ClassifyResult{
			State:  StateGrey,
			Reason: "fcrdns_failed",
			Verify: VerifyFailed,
		}

	case VerifyTimeout:
		// Don't punish for DNS timeout — leave in current state
		return ClassifyResult{
			State:  StatePending,
			Reason: "fcrdns_timeout",
			Verify: VerifyTimeout,
		}

	case VerifyNoRDNS:
		return ClassifyResult{
			State:  StateGrey,
			Reason: "no_rdns",
			Verify: VerifyNoRDNS,
		}

	default:
		return ClassifyResult{
			State:  StateGrey,
			Reason: "verify_unknown",
			Verify: result.Status,
		}
	}
}

// ReloadConfigs reloads allowed and denied crawler configs from disk.
func (c *Classifier) ReloadConfigs() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.loadConfigs()
}

// loadConfigs loads both allowed and denied crawler config files.
// Must be called with c.mu held for writing.
func (c *Classifier) loadConfigs() error {
	allowed, err := loadAllowedCrawlers(c.config.AllowedCrawlersFile)
	if err != nil {
		log.Printf("[botguard] warning: could not load allowed crawlers: %v", err)
		// Non-fatal: operate without allowed list
		allowed = nil
	}
	c.allowedBots = allowed

	// Update verifier's allowed bot list
	if c.verifier != nil {
		c.verifier.allowedBots = allowed
	}

	denied, err := loadDeniedCrawlers(c.config.DeniedCrawlersFile)
	if err != nil {
		log.Printf("[botguard] warning: could not load denied crawlers: %v", err)
		denied = make(map[string]bool)
	}
	c.deniedBots = denied

	log.Printf("[botguard] loaded %d allowed crawlers, %d denied crawlers",
		len(c.allowedBots), len(c.deniedBots))

	return nil
}

// AllowedBots returns a copy of the allowed bot list.
func (c *Classifier) AllowedBots() []BotConfig {
	c.mu.RLock()
	defer c.mu.RUnlock()
	bots := make([]BotConfig, len(c.allowedBots))
	copy(bots, c.allowedBots)
	return bots
}

// loadAllowedCrawlers parses an allowed_crawlers.conf file.
// Format: BOT_NAME|DOMAIN_SUFFIX|VERIFY_MODE|MAX_CONN|MAX_RATE|BURST
func loadAllowedCrawlers(path string) ([]BotConfig, error) {
	f, err := os.Open(filepath.Clean(path)) // #nosec G304 -- path from /etc/nftban/conf.d/ (trusted config dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()

	var bots []BotConfig
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "|", 6)
		if len(parts) < 6 {
			log.Printf("[botguard] skipping malformed allowed_crawlers line: %s", line)
			continue
		}

		maxConn, _ := strconv.Atoi(strings.TrimSpace(parts[3]))
		burst, _ := strconv.Atoi(strings.TrimSpace(parts[5]))

		domains := strings.Split(strings.TrimSpace(parts[1]), ",")
		for i := range domains {
			domains[i] = strings.TrimSpace(domains[i])
		}

		bots = append(bots, BotConfig{
			Name:       strings.TrimSpace(parts[0]),
			Domains:    domains,
			VerifyMode: strings.TrimSpace(parts[2]),
			MaxConn:    maxConn,
			MaxRate:    strings.TrimSpace(parts[4]),
			Burst:      burst,
		})
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}

	return bots, nil
}

// loadDeniedCrawlers parses a denied_crawlers.conf file.
// Format: BOT_NAME|ENABLED
func loadDeniedCrawlers(path string) (map[string]bool, error) {
	f, err := os.Open(filepath.Clean(path)) // #nosec G304 -- path from /etc/nftban/conf.d/ (trusted config dir)
	if err != nil {
		if os.IsNotExist(err) {
			return make(map[string]bool), nil
		}
		return nil, err
	}
	defer f.Close()

	denied := make(map[string]bool)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "|", 2)
		if len(parts) < 2 {
			log.Printf("[botguard] skipping malformed denied_crawlers line: %s", line)
			continue
		}

		name := strings.TrimSpace(parts[0])
		enabled := strings.TrimSpace(parts[1])
		if parseBool(enabled) {
			denied[strings.ToUpper(name)] = true
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("reading %s: %w", path, err)
	}

	return denied, nil
}
