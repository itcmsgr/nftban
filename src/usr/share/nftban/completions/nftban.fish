# Fish completion for nftban
# Install to: /usr/share/fish/vendor_completions.d/nftban.fish

# Main commands
complete -c nftban -f -n "__fish_use_subcommand" -a status -d "Show system status"
complete -c nftban -f -n "__fish_use_subcommand" -a version -d "Show version information"
complete -c nftban -f -n "__fish_use_subcommand" -a help -d "Show help message"
complete -c nftban -f -n "__fish_use_subcommand" -a init -d "Initialize NFTBan"
complete -c nftban -f -n "__fish_use_subcommand" -a feeds -d "Manage threat feeds"
complete -c nftban -f -n "__fish_use_subcommand" -a fail2ban -d "Manage Fail2ban integration"
complete -c nftban -f -n "__fish_use_subcommand" -a geoip -d "Manage GeoIP blocking"
complete -c nftban -f -n "__fish_use_subcommand" -a whitelist -d "Manage IP whitelist"
complete -c nftban -f -n "__fish_use_subcommand" -a stats -d "Show statistics"
complete -c nftban -f -n "__fish_use_subcommand" -a reports -d "Generate reports"
complete -c nftban -f -n "__fish_use_subcommand" -a maintain -d "Run maintenance"

# feeds subcommands
complete -c nftban -f -n "__fish_seen_subcommand_from feeds" -a update -d "Update feeds"
complete -c nftban -f -n "__fish_seen_subcommand_from feeds" -a list -d "List feeds"
complete -c nftban -f -n "__fish_seen_subcommand_from feeds" -a enable -d "Enable feed"
complete -c nftban -f -n "__fish_seen_subcommand_from feeds" -a disable -d "Disable feed"
complete -c nftban -f -n "__fish_seen_subcommand_from feeds" -a status -d "Show feed status"

# fail2ban subcommands
complete -c nftban -f -n "__fish_seen_subcommand_from fail2ban" -a status -d "Show status"
complete -c nftban -f -n "__fish_seen_subcommand_from fail2ban" -a enable -d "Enable jail"
complete -c nftban -f -n "__fish_seen_subcommand_from fail2ban" -a disable -d "Disable jail"
complete -c nftban -f -n "__fish_seen_subcommand_from fail2ban" -a jails -d "List jails"

# geoip subcommands
complete -c nftban -f -n "__fish_seen_subcommand_from geoip" -a update -d "Update database"
complete -c nftban -f -n "__fish_seen_subcommand_from geoip" -a status -d "Show status"
complete -c nftban -f -n "__fish_seen_subcommand_from geoip" -a block -d "Block country"
complete -c nftban -f -n "__fish_seen_subcommand_from geoip" -a allow -d "Allow country"
complete -c nftban -f -n "__fish_seen_subcommand_from geoip" -a list -d "List rules"

# whitelist subcommands
complete -c nftban -f -n "__fish_seen_subcommand_from whitelist" -a add -d "Add IP"
complete -c nftban -f -n "__fish_seen_subcommand_from whitelist" -a remove -d "Remove IP"
complete -c nftban -f -n "__fish_seen_subcommand_from whitelist" -a list -d "List IPs"
complete -c nftban -f -n "__fish_seen_subcommand_from whitelist" -a show -d "Show whitelist"

# stats subcommands
complete -c nftban -f -n "__fish_seen_subcommand_from stats" -a show -d "Show statistics"
complete -c nftban -f -n "__fish_seen_subcommand_from stats" -a update -d "Update stats"
complete -c nftban -f -n "__fish_seen_subcommand_from stats" -a export -d "Export stats"

# reports subcommands
complete -c nftban -f -n "__fish_seen_subcommand_from reports" -a daily -d "Generate daily report"
complete -c nftban -f -n "__fish_seen_subcommand_from reports" -a weekly -d "Generate weekly report"
complete -c nftban -f -n "__fish_seen_subcommand_from reports" -a monthly -d "Generate monthly report"
complete -c nftban -f -n "__fish_seen_subcommand_from reports" -a generate -d "Generate custom report"
