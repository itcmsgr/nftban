#!/usr/bin/env bash
# =============================================================================
# NFTBan - SPDX-FileCopyrightText bulk annotator (v1.229.11 Lane 8)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="add-spdx-copyright"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-25"
# meta:description="Adds SPDX-FileCopyrightText to tracked files that already carry SPDX-License-Identifier, for REUSE compliance. DRY RUN by default; --apply writes. Idempotent. The holder/year string is FIXED and matches the owner-frozen canon in scripts/ci/data/legal-identity-surfaces.tsv, so check-license-identity.sh R4 keeps passing: it greps -F for 'Copyright (c) 2024-2026 Antonios Voulvoulis' and this line is a superstring of it. The holder is NEVER parsed from meta:owner -- several meta:owner values are junk ('metrics','botscan','update','ddos','suricata') and parsing would propagate those errors into legal metadata."
# meta:inventory.files="tools/add-spdx-copyright.sh"
# meta:inventory.binaries="git,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (writes only tracked source files)"
# =============================================================================

set -Eeuo pipefail

# ⛔ FIXED STRING. Frozen by the owner 2026-08-25; matches the 3 precedent files'
# format and is a grep -F superstring of the CI canon.
readonly HOLDER='Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>'
readonly TAG='SPDX-FileCopyrightText'

# ⛔ THE INTERSECTION OF TWO GATES, NOT EITHER ONE ALONE.
# The two authorities disagree about what "source" means, and an in-file
# attribution must satisfy BOTH:
#   tools/validate-headers.sh:34-56          treats .service/.timer/.socket/.path,
#                                            .cfg, .env and templates/* as SOURCE
#   check-core-ownership-identity.sh:146,150 exempts only .sh .go .py cli/sbin/*
#                                            .conf .rules .tsv .yml .yaml
# Annotating the difference (55 systemd units plus .githooks/pre-commit) turned
# each into an UNCLASSIFIED legal-identity surface and failed the ownership gate.
#   A FILE CLASS THAT IS "SOURCE" TO ONE AUTHORITY AND A "LEGAL SURFACE" TO
#   ANOTHER MUST SATISFY THE STRICTER ONE.
# Everything outside this intersection is covered by REUSE.toml, which states the
# same licence and copyright WITHOUT planting an attribution inside the file.
# ⛔ A SHIPPED dpkg/rpm CONFFILE MUST NEVER CARRY AN IN-FILE ANNOTATION.
# Adding one changes the file's checksum, so the new release ships a conffile that
# differs from the previous release's. Combined with the fact that some of these
# are rendered at install time (nftables.conf substitutes __CT_LIMIT_*__), dpkg
# sees "locally modified + new upstream version" and PROMPTS INTERACTIVELY. With
# no stdin — unattended-upgrades, ansible, any scripted rollout — the upgrade
# ABORTS half-configured.
# Measured on a clean v1.229.9 host: 71 of 74 conffiles had been annotated, and
# the v1.229.9 -> v1.229.11 upgrade failed with `end of file on stdin at conffile
# prompt`, leaving dpkg state `iU`.
#   ANNOTATING OPERATOR CONFIG TURNS EVERY UPGRADE INTO A QUESTION.
# These files get their licence and copyright from REUSE.toml instead, which
# asserts the same facts without altering a single shipped byte.
_is_conffile() {
    case "$1" in
        etc/nftban/*|install/config/*|install/nftables/nftables.conf) return 0 ;;
        # ⛔ NOT ALL CONFFILES LIVE UNDER etc/nftban/. install/sysctl/90-nftban.conf
        # ships to /etc/sysctl.d/ and is equally a declared conffile — the first
        # revision of this predicate missed it, and it was the ONE remaining
        # divergence out of 74 after the other 71 were fixed.
        #   A PATH-SHAPED PREDICATE MISSES EVERY FILE THAT DOES NOT SHARE THE PATH.
        install/sysctl/*) return 0 ;;
    esac
    return 1
}

_is_source() {
    _is_conffile "$1" && return 1
    case "$1" in
        *.sh|*.go|*.conf|*.rules) return 0 ;;
        cli/sbin/*)               return 0 ;;
    esac
    return 1
}

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

cd "$(git rev-parse --show-toplevel)"

added=0; skipped_have=0; skipped_nolicence=0; skipped_binary=0; skipped_nonsource=0

while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    # Binary files cannot carry a comment header; REUSE.toml covers them.
    if ! grep -Iq . "$f" 2>/dev/null; then skipped_binary=$((skipped_binary+1)); continue; fi
    # Idempotent: never add a second copyright line.
    if grep -q "$TAG" "$f" 2>/dev/null; then skipped_have=$((skipped_have+1)); continue; fi

    # Only ever annotate a file that ALREADY declares a licence. This makes it
    # structurally impossible to introduce copyright without licensing.
    #   NEVER CREATE A COPYRIGHT CLAIM ON A FILE WHOSE LICENCE IS UNDECLARED.
    # ⛔ SOURCE FILES ONLY — the same classes tools/validate-headers.sh governs.
    # check-core-ownership-identity.sh requires that every copyright-bearing
    # NON-SOURCE file be a REGISTERED legal surface. Stamping Dockerfile,
    # Makefile, .dockerignore, GOVERNANCE.md and docs/security/*.md with an
    # in-file attribution turned them into UNCLASSIFIED legal surfaces and failed
    # that gate 12 times. Those files get their licence and copyright from
    # REUSE.toml instead, which asserts the same facts WITHOUT planting a new
    # legal claim inside the file.
    #   AN IN-FILE ATTRIBUTION IS A LEGAL SURFACE. A REUSE.toml ENTRY IS METADATA.
    if ! _is_source "$f"; then skipped_nonsource=$((skipped_nonsource+1)); continue; fi

    # REUSE-IgnoreStart
    line="$(grep -nE '^[[:space:]]*(#|//)[[:space:]]*SPDX-License-Identifier:' "$f" 2>/dev/null | head -1 || true)"
    # REUSE-IgnoreEnd
    if [[ -z "$line" ]]; then skipped_nolicence=$((skipped_nolicence+1)); continue; fi

    n="${line%%:*}"
    text="${line#*:}"
    # Preserve the file's own comment style, taken from the licence line itself
    # rather than guessed from the extension.
    case "$text" in
        *'<!--'*) new="<!-- ${TAG}: ${HOLDER} -->" ;;
        *'//'*)   new="// ${TAG}: ${HOLDER}" ;;
        *)        new="# ${TAG}: ${HOLDER}" ;;
    esac

    if (( APPLY )); then
        # Insert immediately AFTER the licence line: the two tags stay adjacent
        # and the shebang/encoding lines above are untouched.
        # ⛔ PRESERVE THE FILE MODE. `awk > tmp && mv` creates the temp with the
        # default umask and then REPLACES the original, silently dropping the
        # executable bit. Measured: this stripped +x from 455 tracked files,
        # including every CI gate and cli/sbin/* -- and it broke
        # check-control-enforcement.sh, which tests `[[ -x "$script" ]]` and
        # reported two gates as "missing or not executable".
        #   A REWRITE THAT REPLACES A FILE MUST CARRY ITS MODE WITH IT.
        # Writing in place through the existing inode keeps mode and ownership.
        awk -v n="$n" -v ins="$new" 'NR==n{print; print ins; next} {print}' "$f" > "$f.spdxtmp" || {
            rm -f "$f.spdxtmp"; echo "ERROR: rewrite failed for $f" >&2; exit 1; }
        cat "$f.spdxtmp" > "$f"        # in-place: inode, mode and ownership survive
        rm -f "$f.spdxtmp"
    fi
    added=$((added+1))
done < <(git ls-files)

printf 'SPDX-FileCopyrightText annotator (%s)\n' "$( ((APPLY)) && echo APPLY || echo 'DRY RUN — pass --apply to write')"
printf '  would add / added ....... %d\n' "$added"
printf '  already had the tag ..... %d\n' "$skipped_have"
printf '  no licence line ......... %d  (REUSE.toml covers these)\n' "$skipped_nolicence"
printf '  non-source .............. %d  (REUSE.toml covers these)\n' "$skipped_nonsource"
printf '  binary .................. %d  (REUSE.toml covers these)\n' "$skipped_binary"
