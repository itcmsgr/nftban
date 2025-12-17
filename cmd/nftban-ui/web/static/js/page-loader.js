/**
 * NFTBan Dynamic Page Loader
 * Loads modular HTML pages asynchronously
 */

// Current loaded page
let currentPage = 'dashboard';

// Content container
const contentContainer = document.querySelector('.wrapper');

/**
 * Load a page dynamically
 * @param {string} pageName - Name of the page to load (dashboard, feeds, fail2ban, etc.)
 */
async function loadPage(pageName) {
    if (!contentContainer) {
        console.error('Content container not found');
        return;
    }

    try {
        // Show loading indicator
        contentContainer.innerHTML = '<div class="bg-white main-border rad-10 p-20 text-center"><i class="fa-solid fa-spinner fa-spin fa-2x c-blue"></i><p class="mt-10">Loading...</p></div>';

        // Fetch the page with cache-busting timestamp
        const cacheBuster = new Date().getTime();
        const response = await fetch(`/static/pages/${pageName}.html?v=${cacheBuster}`);

        if (!response.ok) {
            throw new Error(`Failed to load page: ${response.statusText}`);
        }

        const html = await response.text();

        // Load the content
        contentContainer.innerHTML = html;

        // Execute inline scripts (innerHTML doesn't execute them automatically)
        const scripts = contentContainer.querySelectorAll('script');
        scripts.forEach(oldScript => {
            const newScript = document.createElement('script');
            // Copy attributes
            Array.from(oldScript.attributes).forEach(attr => {
                newScript.setAttribute(attr.name, attr.value);
            });
            // Copy content
            newScript.textContent = oldScript.textContent;
            // Replace old script with new one to trigger execution
            oldScript.parentNode.replaceChild(newScript, oldScript);
        });

        // Update current page
        currentPage = pageName;

        // Update active menu item
        updateActiveMenu(pageName);

        // Execute page-specific initialization after DOM is ready
        // Use setTimeout to ensure DOM elements are accessible
        setTimeout(() => {
            initializePage(pageName);
        }, 100);

        console.log(`✅ Loaded page: ${pageName}`);
    } catch (error) {
        console.error(`Error loading page ${pageName}:`, error);
        contentContainer.innerHTML = `
            <div class="bg-white main-border rad-10 p-20 text-center">
                <i class="fa-solid fa-triangle-exclamation fa-2x c-red"></i>
                <h3 class="fs-15 fw-bold mt-10 c-red">Error Loading Page</h3>
                <p class="mt-10 c-grey">${error.message}</p>
                <button onclick="loadPage('${pageName}')" class="mt-10 px-20 p-10 bg-blue c-white rad-6">
                    <i class="fa-solid fa-rotate"></i> Retry
                </button>
            </div>
        `;
    }
}

/**
 * Update active menu item
 */
function updateActiveMenu(pageName) {
    // Remove active class from all menu items
    document.querySelectorAll('.sidebar ul li').forEach(item => {
        item.classList.remove('menu-item-active');
    });

    // Add active class to current menu item
    const menuItem = document.querySelector(`.sidebar ul li[onclick*="'${pageName}'"]`);
    if (menuItem) {
        menuItem.classList.add('menu-item-active');
    }
}

/**
 * Initialize page-specific functionality
 */
function initializePage(pageName) {
    switch(pageName) {
        case 'dashboard':
            // Initialize dashboard stats and charts
            if (typeof loadDashboardStats === 'function') {
                loadDashboardStats();
                console.log('✅ Loaded dashboard stats');
            }
            if (typeof initDashboardCharts === 'function') {
                initDashboardCharts();
                console.log('✅ Initialized dashboard charts');
            }
            // Start auto-refresh for dashboard
            if (typeof startDashboardRefresh === 'function') {
                startDashboardRefresh(30); // 30 seconds
            }
            break;

        case 'feeds':
            // Initialize feeds loading
            if (typeof loadFeeds === 'function') {
                loadFeeds();
            }
            if (typeof updateFeedsCount === 'function') {
                updateFeedsCount();
            }
            break;

        case 'fail2ban':
            // Initialize fail2ban jails loading
            if (typeof loadF2BJails === 'function') {
                loadF2BJails();
            }
            break;

        case 'portscan':
        case 'ddos':
            // These pages have inline scripts that auto-execute after being loaded
            console.log(`✅ Page ${pageName} scripts will auto-execute`);
            break;

        default:
            console.log(`No specific initialization for: ${pageName}`);
    }
}

/**
 * Navigation wrapper function for menu clicks
 */
function navigateToPage(pageName) {
    loadPage(pageName);
}

// Load dashboard on page load
document.addEventListener('DOMContentLoaded', () => {
    console.log('🚀 NFTBan Dynamic Page Loader initialized');
    loadPage('dashboard');
});
