
# nftban — Unified Installation & Maintenance Script

> **Version:** 3.0.3 · **License:** MIT · **Language:** Bash · **Platforms:** Linux (Debian/Ubuntu, RHEL/CentOS/Rocky, SUSE, Alpine)

A simple, safe, and repeatable way to install and maintain **nftban** — a minimal firewall toolkit around **nftables** (with optional **fail2ban** integration). This installer focuses on clarity and control: it **never starts or enables services automatically**. You stay in charge.

---

## ✨ Highlights

- **One script, multiple flows**: Sync from **GitHub**, download as **ZIP**, or do a **local/basic** setup.
- **Package manager–aware**: Supports `apt`, `dnf`, `yum`, `zypper`, `apk` and installs: `nftables`, `fail2ban`, `whois`, and the appropriate DNS utilities.
- **Control panel detection**: Auto-suggests sensible defaults for **DirectAdmin**, **cPanel**, **Plesk** — or a clean **generic** web server template.
- **Beginner-friendly** (optional): `--beginner` adds step‑by‑step tips and friendlier messages; `--no-color` and `--no-unicode` available for strict terminals.
- **Auto‑update (opt‑in)**: A small cron helper keeps your working directory synced with the repo (if you want).
- **Clean uninstall**: Remove symlink, unit file, directory; optional `--purge` clears logs/state, too.
- **Status/JSON**: Query installation state and cron status in human or JSON form.

> **Safety by default:** The script **does not** enable or start system services on its own. Review and start them when **you** decide.

---

## 🧰 Requirements

- **Root privileges** (run via `sudo`).
- Linux with one of: `apt`, `dnf`, `yum`, `zypper`, `apk`.
- Network access to GitHub for the `--github` flow; for `--zip`, HTTPS access to download the archive.

---

## 📦 What gets installed

- **Binaries / scripts** under: `/etc/nftban/bin` and `/etc/nftban/scripts`
- **Configuration** under: `/etc/nftban/config`
- **Templates** under: `/etc/nftban/templates`
- **Logs** under: `/var/log/nftban` (symlinked from `/etc/nftban/logs`)
- **Optional**: `/etc/systemd/system/nftban.service` is **copied** if present in the repo, but **not enabled/started**

Directory layout (simplified):

```text
/etc/nftban
├─ bin/
│  └─ nftban                 # placeholder CLI (full features via repo sync)
├─ scripts/                  # helper scripts (init, fail2ban, etc.)
├─ config/                   # your *.conf.local files live here
├─ templates/
│  └─ control-panels/
│     ├─ directadmin.conf
│     ├─ cpanel.conf
│     ├─ plesk.conf
│     └─ generic.conf
├─ rules/ conf.d/ systemd/ ...
└─ logs -> /var/log/nftban    # convenience symlink
```

---

## 🚀 Quick start

> Recommended for most users — pulls the latest repo and guides you.

```bash
curl -fsSL -o nftban_init.sh https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init_userfriendly.sh
chmod +x nftban_init.sh
sudo ./nftban_init.sh --github -y --beginner
```

- `--github` keeps `/etc/nftban` synced with the repo.
- `-y` assumes “yes” on safe prompts (e.g., package installation).
- `--beginner` enables a friendlier, step‑by‑step mode.

If your terminal has issues with colors or emojis, add `--no-color` and/or `--no-unicode`.

---

## ☑️ Installation flows

### 1) GitHub (recommended)
```bash
sudo ./nftban_init.sh --github -y
```
- Requires `git` (installed if missing).
- Gets all scripts/templates and future updates easily.

### 2) ZIP archive
```bash
sudo ./nftban_init.sh --zip -y
```
- No `git` dependency.
- Downloads and verifies `main.zip`, extracts to target.

### 3) Local/basic setup
```bash
sudo ./nftban_init.sh -y
```
- No repo sync; creates structure and installs packages.
- Good for air‑gapped or custom deployments.

Optional common flags:
- `--target /opt/nftban` choose a non-default directory
- `--branch main` change Git branch when using `--github`
- `--skip-cp-detect` skip control panel / generic template prompts

---

## 🧪 Beginner mode & UI options

- `--beginner` enables a short welcome and clearer human messages.
- `--no-color` disables ANSI colors.
- `--no-unicode` switches to ASCII icons.

These change **only** the presentation, not the behavior.

---

## 🧷 CLI options (full list)

```text
--github                  Use Git clone/pull to sync the repository
--zip                     Download and extract main.zip
--target DIR              Install directory (default: /etc/nftban)
--branch NAME             Git branch (default: main)
--skip-cp-detect          Skip control panel detection
--dry-run                 Print actions without changing the system
--quiet                   Suppress INFO logs (still shows WARN/ERROR)
--enable-auto-update      Install cron-based auto-update after setup (opt-in)
--remove-auto-update      Remove previously enabled cron auto-update
--auto-update-status      Show auto-update cron status
--status                  Show overall status summary
--json                    With --status: emit JSON
--daily-time HH:MM        With --enable-auto-update: run daily at HH:MM
--uninstall               Remove nftban (unit, symlink, directory)
--purge                   With --uninstall: also remove logs/state
--beginner                Friendlier, step-by-step messages
--no-color                Disable colored output
--no-unicode              Use plain ASCII icons
-y                        Assume "yes" to prompts
-h, --help                Show help
```

---

## 🧭 Control panel detection & generic template

During installation the script can detect **DirectAdmin**, **cPanel**, or **Plesk**, and will generate initial allow‑lists of ports accordingly. If no panel is found, you can accept a **generic** web server setup:

- **Inbound (TCP)**: `SSH_PORT (detected)`, `80`, `443`
- **Outbound (TCP)**: `53`, `80`, `443`, `123`

You can **always** edit or extend these later.

---

## ⚙️ Configuration files

All user‑customizable files live in `/etc/nftban/config/` and follow a clear naming pattern:

```text
nftban-configuration-ipv4-ports-input-allow.conf.local
nftban-configuration-ipv4-ports-output-allow.conf.local
nftban-configuration-ipv6-ports-input-allow.conf.local
nftban-configuration-ipv6-ports-output-allow.conf.local
nftban-configuration-user-whitelist_ips.conf.local
nftban-configuration-user-blacklist_ips.conf.local (optional)
```

**Port list format** (one per line):
- `80T` → allow TCP/80
- `53U` → allow UDP/53
- `22B` → allow both TCP & UDP/22

**Whitelist format**: one IPv4/IPv6 (or CIDR) per line, e.g.:
```
203.0.113.10
10.0.0.0/8
2001:db8::/32
```

> Tip: There are also non-`.local` templates you can copy from `/etc/nftban/templates/`.

---

## 🧩 Using the `nftban` helper

A placeholder CLI is installed to `/usr/local/bin/nftban` → `/etc/nftban/bin/nftban`. Common commands:

```bash
nftban --help                    # usage help
nftban version                   # show placeholder version
nftban status                    # print nftables status
nftban list                      # list current nftables rules
nftban init                      # run initial nftables configuration script (if present)
nftban reload                    # reload nftables from config (if present)
nftban flush                     # flush all nftables rules (⚠️ prompts you)
```

> Full functionality arrives when syncing the repo (`--github` or `--zip`).

---

## 🔄 Auto‑update (opt‑in)

Enable a small cron job to keep `/etc/nftban` in sync with the repo:

```bash
sudo ./nftban_init.sh --github -y --enable-auto-update           # every 12 hours
sudo ./nftban_init.sh --enable-auto-update --daily-time "03:30"  # daily at 03:30
sudo ./nftban_init.sh --auto-update-status                       # view status
sudo ./nftban_init.sh --remove-auto-update                       # remove
```

> The cron job only syncs files. It **does not** start/enable services.

---

## 🗑️ Uninstall

```bash
sudo ./nftban_init.sh --uninstall -y            # keep logs/state
sudo ./nftban_init.sh --uninstall --purge -y    # also remove /var/log/nftban and /var/lib/nftban
```

What gets removed:
- symlink `/usr/local/bin/nftban`
- unit file `/etc/systemd/system/nftban.service` (if present) — daemon reloaded
- main directory (default `/etc/nftban`)
- auto‑update cron and helper script

> `--purge` additionally removes logs and state directories.

---

## 🧪 Dry‑run & quiet modes

- `--dry-run` prints actions without touching the system — great for review.
- `--quiet` trims INFO logs but keeps WARN/ERROR visible.

---

## 📓 Logging & troubleshooting

- Installer logs: `/var/log/nftban/nftban_init_YYYY-MM-DD-HHMMSS.log`
- Control‑panel detection logs: `/var/log/nftban/cp_detection_*.log`

Common checks:
- `which nft` → ensure `nftables` is installed
- `systemctl status cron|crond` → confirm cron is running for auto‑updates
- `nft list ruleset` → view active rules

---

## 🔐 Security notes

- Always **review** configuration files before enabling firewall rules in production.
- Keep SSH port accessible to your management IPs.
- Consider enabling `fail2ban` jails appropriate to your services.

---

## 🤝 Contributing

Issues and PRs are welcome. Please:
1. Keep bash changes **POSIX‑aware** where possible; shellcheck when you can.
2. Avoid auto‑starting/enabling services in installer logic.
3. Add/update documentation and examples when changing flags or behavior.

---

## 📄 License

MIT License — see `LICENSE` for details.

---

## 🗺️ Roadmap (ideas)

- Optional language toggle (e.g., `--lang el` for Greek messages)
- More ready‑made templates for popular stacks (Mail, DB, etc.)
- Guided hardening profiles for common roles (Web, Mail, DNS)

---

## 🙋 FAQ

**Q: Does the installer start services?**  
A: No. It deliberately avoids enabling/starting anything. You remain in control.

**Q: I don’t use any control panel. What happens?**  
A: You can accept a simple, safe generic profile, or start with empty config files and fill them yourself.

**Q: My terminal doesn’t display emojis or colors well.**  
A: Use `--no-unicode` and/or `--no-color`.

**Q: Where do I put my custom ports and IPs?**  
A: In the `*.conf.local` files under `/etc/nftban/config/`.

