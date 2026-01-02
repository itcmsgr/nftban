// NFTBan Web GUI - Common Functions
// SPDX-License-Identifier: GPL-3.0-or-later

// API wrapper with session token
const API = {
    call: async function(endpoint, options = {}) {
        const defaultOptions = {
            headers: {
                'X-Session-Token': Session.get(),
                'Content-Type': 'application/json'
            }
        };

        const response = await fetch('/api/v1' + endpoint, {
            ...defaultOptions,
            ...options,
            headers: { ...defaultOptions.headers, ...options.headers }
        });

        // Handle session expiration
        if (response.status === 401) {
            Session.clear();
            window.location.href = '/index.html';
            return null;
        }

        if (!response.ok) {
            throw new Error(`API error: ${response.status} ${response.statusText}`);
        }

        return response.json();
    },

    get: function(endpoint) {
        return this.call(endpoint, { method: 'GET' });
    },

    post: function(endpoint, data) {
        return this.call(endpoint, {
            method: 'POST',
            body: JSON.stringify(data)
        });
    }
};

// Auto-refresh helper
function autoRefresh(callback, intervalSeconds) {
    callback(); // Initial load
    return setInterval(callback, intervalSeconds * 1000);
}

// Format uptime (seconds to human readable)
function formatUptime(seconds) {
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const mins = Math.floor((seconds % 3600) / 60);

    if (days > 0) {
        return `${days}d ${hours}h ${mins}m`;
    } else if (hours > 0) {
        return `${hours}h ${mins}m`;
    } else {
        return `${mins}m`;
    }
}

// Format number with thousands separator
function formatNumber(num) {
    return num.toLocaleString();
}

// Show notification
function showNotification(message, type = 'info') {
    const notif = document.createElement('div');
    notif.className = `notification notification-${type}`;
    notif.textContent = message;
    notif.setAttribute('role', 'alert');
    notif.setAttribute('aria-live', 'polite');
    document.body.appendChild(notif);

    setTimeout(() => {
        notif.classList.add('fade-out');
        setTimeout(() => notif.remove(), 300);
    }, 3000);
}

// Error handler
function handleError(error, userMessage = 'An error occurred') {
    console.error('Error:', error);
    showNotification(userMessage, 'error');
}
