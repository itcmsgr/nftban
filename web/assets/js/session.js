// NFTBan Web GUI - Session Management
// SPDX-License-Identifier: GPL-3.0-or-later

const Session = {
    get: function() {
        return localStorage.getItem('nftban_session_token');
    },

    set: function(token) {
        localStorage.setItem('nftban_session_token', token);
    },

    clear: function() {
        localStorage.removeItem('nftban_session_token');
        localStorage.removeItem('nftban_username');
        localStorage.removeItem('nftban_role');
    },

    setUser: function(username, role) {
        localStorage.setItem('nftban_username', username);
        localStorage.setItem('nftban_role', role);
    },

    getUser: function() {
        return {
            username: localStorage.getItem('nftban_username'),
            role: localStorage.getItem('nftban_role')
        };
    },

    isValid: function() {
        return this.get() !== null;
    }
};

// Redirect to login if no valid session (except on login page)
if (!Session.isValid() && !window.location.pathname.match(/\/?(index\.html)?$/)) {
    window.location.href = '/index.html';
}

// Global logout function
function logout() {
    fetch('/api/v1/logout', {
        method: 'POST',
        headers: {
            'X-Session-Token': Session.get()
        }
    }).finally(() => {
        Session.clear();
        window.location.href = '/index.html';
    });
}
