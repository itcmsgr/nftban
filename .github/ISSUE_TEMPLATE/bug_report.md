---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: itcmsgr

---

name: "🐛 Bug report (Linux servers)"
description: "Report an issue with nftban on Debian/Ubuntu/RHEL/Rocky/Alma/Fedora"
title: "[BUG] short summary here"
labels: ["bug", "needs-triage"]
assignees: []
body:
  - type: markdown
    attributes:
      value: |
        Thanks for helping improve nftban. Please provide enough detail to reproduce the problem.
        Before posting, remove any sensitive data (real IPs, keys, domains).

  - type: input
    id: concise_summary
    attributes:
      label: "Describe the bug"
      description: "One sentence summary of what is wrong."
      placeholder: "Example: GeoIP update succeeds but sets are empty afterward"
    validations:
      required: true

  - type: textarea
    id: steps
    attributes:
      label: "To reproduce"
      description: "Exact steps and commands that lead to the issue."
      value: |
        1. …
        2. …
        3. …
        4. Observed error: …
      placeholder: |
        1. Run: sudo nftban geoip update
        2. Check: sudo nft list sets ip nftban_v4
        3. Compare: journalctl -u nftban --no-pager -n 50
        4. Error appears: …
    validations:
      required: true

  - type: textarea
    id: expected
    attributes:
      label: "Expected behavior"
      placeholder: "What should have happened instead?"
    validations:
      required: true

  - type: textarea
    id: actual
    attributes:
      label: "Actual behavior"
      placeholder: "What actually happened?"
    validations:
      required: true

  - type: dropdown
    id: distro
    attributes:
      label: "OS / Distro"
      description: "Select the closest match."
      options:
        - "Debian 12 (Bookworm)"
        - "Debian 11 (Bullseye)"
        - "Ubuntu 24.04 LTS"
        - "Ubuntu 22.04 LTS"
        - "RHEL / Rocky / Alma 9"
        - "RHEL / Rocky / Alma 8"
        - "Fedora 35+"
        - "Other (specify below)"
    validations:
      required: true

  - type: input
    id: distro_other
    attributes:
      label: "If Other, specify"
      placeholder: "e.g., Proxmox 8 (Debian base), Amazon Linux 2023"
    validations:
      required: false

  - type: input
    id: kernel
    attributes:
      label: "Kernel version"
      placeholder: "e.g., 6.8.0-35-generic"
    validations:
      required: false

  - type: input
    id: nftban_version
    attributes:
      label: "nftban version / commit"
      placeholder: "e.g., v0.9.0-beta, commit abc1234"
    validations:
      required: true

  - type: input
    id: nftables_version
    attributes:
      label: "nftables version"
      placeholder: "Output of: nft --version"
    validations:
      required: false

  - type: dropdown
    id: install_method
    attributes:
      label: "Install method"
      options:
        - "Two-step script (download then run)"
        - "One-liner curl | bash"
        - "Manual (cloned repo)"
        - "Other"
    validations:
      required: true

  - type: checkboxes
    id: modules
    attributes:
      label: "Affected areas (check all that apply)"
      options:
        - label: "Core / CLI"
        - label: "Installer / Uninstall"
        - label: "Fail2Ban integration"
        - label: "DDoS module"
        - label: "Port scan module"
        - label: "GeoIP / Geo blocking"
        - label: "Threat feeds"
        - label: "Whitelist / Blacklist"
        - label: "Cloudflare integration"
        - label: "Stats / Smoketest"
    validations:
      required: false

  - type: textarea
    id: commands
    attributes:
      label: "Commands and outputs"
      description: "Paste relevant commands and their outputs. Mask sensitive data."
      placeholder: |
        Command:
        sudo nftban status

        Output:
        <paste here>

        Command:
        sudo nft list tables

        Output:
        <paste here>
    validations:
      required: false

  - type: textarea
    id: logs
    attributes:
      label: "Logs"
      description: "Paste relevant log lines (journalctl or /var/log/*). Use code fences."
      placeholder: |
        ```text
        journalctl -u nftban --no-pager -n 200
        (paste output here)
        ```
    validations:
      required: false

  - type: textarea
    id: additional
    attributes:
      label: "Additional context"
      placeholder: "Workarounds tried, related issues, environment peculiarities"
    validations:
      required: false
