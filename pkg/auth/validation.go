package auth

import "regexp"

// MaxUsernameLength is the default maximum username length
const MaxUsernameLength = 32

// usernameRegex is a strict allowlist for valid usernames
// Allows: letters, numbers, underscore, hyphen only
// This prevents command injection when usernames are passed to shell scripts
var usernameRegex = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

// ValidUsername checks if a username is valid using strict allowlist validation
// - Not empty
// - Not too long (maxLen, default 32)
// - Matches strict allowlist: only letters, numbers, underscore, hyphen
// - Blocks shell metacharacters: ; & | ( ) $ ` < > etc.
//
// SECURITY: This strict validation prevents command injection attacks
// when usernames are passed to any of the shell scripts in the codebase.
func ValidUsername(u string, maxLen int) bool {
	if maxLen <= 0 {
		maxLen = MaxUsernameLength
	}
	if u == "" || len(u) > maxLen {
		return false
	}
	// CRITICAL: Use allowlist regex to block ALL shell metacharacters
	// Previous code only blocked: / \t\n\r\x00
	// This failed to block: ; & | ( ) $ ` < > { } [ ] ' " \ ! # % ^ * = + ~ ?
	// Attack example: username="user;rm -rf /" would pass old validation
	// Now BLOCKED by strict allowlist
	return usernameRegex.MatchString(u)
}

// ValidUsernameDefault checks username with default max length
func ValidUsernameDefault(u string) bool {
	return ValidUsername(u, MaxUsernameLength)
}
