# Deprecated Installer Files

This directory contains deprecated installer scripts that have been replaced by the modular installer system.

## Deprecated Files

### nftban_installer.sh (v7.0.0 standalone)
- **Status:** Deprecated
- **Replacement:** Use `installer_main.sh` or `nftban_installer_modular.sh` (bootstrap)
- **Reason:** Monolithic script superseded by modular architecture
- **Date Deprecated:** 2025-10-17

## Current Installation Methods

### Recommended: Modular Installer
```bash
sudo bash lib/installer/installer_main.sh install
```

### Alternative: Bootstrap Wrapper
```bash
sudo bash lib/installer/nftban_installer_modular.sh install
```

## Why These Were Deprecated

The standalone `nftban_installer.sh` was a 1000+ line monolithic script that duplicated functionality now available in the modular installer system. The modular approach provides:

1. Better maintainability - each module has single responsibility
2. Easier testing - modules can be tested independently
3. Reduced duplication - shared logic in `installer_core.sh`
4. Cleaner architecture - follows separation of concerns

## Migration Notes

If you have scripts that call `nftban_installer.sh`, update them to use:
```bash
sudo bash lib/installer/installer_main.sh install
```

All functionality from the standalone installer is available in the modular system.
