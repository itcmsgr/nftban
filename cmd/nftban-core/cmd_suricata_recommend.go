// =============================================================================
// NFTBan - Suricata Integration - Security recommendations engine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Security recommendations engine"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/*.conf"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/suricata/recommendations"
	"github.com/itcmsgr/nftban/internal/suricata/stats"
	"github.com/itcmsgr/nftban/pkg/version"
)

// cmdSuricataRecommend generates intelligent recommendations
func cmdSuricataRecommend() error {
	fmt.Println(version.BannerWithEmoji("💡", "Suricata Rule Recommendations"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache and analyzer
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	analyzer := recommendations.NewAnalyzer(cache)

	// Generate recommendations
	fmt.Println("→ Analyzing SID statistics...")
	recs, err := analyzer.AnalyzeAll()
	if err != nil {
		return fmt.Errorf("failed to analyze: %w", err)
	}

	if len(recs) == 0 {
		fmt.Println("✓ No recommendations at this time")
		fmt.Println()
		fmt.Println("All rules appear to be performing optimally based on current data.")
		fmt.Println()
		return nil
	}

	fmt.Printf("✓ Generated %d recommendations\n", len(recs))
	fmt.Println()

	// Group by severity
	highSeverity := make([]*recommendations.Recommendation, 0)
	mediumSeverity := make([]*recommendations.Recommendation, 0)
	lowSeverity := make([]*recommendations.Recommendation, 0)

	for _, rec := range recs {
		switch rec.Severity {
		case "high":
			highSeverity = append(highSeverity, rec)
		case "medium":
			mediumSeverity = append(mediumSeverity, rec)
		case "low":
			lowSeverity = append(lowSeverity, rec)
		}
	}

	// Display high severity first
	if len(highSeverity) > 0 {
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Printf("  🔴 HIGH SEVERITY (%d recommendations)\n", len(highSeverity))
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println()

		for _, rec := range highSeverity {
			printRecommendation(rec)
		}
	}

	// Display medium severity
	if len(mediumSeverity) > 0 {
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Printf("  🟡 MEDIUM SEVERITY (%d recommendations)\n", len(mediumSeverity))
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println()

		for _, rec := range mediumSeverity {
			printRecommendation(rec)
		}
	}

	// Display low severity
	if len(lowSeverity) > 0 {
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Printf("  🟢 LOW SEVERITY (%d recommendations)\n", len(lowSeverity))
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println()

		for _, rec := range lowSeverity {
			printRecommendation(rec)
		}
	}

	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println("  1. Review high severity recommendations first")
	fmt.Println("  2. Investigate SIDs: nftban suricata sid info <SID>")
	fmt.Println("  3. Apply fixes (disable/modify rules as needed)")
	fmt.Println("  4. Monitor results: nftban suricata sid top")
	fmt.Println()

	return nil
}

// cmdSuricataRecommendSummary shows summary statistics
func cmdSuricataRecommendSummary() error {
	fmt.Println(version.BannerWithEmoji("📊", "Recommendations Summary"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache and analyzer
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	analyzer := recommendations.NewAnalyzer(cache)

	// Generate summary
	summary := analyzer.GenerateSummary()

	// Display summary
	fmt.Printf("Total SIDs tracked:        %d\n", summary["total_sids"])
	fmt.Printf("Total recommendations:     %d\n", summary["total_recommendations"])
	fmt.Println()

	// Severity breakdown
	fmt.Println("By Severity:")
	fmt.Printf("  🔴 High:   %d\n", summary["high_severity_count"])
	fmt.Printf("  🟡 Medium: %d\n", summary["medium_severity_count"])
	fmt.Printf("  🟢 Low:    %d\n", summary["low_severity_count"])
	fmt.Println()

	// Type breakdown
	if byType, ok := summary["by_type"].(map[string]int); ok {
		fmt.Println("By Type:")
		if count, exists := byType["false_positive"]; exists && count > 0 {
			fmt.Printf("  False Positives:   %d\n", count)
		}
		if count, exists := byType["noise_reduction"]; exists && count > 0 {
			fmt.Printf("  Noise Reduction:   %d\n", count)
		}
		if count, exists := byType["drop_mode"]; exists && count > 0 {
			fmt.Printf("  Drop Mode:         %d\n", count)
		}
		if count, exists := byType["disable_rule"]; exists && count > 0 {
			fmt.Printf("  Disable Rule:      %d\n", count)
		}
		fmt.Println()
	}

	fmt.Println("For detailed recommendations:")
	fmt.Println("  nftban suricata recommend")
	fmt.Println()

	return nil
}

// printRecommendation formats and prints a recommendation
func printRecommendation(rec *recommendations.Recommendation) {
	// Type icon
	typeIcon := "ℹ️"
	switch rec.Type {
	case recommendations.FalsePositive:
		typeIcon = "⚠️"
	case recommendations.NoiseReduction:
		typeIcon = "🔇"
	case recommendations.DropMode:
		typeIcon = "🛡️"
	case recommendations.DisableRule:
		typeIcon = "❌"
	}

	fmt.Printf("%s SID %s: %s\n", typeIcon, rec.SID, rec.Reason)
	fmt.Printf("   Category: %s\n", rec.Category)

	signature := rec.Signature
	if len(signature) > 60 {
		signature = signature[:57] + "..."
	}
	fmt.Printf("   Signature: %s\n", signature)

	fmt.Println("   Evidence:")
	for _, evidence := range rec.Evidence {
		fmt.Printf("     • %s\n", evidence)
	}

	fmt.Printf("   ✅ Action: %s\n", rec.Action)
	fmt.Println()
}
