#!/usr/bin/env python3
"""
G17: Health JSON Schema Validator

Validates nftban health --json output against the canonical schema.
Used in CI to prevent health output drift.

Usage:
    python3 validate-health-schema.py <json-file>
    python3 validate-health-schema.py --test  # Run test fixtures

Exit codes:
    0 = Valid
    1 = Invalid
    2 = Schema/file error
"""

import json
import sys
import os
from pathlib import Path

try:
    import jsonschema
    from jsonschema import Draft202012Validator, ValidationError
except ImportError:
    print("ERROR: jsonschema not installed. Run: pip install jsonschema", file=sys.stderr)
    sys.exit(2)

SCRIPT_DIR = Path(__file__).parent.absolute()
SCHEMA_DIR = SCRIPT_DIR.parent / "schemas" / "health"
SCHEMA_FILE = SCHEMA_DIR / "health-v1.0.0.schema.json"
TESTDATA_DIR = SCHEMA_DIR / "testdata"


def load_schema():
    """Load the health JSON schema."""
    if not SCHEMA_FILE.exists():
        print(f"ERROR: Schema not found: {SCHEMA_FILE}", file=sys.stderr)
        sys.exit(2)

    with open(SCHEMA_FILE) as f:
        return json.load(f)


def validate_json(json_data, schema):
    """Validate JSON data against schema. Returns (valid, errors)."""
    validator = Draft202012Validator(schema)
    errors = list(validator.iter_errors(json_data))
    return len(errors) == 0, errors


def validate_file(filepath, schema):
    """Validate a JSON file against the schema."""
    try:
        with open(filepath) as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        return False, [f"JSON parse error: {e}"]
    except FileNotFoundError:
        return False, [f"File not found: {filepath}"]

    valid, errors = validate_json(data, schema)
    error_msgs = [f"{e.json_path}: {e.message}" for e in errors]
    return valid, error_msgs


def run_tests(schema):
    """Run validation on test fixtures."""
    if not TESTDATA_DIR.exists():
        print(f"ERROR: Testdata directory not found: {TESTDATA_DIR}", file=sys.stderr)
        return False

    all_passed = True

    # Valid fixtures should pass
    valid_files = list(TESTDATA_DIR.glob("valid_*.json"))
    print(f"\n=== Testing {len(valid_files)} valid fixtures ===")
    for f in sorted(valid_files):
        valid, errors = validate_file(f, schema)
        if valid:
            print(f"  PASS: {f.name}")
        else:
            print(f"  FAIL: {f.name} (expected valid)")
            for err in errors[:3]:
                print(f"        {err}")
            all_passed = False

    # Invalid fixtures should fail
    invalid_files = list(TESTDATA_DIR.glob("invalid_*.json"))
    print(f"\n=== Testing {len(invalid_files)} invalid fixtures ===")
    for f in sorted(invalid_files):
        valid, errors = validate_file(f, schema)
        if not valid:
            print(f"  PASS: {f.name} (correctly rejected)")
        else:
            print(f"  FAIL: {f.name} (expected invalid, but passed)")
            all_passed = False

    print()
    return all_passed


def main():
    if len(sys.argv) < 2:
        print("Usage: validate-health-schema.py <json-file>", file=sys.stderr)
        print("       validate-health-schema.py --test", file=sys.stderr)
        sys.exit(2)

    schema = load_schema()

    if sys.argv[1] == "--test":
        success = run_tests(schema)
        sys.exit(0 if success else 1)

    filepath = sys.argv[1]
    valid, errors = validate_file(filepath, schema)

    if valid:
        print(f"VALID: {filepath}")
        sys.exit(0)
    else:
        print(f"INVALID: {filepath}", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
