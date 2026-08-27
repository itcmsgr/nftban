#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="continuation-classifier-test"
# meta:type="test"
# meta:description="P12-A01/A01b: InstallerContinuation classifier — attribution, precedence, fail-closed"
# meta:ta.id="rebuild_disposition_v122912_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# ⛔ FIXTURES USE THE REAL validator health_output.go FIELD NAMES ONLY.
#    config | structural | runtime | service_state.nftband | schema_version
#    No synthetic `reason` / `base_firewall_valid` / `runtime_required` fields exist.
set -uo pipefail
ROOT="${NFTBAN_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=/dev/null
source "$ROOT/core/nftban_rebuild_classify.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; total=0
mk(){ printf '%s' "$2" > "$T/$1.json"; }
chk(){ local name=$1 want=$2 ctx=$3 f=$4 fatal=$5 st=$6; total=$((total+1))
  local got; got=$(_rebuild_disposition_classify "$ctx" "$f" "$fatal" "$st" | cut -f1)
  if [[ "$got" == "$want" ]]; then printf '  PASS  %-48s %s\n' "$name" "$got"
  else printf '  FAIL  %-48s want %s got %s\n' "$name" "$want" "$got"; fails=$((fails+1)); fi; }
V='"schema_version":"1.84.0"'

mk a "{$V,\"status\":\"degraded\",\"service_state\":{\"nftband\":\"STOPPED\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"missing\",\"runtime\":\"stopped\"}}}"
chk "enabled+missing+runtime=stopped+daemon STOPPED"   DEFERRED_RUNTIME install-deferred "$T/a.json" "" degraded
mk b "{$V,\"status\":\"degraded\",\"service_state\":{\"nftband\":\"RUNNING\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"missing\",\"runtime\":\"running\"}}}"
chk "enabled+missing+runtime=running"                  REGRESSION  install-deferred "$T/b.json" "" degraded
mk c "{$V,\"status\":\"degraded\",\"service_state\":{\"nftband\":\"STOPPED\"},\"modules\":{\"geoban\":{\"config\":\"enabled\",\"structural\":\"missing\"}}}"
chk "enabled+missing+runtime OMITTED (not daemon-dep)" REGRESSION  install-deferred "$T/c.json" "" degraded
mk d "{$V,\"status\":\"degraded\",\"service_state\":{\"nftband\":\"STOPPED\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"unknown\",\"runtime\":\"stopped\"}}}"
chk "structural=unknown -> fail closed"                REGRESSION  install-deferred "$T/d.json" "" degraded
mk e "{$V,\"status\":\"protected\",\"service_state\":{\"nftband\":\"STOPPED\"},\"modules\":{\"ddos\":{\"config\":\"disabled\"}}}"
chk "DISABLED module absent -> no deferred requirement" COMPLETE install-deferred "$T/e.json" "" protected
chk "FATAL APPLY_FAILED dominates daemon-down"         FATAL       install-deferred "$T/a.json" "APPLY_FAILED" degraded
chk "FATAL generation-commit dominates daemon-down"    FATAL       install-deferred "$T/a.json" "GENERATION_COMMIT_FAILED" degraded
mk g 'this is not json {{{'
chk "malformed JSON -> fail closed"                    REGRESSION  install-deferred "$T/g.json" "" degraded
chk "missing observation file -> fail closed"          REGRESSION  install-deferred "$T/nope.json" "" degraded
mk h "{$V,\"status\":\"degraded\",\"service_state\":{\"nftband\":\"STOPPED\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"missing\",\"runtime\":\"stopped\"},\"botguard\":{\"config\":\"enabled\",\"structural\":\"missing\"}}}"
chk "MIXED attributable+unexplained -> NOT deferred"   REGRESSION  install-deferred "$T/h.json" "" degraded
mk i "{$V,\"status\":\"degraded\",\"service_state\":{\"nftband\":\"ERROR\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"missing\",\"runtime\":\"stopped\"}}}"
chk "daemon ERROR (query failed) -> fail closed"       REGRESSION  install-deferred "$T/i.json" "" degraded
chk "attributable but NOT install-context"             REGRESSION  runtime-required "$T/a.json" "" degraded
mk j "{$V,\"status\":\"protected\",\"service_state\":{\"nftband\":\"RUNNING\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"present\",\"runtime\":\"running\"}}}"
chk "all present + protected"                          COMPLETE runtime-required "$T/j.json" "" protected
mk k "{\"status\":\"degraded\",\"service_state\":{\"nftband\":\"STOPPED\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"missing\",\"runtime\":\"stopped\"}}}"
chk "NO schema_version -> fail closed"                 REGRESSION  install-deferred "$T/k.json" "" degraded
mk l "{$V,\"status\":\"down\",\"service_state\":{\"nftband\":\"RUNNING\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"present\",\"runtime\":\"running\"}}}"
chk "nothing missing but status=down -> regression"    REGRESSION  runtime-required "$T/l.json" "" down

mk m "{\"schema_version\":\"99.0.0\",\"status\":\"degraded\",\"service_state\":{\"nftband\":\"STOPPED\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"missing\",\"runtime\":\"stopped\"}}}"
chk "UNSUPPORTED schema 99.0.0 -> fail closed"         REGRESSION  install-deferred "$T/m.json" "" degraded
mk n "{\"schema_version\":\"2.0.0\",\"status\":\"protected\",\"service_state\":{\"nftband\":\"RUNNING\"},\"modules\":{\"ddos\":{\"config\":\"enabled\",\"structural\":\"present\",\"runtime\":\"running\"}}}"
chk "UNSUPPORTED schema even when healthy -> closed"   REGRESSION  runtime-required "$T/n.json" "" protected

echo; if (( fails )); then echo "CLASSIFIER FIXTURES FAILED ($fails/$total)"; exit 1; fi
echo "CLASSIFIER FIXTURES PASSED — $total/$total"
