// =============================================================================
// NFTBan - Suricata Event Processor
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="processor"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Main event processing loop for Suricata integration"
// meta:input="Suricata eve.json events"
// meta:output="Ban actions, log entries"
// meta:depends="github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package suricata

import (
	"fmt"
	"os"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// Processor handles the main Suricata event processing loop
type Processor struct {
	config     *Config
	matcher    *FilterMatcher
	scorer     *Scorer
	logger     *EventLogger
	reader     *EveReader
	eventChan  chan *Event
	stopChan   chan struct{}
	banHandler BanHandler
}

// BanHandler defines the interface for banning IPs
type BanHandler interface {
	BanIP(ip string, duration time.Duration, reason string) error
}

// ProcessorConfig holds configuration for the processor
type ProcessorConfig struct {
	ConfigDir   string
	EvePath     string
	LogPath     string
	BanHandler  BanHandler
}

// NewProcessor creates a new Suricata event processor
func NewProcessor(cfg *ProcessorConfig) (*Processor, error) {
	// Load configuration
	config, err := LoadConfig(cfg.ConfigDir)
	if err != nil {
		return nil, fmt.Errorf("failed to load config: %w", err)
	}

	if !config.GlobalEnabled {
		return nil, fmt.Errorf("suricata integration is disabled in config")
	}

	// Create filter matcher
	matcher := NewFilterMatcher(config)

	// Create scorer
	scorer := NewScorer(config)

	// Create event logger
	logger, err := NewEventLogger(cfg.LogPath)
	if err != nil {
		return nil, fmt.Errorf("failed to create logger: %w", err)
	}

	// Create eve.json reader
	reader, err := NewEveReader(cfg.EvePath, matcher)
	if err != nil {
		logger.Close()
		return nil, fmt.Errorf("failed to create eve reader: %w", err)
	}

	p := &Processor{
		config:     config,
		matcher:    matcher,
		scorer:     scorer,
		logger:     logger,
		reader:     reader,
		eventChan:  make(chan *Event, 1000), // Buffer 1000 events
		stopChan:   make(chan struct{}),
		banHandler: cfg.BanHandler,
	}

	return p, nil
}

// Start starts the processor
func (p *Processor) Start() error {
	// Get config dir from central config
	// NO FALLBACK - path must come from /etc/nftban/nftban.conf
	cfg := nftbanconf.MustLoad()
	configDir := cfg.ConfigDir

	fmt.Printf("🛡️  NFTBan Suricata Processor Starting...\n")
	fmt.Printf("   Config Dir: %s\n", configDir)
	fmt.Printf("   Eve Log:    %s\n", p.reader.path)
	fmt.Printf("   Event Log:  %s\n", p.logger.path)
	fmt.Printf("   Filters:    %d enabled\n\n", len(p.config.GetEnabledFilters()))

	// Start reader goroutine
	go func() {
		if err := p.reader.ReadEvents(p.eventChan, p.stopChan); err != nil {
			fmt.Fprintf(os.Stderr, "Eve reader error: %v\n", err)
		}
	}()

	// Start processing goroutine
	go p.processEvents()

	fmt.Println("✅ Suricata processor started")
	return nil
}

// Stop stops the processor
func (p *Processor) Stop() error {
	fmt.Println("⏹️  Stopping Suricata processor...")

	// Signal stop
	close(p.stopChan)

	// Close resources
	if p.reader != nil {
		p.reader.Close()
	}
	if p.logger != nil {
		p.logger.Close()
	}
	if p.scorer != nil {
		p.scorer.Stop()
	}

	fmt.Println("✅ Suricata processor stopped")
	return nil
}

// processEvents processes incoming events
func (p *Processor) processEvents() {
	for {
		select {
		case <-p.stopChan:
			return
		case event := <-p.eventChan:
			if event != nil {
				p.handleEvent(event)
			}
		}
	}
}

// handleEvent handles a single Suricata event
func (p *Processor) handleEvent(event *Event) {
	// Skip if no filter matched
	if event.Filter == "" {
		return
	}

	// Get filter config
	filter, ok := p.config.GetFilter(event.Filter)
	if !ok || !filter.Enabled {
		return
	}

	// Add event and calculate score
	score := p.scorer.AddEvent(event)

	// Determine decision based on action and score
	decision := "LOG"
	shouldBan := false

	switch filter.Action {
	case "log":
		// Just log, never ban
		decision = "LOG"
		shouldBan = false

	case "observe":
		// Log and track, but don't ban
		if score >= filter.Threshold {
			decision = "OBSERVE"
		} else {
			decision = "TRACK"
		}
		shouldBan = false

	case "ban":
		// Ban if score exceeds threshold
		if score >= filter.Threshold {
			decision = "BAN"
			shouldBan = true
		} else {
			decision = "MONITOR"
		}
	}

	// Log the event
	if err := p.logger.LogEvent(event, score, filter.Threshold, filter.Action, decision); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to log event: %v\n", err)
	}

	// Execute ban if needed
	if shouldBan && p.banHandler != nil {
		// Determine ban duration based on ban_type
		banDuration := filter.BanTime
		banType := "temporary"
		reason := fmt.Sprintf("Suricata: %s (score=%d)", event.Signature, score)

		if filter.BanType == "permanent" {
			// Always permanent
			banDuration = 0 // 0 = permanent in nftban
			banType = "permanent"
		} else if filter.BanType == "escalate" {
			// Check ban history for escalation
			ipScore := p.scorer.GetIPScore(event.SrcIP)
			if ipScore != nil && filter.MaxBans > 0 && filter.Period > 0 {
				// Count bans in the escalation period
				cutoff := time.Now().Add(-filter.Period)
				recentBans := 0
				for _, t := range ipScore.Events {
					if t.After(cutoff) {
						recentBans++
					}
				}

				// If exceeded threshold, escalate to permanent
				if recentBans >= filter.MaxBans {
					banDuration = 0 // permanent
					banType = "permanent (escalated)"
					reason = fmt.Sprintf("Suricata: %s (score=%d, %d bans in %s - ESCALATED)",
						event.Signature, score, recentBans, filter.Period)
				}
			}
		}

		// Execute the ban
		if err := p.banHandler.BanIP(event.SrcIP, banDuration, reason); err != nil {
			p.logger.LogError(fmt.Sprintf("Failed to ban %s", event.SrcIP), err)
		} else {
			// Log successful ban action
			p.logger.LogBanAction(event.SrcIP, filter.Name, score, filter.Threshold, banDuration, reason+" ["+banType+"]")
			// Don't reset score - keep tracking for escalation
		}
	}
}

// GetStats returns current processor statistics
func (p *Processor) GetStats() map[string]interface{} {
	scores := p.scorer.GetAllScores()

	stats := map[string]interface{}{
		"enabled_filters": len(p.config.GetEnabledFilters()),
		"total_filters":   len(p.config.Filters),
		"tracked_ips":     len(scores),
		"event_queue":     len(p.eventChan),
	}

	return stats
}

// GetScores returns all current IP scores
func (p *Processor) GetScores() map[string]*IPScore {
	return p.scorer.GetAllScores()
}
