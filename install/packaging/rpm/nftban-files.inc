# =============================================================================
# NFTBan RPM %files include
# =============================================================================
# Generated from build/fhs-spec.yaml - DO NOT EDIT
#
# Include in nftban.spec: %include nftban-files.inc
#
# Note: This file contains %dir entries with proper %attr() for directories
#       that are created by the package. Directories marked created_by=tmpfiles
#       are NOT listed here (they are created by systemd-tmpfiles at runtime).
# =============================================================================

# ---------------------------------------------------------------------------
# SYSTEM DIRECTORIES (root:root)
# ---------------------------------------------------------------------------
%dir %attr(0755,root,root) /usr/lib/nftban
%dir %attr(0755,root,root) /usr/lib/nftban/core
%dir %attr(0755,root,root) /usr/lib/nftban/cli
%dir %attr(0755,root,root) /usr/lib/nftban/lib
%dir %attr(0755,root,root) /usr/lib/nftban/bin
%dir %attr(0755,root,root) /usr/lib/nftban/exporters
%dir %attr(0755,root,root) /usr/lib/nftban/setup
%dir %attr(0755,root,root) /usr/lib/nftban/tests
%dir %attr(0755,root,root) /usr/lib/nftban/helpers
%dir %attr(0755,root,root) /usr/lib/nftban/cron
%dir %attr(0755,root,root) /usr/lib/nftban/modules
%dir %attr(0755,root,root) /usr/lib/nftban/sbin
%dir %attr(0755,root,root) /usr/lib/nftban/health
%dir %attr(0755,root,root) /usr/lib/nftban/data
%dir %attr(0755,root,root) /usr/lib/nftban/tools

# ---------------------------------------------------------------------------
# CONFIGURATION DIRECTORIES (root:nftban)
# ---------------------------------------------------------------------------
%dir %attr(0750,root,nftban) /etc/nftban
%dir %attr(0750,root,nftban) /etc/nftban/conf.d
%dir %attr(0750,root,nftban) /etc/nftban/conf.d/ddos
%dir %attr(0750,root,nftban) /etc/nftban/conf.d/portscan
%dir %attr(0750,root,nftban) /etc/nftban/conf.d/login
%dir %attr(0750,root,nftban) /etc/nftban/conf.d/panels
%dir %attr(0750,root,nftban) /etc/nftban/conf.d/botscan
%dir %attr(0750,root,nftban) /etc/nftban/conf.d/botguard
%dir %attr(0750,root,nftban) /etc/nftban/patterns.d
%dir %attr(0750,root,nftban) /etc/nftban/patterns.d/botscan
%dir %attr(0750,root,nftban) /etc/nftban/whitelist.d
%dir %attr(0750,root,nftban) /etc/nftban/blacklist.d
%dir %attr(0750,root,nftban) /etc/nftban/ports.d
%dir %attr(0750,root,nftban) /etc/nftban/rules.d
%dir %attr(0750,root,nftban) /etc/nftban/connectors
%dir %attr(0755,root,root) /etc/nftban/distros

# ---------------------------------------------------------------------------
# SHARED DATA DIRECTORIES (root:root)
# ---------------------------------------------------------------------------
%dir %attr(0755,root,root) /usr/share/nftban
%dir %attr(0755,root,root) /usr/share/nftban/templates
%dir %attr(0755,root,root) /usr/share/nftban/templates/mail
%dir %attr(0755,root,root) /usr/share/nftban/templates/reports
%dir %attr(0755,root,root) /usr/share/nftban/templates/zabbix
%dir %attr(0755,root,root) /usr/share/nftban/dashboards
%dir %attr(0755,root,root) /usr/share/nftban/dashboards/grafana
%dir %attr(0755,root,root) /usr/share/nftban/specs
