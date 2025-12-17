# NFTBan UI Development Mode

## Problem

The NFTBan Web GUI uses Go's `//go:embed` directive to compile static files (HTML, JavaScript, CSS) directly into the binary. This creates a **single self-contained executable**, which is great for production deployment.

However, during development, this approach requires **rebuilding the entire binary** every time you make changes to HTML, JS, or CSS files. This is time-consuming and frustrating.

## Solution: `--dev` Flag

The `--dev` flag enables **development mode**, which serves static files directly from disk instead of the embedded filesystem. This means:

- ✅ **No rebuild needed** for HTML/JS/CSS changes
- ✅ **Just edit and refresh** your browser
- ✅ **Faster development iteration**
- ✅ **Production builds** still use embedded files (single binary)

## Usage

### Production Mode (Default)

Uses embedded files compiled into the binary:

```bash
./nftban-ui
```

### Development Mode

Serves files from disk (no rebuild needed for HTML/JS/CSS changes):

```bash
./nftban-ui --dev
```

## How It Works

### readFile() Helper Function

```go
func readFile(path string) ([]byte, error) {
    if isDevelopmentMode {
        // Development mode: read from disk
        return os.ReadFile(path)
    }
    // Production mode: read from embedded FS
    return embedFS.ReadFile(path)
}
```

### File Paths

When running in dev mode, files are served from:

```
/root/nftban-dev/cmd/nftban-ui/web/static/
```

You must run `nftban-ui --dev` from the directory containing the `web/` folder.

## Development Workflow

### 1. Build Once

```bash
cd /root/nftban-dev/cmd/nftban-ui
CGO_ENABLED=1 go build -o nftban-ui .
```

### 2. Run in Dev Mode

```bash
./nftban-ui --dev
```

You'll see:
```
[DEV MODE] Serving files from disk (cmd/nftban-ui/web/) - No rebuild needed for HTML/JS/CSS changes!
```

### 3. Edit HTML/JS/CSS Files

```bash
# Edit any file in web/static/
vim web/static/pages/portscan.html
vim web/static/js/page-loader.js
vim web/static/css/nftban-modern.css
```

### 4. Refresh Browser

Just hit **F5** or **Ctrl+Shift+R** (hard refresh) - changes appear immediately!

### 5. When Done: Production Build

Before deploying to production, rebuild without `--dev` to embed files:

```bash
CGO_ENABLED=1 go build -o nftban-ui .
# Files are now embedded in the binary
```

## Files Using Dev Mode

The following handlers support dev mode:

- `/` and `/index.html` - Main page
- `/static/pages/*.html` - Modular pages (dashboard, portscan, ddos, fail2ban, etc.)
- `/static/js/page-loader.js` - Dynamic page loader

## Security Considerations

### File Permissions (FHS Compliance)

All files maintain proper FHS permissions:

```bash
# Files owned by nftban user/group
chown -R nftban:nftban /root/nftban-dev/cmd/nftban-ui/web/

# Secure permissions
chmod 755 /root/nftban-dev/cmd/nftban-ui/web/
chmod 644 /root/nftban-dev/cmd/nftban-ui/web/static/**/*
```

### Production Deployment

**IMPORTANT:** Never use `--dev` in production!

- ✅ Production: Embedded files (single binary, no disk access)
- ❌ Development: Disk files (requires source directory)

## Benefits

### Before (Embedded Only)

```bash
# Edit HTML file
vim web/static/pages/portscan.html

# Rebuild (slow!)
go build -o nftban-ui .     # ~10-30 seconds

# Deploy
systemctl restart nftban-ui

# Repeat for every change 😫
```

### After (With --dev Flag)

```bash
# Build ONCE
go build -o nftban-ui .

# Run in dev mode
./nftban-ui --dev

# Edit HTML file
vim web/static/pages/portscan.html

# Refresh browser (instant!)  # ✨ No rebuild needed! ✨

# Repeat edits as many times as needed 😊
```

## Examples

### Editing Portscan Page

```bash
# 1. Start dev mode
cd /root/nftban-dev/cmd/nftban-ui
./nftban-ui --dev

# 2. Edit portscan page
vim web/static/pages/portscan.html

# 3. Save and refresh browser
# Changes appear immediately!

# 4. Edit page loader
vim web/static/js/page-loader.js

# 5. Refresh again
# Changes appear immediately!
```

### Switching Between Modes

```bash
# Development mode (read from disk)
./nftban-ui --dev

# Production mode (read from embedded FS)
./nftban-ui
```

## Troubleshooting

### Files Not Updating

**Problem:** Changes don't appear after browser refresh

**Solution:** Hard refresh (Ctrl+Shift+R) to bypass browser cache

### 404 Not Found

**Problem:** Static files return 404 errors

**Solution:** Ensure you're running from the directory containing `web/`:

```bash
cd /root/nftban-dev/cmd/nftban-ui
./nftban-ui --dev
```

### Permission Denied

**Problem:** Cannot read files from disk

**Solution:** Check file permissions:

```bash
chmod 644 web/static/pages/*.html
chmod 755 web/static/pages/
```

## Systemd Service with Dev Mode

To run the systemd service in dev mode:

```bash
# Edit service file
vim /etc/systemd/system/nftban-ui.service

# Change ExecStart to:
ExecStart=/usr/sbin/nftban-ui --dev

# But ensure WorkingDirectory is set:
WorkingDirectory=/root/nftban-dev/cmd/nftban-ui

# Reload and restart
systemctl daemon-reload
systemctl restart nftban-ui
```

**⚠️ WARNING:** Only use this for development servers, never in production!

## Summary

| Feature | Production Mode | Development Mode |
|---------|----------------|------------------|
| **Command** | `./nftban-ui` | `./nftban-ui --dev` |
| **File Source** | Embedded in binary | Read from disk |
| **Rebuild Needed** | Yes (for every change) | No (just refresh browser) |
| **Performance** | Faster (embedded) | Slightly slower (disk I/O) |
| **Deployment** | Single binary | Requires source directory |
| **Use Case** | Production | Development |

## Related Files

- `cmd/nftban-ui/main.go` - Contains `readFile()` helper and `--dev` flag
- `cmd/nftban-ui/web/static/pages/*.html` - Modular HTML pages
- `cmd/nftban-ui/web/static/js/page-loader.js` - Dynamic page loader
- `cmd/nftban-ui/web/static/index.html` - Main entry point

## Questions?

See commit message for implementation details:
```
feat(ui): Add --dev flag to avoid rebuilds for HTML/JS/CSS changes
```

Resolves: "why to be build?" development pain point
