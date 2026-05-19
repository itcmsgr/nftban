# Upgrading from v1.120.0 or Earlier to v1.121.0+

## TL;DR

Use bare version syntax when upgrading from v1.120.0 or earlier:

```
nftban update github 1.121.0
```

Not:

```
nftban update github v1.121.0
```

The leading-v form is rejected by the updater on v1.120.0 and earlier.
After the upgrade to v1.121.0+ lands, both forms (`1.X.Y` and `v1.X.Y`
and `V1.X.Y`) are accepted.

## Why

`nftban update github [VERSION]` validates the version argument against
a strict regex before doing anything else. Prior to v1.121.0 the regex
was `^[0-9]+\.[0-9]+\.[0-9]+$` — that rejects a leading `v` or `V`.

v1.121.0 (PR #639) added a normalization step in
`cli/lib/nftban/cli/cmd_update_methods.sh` that strips an optional
leading `v` or `V` before the regex runs, so post-V121 the user-facing
input is more forgiving.

The self-bootstrapping aspect: the fix lives in v1.121.0 itself, so a
host at v1.113.0 (or any version through v1.120.0) does not yet have
the leading-v strip. The bare-format invocation is the only path that
works for the first jump.

## What happens if you use the leading-v form anyway

The updater fails fast — before any package transition:

```
$ nftban update github v1.121.0
  Acquiring update lock...
  Lock acquired
  === Update started on <host> ===
  ...
  Creating backup...
  ✓ Backup: nftban-1.113.0-<timestamp>
  ✗ Invalid version format: 'v1.121.0' (expected: N.N.N)
  ✗ === Update failed: <version> (4s) ===
```

Exit code 1. No RPM/DEB transition happens. The pre-upgrade backup is
created and retained. Re-invoke with the bare form and the upgrade
proceeds.

## Gate-authorized fallback (operator-only)

If the pre-package-transition failure is recorded as a finding under
an operator-authorized fleet rollout gate, direct dnf/apt install of
the release asset is the documented escape hatch:

```
# RPM hosts
dnf install -y https://github.com/itcmsgr/nftban/releases/download/v1.121.0/nftban-el9-x86_64.rpm

# DEB hosts
NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive \
  apt-get install -y ./nftban-ubuntu22.04-amd64.deb
```

Bypasses the `nftban update` lifecycle (no automatic
firewall-rebuild scheduling, no update-hook scripts). Should only be
used under explicit gate authorization with the pre-transition
failure recorded.

## Post-V121 behavior

Once a host is at v1.121.0+, all four input forms work:

```
nftban update github 1.122.0
nftban update github v1.122.0
nftban update github V1.122.0
nftban update github 1.122.0      # also works
```

The downstream strict regex is preserved (just runs after the
optional leading-letter strip). Inputs like `not-a-version`,
`latest`, or `1.122` (two-part) remain rejected.

## Companion: operator-curated CSF config preservation

The companion document
[`docs/operator/CSF_REMOVAL_AND_TAKEOVER.md`](CSF_REMOVAL_AND_TAKEOVER.md)
recommends the codified `nftban firewall takeover --panel-auto-takeover`
path for disarming CSF before upgrade. If your local operator
sequence diverges and reaches `da build remove_csf`, note that the
DirectAdmin command **deletes `/etc/csf/csf.allow` and
`/etc/csf/csf.deny`** as part of its full removal pass. If you have
operator-curated entries in those files you may want to re-arm CSF
later, back them up first:

```
mkdir -p /var/lib/nftban/state/operator-csf-backup-$(date -u +%Y%m%dT%H%M%SZ)
cp -p /etc/csf/csf.allow /etc/csf/csf.deny \
   /var/lib/nftban/state/operator-csf-backup-$(date -u +%Y%m%dT%H%M%SZ)/
```

These files are NOT recreated by `da build set csf yes && da build csf`
— that command re-fetches CSF from upstream and writes default
configurations. Operator entries must be restored from your backup.

The codified takeover path (`nftban firewall takeover`) preserves
`/etc/csf/` byte-equivalent and avoids this issue entirely, but is a
disarm (reversible) rather than a remove (over-removal).

## Code references

| Component | File | Note |
|-----------|------|------|
| Version-string normalization (PR #639) | `cli/lib/nftban/cli/cmd_update_methods.sh` | strips leading `v` / `V` |
| Strict regex (preserved post-strip) | `cli/lib/nftban/cli/cmd_update_methods.sh` | `^[0-9]+\.[0-9]+\.[0-9]+$` |
| Registry doc | `commands.registry.yml` | `update.subcommands.github` `arguments: VERSION` block |
| Auto-rendered wiki coverage | (output of registry → wiki build) | covers all four input forms |

## Related cycle artifacts

- `AUDIT_190_LIFECYCLE/V121_UPDATE_GITHUB_VERSION_ARG_DOC_SCOPE.md`
- `AUDIT_190_LIFECYCLE/V121_OPERATOR_SAFETY_HARDENING_SCHEMA_IMPACT_DECISION.md`
- v1.121.0 CHANGELOG entry (V121 Part B normalization)
