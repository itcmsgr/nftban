// =============================================================================
// NFTBan - GOTH GUI Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="goth"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-15"
// meta:description="HTTP handlers for GOTH GUI (Go + Templ + HTMX)"
// meta:input="HTTP requests"
// meta:output="HTML responses via Templ"
// meta:depends="github.com/a-h/templ,github.com/itcmsgr/nftban/internal/ui"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package handlers

import (
	"log"
	"net/http"
	"os/exec"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/ui"
	"github.com/itcmsgr/nftban/internal/ui/fragments"
	"github.com/itcmsgr/nftban/internal/ui/pages"
	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/session"
)

// GOTHHandlers holds dependencies for GOTH UI handlers
type GOTHHandlers struct {
	Auth         *auth.PAMAuth
	SessionStore *session.Store
}

// NewGOTHHandlers creates a new GOTHHandlers instance
func NewGOTHHandlers(authService *auth.PAMAuth, sessionStore *session.Store) *GOTHHandlers {
	return &GOTHHandlers{
		Auth:         authService,
		SessionStore: sessionStore,
	}
}

// =============================================================================
// PAGE HANDLERS
// =============================================================================

// HandleLogin renders the login page
func (h *GOTHHandlers) HandleLogin(w http.ResponseWriter, r *http.Request) {
	// If already logged in, redirect to dashboard
	if cookie, err := r.Cookie("session_id"); err == nil {
		if _, err := h.SessionStore.Get(cookie.Value); err == nil {
			http.Redirect(w, r, "/ui/", http.StatusSeeOther)
			return
		}
	}

	errorMsg := r.URL.Query().Get("error")
	pages.Login(errorMsg).Render(r.Context(), w)
}

// HandleDashboard renders the dashboard page
func (h *GOTHHandlers) HandleDashboard(w http.ResponseWriter, r *http.Request) {
	summary := h.getSummaryData()
	pages.Dashboard(summary).Render(r.Context(), w)
}

// =============================================================================
// FRAGMENT HANDLERS (HTMX partial updates)
// =============================================================================

// HandleFragSummary returns the summary cards fragment for HTMX refresh
func (h *GOTHHandlers) HandleFragSummary(w http.ResponseWriter, r *http.Request) {
	summary := h.getSummaryData()
	fragments.SummaryCards(summary).Render(r.Context(), w)
}

// =============================================================================
// ACTION HANDLERS (Form submissions)
// =============================================================================

// HandleActionLogin processes login form submission
func (h *GOTHHandlers) HandleActionLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
		return
	}

	username := r.FormValue("username")
	password := r.FormValue("password")

	// Authenticate via PAM (through Unix socket to nftban-ui-auth)
	user, err := h.Auth.Authenticate(username, password)
	if err != nil {
		log.Printf("[GOTH] Login failed for user %s: %v", username, err)
		http.Redirect(w, r, "/ui/login?error=Invalid+credentials", http.StatusSeeOther)
		return
	}

	// Get client IP
	clientIP := r.RemoteAddr
	if forwarded := r.Header.Get("X-Forwarded-For"); forwarded != "" {
		clientIP = forwarded
	}

	// Create session
	sess, err := h.SessionStore.Create(user.Username, user.Groups, clientIP)
	if err != nil {
		log.Printf("[GOTH] Failed to create session for user %s: %v", username, err)
		http.Redirect(w, r, "/ui/login?error=Session+error", http.StatusSeeOther)
		return
	}

	// Set session cookie
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    sess.Token,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteStrictMode,
	})

	log.Printf("[GOTH] User %s logged in successfully", username)
	http.Redirect(w, r, "/ui/", http.StatusSeeOther)
}

// HandleActionLogout processes logout
func (h *GOTHHandlers) HandleActionLogout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("session_id"); err == nil {
		h.SessionStore.Delete(cookie.Value)
	}

	// Clear cookie
	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		MaxAge:   -1,
	})

	http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
}

// =============================================================================
// MIDDLEWARE
// =============================================================================

// RequireSession middleware ensures user is authenticated
func (h *GOTHHandlers) RequireSession(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session_id")
		if err != nil {
			http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
			return
		}

		if _, err := h.SessionStore.Get(cookie.Value); err != nil {
			http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
			return
		}

		next(w, r)
	}
}

// =============================================================================
// HELPERS
// =============================================================================

// getSummaryData fetches current statistics by calling nftban CLI
func (h *GOTHHandlers) getSummaryData() ui.SummaryData {
	summary := ui.SummaryData{}

	// Get active bans count
	if output, err := execNFTBanCommand("count"); err == nil {
		if count, err := strconv.Atoi(strings.TrimSpace(output)); err == nil {
			summary.ActiveBans = count
		}
	}

	// Get whitelist count
	if output, err := execNFTBanCommand("whitelist", "count"); err == nil {
		if count, err := strconv.Atoi(strings.TrimSpace(output)); err == nil {
			summary.WhitelistCount = count
		}
	}

	// Get modules status (count enabled)
	if output, err := execNFTBanCommand("module", "list", "--enabled"); err == nil {
		lines := strings.Split(strings.TrimSpace(output), "\n")
		summary.ModulesUp = len(lines)
	}

	// Events last hour - placeholder for now
	summary.EventsLastHour = 0

	return summary
}

// execNFTBanCommand executes an nftban CLI command
func execNFTBanCommand(args ...string) (string, error) {
	cmd := exec.Command("nftban", args...)
	output, err := cmd.CombinedOutput()
	return string(output), err
}
