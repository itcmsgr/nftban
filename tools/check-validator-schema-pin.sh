#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-validator-schema-pin"
# meta:type="tool"
# meta:description="P12-A01: assert the shell continuation classifier's SUPPORTED producer schema matches Go validator.SchemaVersionCurrent"
#
# ⛔ WHY THIS EXISTS
# The InstallerContinuation classifier consumes validator JSON SEMANTICS, not just field
# names — Runtime OMISSION means "not daemon-dependent", Structural=unknown means
# "expectation unestablished", has("config") identifies a module shape. A newer producer
# schema could change any of those while keeping the field names.
#
# So the consumer PINS the producer schema it knows how to interpret. That pin duplicates
# one value across Go and shell ON PURPOSE: it is a PRODUCER/CONSUMER COMPATIBILITY
# CONTRACT, not a second semantic authority. This check makes the drift MECHANICALLY
# DETECTABLE instead of silent.
#
# When it fails, the required answer is NOT "bump the number". It is:
#   "are the fields and omission semantics consumed by InstallerContinuation still
#    compatible with the new producer schema?"  Update deliberately, either way.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GO_SRC="$ROOT/internal/validator/types.go"
SH_SRC="$ROOT/cli/lib/nftban/core/nftban_rebuild_classify.sh"

[[ -r "$GO_SRC" ]] || { echo "FAIL: cannot read $GO_SRC" >&2; exit 2; }
[[ -r "$SH_SRC" ]] || { echo "FAIL: cannot read $SH_SRC" >&2; exit 2; }

go_ver=$(grep -oE 'SchemaVersionCurrent[[:space:]]*=[[:space:]]*"[^"]+"' "$GO_SRC" | grep -oE '"[^"]+"' | tr -d '"' | head -1)
sh_set=$(grep -oE 'SUPPORTED_VALIDATOR_SCHEMAS="[^"]*"' "$SH_SRC" | grep -oE '"[^"]*"' | tr -d '"' | head -1)

[[ -n "$go_ver" ]] || { echo "FAIL: SchemaVersionCurrent not found in $GO_SRC" >&2; exit 1; }
[[ -n "$sh_set" ]] || { echo "FAIL: SUPPORTED_VALIDATOR_SCHEMAS not found in $SH_SRC" >&2; exit 1; }

printf 'validator SchemaVersionCurrent      : %s\n' "$go_ver"
printf 'classifier SUPPORTED_VALIDATOR_SCHEMAS: %s\n' "$sh_set"

for v in $sh_set; do
    if [[ "$v" == "$go_ver" ]]; then
        echo "PASS — the consumer accepts the current producer schema."
        exit 0
    fi
done
cat >&2 <<MSG
FAIL — VALIDATOR SCHEMA DRIFT.
  The continuation classifier does not accept the validator's current schema.
  DO NOT simply bump the pin. Answer this first:
    are the fields AND OMISSION SEMANTICS consumed by InstallerContinuation
    (Runtime omitted => not daemon-dependent; Structural=unknown => expectation
     unestablished; has("config") => module shape) still compatible with $go_ver?
  If yes  -> add $go_ver to SUPPORTED_VALIDATOR_SCHEMAS deliberately.
  If no   -> update the classifier, then the pin.
MSG
exit 1
