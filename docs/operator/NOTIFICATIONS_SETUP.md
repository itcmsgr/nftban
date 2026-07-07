# Notifications setup (email alerts)

As of v1.218.1, `nftban health` reports a named **Communication (central-comms)** component. This
page explains the one warning a first-time operator is most likely to see there and how to resolve
it.

## Why the warning appears

`nftban health` may show:

```
  Communication:       WARN  (COMMUNICATION_CONFIG_MISSING_RECIPIENT: no recipient resolves ...)
                       Impact: alert notifications are generated but cannot be delivered.
                       Fix:    nftban mail setup <your-email>
                       Verify: nftban mail test   then   nftban health
```

This means an alert producer is enabled (for example email-delivered scheduled reports, RBL
reputation alerts, tunnel alerts, or `MAIL_ENABLED=true`) but **no recipient address resolves**, so
NFTBan has nowhere to send the notifications it generates.

The warning never fails firewall or security posture — bans and rules are unaffected. It only
reports that outbound notifications cannot be delivered.

## One-command setup

```
nftban mail setup you@example.com
```

This writes the recipient to `mail.conf.local` (your durable override). Add `--all` to route all
alert categories to that address, and `--test` to send a test message as part of setup:

```
nftban mail setup you@example.com --all --test
```

To review the current mail configuration without changing it:

```
nftban mail setup --show
```

## Verification

```
nftban mail test      # attempt a delivery and report the outcome
nftban health         # the Communication component should now read CLEAN
```

## No local mail server?

A local MTA (Postfix/Exim/Sendmail) is **not required**. If `nftban health` adds:

```
                       Note:   no local mail transport — 'mail setup' can use SMTP (curl); no local MTA required.
```

then configure an SMTP relay in `mail.conf.local` (host, port, credentials). NFTBan sends over SMTP
directly with `curl`; no mail daemon needs to run on the host.

## Disk-only reports — no action required

If you generate reports only to disk (the default scheduled report writes to
`<data>/reports` and does **not** email), the Communication component reports:

```
  Communication:       INFO  (NOT CONFIGURED — no outbound alert transport configured; ...)
                       (no action required — no enabled alert producer needs email delivery)
```

This is the expected state when nothing is configured to send email. No recipient is needed, and no
setup is required. A report becomes an email producer only when it is configured for email delivery
(an explicit report recipient, or a report timer whose service runs with `--email`) — generating
reports to disk alone does not.
