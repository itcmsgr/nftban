# NFTBan Bash Completion

Tab completion for nftban commands - type `nftban <TAB>` to auto-complete commands and subcommands.

## Features

- Complete main commands (whitelist, blacklist, geo, feeds, cloudflare, stats, etc.)
- Complete subcommands for each main command
- Smart context-aware completion (e.g., feed IDs for `nftban feeds enable <TAB>`)

## Quick Install

### Automatic (via installer - coming in v0.9.1)
```bash
# Will be integrated into main installer in next version
bash lib/installer/installer_main.sh install
```

### Manual Installation

```bash
# Copy completion script to system directory
sudo cp completions/nftban-completion.bash /usr/share/bash-completion/completions/nftban

# OR for older systems:
sudo cp completions/nftban-completion.bash /etc/bash_completion.d/nftban

# Source it in current shell
source /usr/share/bash-completion/completions/nftban
```

## Usage Examples

```bash
# Type and press TAB to see all main commands
nftban <TAB>

# Complete whitelist subcommands
nftban whitelist <TAB>

# Complete cloudflare actions
nftban cloudflare <TAB>

# Complete geo subcommands
nftban geo <TAB>

# Feeds with provider ID suggestions
nftban feeds enable <TAB>
```

## Supported Commands

### Main Commands
- whitelist, blacklist, ban, unban
- geo, feeds, cloudflare
- stats, monitor, login
- port, rate, ddos, portscan
- search, verify
- init, status, update, sync, maintenance
- version, help

### Subcommands
Each command has context-aware subcommand completion. Try it out!

## Troubleshooting

**Completion not working?**
1. Check bash-completion is installed:
   ```bash
   # RHEL/CentOS/Fedora
   sudo dnf install bash-completion

   # Debian/Ubuntu
   sudo apt install bash-completion
   ```

2. Restart your shell or source bashrc:
   ```bash
   source ~/.bashrc
   ```

3. Manually load the completion:
   ```bash
   source /usr/share/bash-completion/completions/nftban
   ```

**Still not working?**
- Verify file exists: `ls -la /usr/share/bash-completion/completions/nftban`
- Check permissions: Should be 644 and readable
- Test completion function: `type _nftban_completion`

## Development

To add new commands:
1. Edit `completions/nftban-completion.bash`
2. Add command to `main_commands` list
3. Add subcommands to relevant `*_cmds` variable
4. Add case statement for subcommand completion
5. Test with `source completions/nftban-completion.bash`

## Notes

- Completion works for both `nftban` and `nft-ban` (if that variant exists)
- Country codes, feed IDs, and other context-specific completions are pre-populated
- Completion is non-intrusive - if not installed, nftban works normally
