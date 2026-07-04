#!/usr/bin/env bash
# =============================================================================
# NFTBan — CONFIG_LOCAL_RECOVERY IMPL-2 — read-only `config local` verbs test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="config_local_impl2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-24"
# meta:description="IMPL-2: nftban config local list/validate/doctor are read-only diagnostics — list enumerates *.conf.local (path/base/sha/size/mtime/syntax), validate bash -n distinguishes OK/SYNTAX_ERROR, doctor lints KEY=VALUE against config-schema.json (OK/UNKNOWN_KEY/DEPRECATED_KEY/BAD_VALUE) with NO mutation/quarantine, registry+help wired, lint is schema-derived (no second key list)."
# meta:input="nftban_config_local.sh, config-schema.json, commands.registry.yml"
# meta:output="PASS/FAIL per assertion; nonzero on any FAIL"
# meta:depends="bash,jq,sha256sum,stat"
# meta:inventory.files=""
# meta:inventory.binaries="jq,sha256sum,stat,bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
export NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban"
_tmp="$(mktemp -d)"; export NFTBAN_CONFIG_DIR="$_tmp/etc/nftban"
mkdir -p "$NFTBAN_CONFIG_DIR/conf.d"
trap 'rm -rf "$_tmp"' EXIT
P=0; F=0; ok(){ P=$((P+1)); echo "  PASS: $1"; }; no(){ F=$((F+1)); echo "  FAIL: $1"; }

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/env.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_config_schema.sh"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_config_local.sh"
# env.sh / schema set -Eeuo pipefail; this test deliberately exercises verbs that
# return nonzero (the "issues found" contract), so drop -e here (keep -u + pipefail).
set +e

# plant fixtures
printf 'NFTBAN_SSH_TEST_PORT="2222"\n' > "$NFTBAN_CONFIG_DIR/conf.d/recovery.conf.local"          # clean, valid
printf 'NFTBAN_RECOVERY_ENABLED="true"\nNFTBAN_FAKE_KEY_XYZ="x"\nNFTBAN_SSH_TEST_PORT="nope"\n' > "$NFTBAN_CONFIG_DIR/conf.d/ddos.conf.local"  # deprecated+unknown+badvalue
printf 'NFTBAN_A="1"\n((( broken\n' > "$NFTBAN_CONFIG_DIR/nftban.conf.local"                       # malformed

echo "== list =="
out=$(nftban_cmd_config_local_list)
grep -q 'recovery.conf.local' <<<"$out" && grep -q 'overrides:' <<<"$out" && ok "list enumerates .local + base mapping" || no "list enumerate"
grep -q 'MALFORMED' <<<"$out" && ok "list flags MALFORMED syntax" || no "list syntax flag"
nftban_cmd_config_local_list --json | jq -e 'type=="array" and length==3 and (.[0]|has("sha256") and has("size") and has("mtime") and has("syntax"))' >/dev/null && ok "list --json (3 files, sha/size/mtime/syntax)" || no "list --json"

echo "== validate =="
nftban_cmd_config_local_validate >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "validate rc≠0 (malformed present)" || no "validate rc"
vout=$(nftban_cmd_config_local_validate 2>&1)
grep -q 'SYNTAX_ERROR.*nftban.conf.local' <<<"$vout" && ok "validate flags SYNTAX_ERROR on malformed" || no "validate syntax_error"
grep -q 'OK .*recovery.conf.local' <<<"$vout" && ok "validate OK on clean" || no "validate ok"

echo "== doctor classification (schema-derived) =="
dout=$(nftban_cmd_config_local_doctor 2>&1); drc_out=$(nftban_cmd_config_local_doctor >/dev/null 2>&1; echo $?)
grep -q 'DEPRECATED_KEY NFTBAN_RECOVERY_ENABLED' <<<"$dout" && ok "doctor: deprecated recovery key → DEPRECATED_KEY" || no "doctor deprecated"
grep -q 'UNKNOWN_KEY .*NFTBAN_FAKE_KEY_XYZ' <<<"$dout" && ok "doctor: unknown key → UNKNOWN_KEY" || no "doctor unknown"
grep -q 'BAD_VALUE .*NFTBAN_SSH_TEST_PORT' <<<"$dout" && ok "doctor: bad value → BAD_VALUE" || no "doctor bad_value"
grep -qE 'OK +NFTBAN_SSH_TEST_PORT' <<<"$dout" && ok "doctor: valid key+value → OK" || no "doctor ok"
[ "$drc_out" -ne 0 ] && ok "doctor rc≠0 when issues found" || no "doctor rc"
# capture first — doctor exits nonzero by design (issues found); pipefail would otherwise
# mask jq's verdict with doctor's rc.
djson=$(nftban_cmd_config_local_doctor --json 2>/dev/null)
printf '%s' "$djson" | jq -e '[.[]|select(.path|endswith("ddos.conf.local")).keys[].class] as $c
  | (["DEPRECATED_KEY","UNKNOWN_KEY","BAD_VALUE"]|all(. as $x|$c|index($x)!=null))' >/dev/null \
  && ok "doctor --json carries DEPRECATED+UNKNOWN+BAD_VALUE" || no "doctor --json"

echo "== READ-ONLY (no mutation, no quarantine) =="
pre=$(find "$NFTBAN_CONFIG_DIR" -name '*.local' -exec sha256sum {} \; | sort)
nftban_cmd_config_local_list >/dev/null 2>&1; nftban_cmd_config_local_validate >/dev/null 2>&1; nftban_cmd_config_local_doctor >/dev/null 2>&1
post=$(find "$NFTBAN_CONFIG_DIR" -name '*.local' -exec sha256sum {} \; | sort)
[ "$pre" = "$post" ] && ok ".local files byte-identical after all verbs" || no "files mutated"
[ ! -d "$_tmp/var/lib/nftban/config-quarantine" ] && [ ! -d "$NFTBAN_CONFIG_DIR/config-quarantine" ] && ok "no config-quarantine dir created" || no "quarantine dir appeared"
# no mutating verbs leaked into the dispatcher
for v in disable reset restore quarantine; do
  nftban_cmd_config_local "$v" >/dev/null 2>&1 && no "mutating verb '$v' is accepted (must not exist in IMPL-2)" || :; done
ok "no disable/reset/restore/quarantine verbs in 'config local'"

echo "== help + registry contract =="
nftban_cmd_config_local --help 2>&1 | grep -qi 'read-only' && ok "config local --help present + states read-only" || no "help"
nftban_cmd_config_local doctor --help 2>&1 | grep -qi 'never modifies' && ok "doctor --help states read-only by design (no future mutate mode implied)" || no "doctor help wording"
python3 -c "import yaml,sys; d=yaml.safe_load(open('$REPO_ROOT/commands.registry.yml')); s=d['config']['subcommands']['local']; sys.exit(0 if (s.get('mutates') is False and set(s['subcommands'])>={'list','validate','doctor'}) else 1)" \
  && ok "commands.registry.yml: config.local wired (mutates:false, list/validate/doctor)" || no "registry wiring"

echo "== -e safety (production dispatcher runs set -Eeuo pipefail) =="
# A malformed .local is present; under -e a verb that returns 0 must still complete
# fully (no mid-loop [[ ]] && abort). list returns 0 and must emit all 3 files.
n_listed=$( set -Eeuo pipefail; nftban_cmd_config_local_list 2>/dev/null | grep -c 'overrides:' )
[ "$n_listed" -eq 3 ] && ok "list completes under -e with malformed fixture present (3 files, no abort)" || no "-e abort: only $n_listed/3 listed"

echo "== single source of truth (no second hardcoded key allowlist) =="
# the lint must derive keys from config-schema.json via the schema accessor, not an embedded list
if grep -qE 'nftban_(config_validate_value|schema_get_property)' "$NFTBAN_LIB_DIR/core/nftban_config_local.sh" \
   && ! grep -qE '^[[:space:]]*(VALID_KEYS|ALLOWED_KEYS|KNOWN_KEYS)=' "$NFTBAN_LIB_DIR/core/nftban_config_local.sh"; then
  ok "lint is schema-derived (no embedded key allowlist)"
else no "lint not schema-derived / embedded key list found"; fi

echo "-----------------------------------------------"
echo "config local IMPL-2 tests: $P passed, $F failed"
[ "$F" -eq 0 ]
