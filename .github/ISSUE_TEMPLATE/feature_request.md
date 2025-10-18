---
name: Feature request
about: Suggest an idea for this project
title: ''
labels: ''
assignees: itcmsgr

---

name: "💡 Feature request"
description: "Suggest an enhancement for nftban on Linux servers"
title: "[FEATURE] short summary here"
labels: ["enhancement", "needs-triage"]
assignees: []
body:
  - type: markdown
    attributes:
      value: |
        Thanks for proposing an improvement. Clear use-cases help us evaluate and design the change.

  - type: input
    id: summary
    attributes:
      label: "What would you like to add or change?"
      placeholder: "One sentence summary"
    validations:
      required: true

  - type: textarea
    id: motivation
    attributes:
      label: "Why is this needed?"
      description: "Problem statement or operational pain the feature solves"
      placeholder: "Describe the use-case and impact"
    validations:
      required: true

  - type: textarea
    id: proposal
    attributes:
      label: "Proposed solution"
      description: "High-level approach, CLI flags, config keys, example behavior"
      placeholder: |
        Example:
        - New command: nftban feeds refresh --fast
        - Config: /etc/nftban/nftban.env -> FEEDS_REFRESH_INTERVAL=15m
    validations:
      required: false

  - type: checkboxes
    id: scope
    attributes:
      label: "Which areas are affected?"
      options:
        - label: "Core / CLI"
        - label: "Installer / Packaging"
        - label: "Fail2Ban integration"
        - label: "DDoS / Port scan"
        - label: "GeoIP / Feeds"
        - label: "Docs"
        - label: "Testing / CI"
    validations:
      required: false

  - type: textarea
    id: alternatives
    attributes:
      label: "Alternatives considered"
      placeholder: "Other approaches and why they are less suitable"
    validations:
      required: false

  - type: textarea
    id: additional
    attributes:
      label: "Additional context"
      placeholder: "Links, prior art, related issues"
    validations:
      required: false
