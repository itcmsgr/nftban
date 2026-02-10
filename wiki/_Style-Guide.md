# Documentation Style Guide

Style guide for nftban GitHub Wiki pages. All documentation must follow these rules.

---

## Table of Contents
- [Tone and Voice](#tone-and-voice)
- [Page Structure](#page-structure)
- [Markdown Formatting](#markdown-formatting)
- [Naming Conventions](#naming-conventions)
- [Code Examples](#code-examples)
- [Error Documentation](#error-documentation)
- [Cross-Referencing](#cross-referencing)
- [Templates](#templates)

---

## Tone and Voice

### Required
- Professional, concise, and precise
- Present tense and imperative mood for instructions
- Factual statements grounded in code

### Avoid
- Verbosity and filler text
- Speculation ("might", "could") when specifics are known
- Marketing language or enthusiasm
- Competitor mentions or comparisons

**Good:** "Run the health check to verify system state."
**Bad:** "You should probably run the amazing health check feature."

---

## Page Structure

Every page must have:

1. **Title** - Clear, descriptive `# Title`
2. **One-line description** - What this page documents
3. **Table of Contents** - If content exceeds 300 words
4. **Standard sections** (as applicable):
   - Purpose
   - Prerequisites
   - Details/Usage
   - Examples
   - Common Errors
   - References

### Heading Levels

```markdown
# Page Title
## Section
### Subsection
```

Do not go deeper than `###`.

---

## Markdown Formatting

### Code Blocks

Always specify language:

```bash
systemctl status nftband
```

### Inline Code

Use backticks for:
- Commands: `nftban health check`
- Paths: `/etc/nftban/conf.d/`
- Unit names: `nftband.service`
- Config keys: `NFTBAN_MODE`

### Tables

Use for structured data:

```markdown
| Column | Description |
|--------|-------------|
| Value  | Explanation |
```

---

## Naming Conventions

### File Paths

Use FHS-compliant paths:

| Path | Purpose |
|------|---------|
| `/etc/nftban/` | Configuration |
| `/etc/nftban/conf.d/` | Module configs |
| `/usr/sbin/nftban` | Main executable |
| `/usr/lib/nftban/` | Libraries and binaries |
| `/var/lib/nftban/` | Variable data |
| `/var/log/nftban/` | Logs |
| `/var/cache/nftban/` | Cache files |

### Systemd Units

Always use exact unit names:

- **Good:** `nftband.service`
- **Bad:** "the daemon service"

### Terminology

| Term | Meaning |
|------|---------|
| auto-heal | Automated fix logic in health check |
| health check | nftban internal self-test |
| commit-confirm | Auto-rollback safety mechanism |
| polkit | Privilege separation system |

---

## Code Examples

### Requirements

Every example must include:
1. Command with proper syntax
2. Brief explanation of flags
3. Expected behavior

### Format

```bash
# Purpose of command
nftban health check --auto-heal
```

Flags:
- `--auto-heal` — Attempt automatic corrections

### Output Examples

Include sample output when helpful:

```
Health: OK
Services: 3/3 running
```

---

## Error Documentation

### Format

1. Error message in backticks (verbatim)
2. Cause
3. Fix
4. Expected result after fix

### Example

**Error:** `Permission denied`

**Cause:** Command requires root privileges.

**Fix:**
```bash
sudo nftban health check
```

---

## Cross-Referencing

### Internal Links

Use relative wiki links:

```markdown
See [CLI Reference](CLI-Reference)
```

### Code Links

Link to exact source locations:

```markdown
Source: `cli/lib/nftban/cli/cmd_health.sh`
```

---

## Templates

### Universal Page Template

```markdown
# Page Title

One-line description of what this page documents.

---

## Table of Contents
- [Purpose](#purpose)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Purpose

Why this feature exists.

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| nftban | Version X.X+ |
| Privileges | Root or nftban group |

---

## Usage

How to use this feature.

---

## Examples

```bash
# Example command
nftban command subcommand
```

---

## Troubleshooting

### Error Message

**Cause:** Explanation.

**Fix:**
```bash
fix command
```

---

## References

- [Related Page](Related-Page)
- Source: `path/to/source.sh`
```

---

## AI Editing Prompt

When using AI to edit wiki pages, include this context:

```
You are editing the nftban GitHub Wiki.

Follow the nftban Documentation Style Guide strictly:
- Professional, concise tone
- No speculation or enthusiasm
- FHS-compliant paths
- Exact systemd unit names
- Proper markdown structure
- Short, precise sections
- No invented behavior

Do not expand beyond documented functionality.
```

---

## Checklist

Before committing wiki changes:

- [ ] Title is clear and descriptive
- [ ] One-line description present
- [ ] TOC included (if >300 words)
- [ ] Code blocks have language specified
- [ ] Paths are FHS-compliant
- [ ] Unit names are exact
- [ ] Examples are copy-paste safe
- [ ] Error messages are verbatim
- [ ] Internal links work
- [ ] No marketing language
