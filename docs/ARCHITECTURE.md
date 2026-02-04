# NFTBan Architecture

## Binary Distribution Architecture

### nftband (Core IPC Daemon)
- **Built by**: `build.sh` (line 236-248)
- **Installed by**: `install.sh` (line 1047-1065)
- **Location**: `/usr/lib/nftban/bin/nftband`
- **Package**: Part of CORE installation, NOT nftban-ui package

### nftban-ui (Web GUI)
- **Built by**: `packaging/deb/rules` or `packaging/rpm/nftban-ui.spec`
- **Package**: Separate optional package
- **Depends on**: nftband (from core) must be installed first

### Why DEB rules doesn't build nftband
The DEB `nftban-ui` package is GUI-only. nftband is installed by:
1. Direct install via `install.sh` (recommended)
2. Future `nftban-core` package (planned)

This is intentional separation of concerns - UI package depends on core being installed.
