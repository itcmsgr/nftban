---
name: Bug report
about: Create a report to help us improve
title: ''
labels: ''
assignees: ''

---

name: 🐞 Debug / Bug Report
description: Report unexpected behavior or errors in nftban
title: "[BUG] <short summary>"
labels: [bug, needs-triage]
assignees: []
body:
  - type: markdown
    attributes:
      value: |
        Thank you for reporting a bug 🐛
        Please fill out all sections to help us reproduce and fix the issue quickly.

  - type: input
    id: summary
    attributes:
      label: Describe the bug
      description: A clear and concise description of what the bug is.
      placeholder: Example: "GeoIP module fails to reload after update"
    validations:
      required: true

  - type: textarea
    id: steps
    attributes:
      label: To Reproduce
      description: Steps to reproduce the behavior.
      placeholder: |
        1. Run `sudo nftban geoip update`
        2. Observe error message in console
        3. Check system logs at /var/log/nftban.log
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
      description: A clear and concise description of what you expected to happen.
      placeholder: Example: "GeoIP sets should reload successfully without syntax errors."
    validations:
      required: true

  - type: textarea
    id: screenshots
    attributes:
      label: Screenshots or Logs
      description: If applicable, add screenshots, terminal outputs, or log snippets.
      placeholder: |
        Attach screenshots or paste log excerpts between triple backticks:
        ```
        <log output>
        ```

  - type: markdown
    attributes:
      value: "### 🖥️ System Information"

  - type: input
    id: desktop-os
    attributes:
      label: OS and Version
      placeholder: "e.g. Debian 12, Ubuntu 24.04, CentOS 9 Stream"
    validations:
      required: true

  - type: input
    id: nftban-version
    attributes:
      label: nftban Version
      placeholder: "e.g. v0.9.0-beta, commit 1a2b3c4"

  - type: textarea
    id: smartphone
    attributes:
      label: Smartphone (optional)
      description: Only if the issue relates to mobile panels or dashboards.
      placeholder: |
        Device: [e.g. iPhone 12]
        OS: [e.g. iOS 17.1]
        Browser: [e.g. Safari]
        Version: [e.g. 22]

  - type: textarea
    id: additional
    attributes:
      label: Additional context
      description: Add any other context or observations about the issue here.
