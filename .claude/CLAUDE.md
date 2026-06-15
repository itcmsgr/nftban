# NFTBan Project Instructions for Claude

## [VERIFIED] Protocol - Hallucination Prevention

When user prefixes a question with `[VERIFIED]`, Claude MUST:

### 1. Research First (BEFORE answering)
```
- Search codebase with Grep/Glob
- Read actual files
- Collect evidence with file:line citations
- Do NOT answer from memory
```

### 2. Verify Each Claim
```
□ File paths exist (actually check)
□ Functions are real (grep for definition)
□ CLI commands are valid (see list below)
□ Config options exist (search config files)
□ Numbers have evidence (no inventing benchmarks)
```

### 3. Response Format
```markdown
## Answer
[Main answer with inline citations]

Evidence:
- `file.sh:123-145` - [what it shows]
- `cmd_ban.sh:45` - [specific evidence]

## Verification
| Claim | Evidence | Status |
|-------|----------|--------|
| claim 1 | file:line | ✅ VERIFIED |
| claim 2 | no evidence | ❓ UNVERIFIED |

Confidence: HIGH / MEDIUM / LOW
```

### 4. Confidence Indicators
```
✅ VERIFIED     - Found in code, read the file
⚠️ LIKELY       - Based on patterns, not 100% confirmed
❓ UNVERIFIED   - No evidence found
❌ NOT SUPPORTED - Feature does not exist
```

---

## NFTBan Ground Truth

### Valid CLI Commands
```
ban, unban, status, whitelist, blacklist, feeds,
watchdog, stats, health, version, install, uninstall,
update, rebuild, login, metrics, export, portscan,
ddos, suricata, config, service, services, timers, geoip, geoban,
emulate, search, list, fhs, botguard, tunnel, sync
```

### Current Version
```
v1.56.0 (check /VERSION file for updates)
```

### NOT Supported (Common Hallucinations)
```
❌ Redis
❌ Cluster mode
❌ Port knocking
❌ Process tracking (PT_*)
❌ fail2ban integration
❌ iptables (nftables only)
❌ Webmin module
```

If claiming any of these exist → HALLUCINATION

### Key Paths
```
/usr/lib/nftban/     - Installation (lib/, cli/, core/, setup/)
/etc/nftban/         - Configuration (conf.d/, whitelist.d/, blacklist.d/)
/var/lib/nftban/     - Data (feeds/, state/)
/var/log/nftban/     - Logs
cli/lib/nftban/      - Source (repo mirror of /usr/lib/nftban/)
```

---

## MUST NOT Do

1. **Invent file paths** - If can't find it, say "NOT FOUND"
2. **Guess function names** - Search first
3. **Make up CLI commands** - Check valid list above
4. **Claim unsupported features** - Check NOT Supported list
5. **Invent performance numbers** - No benchmarks = no claims
6. **Answer without reading code** - Always verify first

---

## Example [VERIFIED] Flow

**User:** `[VERIFIED] How does NFTBan detect port scans?`

**Claude does:**
1. `grep -rn "portscan" cli/lib/nftban/`
2. Reads `nftban_portscan.sh`
3. Reads `cmd_portscan.sh`
4. Extracts evidence with line numbers
5. Self-audits each claim
6. Returns response with verification table

---

## Quick Verification Commands

When user says `verify this`:
- Re-check all claims against code
- Correct any hallucinations
- Update confidence levels

When user says `show me the evidence`:
- Provide file:line for every claim
- Quote actual code snippets

When user says `which files did you read?`:
- List all files actually read
- Show grep/glob commands used

---

## Documentation Style Rules

When writing wiki pages, docs, README sections, or release notes, follow:

- **Writing standard:** `.claude/docs/DOCS_WRITING_STANDARD.md` — principles, tone, structure, fact discipline
- **Do/Don't guide:** `.claude/docs/DOCS_DO_AND_DONT.md` — 24 paired examples
- **Claims guardrails:** `.claude/docs/CLAIMS_AND_WORDING_GUARDRAILS.md` — safe vs unsafe wording
- **Pre-publish checklist:** `.claude/docs/WIKI_PAGE_CHECKLIST.md` — verification before publishing
- **Claude rewrite rules:** `.claude/docs/DOCS_REWRITE_RULES_FOR_CLAUDE.md` — standing instructions for doc rewrites
- **Wiki style guide:** `.claude/WIKI_STYLE_GUIDE.md` — markdown formatting, templates
- **Brand guide:** `.claude/BRAND_GUIDE.md` — positioning, SEO, tone

### Key writing rules (summary)
- **No marketing.** No superlatives, no comparisons to other tools, no promotional language.
- **No comparisons.** Never frame NFTBan against competing tools. Describe what it does.
- **Calm tone.** Write like a senior engineer explaining to a peer.
- **Code-truth first.** Every claim must trace to code, config, runtime, or a release.
- **Version scope.** Every behavior claim needs "As of vX.Y.Z" or equivalent.
- **Mechanisms, not adjectives.** "Uses atomic rebuild" not "robust deployment."
- **CLI is a report.** Kernel verification (`nft list set`) proves enforcement, not CLI output alone.

## Additional Resources

- Full hallucination guide: `/home/commonfolder/LLMAI4NFTBAN/HOW_TO_ASK_ELIMINATE_HALLUCINATION.md`
- Hallucination detector: `/home/commonfolder/LLMAI4NFTBAN/validators/scripts/detect_hallucinations.sh`
- Auditor system: `/home/commonfolder/LLMAI4NFTBAN/prompts/hallucination_auditor_system.md`
- FHS authority graph (canonical): `/home/commonfolder/LLMAI4NFTBAN/NFTBAN_ROADMAP/V1_139_FHS_AUTHORITY_GRAPH.md` — single source of truth for the FHS authority topology (which surface owns which dir/file perms + closure status of historical gaps; v1.139 PR-C formalization).
