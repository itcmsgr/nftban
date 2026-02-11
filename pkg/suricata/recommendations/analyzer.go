// =============================================================================
// NFTBan - Suricata Recommendations Analyzer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="analyzer"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Analyzes SID statistics for false positives, noisy rules, and attack patterns"
// meta:input="SID statistics from cache"
// meta:output="Rule recommendations (tune, disable, drop mode)"
// meta:depends="github.com/itcmsgr/nftban/pkg/suricata/stats"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package recommendations

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/suricata/stats"
)

// attackCategorySet is a pre-built hash set for O(1) attack category lookup
// Initialized once at package load instead of creating slice on each call
var attackCategorySet = map[string]struct{}{
	"exploit":                {},
	"attack":                 {},
	"shellcode":              {},
	"trojan":                 {},
	"malware":                {},
	"web-application-attack": {},
	"sql-injection":          {},
}

// RecommendationType represents the type of recommendation
type RecommendationType string

const (
	FalsePositive    RecommendationType = "false_positive"
	NoiseReduction   RecommendationType = "noise_reduction"
	DropMode         RecommendationType = "drop_mode"
	DisableRule      RecommendationType = "disable_rule"
	InvestigateFurther RecommendationType = "investigate"
)

// Recommendation represents a single recommendation
type Recommendation struct {
	Type        RecommendationType
	SID         string
	Signature   string
	Category    string
	Severity    string // high, medium, low
	Reason      string
	Evidence    []string
	Action      string
	TriggerCount int
	SourceCount  int
	Ratio       float64 // Triggers per unique source
}

// Analyzer analyzes SID statistics and generates recommendations
type Analyzer struct {
	cache *stats.Cache
}

// NewAnalyzer creates a new recommendations analyzer
func NewAnalyzer(cache *stats.Cache) *Analyzer {
	return &Analyzer{
		cache: cache,
	}
}

// AnalyzeAll generates all recommendations
func (a *Analyzer) AnalyzeAll() ([]*Recommendation, error) {
	recommendations := make([]*Recommendation, 0)

	// Get all SID statistics
	allStats := a.cache.GetAllStats()

	// Analyze each SID
	for _, sidStats := range allStats {
		// Skip if no triggers
		if sidStats.TriggerCount == 0 {
			continue
		}

		// Check for various patterns
		if rec := a.analyzeFalsePositive(sidStats); rec != nil {
			recommendations = append(recommendations, rec)
		}
		if rec := a.analyzeNoiseReduction(sidStats); rec != nil {
			recommendations = append(recommendations, rec)
		}
		if rec := a.analyzeDropMode(sidStats); rec != nil {
			recommendations = append(recommendations, rec)
		}
		if rec := a.analyzeDisableRule(sidStats); rec != nil {
			recommendations = append(recommendations, rec)
		}
	}

	// Sort by severity
	sort.Slice(recommendations, func(i, j int) bool {
		severityOrder := map[string]int{"high": 3, "medium": 2, "low": 1}
		return severityOrder[recommendations[i].Severity] > severityOrder[recommendations[j].Severity]
	})

	return recommendations, nil
}

// analyzeFalsePositive detects potential false positives
// Pattern: Very high trigger count from very few unique sources
func (a *Analyzer) analyzeFalsePositive(sidStats *stats.SIDStats) *Recommendation {
	// Calculate ratio
	ratio := float64(sidStats.TriggerCount) / float64(sidStats.SourceCount)

	// Thresholds:
	// - More than 100 triggers
	// - From 1-3 sources
	// - Ratio > 50 (50+ triggers per source on average)
	if sidStats.TriggerCount > 100 && sidStats.SourceCount <= 3 && ratio > 50 {
		severity := "medium"
		if ratio > 200 {
			severity = "high"
		}

		evidence := []string{
			fmt.Sprintf("%d triggers from only %d unique source(s)", sidStats.TriggerCount, sidStats.SourceCount),
			fmt.Sprintf("Ratio: %.1f triggers per source", ratio),
		}

		if sidStats.SourceCount == 1 {
			evidence = append(evidence, "All triggers from single IP (likely misconfiguration or testing)")
		}

		return &Recommendation{
			Type:         FalsePositive,
			SID:          sidStats.SID,
			Signature:    sidStats.Signature,
			Category:     sidStats.Category,
			Severity:     severity,
			Reason:       "Potential false positive: High triggers from very few sources",
			Evidence:     evidence,
			Action:       "Review rule configuration and consider tuning threshold or disabling",
			TriggerCount: sidStats.TriggerCount,
			SourceCount:  sidStats.SourceCount,
			Ratio:        ratio,
		}
	}

	return nil
}

// analyzeNoiseReduction detects noisy rules
// Pattern: Extremely high trigger count from many sources (common activity)
func (a *Analyzer) analyzeNoiseReduction(sidStats *stats.SIDStats) *Recommendation {
	ratio := float64(sidStats.TriggerCount) / float64(sidStats.SourceCount)

	// Thresholds:
	// - More than 1000 triggers
	// - From many sources (>20)
	// - But ratio is low (<20) indicating distributed common activity
	if sidStats.TriggerCount > 1000 && sidStats.SourceCount > 20 && ratio < 20 {
		severity := "low"
		if sidStats.TriggerCount > 10000 {
			severity = "medium"
		}

		evidence := []string{
			fmt.Sprintf("%d triggers from %d unique sources", sidStats.TriggerCount, sidStats.SourceCount),
			fmt.Sprintf("Ratio: %.1f triggers per source (widespread activity)", ratio),
			"May be detecting normal/benign traffic patterns",
		}

		return &Recommendation{
			Type:         NoiseReduction,
			SID:          sidStats.SID,
			Signature:    sidStats.Signature,
			Category:     sidStats.Category,
			Severity:     severity,
			Reason:       "Noisy rule: High volume from many sources",
			Evidence:     evidence,
			Action:       "Consider tightening rule conditions or increasing threshold",
			TriggerCount: sidStats.TriggerCount,
			SourceCount:  sidStats.SourceCount,
			Ratio:        ratio,
		}
	}

	return nil
}

// analyzeDropMode recommends switching to drop mode
// Pattern: Moderate triggers from many different sources (distributed attack)
func (a *Analyzer) analyzeDropMode(sidStats *stats.SIDStats) *Recommendation {
	ratio := float64(sidStats.TriggerCount) / float64(sidStats.SourceCount)

	// Thresholds:
	// - More than 50 triggers
	// - From many sources (>10)
	// - Ratio between 2-10 (targeted but distributed)
	// - Category indicates attack pattern
	isAttackCategory := isAttackCategoryMatch(sidStats.Category)

	if sidStats.TriggerCount > 50 && sidStats.SourceCount > 10 && ratio >= 2 && ratio <= 10 && isAttackCategory {
		severity := "high"
		if sidStats.TriggerCount > 500 {
			severity = "high"
		} else {
			severity = "medium"
		}

		evidence := []string{
			fmt.Sprintf("%d triggers from %d unique sources", sidStats.TriggerCount, sidStats.SourceCount),
			fmt.Sprintf("Category: %s (attack pattern)", sidStats.Category),
			"Distributed attack pattern detected",
		}

		return &Recommendation{
			Type:         DropMode,
			SID:          sidStats.SID,
			Signature:    sidStats.Signature,
			Category:     sidStats.Category,
			Severity:     severity,
			Reason:       "Active attack pattern: Consider blocking mode",
			Evidence:     evidence,
			Action:       "Switch rule from 'alert' to 'drop' mode to actively block attacks",
			TriggerCount: sidStats.TriggerCount,
			SourceCount:  sidStats.SourceCount,
			Ratio:        ratio,
		}
	}

	return nil
}

// analyzeDisableRule recommends disabling extremely noisy rules
// Pattern: Excessive triggers that provide minimal security value
func (a *Analyzer) analyzeDisableRule(sidStats *stats.SIDStats) *Recommendation {
	// Thresholds:
	// - More than 10,000 triggers in total
	// - Very recent activity (within last hour)
	// - Very high frequency

	hourAgo := time.Now().Add(-1 * time.Hour)
	isVeryRecent := sidStats.LastTrigger.After(hourAgo)

	if sidStats.TriggerCount > 10000 && isVeryRecent {
		evidence := []string{
			fmt.Sprintf("%d total triggers (excessive volume)", sidStats.TriggerCount),
			fmt.Sprintf("%d unique sources", sidStats.SourceCount),
			fmt.Sprintf("Last trigger: %s (very recent)", sidStats.LastTrigger.Format("2006-01-02 15:04:05")),
			"Extremely high volume may indicate rule misconfiguration",
		}

		return &Recommendation{
			Type:         DisableRule,
			SID:          sidStats.SID,
			Signature:    sidStats.Signature,
			Category:     sidStats.Category,
			Severity:     "high",
			Reason:       "Extremely noisy rule: Consider disabling",
			Evidence:     evidence,
			Action:       "Disable this rule and investigate why it's triggering so frequently",
			TriggerCount: sidStats.TriggerCount,
			SourceCount:  sidStats.SourceCount,
			Ratio:        float64(sidStats.TriggerCount) / float64(sidStats.SourceCount),
		}
	}

	return nil
}

// GetTopNoisyRules returns rules with highest trigger counts
func (a *Analyzer) GetTopNoisyRules(n int) []*stats.SIDStats {
	return a.cache.GetTopSIDs(n)
}

// GetRecentThreats returns recently triggered rules
func (a *Analyzer) GetRecentThreats(duration time.Duration) []*stats.SIDStats {
	return a.cache.GetRecentSIDs(duration)
}

// GenerateSummary creates a summary report
func (a *Analyzer) GenerateSummary() map[string]interface{} {
	allStats := a.cache.GetAllStats()
	recommendations, _ := a.AnalyzeAll()

	// Count by type
	typeCounts := make(map[string]int)
	for _, rec := range recommendations {
		typeCounts[string(rec.Type)]++
	}

	// Count by severity
	severityCounts := make(map[string]int)
	for _, rec := range recommendations {
		severityCounts[rec.Severity]++
	}

	return map[string]interface{}{
		"total_sids":              len(allStats),
		"total_recommendations":   len(recommendations),
		"by_type":                 typeCounts,
		"by_severity":             severityCounts,
		"high_severity_count":     severityCounts["high"],
		"medium_severity_count":   severityCounts["medium"],
		"low_severity_count":      severityCounts["low"],
	}
}

// isAttackCategoryMatch checks if a category matches known attack patterns
// Optimized: Uses hash set for O(1) lookup instead of O(n) linear search
func isAttackCategoryMatch(category string) bool {
	categoryLower := strings.ToLower(category)

	// Direct match in hash set - O(1)
	if _, ok := attackCategorySet[categoryLower]; ok {
		return true
	}

	// Check if category contains any attack keyword (for compound categories)
	for keyword := range attackCategorySet {
		if strings.Contains(categoryLower, keyword) {
			return true
		}
	}

	return false
}
