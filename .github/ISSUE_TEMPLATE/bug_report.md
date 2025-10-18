name: 🐞 Debug / Bug Report
description: Report unexpected behavior or errors in nftban
title: "[BUG] <short summary here>"
labels: [bug, needs-triage]
assignees: []
body:
  - type: markdown
    attributes:
      value: |
        Thanks for filing a bug! Please complete the required fields so we can reproduce it quickly.

  - type: input
    id: summary
    attributes:
      label: Describe the bug
      description: A concise description of the problem.
      placeholder: Example: GeoIP module fails to reload after update
    validations:
      required: true

  - type: textarea
    id: steps
    attributes:
      label: To Reproduce
      description: Exact steps that lead to the bug.
      placeholder: |
        1. Run `sudo nftban geoip update`
        2. Observe error in console
        3. Check /var/log/nftban.log
      value: |
        1. Go to '...'
        2. Click on '...'
        3. Scroll down to '...'
        4. See error
    validations:
      required: true

  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
      placeholder: Example: GeoIP sets reload successfully without syntax errors.
    validations:
      required: true

  - type: textarea
    id: logs
    attributes:
      label: Screenshots or logs
      description: Paste relevant logs or attach screenshots.
      placeholder: |
        ```text
        <log output>
        ```
    validations:
      required: false

  - type: markdown
    attributes:
      value: "### 🖥️ Environment (required)"

  - type: dropdown
    id: os
    attributes:
      label: OS / Distro
      options:
        - Debian 12
        - Debian 11
        - Ubuntu 24.04
        - Ubuntu 22.04
        - RHEL/Rocky/Alma 9
        - RHEL/Rocky/Alma 8
        - Fedora 35+
        - Other (specify below)
    validations:
      required: true

  - type: input
    id: os_other
    attributes:
      label: If "Other", specify
    validations:
      required: false

  - type: input
    id: nftban_version
    attributes:
      label: nftban version / commit
      placeholder: e.g., v0.9.0-beta, commit 1a2b3c4
    validations:
      required: true

  - type: input
    id: kernel
    attributes:
      label: Kernel version
      placeholder: e.g., 6.8.0-35-generic
    validations:
      required: false

  - type: checkboxes
    id: families
    attributes:
      label: Affected address families
      options:
        - label: IPv4
        - label: IPv6
        - label: Both / Unsure
    validations:
      required: false

  - type: textarea
    id: smartphone
    attributes:
      label: Smartphone (optional)
      description: Only if the issue relates to mobile/admin panels.
      placeholder: |
        Device: iPhone 12
        OS: iOS 17.1
        Browser: Safari
    validations:
      required: false

  - type: textarea
    id: extra
    attributes:
      label: Additional context
      placeholder: Anything else we should know?
    validations:
      required: false
