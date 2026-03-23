// =============================================================================
// NFTBan v1.0 - Zabbix Multi-Target Manager
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="multi"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Manages multiple Zabbix server targets for redundancy"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="10051/tcp"
// meta:inventory.privileges="none"
// =============================================================================

package zabbix

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// =============================================================================
// Multi-Target Manager
// =============================================================================

// SendMode determines how metrics are sent to multiple targets
type SendMode string

const (
	// SendModeAll sends to all enabled targets
	SendModeAll SendMode = "all"
	// SendModePrimary sends only to the primary (highest priority) target
	SendModePrimary SendMode = "primary"
	// SendModeFailover sends to primary, falls back to secondary on failure
	SendModeFailover SendMode = "failover"
)

// MultiSender manages multiple Zabbix server targets
type MultiSender struct {
	config *Config
	mode   SendMode

	// Senders by target name
	senders   map[string]*Sender
	sendersMu sync.RWMutex

	// Ordered list of targets by priority
	targetOrder []string

	// Health tracking
	health   map[string]*TargetHealth
	healthMu sync.RWMutex

	// Background workers
	wg     sync.WaitGroup
	ctx    context.Context
	cancel context.CancelFunc

	// Shutdown
	closed atomic.Bool
}

// TargetHealth tracks the health of a target
type TargetHealth struct {
	Name           string
	Healthy        bool
	LastCheck      time.Time
	LastSuccess    time.Time
	LastError      time.Time
	LastErrorMsg   string
	ConsecFailures int
	ConsecSuccess  int
}

// MultiSenderOption is a functional option for MultiSender
type MultiSenderOption func(*MultiSender)

// WithSendMode sets the send mode
func WithSendMode(mode SendMode) MultiSenderOption {
	return func(m *MultiSender) {
		m.mode = mode
	}
}

// NewMultiSender creates a new multi-target sender
func NewMultiSender(config *Config, opts ...MultiSenderOption) (*MultiSender, error) {
	if config == nil {
		return nil, fmt.Errorf("config is required")
	}

	ctx, cancel := context.WithCancel(context.Background())

	m := &MultiSender{
		config:  config,
		mode:    SendModeAll, // default
		senders: make(map[string]*Sender),
		health:  make(map[string]*TargetHealth),
		ctx:     ctx,
		cancel:  cancel,
	}

	// Apply options
	for _, opt := range opts {
		opt(m)
	}

	// Initialize senders for enabled targets
	enabledTargets := config.GetEnabledTargets()
	if len(enabledTargets) == 0 {
		cancel()
		return nil, fmt.Errorf("no enabled targets configured")
	}

	for _, tc := range enabledTargets {
		target := tc.ToTarget()
		sender, err := NewSender(target, config)
		if err != nil {
			// Clean up already created senders
			for _, s := range m.senders {
				s.Close()
			}
			cancel()
			return nil, fmt.Errorf("failed to create sender for %s: %w", tc.Name, err)
		}

		m.senders[tc.Name] = sender
		m.targetOrder = append(m.targetOrder, tc.Name)
		m.health[tc.Name] = &TargetHealth{
			Name:    tc.Name,
			Healthy: true, // Assume healthy until proven otherwise
		}
	}

	return m, nil
}

// =============================================================================
// Send Operations
// =============================================================================

// Send sends metrics according to the configured mode
func (m *MultiSender) Send(ctx context.Context, metrics []Metric) (*MultiSendResult, error) {
	if m.closed.Load() {
		return nil, fmt.Errorf("multi-sender is closed")
	}

	switch m.mode {
	case SendModeAll:
		return m.sendToAll(ctx, metrics)
	case SendModePrimary:
		return m.sendToPrimary(ctx, metrics)
	case SendModeFailover:
		return m.sendWithFailover(ctx, metrics)
	default:
		return m.sendToAll(ctx, metrics)
	}
}

// MultiSendResult contains results from sending to multiple targets
type MultiSendResult struct {
	Success    bool
	Results    map[string]*TargetResult
	TotalSent  int
	TotalFailed int
}

// TargetResult contains the result for a single target
type TargetResult struct {
	Target   string
	Success  bool
	Response *TrapperResponse
	Error    error
	Latency  time.Duration
}

// sendToAll sends metrics to all enabled targets in parallel
func (m *MultiSender) sendToAll(ctx context.Context, metrics []Metric) (*MultiSendResult, error) {
	m.sendersMu.RLock()
	targets := make([]string, len(m.targetOrder))
	copy(targets, m.targetOrder)
	m.sendersMu.RUnlock()

	result := &MultiSendResult{
		Results: make(map[string]*TargetResult),
	}

	var wg sync.WaitGroup
	var mu sync.Mutex

	for _, name := range targets {
		m.sendersMu.RLock()
		sender := m.senders[name]
		m.sendersMu.RUnlock()

		if sender == nil {
			continue
		}

		wg.Add(1)
		go func(name string, s *Sender) {
			defer wg.Done()

			start := time.Now()
			resp, err := s.Send(ctx, metrics)
			latency := time.Since(start)

			tr := &TargetResult{
				Target:   name,
				Response: resp,
				Error:    err,
				Latency:  latency,
				Success:  err == nil && (resp == nil || resp.IsSuccess()),
			}

			mu.Lock()
			result.Results[name] = tr
			if tr.Success {
				result.TotalSent++
			} else {
				result.TotalFailed++
			}
			mu.Unlock()

			// Update health
			m.updateHealth(name, tr.Success, err)
		}(name, sender)
	}

	wg.Wait()

	// Success if at least one target succeeded
	result.Success = result.TotalSent > 0

	return result, nil
}

// sendToPrimary sends metrics only to the primary (first healthy) target
func (m *MultiSender) sendToPrimary(ctx context.Context, metrics []Metric) (*MultiSendResult, error) {
	m.sendersMu.RLock()
	targets := make([]string, len(m.targetOrder))
	copy(targets, m.targetOrder)
	m.sendersMu.RUnlock()

	result := &MultiSendResult{
		Results: make(map[string]*TargetResult),
	}

	// Find first healthy target
	var primaryName string
	var primarySender *Sender

	m.healthMu.RLock()
	for _, name := range targets {
		if h := m.health[name]; h != nil && h.Healthy {
			m.sendersMu.RLock()
			primarySender = m.senders[name]
			m.sendersMu.RUnlock()
			if primarySender != nil {
				primaryName = name
				break
			}
		}
	}
	m.healthMu.RUnlock()

	// If no healthy target, try the first one anyway
	if primarySender == nil && len(targets) > 0 {
		primaryName = targets[0]
		m.sendersMu.RLock()
		primarySender = m.senders[primaryName]
		m.sendersMu.RUnlock()
	}

	if primarySender == nil {
		return nil, fmt.Errorf("no available targets")
	}

	start := time.Now()
	resp, err := primarySender.Send(ctx, metrics)
	latency := time.Since(start)

	tr := &TargetResult{
		Target:   primaryName,
		Response: resp,
		Error:    err,
		Latency:  latency,
		Success:  err == nil && (resp == nil || resp.IsSuccess()),
	}

	result.Results[primaryName] = tr
	if tr.Success {
		result.TotalSent = 1
		result.Success = true
	} else {
		result.TotalFailed = 1
	}

	m.updateHealth(primaryName, tr.Success, err)

	return result, nil
}

// sendWithFailover sends to primary, falls back to secondary targets on failure
func (m *MultiSender) sendWithFailover(ctx context.Context, metrics []Metric) (*MultiSendResult, error) {
	m.sendersMu.RLock()
	targets := make([]string, len(m.targetOrder))
	copy(targets, m.targetOrder)
	m.sendersMu.RUnlock()

	result := &MultiSendResult{
		Results: make(map[string]*TargetResult),
	}

	for _, name := range targets {
		m.sendersMu.RLock()
		sender := m.senders[name]
		m.sendersMu.RUnlock()

		if sender == nil {
			continue
		}

		start := time.Now()
		resp, err := sender.Send(ctx, metrics)
		latency := time.Since(start)

		tr := &TargetResult{
			Target:   name,
			Response: resp,
			Error:    err,
			Latency:  latency,
			Success:  err == nil && (resp == nil || resp.IsSuccess()),
		}

		result.Results[name] = tr
		m.updateHealth(name, tr.Success, err)

		if tr.Success {
			result.TotalSent = 1
			result.Success = true
			return result, nil
		}

		result.TotalFailed++
		// Continue to next target on failure
	}

	return result, fmt.Errorf("all targets failed")
}

// =============================================================================
// Health Management
// =============================================================================

// updateHealth updates the health status for a target
func (m *MultiSender) updateHealth(name string, success bool, err error) {
	m.healthMu.Lock()
	defer m.healthMu.Unlock()

	h := m.health[name]
	if h == nil {
		h = &TargetHealth{Name: name}
		m.health[name] = h
	}

	h.LastCheck = time.Now()

	if success {
		h.LastSuccess = time.Now()
		h.ConsecSuccess++
		h.ConsecFailures = 0
		// Mark healthy after 2 consecutive successes
		if h.ConsecSuccess >= 2 || h.Healthy {
			h.Healthy = true
		}
	} else {
		h.LastError = time.Now()
		h.ConsecFailures++
		h.ConsecSuccess = 0
		if err != nil {
			h.LastErrorMsg = err.Error()
		}
		// Mark unhealthy after 3 consecutive failures
		if h.ConsecFailures >= 3 {
			h.Healthy = false
		}
	}
}

// GetHealth returns health status for all targets
func (m *MultiSender) GetHealth() map[string]TargetHealth {
	m.healthMu.RLock()
	defer m.healthMu.RUnlock()

	result := make(map[string]TargetHealth)
	for name, h := range m.health {
		result[name] = *h
	}
	return result
}

// GetHealthyTargets returns names of healthy targets
func (m *MultiSender) GetHealthyTargets() []string {
	m.healthMu.RLock()
	defer m.healthMu.RUnlock()

	var healthy []string
	for _, name := range m.targetOrder {
		if h := m.health[name]; h != nil && h.Healthy {
			healthy = append(healthy, name)
		}
	}
	return healthy
}

// =============================================================================
// Status & Lifecycle
// =============================================================================

// Status returns the overall multi-sender status
func (m *MultiSender) Status() ExporterStatus {
	m.sendersMu.RLock()
	defer m.sendersMu.RUnlock()

	status := ExporterStatus{
		Enabled:   m.config.Enabled,
		Running:   !m.closed.Load(),
		StartTime: time.Now(), // TODO: track actual start time
		Targets:   make([]SenderStatus, 0, len(m.senders)),
	}

	for _, name := range m.targetOrder {
		if sender := m.senders[name]; sender != nil {
			s := sender.Status()
			status.Targets = append(status.Targets, s)
			status.TotalSent += s.MetricsSent
			status.TotalErrors += s.ErrorCount
		}
	}

	return status
}

// Close closes all senders
func (m *MultiSender) Close() error {
	if m.closed.Swap(true) {
		return nil // Already closed
	}

	m.cancel()

	m.sendersMu.Lock()
	defer m.sendersMu.Unlock()

	var errs []error
	for name, sender := range m.senders {
		if err := sender.Close(); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", name, err))
		}
	}

	m.wg.Wait()

	if len(errs) > 0 {
		return fmt.Errorf("errors closing senders: %v", errs)
	}

	return nil
}

// =============================================================================
// Target Management
// =============================================================================

// AddTarget adds a new target dynamically
func (m *MultiSender) AddTarget(tc TargetConfig) error {
	if m.closed.Load() {
		return fmt.Errorf("multi-sender is closed")
	}

	target := tc.ToTarget()
	sender, err := NewSender(target, m.config)
	if err != nil {
		return fmt.Errorf("failed to create sender: %w", err)
	}

	m.sendersMu.Lock()
	m.senders[tc.Name] = sender
	m.targetOrder = append(m.targetOrder, tc.Name)
	m.sendersMu.Unlock()

	m.healthMu.Lock()
	m.health[tc.Name] = &TargetHealth{
		Name:    tc.Name,
		Healthy: true,
	}
	m.healthMu.Unlock()

	return nil
}

// RemoveTarget removes a target dynamically
func (m *MultiSender) RemoveTarget(name string) error {
	m.sendersMu.Lock()
	sender := m.senders[name]
	delete(m.senders, name)

	// Remove from order
	for i, n := range m.targetOrder {
		if n == name {
			m.targetOrder = append(m.targetOrder[:i], m.targetOrder[i+1:]...)
			break
		}
	}
	m.sendersMu.Unlock()

	m.healthMu.Lock()
	delete(m.health, name)
	m.healthMu.Unlock()

	if sender != nil {
		return sender.Close()
	}

	return nil
}

// GetTargets returns the list of target names
func (m *MultiSender) GetTargets() []string {
	m.sendersMu.RLock()
	defer m.sendersMu.RUnlock()

	targets := make([]string, len(m.targetOrder))
	copy(targets, m.targetOrder)
	return targets
}

// GetSender returns the sender for a specific target
func (m *MultiSender) GetSender(name string) *Sender {
	m.sendersMu.RLock()
	defer m.sendersMu.RUnlock()
	return m.senders[name]
}

// =============================================================================
// Testing Helpers
// =============================================================================

// TestAllConnections tests connectivity to all targets
func (m *MultiSender) TestAllConnections(ctx context.Context) map[string]error {
	m.sendersMu.RLock()
	targets := make([]string, len(m.targetOrder))
	copy(targets, m.targetOrder)
	m.sendersMu.RUnlock()

	results := make(map[string]error)
	var mu sync.Mutex
	var wg sync.WaitGroup

	for _, name := range targets {
		m.sendersMu.RLock()
		sender := m.senders[name]
		m.sendersMu.RUnlock()

		if sender == nil {
			continue
		}

		wg.Add(1)
		go func(name string, s *Sender) {
			defer wg.Done()
			err := s.TestConnection(ctx)
			mu.Lock()
			results[name] = err
			mu.Unlock()
		}(name, sender)
	}

	wg.Wait()
	return results
}

// PingAll pings all targets and returns latencies
func (m *MultiSender) PingAll(ctx context.Context) map[string]time.Duration {
	m.sendersMu.RLock()
	targets := make([]string, len(m.targetOrder))
	copy(targets, m.targetOrder)
	m.sendersMu.RUnlock()

	results := make(map[string]time.Duration)
	var mu sync.Mutex
	var wg sync.WaitGroup

	for _, name := range targets {
		m.sendersMu.RLock()
		sender := m.senders[name]
		m.sendersMu.RUnlock()

		if sender == nil {
			continue
		}

		wg.Add(1)
		go func(name string, s *Sender) {
			defer wg.Done()
			latency, err := s.Ping(ctx)
			mu.Lock()
			if err == nil {
				results[name] = latency
			} else {
				results[name] = -1 // Indicate failure
			}
			mu.Unlock()
		}(name, sender)
	}

	wg.Wait()
	return results
}
