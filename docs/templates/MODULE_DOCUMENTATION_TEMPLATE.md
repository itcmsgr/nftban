# NFTBan Module: [MODULE_NAME]

**Version:** [Version Number]
**Status:** [Production|Development|Experimental]
**Category:** [Core|Security|Integration|Management|Monitoring]
**Author:** ITCMS Team (Antonios Voulvoulis)
**Contact:** contact@itcms.gr
**Website:** https://itcms.gr
**Last Updated:** [YYYY-MM-DD]

---

## Overview

**Purpose:** [One sentence describing what this module does]

**Key Features:**
- [Feature 1]
- [Feature 2]
- [Feature 3]

**Dependencies:**
- [Required module 1]
- [Required module 2]
- [Required system commands]

**When to Use:**
[Describe use cases]

---

## Architecture

### Module Structure

**File:** `/etc/nftban/lib/nftban_[module]_module.sh`

**Exports:**
- `function1()` - [Description]
- `function2()` - [Description]

**Internal Functions:**
- `_private_function()` - [Description]

### Data Flow

```
[Input] → [Processing] → [Output]
```

[Explain how data flows through the module]

### State Management

[Describe any state the module maintains - files, variables, nftables sets, etc.]

---

## API Reference

### Public Functions

#### function_name()

**Purpose:** [One sentence]

**Syntax:**
```bash
function_name <param1> [param2]
```

**Parameters:**
- `param1` (required): [Description, type, validation rules]
- `param2` (optional): [Description, default value]

**Returns:**
- `0`: Success
- `1`: Error [describe error conditions]

**Example:**
```bash
if function_name "value1" "value2"; then
    echo "Success"
else
    echo "Failed"
fi
```

**Notes:**
- [Important implementation details]
- [Security considerations]
- [Performance notes]

---

## Integration

### CLI Commands

```bash
nftban [module] <action> [options]
```

**Available Actions:**
- `action1` - [Description]
- `action2` - [Description]

**Examples:**
```bash
# Example 1: [Description]
sudo nftban [module] action1

# Example 2: [Description]
nftban [module] action2 --option
```

### Module Integration

**Loading the Module:**
```bash
source "${NFTBAN_LIB_DIR}/nftban_[module]_module.sh"
```

**Using in Scripts:**
```bash
#!/usr/bin/env bash
source /etc/nftban/lib/nftban_core.sh
source /etc/nftban/lib/nftban_[module]_module.sh

# Use module functions
function_name "parameter"
```

### nftables Integration

[If module interacts with nftables, describe the sets, chains, and rules it uses]

**nftables Objects:**
- Table: `nftban_v4`, `nftban_v6`
- Sets: `[set_name]` - [purpose]
- Chains: `[chain_name]` - [purpose]

---

## Configuration

### Configuration File

**Location:** `/etc/nftban/config/[config_file].conf`

**Format:**
```bash
# Configuration format
SETTING_NAME="value"
```

**Available Settings:**

| Setting | Type | Default | Description |
|---------|------|---------|-------------|
| `SETTING_1` | string | `"default"` | [Description] |
| `SETTING_2` | integer | `100` | [Description] |
| `SETTING_3` | boolean | `true` | [Description] |

**Example Configuration:**
```bash
# /etc/nftban/config/[module].conf
SETTING_1="custom_value"
SETTING_2=200
SETTING_3=false
```

---

## Security Considerations

### Security Rating

**Current (v0.9.2):** [Rating]/10
**Target (v0.9.3):** 9/10
**Improvement:** +[X] points

**Rating Breakdown:**
- **Input Validation:** [Score]/10 - [Status]
- **Permission Security:** [Score]/10 - [Status]
- **Attack Surface:** [LOW|MEDIUM|HIGH] - [Details]
- **Known Vulnerabilities:** [Count] HIGH, [Count] MEDIUM

### Production-Hardened Security (v0.9.3+)

**This module uses the v0.9.3 production-hardened header with:**
- ✅ PATH sanitization (prevents hijacking - CWE-426)
- ✅ Locale standardization (prevents parsing attacks - CWE-134)
- ✅ Strict error handling (set -Eeuo pipefail)
- ✅ Error traps with line numbers
- ✅ Secure temporary directories (prevents TOCTOU - CWE-362, CWE-377)
- ✅ Automatic cleanup on exit (prevents information leakage - CWE-459)
- ✅ Command verification (fail early)
- ✅ Readonly critical variables (prevents tampering)

### Vulnerabilities Addressed

**v0.9.3 Security Improvements:**
- **CWE-362:** Race Condition → MITIGATED (atomic operations, secure temp dirs)
- **CWE-377:** Insecure Temp File → MITIGATED (mktemp + chmod 700)
- **CWE-426:** Untrusted Search Path → MITIGATED (PATH sanitization)
- **CWE-459:** Incomplete Cleanup → MITIGATED (exit traps)
- **[MODULE-SPECIFIC-CWE]**: [Description] → [Status]

**Module-Specific Fixes:**
- **[VULNERABILITY_ID]**: [Description and fix]

### Security Features

**Input Validation:**
- [Describe validation rules]
- IP addresses: Regex + range validation
- Ports: Numeric validation (1-65535)
- Country codes: Whitelist validation
- File paths: Path traversal prevention

**Permission Checks:**
- [Describe permission requirements]
- Root required: [Yes/No]
- File permissions: 640 (configs), 600 (sensitive)
- Directory permissions: 750

**Sanitization:**
- [Describe sanitization methods]
- Command injection: All inputs validated
- Quote all expansions: "${var}" pattern
- Arrays for commands: cmd=(...) ; "${cmd[@]}"

**Logging Security:**
- [Describe security-relevant logging]
- Sensitive data: Never logged (use counts instead)
- IP privacy: Log "[REDACTED]" or count only
- Error context: No variable dumps

### Attack Surface

**Input Sources:**
- CLI arguments (validated)
- Configuration files (permission-checked)
- External data (sanitized)
- nftables output (parsed safely)

**Potential Risks:**
- **Risk 1:** [Description]
  - **Likelihood:** [LOW|MEDIUM|HIGH]
  - **Impact:** [LOW|MEDIUM|HIGH|CRITICAL]
  - **Mitigation:** [How it's prevented]
- **Risk 2:** [Description]
  - **Likelihood:** [LOW|MEDIUM|HIGH]
  - **Impact:** [LOW|MEDIUM|HIGH|CRITICAL]
  - **Mitigation:** [How it's prevented]

### File Security

**Configuration Files:**
- Location: `/etc/nftban/config/[module].conf`
- Permissions: `640` (owner: rw, group: r, other: none)
- Owner: `root:root`

**Sensitive Files:**
- [List sensitive files]
- Permissions: `600` (owner only)
- Never world-readable

**Log Files:**
- Location: `/var/log/nftban/[module].log`
- Permissions: `640`
- Errors: `/var/log/nftban/errors.log` (600)

### Compliance

**Security Standards:**
- CIS Benchmarks: [Alignment level]
- OWASP: [Compliance notes]
- Production-grade: ✅ Yes (v0.9.3+)

---

## Troubleshooting

### Common Issues

#### Issue: [Problem Description]

**Symptoms:**
- [Symptom 1]
- [Symptom 2]

**Cause:** [Root cause]

**Solution:**
```bash
# Commands to fix
[fix commands]
```

#### Issue: [Another Problem]

[Same format as above]

### Logs

**Relevant Log Files:**
- `/var/log/nftban/[module].log` - [What's logged here]
- `/var/log/nftban/errors.log` - [Error logging]

**Viewing Logs:**
```bash
# View module logs
tail -f /var/log/nftban/[module].log

# Search for errors
grep "ERROR" /var/log/nftban/[module].log

# View last 100 lines
tail -n 100 /var/log/nftban/[module].log
```

### Debugging

**Enable Debug Mode:**
```bash
export NFTBAN_DEBUG=1
nftban [module] [action]
```

**Validation Commands:**
```bash
# Verify module is working
nftban [module] status

# Run diagnostics
nftban [module] verify

# Test configuration
nftban [module] test
```

---

## Testing

### Unit Testing

[If tests exist, describe how to run them]

### Integration Testing

[Describe how to test the module in a real system]

### Test Cases

1. **Test Case 1: [Description]**
   - Input: [Input data]
   - Expected: [Expected result]
   - Validation: [How to verify]

2. **Test Case 2: [Description]**
   - [Same format]

---

## Performance

### Resource Usage

- **Memory**: [Typical memory usage]
- **CPU**: [CPU impact]
- **Disk I/O**: [I/O patterns]
- **Network**: [Network usage if applicable]

### Optimization

[Describe any performance considerations or optimization tips]

---

## Maintenance

### Regular Tasks

- [ ] [Task 1] - [Frequency]
- [ ] [Task 2] - [Frequency]

### Backup Considerations

[Describe what data should be backed up and how]

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 0.9.3-dev | 2025-10-22 | Security maturity release (in development) |
| 0.9.2 | 2025-10-20 | Emergency fixes, validation system |
| 0.9.1 | 2025-10-15 | Initial modular release |

---

## References

### Related Documentation

- [Link to related docs]
- [Link to security docs]

### External Resources

- [Link to external resources]

---

## Footer

**Document Status:** [Draft|Review|Final]
**Review Date:** [Next review date]
**Maintainer:** ITCMS Team

---

## License

**MIT License**

Copyright (c) 2025 ITCMS Team (Antonios Voulvoulis)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

**Contact:** contact@itcms.gr | Website: https://itcms.gr

---

*Generated: [YYYY-MM-DD HH:MM:SS UTC]*
*NFTBan Version: [Version]*
