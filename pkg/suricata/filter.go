package suricata

import (
	"strings"
)

// FilterMatcher handles matching Suricata signatures to filters
type FilterMatcher struct {
	config *Config
}

// NewFilterMatcher creates a new filter matcher
func NewFilterMatcher(config *Config) *FilterMatcher {
	return &FilterMatcher{
		config: config,
	}
}

// MatchSignature matches a Suricata signature against configured filters
// Returns the matching filter name, or empty string if no match
func (fm *FilterMatcher) MatchSignature(signature string) (string, *FilterConfig) {
	sigLower := strings.ToLower(signature)

	// Try to match against each enabled filter
	for name, filter := range fm.config.GetEnabledFilters() {
		// Check if any keyword matches
		for _, keyword := range filter.Keywords {
			if strings.Contains(sigLower, keyword) {
				return name, filter
			}
		}
	}

	return "", nil
}

// MatchCategory matches a Suricata category against configured filters
func (fm *FilterMatcher) MatchCategory(category string) (string, *FilterConfig) {
	catLower := strings.ToLower(category)

	// Try to match category against filter keywords
	for name, filter := range fm.config.GetEnabledFilters() {
		for _, keyword := range filter.Keywords {
			if strings.Contains(catLower, keyword) {
				return name, filter
			}
		}
	}

	return "", nil
}

// GetFilterForEvent determines which filter matches an event
// Tries signature first, then category, returns first match
func (fm *FilterMatcher) GetFilterForEvent(signature, category string) (string, *FilterConfig) {
	// Try signature match first (more specific)
	if name, filter := fm.MatchSignature(signature); filter != nil {
		return name, filter
	}

	// Fall back to category match
	if name, filter := fm.MatchCategory(category); filter != nil {
		return name, filter
	}

	// No match
	return "", nil
}
