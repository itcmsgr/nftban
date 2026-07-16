#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="packaging/lib/provenance"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Build provenance: source-identity resolution, embedded-commit verification, prebuilt-manifest gen/verify, allowlisted bin cleanup — the anti-stale-prebuilt guard shared by build.sh and packaging/build_nftban.sh"
# meta:inventory.files="bin/*, build-manifest.json, SOURCE_COMMIT"
# meta:inventory.binaries="go, sha256sum, file, jq"
# meta:inventory.env_vars="PROV_SOURCE_COMMIT, PROV_SOURCE_VERSION"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# NOT executable on its own — `source` it. Every function is fail-closed:
# on any ambiguity it returns non-zero and prints an error, never a silent
# fallback to whatever binary happens to be on disk.
# =============================================================================

# The exact, complete set of packaged Go executables. A prebuilt bundle MUST
# contain all of these and nothing extra; the source build produces all of them.
set -Eeuo pipefail

PROV_BINARIES=(nftban-core nftband nftban-botscan-matcher nftban-validate nftban-detect-ssh-ports nftban-installer)

# Commit ANCHORS: binaries that reliably print the embedded 40-hex commit via
# `--version` (version.String()). Their embedded commit is read and checked to
# bind the whole build to the source commit. Every binary (anchor or not) is
# bound by sha256 in the manifest — all six are produced by ONE build.sh run — so
# a non-anchor (e.g. nftban-detect-ssh-ports, which has no --version) is still
# provenance-locked by its checksum + the anchors proving the source commit.
PROV_COMMIT_ANCHORS=(nftban-core nftband)

_prov_is_anchor() { local x="$1" a; for a in "${PROV_COMMIT_ANCHORS[@]}"; do [[ "$a" == "$x" ]] && return 0; done; return 1; }

PROV_TARGET_OS="linux"
PROV_TARGET_ARCH="amd64"

_prov_err() { echo "[provenance][ERROR] $*" >&2; }
_prov_log() { echo "[provenance] $*" >&2; }

# is the value a full 40-char lowercase hex commit?
prov_is_full_commit() {
	[[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]
}

# prov_resolve_source_identity <repo_root> [manifest_commit]
# Deterministic authority order → sets PROV_SOURCE_COMMIT (40-hex) + PROV_SOURCE_VERSION.
#   1. explicit manifest commit (prebuilt mode)   2. SOURCE_COMMIT file
#   3. git HEAD (full)                            4. hard failure
# When BOTH .git and SOURCE_COMMIT exist they must agree (a stale exported
# identity file must never contaminate a live checkout).
prov_resolve_source_identity() {
	local root="$1" manifest_commit="${2:-}"
	PROV_SOURCE_VERSION="$(cat "$root/VERSION" 2>/dev/null || echo "")"

	local git_commit="" file_commit=""
	if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
		git_commit="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo "")"
	fi
	if [[ -f "$root/SOURCE_COMMIT" ]]; then
		file_commit="$(tr -d '[:space:]' < "$root/SOURCE_COMMIT")"
	fi

	# .git + SOURCE_COMMIT must agree.
	if [[ -n "$git_commit" && -n "$file_commit" && "$git_commit" != "$file_commit" ]]; then
		_prov_err "SOURCE_COMMIT ($file_commit) != git HEAD ($git_commit) — stale exported identity in a live checkout"
		return 1
	fi

	local resolved=""
	if [[ -n "$manifest_commit" ]]; then
		# The manifest is authoritative for prebuilts, but it MUST NOT override a
		# contradictory source tree — it has to agree with any present git HEAD
		# and/or SOURCE_COMMIT.
		if [[ -n "$git_commit" && "$git_commit" != "$manifest_commit" ]]; then
			_prov_err "manifest commit ($manifest_commit) != git HEAD ($git_commit) — manifest cannot override the source tree"
			return 1
		fi
		if [[ -n "$file_commit" && "$file_commit" != "$manifest_commit" ]]; then
			_prov_err "manifest commit ($manifest_commit) != SOURCE_COMMIT ($file_commit)"
			return 1
		fi
		resolved="$manifest_commit"
	elif [[ -n "$file_commit" ]]; then
		resolved="$file_commit"
	elif [[ -n "$git_commit" ]]; then
		resolved="$git_commit"
	else
		_prov_err "no source identity: not a git checkout and no SOURCE_COMMIT file (refusing to embed 'dev')"
		return 1
	fi

	if ! prov_is_full_commit "$resolved"; then
		_prov_err "source commit '$resolved' is not a full 40-char hex sha (shortened sha is insufficient for provenance)"
		return 1
	fi
	PROV_SOURCE_COMMIT="$resolved"
	return 0
}

# prov_binary_embedded_commit <binary> → prints the 40-hex commit the binary was built from.
# Reads it from `--version` (works without Go, on the static linux/amd64 ELF).
prov_binary_embedded_commit() {
	local bin="$1" out c
	out="$("$bin" --version 2>/dev/null || true)"
	# format: "<component> <ver> (git <COMMIT>, build <DATE>)"
	c="$(printf '%s' "$out" | grep -oiE 'git [0-9a-f]{40}' | head -1 | awk '{print $2}')"
	[[ -n "$c" ]] || { _prov_err "$bin: no embedded 40-hex commit in --version (uninjected/'dev' build?)"; return 1; }
	printf '%s\n' "$c"
}

# prov_check_elf_arch <binary> — regular file (not symlink), ELF, linux, expected arch.
prov_check_elf_arch() {
	local bin="$1" ft
	[[ -e "$bin" ]] || { _prov_err "$bin: missing"; return 1; }
	[[ -L "$bin" ]] && { _prov_err "$bin: is a symlink (rejected)"; return 1; }
	[[ -f "$bin" ]] || { _prov_err "$bin: not a regular file"; return 1; }
	ft="$(file -b "$bin" 2>/dev/null)"
	[[ "$ft" == *ELF* ]] || { _prov_err "$bin: not an ELF ($ft)"; return 1; }
	# amd64 → "x86-64" in file(1) output
	case "$PROV_TARGET_ARCH" in
		amd64) [[ "$ft" == *x86-64* ]] || { _prov_err "$bin: not $PROV_TARGET_ARCH ($ft)"; return 1; } ;;
		arm64) [[ "$ft" == *aarch64* ]] || { _prov_err "$bin: not $PROV_TARGET_ARCH ($ft)"; return 1; } ;;
	esac
	return 0
}

prov_sha256() { sha256sum "$1" | awk '{print $1}'; }

# prov_clean_generated_bins <repo_root> — allowlisted deletion of ONLY the known
# generated binaries directly under <root>/bin. Never a broad rm; never a symlink;
# never a tracked/source path; never anything outside <root>/bin.
prov_clean_generated_bins() {
	local root="$1" bindir b target real_bin real_target
	bindir="$root/bin"
	[[ -d "$bindir" ]] || return 0
	real_bin="$(cd "$bindir" && pwd -P)" || return 1
	for b in "${PROV_BINARIES[@]}"; do
		target="$bindir/$b"
		[[ -e "$target" || -L "$target" ]] || continue
		# basename must be exactly an allowlisted name
		case " ${PROV_BINARIES[*]} " in *" $b "*) : ;; *) _prov_err "refuse: $b not allowlisted"; return 1 ;; esac
		# refuse symlinks (no traversal)
		if [[ -L "$target" ]]; then _prov_err "refuse: $target is a symlink"; return 1; fi
		# resolved parent dir must be exactly <root>/bin
		real_target="$(cd "$(dirname "$target")" && pwd -P)/$(basename "$target")"
		[[ "$(dirname "$real_target")" == "$real_bin" ]] || { _prov_err "refuse: $target escapes $real_bin"; return 1; }
		# must NOT be git-tracked source
		if git -C "$root" ls-files --error-unmatch "bin/$b" >/dev/null 2>&1; then
			_prov_err "refuse: bin/$b is git-tracked (not a generated output)"; return 1
		fi
		rm -f "$real_target" || { _prov_err "failed to remove $real_target"; return 1; }
	done
	return 0
}

# prov_write_manifest <repo_root> <bindir> <out.json> — schema v1, all 6 binaries.
prov_write_manifest() {
	local root="$1" bindir="$2" out="$3" b sha ec first=1 modlock
	prov_resolve_source_identity "$root" || return 1
	modlock="$( (cat "$root/go.mod" "$root/go.sum" 2>/dev/null) | sha256sum | awk '{print $1}')"
	{
		printf '{\n'
		printf '  "manifest_version": 1,\n'
		printf '  "source_commit": "%s",\n' "$PROV_SOURCE_COMMIT"
		printf '  "source_version": "%s",\n' "${PROV_SOURCE_VERSION:-}"
		printf '  "target_os": "%s",\n' "$PROV_TARGET_OS"
		printf '  "target_arch": "%s",\n' "$PROV_TARGET_ARCH"
		printf '  "go_version": "%s",\n' "$(go version 2>/dev/null | awk '{print $3}' || echo unknown)"
		printf '  "module_lock_sha256": "%s",\n' "$modlock"
		printf '  "binaries": [\n'
		for b in "${PROV_BINARIES[@]}"; do
			[[ -f "$bindir/$b" ]] || { _prov_err "manifest: missing $bindir/$b"; return 1; }
			sha="$(prov_sha256 "$bindir/$b")"
			if _prov_is_anchor "$b"; then
				ec="$(prov_binary_embedded_commit "$bindir/$b")" || return 1
				[[ "$ec" == "$PROV_SOURCE_COMMIT" ]] || { _prov_err "manifest: $b embedded $ec != source $PROV_SOURCE_COMMIT"; return 1; }
			else
				# non-anchor: bound by sha; commit is the shared source of this one build
				ec="$PROV_SOURCE_COMMIT"
			fi
			[[ $first -eq 1 ]] || printf ',\n'
			first=0
			printf '    { "name": "%s", "sha256": "%s", "embedded_commit": "%s" }' "$b" "$sha" "$ec"
		done
		printf '\n  ]\n}\n'
	} > "$out"
	_prov_log "wrote manifest $out (source $PROV_SOURCE_COMMIT)"
	return 0
}

# prov_verify_prebuilt <repo_root> <bindir> <manifest.json>
# Mode 3 gate: verify ALL SIX binaries against the manifest AND the source identity.
# Rejects: missing/extra/duplicate binaries, bad type/ELF/arch/OS, commit or sha
# mismatch, malformed hashes, version/manifest-version mismatch. Complete-set only.
prov_verify_prebuilt() {
	local root="$1" bindir="$2" manifest="$3"
	command -v jq >/dev/null 2>&1 || { _prov_err "jq required to verify a prebuilt manifest"; return 1; }
	[[ -f "$manifest" ]] || { _prov_err "manifest not found: $manifest"; return 1; }
	jq -e . "$manifest" >/dev/null 2>&1 || { _prov_err "manifest is not valid JSON"; return 1; }

	local mver mcommit mos march
	mver="$(jq -r '.manifest_version' "$manifest")"
	[[ "$mver" == "1" ]] || { _prov_err "unsupported manifest_version: $mver"; return 1; }
	mcommit="$(jq -r '.source_commit' "$manifest")"
	mos="$(jq -r '.target_os' "$manifest")"
	march="$(jq -r '.target_arch' "$manifest")"
	[[ "$mos" == "$PROV_TARGET_OS" ]]   || { _prov_err "manifest target_os $mos != $PROV_TARGET_OS"; return 1; }
	[[ "$march" == "$PROV_TARGET_ARCH" ]] || { _prov_err "manifest target_arch $march != $PROV_TARGET_ARCH"; return 1; }

	# source identity: manifest commit is the authority in prebuilt mode, but if a
	# live source identity exists it MUST agree.
	prov_resolve_source_identity "$root" "$mcommit" || return 1
	[[ "$PROV_SOURCE_COMMIT" == "$mcommit" ]] || { _prov_err "manifest commit != resolved source identity"; return 1; }

	# manifest binary set must equal the required set exactly (no missing / extra / dup)
	local names dupes
	names="$(jq -r '.binaries[].name' "$manifest")"
	dupes="$(printf '%s\n' "$names" | sort | uniq -d)"
	[[ -z "$dupes" ]] || { _prov_err "duplicate binary names in manifest: $dupes"; return 1; }
	local want got
	want="$(printf '%s\n' "${PROV_BINARIES[@]}" | sort)"
	got="$(printf '%s\n' "$names" | sort)"
	[[ "$want" == "$got" ]] || { _prov_err "manifest binary set != required 6 (missing/extra)"; return 1; }

	# no extra Go executable on disk beyond the 6
	local f base
	for f in "$bindir"/*; do
		[[ -f "$f" ]] || continue
		base="$(basename "$f")"
		case " ${PROV_BINARIES[*]} " in *" $base "*) : ;; *)
			# only fail for ELF extras (ignore manifest/notes)
			file -b "$f" 2>/dev/null | grep -q ELF && { _prov_err "unexpected ELF in bindir: $base"; return 1; } ;;
		esac
	done

	local b msha mec dsha dec
	for b in "${PROV_BINARIES[@]}"; do
		msha="$(jq -r --arg n "$b" '.binaries[] | select(.name==$n) | .sha256' "$manifest")"
		mec="$(jq -r --arg n "$b" '.binaries[] | select(.name==$n) | .embedded_commit' "$manifest")"
		[[ "$msha" =~ ^[0-9a-f]{64}$ ]] || { _prov_err "$b: malformed manifest sha256"; return 1; }
		prov_is_full_commit "$mec" || { _prov_err "$b: malformed manifest embedded_commit"; return 1; }
		[[ "$mec" == "$mcommit" ]] || { _prov_err "$b: manifest embedded_commit != source_commit"; return 1; }
		prov_check_elf_arch "$bindir/$b" || return 1
		dsha="$(prov_sha256 "$bindir/$b")"
		[[ "$dsha" == "$msha" ]] || { _prov_err "$b: on-disk sha $dsha != manifest $msha"; return 1; }
		# Anchor binaries additionally prove their embedded commit matches (source binding);
		# non-anchors are bound by the sha above + the anchors' commit proof.
		if _prov_is_anchor "$b"; then
			dec="$(prov_binary_embedded_commit "$bindir/$b")" || return 1
			[[ "$dec" == "$mec" ]] || { _prov_err "$b: embedded $dec != manifest $mec"; return 1; }
		fi
	done
	_prov_log "prebuilt bundle VERIFIED: all ${#PROV_BINARIES[@]} binaries @ $mcommit"
	return 0
}

# prov_verify_source_build <repo_root> <bindir> — after a source rebuild, assert
# every one of the 6 exists, is ELF/arch-correct, and embeds the resolved source commit.
prov_verify_source_build() {
	local root="$1" bindir="$2" b ec
	prov_resolve_source_identity "$root" || return 1
	for b in "${PROV_BINARIES[@]}"; do
		prov_check_elf_arch "$bindir/$b" || return 1
		if _prov_is_anchor "$b"; then
			ec="$(prov_binary_embedded_commit "$bindir/$b")" || return 1
			[[ "$ec" == "$PROV_SOURCE_COMMIT" ]] || { _prov_err "$b embedded $ec != source $PROV_SOURCE_COMMIT"; return 1; }
		fi
	done
	_prov_log "source build VERIFIED: all ${#PROV_BINARIES[@]} binaries present (anchors embed $PROV_SOURCE_COMMIT)"
	return 0
}
