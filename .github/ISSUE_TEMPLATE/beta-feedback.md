---
name: Beta Feedback
about: 'Beta Feedback '
title: ''
labels: ''
assignees: itcmsgr

---

name: "🧪 Beta feedback (v0.9)"
description: "Share test results and observations from the beta program"
title: "[BETA] short summary here"
labels: ["beta-feedback", "needs-triage"]
assignees: []
body:
  - type: markdown
    attributes:
      value: |
        Thanks for testing nftban v0.9. Please include clear steps and environment details.

  - type: dropdown
    id: distro
    attributes:
      label: "OS / Distro"
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
      placeholder: "e.g., Proxmox 8 (Debian base)"
    validations:
      required: false

  - type: input
    id: nftban_version
    attributes:
      label: "nftban version / commit"
      placeholder: "e.g., v0.9.0-beta, commit abc1234"
    validations:
      required: true

  - type: checkboxes
    id: features
    attributes:
      label: "Areas you exercised"
      options:
        - label: "Installer / Upgrade"
        - label: "Core / CLI"
        - label: "Fail2Ban integration"
        - label: "DDoS protections"
        - label: "Port scan detection"
        - label: "GeoIP / Feeds"
        - label: "Whitelist / Blacklist"
        - label: "Cloudflare integration"
        - label: "Smoketest / Stats"
    validations:
      required: false

  - type: textarea
    id: steps
    attributes:
      label: "What you tested"
      description: "Commands run, scenarios covered, and expected outcomes"
      placeholder: |
        Example:
        - sudo nftban ddos enable
        - sudo nftban portscan enable
        - sudo nftban smoketest
    validations:
      required: true

  - type: textarea
    id: results
    attributes:
      label: "Results and observations"
      description: "Successes, failures, surprises, performance impressions"
      placeholder: "Share what worked, what didn't, and any timing or resource notes"
    validations:
      required: true

  - type: textarea
    id: logs
    attributes:
      label: "Relevant logs (optional)"
      placeholder: |
        ```text
        journalctl -u nftban --no-pager -n 200
        ```
    validations:
      required: false

  - type: textarea
    id: suggestions
    attributes:
      label: "Suggestions"
      placeholder: "Improvements to UX, docs, defaults, or safety checks"
    validations:
      required: false
