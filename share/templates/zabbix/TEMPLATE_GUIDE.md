# Zabbix Template Development Guide

> Lessons learned from NFTBan Zabbix 7.x template development.

## UUID Requirements (CRITICAL)

Zabbix 7.x has **strict UUID validation**. Invalid UUIDs cause:
```
Import failed: Invalid parameter "/1/uuid": UUIDv4 is expected.
```

### Valid UUID Format

| Requirement | Value |
|-------------|-------|
| Length | **32 characters** (no dashes) |
| Characters | Lowercase hex: `0-9a-f` |
| Position 12 | Must be `4` (version nibble) |
| Position 16 | Must be `8`, `9`, `a`, or `b` (variant) |

### Examples

```yaml
# VALID UUIDs
uuid: 7df96b18c230490a9a0a9e2307226338  # pos12=4, pos16=9
uuid: 185f23a7e83b4e78b1d79faee0299ea0  # pos12=4, pos16=b
uuid: 88ae4faa08af4711acdf461a7fc6ed0b  # pos12=4, pos16=a

# INVALID UUIDs (will fail import)
uuid: 4a8f2c1d3e5b6a7c8d9e0f1a2b3c4d5e  # pos12=6, pos16=8 - WRONG
uuid: 1234567890abcdef1234567890abcdef  # pos12=e, pos16=2 - WRONG
uuid: 7df96b18-c230-490a-9a0a-9e2307226338  # HAS DASHES - WRONG
```

### Generate Valid UUIDs

```bash
# Python (recommended)
python3 -c "import uuid; print(str(uuid.uuid4()).replace('-',''))"

# Bash one-liner
uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]'
```

### Validate Existing UUIDs

```python
import re

def is_valid_uuid4(uuid_str):
    """Check if 32-char UUID is RFC 4122 v4 compliant"""
    if len(uuid_str) != 32:
        return False
    if uuid_str[12] != '4':  # Version must be 4
        return False
    if uuid_str[16] not in '89ab':  # Variant bits
        return False
    return True

# Check all UUIDs in template
with open('nftban_template_7x.yaml') as f:
    for uuid in re.findall(r'uuid: ([a-f0-9]{32})', f.read()):
        if not is_valid_uuid4(uuid):
            print(f"INVALID: {uuid}")
```

### Regenerate All UUIDs

```python
import re
import uuid

with open('nftban_template_7x.yaml', 'r') as f:
    content = f.read()

def new_uuid(match):
    return f"uuid: {str(uuid.uuid4()).replace('-', '')}"

content = re.sub(r'uuid: [a-f0-9-]{32,36}', new_uuid, content)

with open('nftban_template_7x.yaml', 'w') as f:
    f.write(content)
```

---

## Dashboard Widget Bindings (CRITICAL)

Dashboard widgets in templates must reference items correctly. **This is the #1 cause of "Inaccessible widget" errors.**

### Key Rules

1. **Use template NAME, not CODE**: `host: 'NFTBan Firewall Monitoring'` (not `host: NFTBan`)
2. **Use strings for geometry**: `width: '6'` (not `width: 6`)
3. **Use raw operators in expressions**: `<` `>` (not `&lt;` `&gt;`)

### Template Name vs Code

```yaml
templates:
  - uuid: 185f23a7e83b4e78b1d79faee0299ea0
    template: 'NFTBan'              # This is the CODE (used in expressions)
    name: 'NFTBan Firewall Monitoring'         # This is the NAME (used in widget host:)
```

- **Expressions**: Use CODE → `last(/NFTBan/nftban.status)`
- **Widget host:**: Use NAME → `host: 'NFTBan Firewall Monitoring'`

### Required Structure

```yaml
widgets:
  - type: item_value
    name: 'Daemon Status'
    width: '6'                      # STRING, not integer
    height: '3'                     # STRING, not integer
    fields:
      - type: ITEM
        name: itemid.0              # MUST have .0 suffix
        value:
          host: 'NFTBan Firewall Monitoring'   # MUST be template NAME (not code!)
          key: nftban.status        # Item key
```

### Widget Field Naming

| Widget Type | Field Name Pattern |
|-------------|-------------------|
| item_value | `itemid.0` |
| svggraph | `ds.0.itemid.0`, `ds.1.itemid.0` |
| gauge | `itemid.0` |
| top_hosts | `columns.0.item.0` |

### Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| "Inaccessible widget" | `host: NFTBan` (wrong) | Use `host: 'NFTBan Firewall Monitoring'` (template NAME) |
| "Inaccessible widget" | Missing `host:` tag | Add `host: 'NFTBan Firewall Monitoring'` |
| "Object does not exist" | Wrong key name | Verify item key exists in template |
| Empty dashboard page | No data received | Send test data via trapper |
| Import fails | HTML escapes in expressions | Use `<` `>` not `&lt;` `&gt;` |

### Trigger Expressions

```yaml
# CORRECT - raw operators
expression: 'last(/NFTBan/nftban.bans.24h)>1000'
expression: 'last(/NFTBan/nftban.mode)<>"normal"'

# WRONG - HTML escapes
expression: 'last(/NFTBan/nftban.bans.24h)&gt;1000'  # FAILS!
expression: 'last(/NFTBan/nftban.mode)&lt;&gt;"normal"'  # FAILS!
```

---

## Template Structure (Zabbix 7.x)

```yaml
zabbix_export:
  version: '7.0'

  template_groups:
    - uuid: <32-char-uuid>
      name: 'Templates/Security'

  templates:
    - uuid: <32-char-uuid>
      template: 'NFTBan'              # Internal name (no spaces)
      name: 'NFTBan Firewall Monitoring'         # Display name
      vendor:
        name: NFTBan
        version: '1.4.0'
      groups:
        - name: 'Templates/Security'  # Must match template_groups

      macros:
        - macro: '{$NFTBAN.THRESHOLD}'
          value: '100'
          description: 'Description here'

      items:
        - uuid: <32-char-uuid>
          name: 'NFTBan: Item name'
          type: TRAP                  # Trapper item
          key: nftban.key
          value_type: UNSIGNED        # UNSIGNED, FLOAT, TEXT, LOG
          description: 'What this measures'
          preprocessing:              # Optional
            - type: DISCARD_UNCHANGED_HEARTBEAT
              parameters:
                - '3600'              # 1 hour for static data
          tags:
            - tag: component
              value: daemon
          triggers:
            - uuid: <32-char-uuid>
              expression: 'last(/NFTBan/nftban.key)=0'
              name: 'Trigger name'
              priority: DISASTER      # NOT_CLASSIFIED, INFO, WARNING, AVERAGE, HIGH, DISASTER

      dashboards:
        - uuid: <32-char-uuid>
          name: 'NFTBan Overview'
          pages:
            - name: 'Status'
              widgets:
                # ... widget definitions
```

---

## Item Types

| Type | Use Case |
|------|----------|
| `TRAP` | Data pushed via zabbix_sender or trapper protocol |
| `ZABBIX_ACTIVE` | Agent pulls from monitored host |
| `DEPENDENT` | Derived from another item |
| `CALCULATED` | Formula-based |

## Value Types

| Type | Description |
|------|-------------|
| `UNSIGNED` | Positive integers (counters, status) |
| `FLOAT` | Decimal numbers (percentages, rates) |
| `TEXT` | Strings (version, hostname) |
| `LOG` | Log entries |

---

## Preprocessing

### DISCARD_UNCHANGED_HEARTBEAT

For static/slow-changing metrics (reduce storage):

```yaml
preprocessing:
  - type: DISCARD_UNCHANGED_HEARTBEAT
    parameters:
      - '3600'    # Send at least every 1 hour
```

Recommended intervals:
- Dynamic metrics (bans, memory): No preprocessing
- Semi-static (version, mode): 5m heartbeat
- Inventory (OS, hostname): 1h heartbeat

---

## Inventory Auto-Population

Map items to host inventory fields:

```yaml
items:
  - uuid: <uuid>
    name: 'Server OS'
    key: nftban.server.os
    inventory_link: OS              # Auto-populates inventory
```

| inventory_link | Zabbix Field |
|----------------|--------------|
| OS | Operating System |
| HOST_NETMASK | Host subnet mask |
| MACADDRESS_A | MAC address A |
| HOST_NETWORKS | Host networks |

---

## Trigger Expressions

```yaml
# Basic comparison
expression: 'last(/NFTBan/nftban.status)=0'

# No data check
expression: 'nodata(/NFTBan/nftban.status,5m)=1'

# Threshold with macro
expression: 'last(/NFTBan/nftban.bans.rate)>{$NFTBAN.BAN.RATE.WARN}'

# Change detection
expression: 'change(/NFTBan/nftban.version)<>0'

# Average over time
expression: 'avg(/NFTBan/nftban.memory.rss,5m)>{$NFTBAN.MEMORY.WARN}'
```

---

## Testing Templates

### 1. Validate YAML Syntax

```bash
python3 -c "import yaml; yaml.safe_load(open('nftban_template_7x.yaml'))"
```

### 2. Validate UUIDs

```bash
python3 << 'EOF'
import re
with open('nftban_template_7x.yaml') as f:
    content = f.read()
uuids = re.findall(r'uuid: ([a-f0-9]{32})', content)
invalid = [u for u in uuids if u[12] != '4' or u[16] not in '89ab']
print(f"Total: {len(uuids)}, Invalid: {len(invalid)}")
for u in invalid: print(f"  {u}")
EOF
```

### 3. Test Import (Zabbix API)

```bash
# Dry-run import
curl -X POST "http://zabbix/api_jsonrpc.php" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "configuration.import",
    "params": {
      "format": "yaml",
      "source": "'"$(cat nftban_template_7x.yaml | jq -Rs .)"'",
      "rules": {
        "templates": {"createMissing": true, "updateExisting": false}
      }
    },
    "auth": "'$ZABBIX_TOKEN'",
    "id": 1
  }'
```

### 4. Send Test Data

```bash
# Using zabbix_sender
zabbix_sender -z monitor.example.com -s "hostname" -k nftban.status -o 1

# Using native protocol (netcat)
echo '{"request":"sender data","data":[{"host":"hostname","key":"nftban.status","value":"1"}]}' | nc -w5 monitor.example.com 10051
```

---

## Inventory Links

Inventory links auto-populate host inventory fields from item values.

### Format

Use **string names**, not numeric IDs:

```yaml
# CORRECT - string names
inventory_link: NAME
inventory_link: ALIAS
inventory_link: OS

# WRONG - numeric IDs (may work but less compatible)
inventory_link: 3
inventory_link: 4
inventory_link: 5
```

### Available Fields

| inventory_link | Zabbix Field | Example Use |
|----------------|--------------|-------------|
| NAME | Name | Server hostname |
| ALIAS | Alias | FQDN |
| OS | OS | Operating system (debian, rhel) |
| OS_SHORT | OS (Short) | OS release name |
| TYPE | Type | Architecture (x86_64) |
| TYPE_FULL | Type (Full details) | Virtualization type |
| SOFTWARE | Software | Kernel version |
| HARDWARE | Hardware | CPU model |
| MACADDRESS_A | MAC address A | Primary MAC |
| HOST_NETWORKS | Host networks | JSON network info |
| HOST_NETMASK | Host subnet mask | Subnet (/24, /32) |
| HOST_ROUTER | Host router | Gateway or primary IP |
| VENDOR | Vendor | Cloud provider |
| LOCATION | Location | Region/datacenter |

### Host Inventory Mode (CRITICAL)

**Inventory fields will NOT populate unless the host has inventory mode enabled!**

| Mode | Behavior |
|------|----------|
| Disabled | inventory_link ignored, fields stay empty |
| Manual | Fields editable, inventory_link populates |
| **Automatic** | inventory_link auto-populates (recommended) |

Set in: Configuration → Hosts → [hostname] → Inventory → **Automatic**

---

## Preprocessing (DISCARD_UNCHANGED_HEARTBEAT)

### Purpose

Reduces storage by only storing values when they change OR after heartbeat interval.

```yaml
preprocessing:
  - type: DISCARD_UNCHANGED_HEARTBEAT
    parameters:
      - '1d'    # Send unchanged value at least once per day
```

### Recommended Intervals

| Data Type | Heartbeat | Rationale |
|-----------|-----------|-----------|
| Dynamic (bans, memory) | No preprocessing | Changes frequently |
| Semi-static (version, mode) | `'5m'` | Rarely changes |
| Inventory (OS, hostname) | `'1d'` | Almost never changes |

### Inventory Gotcha (CRITICAL)

**Problem**: If you enable host inventory AFTER items already have values, the inventory fields stay empty because:
1. Values haven't changed
2. DISCARD_UNCHANGED_HEARTBEAT filters them out
3. Filtered values don't write to inventory

**Solutions**:

1. **Wait for heartbeat** - Values will populate after heartbeat interval (e.g., 1 day)

2. **Force refresh** - Send slightly different values to bypass filter:
   ```bash
   # Clear cache and resend
   rm -f /var/cache/nftban/metrics/*.json
   /usr/lib/nftban/exporters/nftban_unified_exporter.sh
   /usr/lib/nftban/exporters/nftban_zabbix_exporter.sh
   ```

3. **Temporarily reduce heartbeat** - Change `'1d'` to `'5m'`, import, wait, revert

---

## Troubleshooting

### "Inaccessible widget" Error

**Cause**: Widget `host:` references template CODE instead of NAME.

```yaml
# Template definition
template: 'NFTBan'           # CODE - used in expressions
name: 'NFTBan Firewall Monitoring'      # NAME - used in widget host:

# WRONG
host: NFTBan

# CORRECT
host: 'NFTBan Firewall Monitoring'
```

### Inventory Tab Empty (Despite Automatic Mode)

1. **Check Latest Data** - If items have values, template works
2. **Check preprocessing** - DISCARD_UNCHANGED_HEARTBEAT may filter
3. **Force refresh** - Clear cache, resend metrics
4. **Wait for heartbeat** - Inventory items often have 1d heartbeat

### Import Fails "UUIDv4 expected"

Check ALL UUIDs for RFC 4122 compliance:
```bash
python3 << 'EOF'
import re
with open('nftban_template_7x.yaml') as f:
    for uuid in re.findall(r'uuid: ([a-f0-9]{32})', f.read()):
        if uuid[12] != '4' or uuid[16] not in '89ab':
            print(f"INVALID: {uuid}")
EOF
```

### Dashboard Shows No Data

1. Check items receive data (Latest Data)
2. Check widget `host:` = template NAME
3. Check item keys match exactly
4. Verify user has permissions to template

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| UUIDs with dashes | Import fails "UUIDv4 expected" | Remove all dashes (32 chars) |
| Invalid UUID version | Import fails | Ensure pos12='4' |
| Invalid UUID variant | Import fails | Ensure pos16='8/9/a/b' |
| `host: NFTBan` (code) | "Inaccessible widget" | Use `host: 'NFTBan Firewall Monitoring'` (NAME) |
| Missing `host:` in widget | "Inaccessible widget" | Add `host: 'Template Name'` |
| `&lt;` `&gt;` in expressions | Import fails / triggers broken | Use raw `<` `>` operators |
| `width: 6` (integer) | Import fails "string expected" | Use `width: '6'` (string) |
| Wrong field suffix | Widget error | Use `.0` suffix (`itemid.0`) |
| YAML indentation | Parse error | Use 2-space indent consistently |
| `inventory_link: 3` (numeric) | May not populate | Use `inventory_link: NAME` (string) |
| Host inventory = Disabled | Fields stay empty | Set to Automatic |
| Inventory + HEARTBEAT | Fields don't populate | Force refresh or wait for heartbeat |

---

## Version History

| Zabbix | UUID Format | Notes |
|--------|-------------|-------|
| 6.x | 32-char no-dash | Less strict validation |
| 7.0 | 32-char no-dash | Strict RFC 4122 UUIDv4 validation |
| 7.0+ | 32-char no-dash | Same as 7.0 |

---

## References

- [Zabbix Template Guidelines](https://www.zabbix.com/documentation/current/en/manual/xml_export_import/templates)
- [RFC 4122 - UUID Specification](https://www.rfc-editor.org/rfc/rfc4122)
- [Zabbix Dashboard Widgets](https://www.zabbix.com/documentation/current/en/manual/web_interface/frontend_sections/dashboards/widgets)

---

*Last updated: 2026-01-24 | NFTBan v1.4.0*
