# DirectAdmin test fixtures

Captured from production hosts during v1.79.x soak (2026-04-08/09).

## srv3_login.log

- **Source:** `root@app-node-03.example.test:/var/log/directadmin/login.log`
- **Captured:** 2026-04-09
- **Host:** Ubuntu 22.04 + DirectAdmin
- **Lines:** 30 (9 failed login, 21 successful login)
- **Attacker:** `192.0.2.122` (single source, recurring against `admin`)
- **Date range:** 2026-04-04 to 2026-04-08

This fixture exercises:
- DA's native login.log format: `YYYY:MM:DD-HH:MM:SS: 'IP' N failed login attempts. Account 'USER'`
- Successful-login lines that must be skipped
- The `via 'ACCOUNT'` variant of successful logins
- Single attacker, single target (parity check against `192.0.2.122` / `admin`)

## security.log

Not captured — empty (0 bytes) on a sample host as of 2026-04-09. DA's BFM
(Brute Force Manager) is either not configured to write here or the log
was rotated. Will be added when a real sample becomes available.
