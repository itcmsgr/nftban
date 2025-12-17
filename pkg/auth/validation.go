package auth

import "strings"

// MaxUsernameLength is the default maximum username length
const MaxUsernameLength = 32

// ValidUsername checks if a username is valid
// - Not empty
// - Not too long (maxLen, default 32)
// - No path separators, whitespace, or null bytes
func ValidUsername(u string, maxLen int) bool {
	if maxLen <= 0 {
		maxLen = MaxUsernameLength
	}
	if u == "" || len(u) > maxLen {
		return false
	}
	// Reject path separators, whitespace, and null bytes
	if strings.ContainsAny(u, "/ \t\n\r\x00") {
		return false
	}
	return true
}

// ValidUsernameDefault checks username with default max length
func ValidUsernameDefault(u string) bool {
	return ValidUsername(u, MaxUsernameLength)
}
