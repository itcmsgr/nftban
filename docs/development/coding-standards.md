# NFTBan Coding Standards

> **Purpose:** Mandatory coding standards for all NFTBan bash scripts
> **Status:** REQUIRED - All code must comply
> **Last Updated:** 2025-10-30

---

## 🔒 Critical Rules (MUST FOLLOW)

### 1. Script Headers - REQUIRED

Every bash script MUST include:

```bash
#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - [Component Name]
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: [Brief description]
#
# meta:name=[script_name]
# meta:type=[cli|core|tool|cron|exporter]
# meta:header=[Display Name]
# meta:version=0.10.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=[Detailed description]
# meta:input=[What the script accepts]
# meta:output=[What the script produces]
#
# **Inventory & Requirements**
# meta:depends=[comma,separated,dependencies]
#
# meta:created_date=YYYY-MM-DD

set -Eeuo pipefail
```

### 2. Error Handling - `set -Eeuo pipefail` is MANDATORY

**ALL scripts MUST use:**
```bash
set -Eeuo pipefail
```

**What this means:**
- `-E`: ERR trap inherited by functions
- `-e`: Exit on error
- `-u`: Exit on undefined variable
- `-o pipefail`: Exit if any command in pipeline fails

---

## ⚠️ CRITICAL: Arithmetic Expressions

### ❌ NEVER DO THIS:

```bash
# WRONG - Will exit script when counter=0 with set -e
counter=0
[[ condition ]] && ((counter++))

# WRONG - Silent failure risk
some_command && ((count++))
```

### ✅ ALWAYS DO THIS:

```bash
# CORRECT - Safe arithmetic assignment
counter=0
[[ condition ]] && counter=$((counter + 1))

# CORRECT - Standalone increment (not chained)
if [[ condition ]]; then
    ((counter++))
fi

# CORRECT - Add || true if you must use ((...))
[[ condition ]] && ((counter++)) || true
```

### Why This Matters

With `set -e`, `((var++))` returns exit code 1 when `var=0`, causing script termination.

**Test cases:**
```bash
# FAILS - exits immediately
set -e; x=0; [[ true ]] && ((x++)); echo "never reached"

# WORKS - completes successfully
set -e; x=0; [[ true ]] && x=$((x+1)); echo "SUCCESS"
```

**See:** `KNOWN_BUGS.md` BUG-001 for full details.

---

## 📝 Variable Naming

### Conventions

```bash
# Global constants (readonly)
readonly NFTBAN_VERSION="0.10.0"
readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Environment variables (exported)
export NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

# Local variables (function scope)
local_var="value"
local count=0

# Function names
function nftban_do_something() {
    local result="value"
    echo "$result"
}
```

### Naming Rules

1. **Global constants:** `UPPER_CASE` with `readonly`
2. **Environment variables:** `UPPER_CASE` with `export`
3. **Local variables:** `lower_case` or `snake_case`
4. **Functions:** Prefix with `nftban_` for library functions
5. **Private functions:** Prefix with `_nftban_` (underscore)

---

## 🛡️ Safe Coding Patterns

### Counter Increments

```bash
# Initialize
count=0
errors=0
success=0

# ✅ Safe increment patterns
count=$((count + 1))
errors=$((errors + 1))

# ✅ Safe decrement
count=$((count - 1))

# ✅ Safe arithmetic
total=$((success + errors))
percentage=$((success * 100 / total))
```

### Conditional Logic

```bash
# ✅ Safe condition checking
if [[ -f "$file" ]]; then
    process_file "$file"
fi

# ✅ Safe with counters
if [[ ! -d "/path/to/dir" ]]; then
    missing_dirs=$((missing_dirs + 1))
fi

# ❌ AVOID chaining arithmetic
[[ ! -d "/path" ]] && ((missing++))  # DANGEROUS

# ✅ CORRECT alternative
[[ ! -d "/path" ]] && missing=$((missing + 1))
```

### Loop Counters

```bash
# ✅ Safe loop with arithmetic
for ((i=0; i<10; i++)); do
    echo "Iteration $i"
done

# ✅ Safe while loop
counter=0
while [[ $counter -lt 10 ]]; do
    echo "Count: $counter"
    counter=$((counter + 1))
done
```

---

## 🎨 Code Style

### Indentation

- Use **4 spaces** (not tabs)
- Consistent indentation throughout

### Line Length

- Maximum 100 characters per line
- Break long lines with `\`

```bash
long_command \
    --option1 "value1" \
    --option2 "value2" \
    --option3 "value3"
```

### Quotes

```bash
# ✅ Always quote variables
echo "$variable"
path="$HOME/nftban"

# ✅ Quote command substitution
files=$(ls /path/to/dir)

# ❌ Unquoted (only when intentional word splitting needed)
args=$*  # Rare cases only
```

### Command Substitution

```bash
# ✅ Prefer $(...) over backticks
result=$(command arg1 arg2)

# ❌ Avoid backticks
result=`command arg1 arg2`
```

---

## 🔍 Error Handling

### Check Command Success

```bash
# ✅ Check return codes
if command arg1 arg2; then
    echo "Success"
else
    echo "Failed"
    return 1
fi

# ✅ Store output and check
output=$(command 2>&1)
if [[ $? -eq 0 ]]; then
    process_output "$output"
fi
```

### Trap Errors

```bash
# ✅ Use trap for cleanup
cleanup() {
    rm -f "$temp_file"
}
trap cleanup EXIT ERR

temp_file=$(mktemp)
# ... do work ...
```

### Validate Inputs

```bash
function process_file() {
    local file="${1:?Missing file argument}"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file" >&2
        return 1
    fi

    # Process file
}
```

---

## 📚 Function Guidelines

### Function Template

```bash
#
# function_name - Brief description
#
# Arguments:
#   $1 - First argument description
#   $2 - Second argument description (optional)
#
# Returns:
#   0 on success, 1 on error
#
# Example:
#   function_name "arg1" "arg2"
#
function_name() {
    local arg1="${1:?Missing required argument}"
    local arg2="${2:-default_value}"

    # Function body

    return 0
}
```

### Function Naming

```bash
# Public API functions
nftban_render_banner() { ... }
nftban_check_health() { ... }

# Private helper functions
_nftban_internal_helper() { ... }
_validate_input() { ... }
```

---

## 🧪 Testing Requirements

### Syntax Validation

```bash
# MUST pass before commit
bash -n script.sh
shellcheck script.sh
```

### Unit Testing

```bash
# Test arithmetic operations
test_counter_increment() {
    local count=0
    count=$((count + 1))
    [[ $count -eq 1 ]] || return 1
    return 0
}
```

---

## 📋 Pre-Commit Checklist

Before committing ANY bash script:

- [ ] Includes proper SPDX header
- [ ] Uses `set -Eeuo pipefail`
- [ ] No conditional arithmetic `&& ((var++))`
- [ ] All variables quoted properly
- [ ] Passes `bash -n script.sh`
- [ ] Passes `shellcheck script.sh` (if available)
- [ ] Functions documented
- [ ] Error handling implemented

---

## 🔗 Related Documentation

- `KNOWN_BUGS.md` - Current bug registry
- `docs/DEPLOYMENT_GUIDE.md` - Deployment procedures
- `README_v0.10.0.md` - Project overview

---

## 📖 References

- [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- [Bash Best Practices](https://mywiki.wooledge.org/BashGuide/Practices)
- [ShellCheck Wiki](https://www.shellcheck.net/wiki/)

---

**Last Updated:** 2025-10-30
**Enforced Since:** v0.10.0
**Status:** MANDATORY for all new and modified scripts

**EOF**
