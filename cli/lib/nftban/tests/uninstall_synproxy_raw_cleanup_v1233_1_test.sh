#!/usr/bin/env bash
# =============================================================================
# NFTBan - Uninstall removes NFTBan SYNPROXY raw notrack rules (v1.233.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="uninstall_synproxy_raw_cleanup_v1233_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="packaging"
# meta:ta.id="uninstall_synproxy_raw_cleanup_v1233_1_test"
# meta:ta.owner="packaging"
# meta:ta.module="uninstall-lifecycle"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.233.1 BUG-UNINSTALL-DOES-NOT-REMOVE-SYNPROXY-RAW-NOTRACK-RULES. NFTBan's SYNPROXY notrack rules live in the FOREIGN ip/ip6 raw prerouting chains; after Stop()!=Disable() no daemon stop removes them, so every uninstall path must. Locks: (1) DRIFT - the self-contained _nftban_uninstall_synproxy_raw is byte-identical in packaging/deb/postrm, the RPM %postun of the GENERATED spec (rendered from packaging/build_nftban.sh) and uninstall.sh; (2) PLACEMENT/ORDERING - DEB postrm remove AND purge arms and RPM %postun (\$1 -eq 0 only) call it after the nftban table deletions; uninstall.sh calls it from uninstall_nftables; the function sources nothing (payload is gone at postrm/%postun time) and mutates only 'nft delete rule ... raw prerouting handle N'; the daemon is stopped before (DEB prerm remove, RPM %preun \$1==0); (3) FUNCTIONAL on a stateful fake kernel, for EACH of the three copies, under sh -e (scriptlet) and bash -Eeuo pipefail (uninstall.sh): NFTBan SYNPROXY rules removed from ip and ip6, POSITIVE CONTROL operator notrack rules in ip raw prerouting survive, a SYNPROXY-commented rule in raw output survives, raw tables/chains survive; no raw tables => no mutation; nft missing / listing EPERM => NOT_OBSERVED reported, rc 0, nothing deleted; failed delete => residue reported, rc 0; (4) NEGATIVE CONTROL against v1.233.0 (eef635a6): its postrm has no raw cleanup and its remove-arm statements leave the rule in place."
# meta:inventory.files="packaging/deb/postrm,packaging/deb/prerm,packaging/build_nftban.sh,uninstall.sh,cli/lib/nftban/lib/nft_fragment.sh"
# meta:inventory.binaries="bash,sh,awk,git,tar,grep,sed,env"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SD/../../../.." && pwd)"
HIST_SHA="eef635a692a4802464e399b74cdbf0f4e562fc53"   # v1.233.0
POSTRM="$ROOT/packaging/deb/postrm"
PRERM="$ROOT/packaging/deb/prerm"
BUILD="$ROOT/packaging/build_nftban.sh"
UNINST="$ROOT/uninstall.sh"
FN=_nftban_uninstall_synproxy_raw

PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }

for b in awk git tar sh env; do
    command -v "$b" >/dev/null 2>&1 || { echo "NOT_EXECUTED: required binary '$b' missing - this is not a PASS"; exit 1; }
done

W="$(mktemp -d)"; _owner=$$
trap '[ "$$" = "$_owner" ] && rm -rf "$W"' EXIT

echo "=== Uninstall removes NFTBan SYNPROXY raw notrack rules (v1.233.1) ==="

# -----------------------------------------------------------------------------
# Render the REAL RPM spec from the REAL generator (the heredoc is the subject)
# -----------------------------------------------------------------------------
awk '/^create_rpm_spec_nftban_core\(\) *\{/{n=1}
     n && /<<EOF$/{h=1}
     n && h && /^EOF$/{h=0; print; next}
     n{print}
     n && !h && /^\}$/{exit}' "$BUILD" > "$W/gen.sh"
mkdir -p "$W/SPECS"
(
    set +e
    export BUILD_DIR="$W" PROJECT_ROOT="$ROOT"
    export PKG_VERSION="0.0.0-test" PKG_RELEASE="1" PKG_VERSION_DATE="2026-01-01"
    log_info(){ :; }; log_error(){ :; }; log_warn(){ :; }; log_success(){ :; }
    # shellcheck disable=SC1091
    . "$W/gen.sh"
    create_rpm_spec_nftban_core
) >"$W/gen.out" 2>"$W/gen.err"
SPEC="$W/SPECS/nftban-core.spec"
if [ -s "$SPEC" ]; then
    ok "R0 RPM spec rendered from packaging/build_nftban.sh ($(wc -l < "$SPEC") lines)"
else
    no "R0 RPM spec generation failed - every RPM arm would be vacuous" "$(head -3 "$W/gen.err")"
    echo "  PASS=$PASS FAIL=$FAIL"; exit 1
fi
GENERR=$(grep -vF 'log_success' "$W/gen.err" | grep -v '^[[:space:]]*$' || true)
[ -z "$GENERR" ] && ok "R0b spec generation executed nothing (heredoc inert)" \
                 || no "R0b spec generation executed something - unescaped \$( ) in the heredoc" "$GENERR"
POSTUN="$W/postun.sh"
awk '/^%postun$/{n=1;next} n && /^%[a-z]+$/{exit} n{print}' "$SPEC" > "$POSTUN"

# -----------------------------------------------------------------------------
# (1) DRIFT: one function, three byte-identical copies
# -----------------------------------------------------------------------------
extract_fn(){ awk '/^# >>> NFTBAN_SYNPROXY_RAW_CLEANUP_BEGIN >>>$/{f=1} f{print} /^# <<< NFTBAN_SYNPROXY_RAW_CLEANUP_END <<<$/{f=0}' "$1"; }
extract_fn "$POSTRM" > "$W/fn.deb"
extract_fn "$POSTUN" > "$W/fn.rpm"
extract_fn "$UNINST" > "$W/fn.uninst"
for c in deb rpm uninst; do
    n=$(grep -c "^${FN}() {" "$W/fn.$c" || true)
    [ "$n" = 1 ] && ok "D1 $c copy present exactly once" || no "D1 $c copy count=$n (want 1)"
done
if cmp -s "$W/fn.deb" "$W/fn.rpm" && cmp -s "$W/fn.deb" "$W/fn.uninst"; then
    ok "D2 DEB postrm == rendered RPM %postun == uninstall.sh (byte-identical, $(wc -l < "$W/fn.deb") lines)"
else
    no "D2 copies drifted" "$(diff "$W/fn.deb" "$W/fn.rpm" | head -5; diff "$W/fn.deb" "$W/fn.uninst" | head -5)"
fi
# Each file defines the function exactly once (no stray second definition).
for f in "$POSTRM" "$POSTUN" "$UNINST"; do
    n=$(grep -c "^[[:space:]]*${FN}() {" "$f" || true)
    [ "$n" = 1 ] || no "D3 $(basename "$f") defines $FN $n times"
done
ok "D3 single definition per subject"

# -----------------------------------------------------------------------------
# (2) PLACEMENT / ORDERING / SCOPE (comments stripped: prose never satisfies)
# -----------------------------------------------------------------------------
code(){ sed 's/[[:space:]]#.*$//; /^[[:space:]]*#/d'; }
body="$(code < "$W/fn.deb")"
if grep -qE '(^|[;[:space:]])(source|\.)[[:space:]]+/|/usr/lib/nftban|NFTBAN_LIB_DIR' <<<"$body"; then
    no "P1 function references product libraries (payload is gone at postrm/%postun time)"
else
    ok "P1 function is self-contained (sources nothing, no /usr/lib/nftban)"
fi
muts="$(grep -oE 'nft [a-z-]+ [a-z]+' <<<"$body" | sort -u | tr '\n' '|')"
if grep -qE 'flush|delete (table|chain)|add |insert |replace ' <<<"$body"; then
    no "P2 function carries a non rule-scoped mutation" "$muts"
elif grep -qE 'nft delete rule "\$_nsr_fam" raw prerouting handle "\$_nsr_h"' <<<"$body"; then
    ok "P2 only mutation is 'nft delete rule <fam> raw prerouting handle N' ($muts)"
else
    no "P2 delete-by-handle statement not found" "$muts"
fi
arm(){ awk -v a="$2" 'index($0, "    " a ")") == 1 {i=1;next} i && /^        ;;/{exit} i{print}' "$1" | code; }
for a in remove purge; do
    ab="$(arm "$POSTRM" "$a")"
    ln_del=$(grep -n 'nft delete table ip6 nftban' <<<"$ab" | head -1 | cut -d: -f1)
    ln_fn=$(grep -n "^[[:space:]]*${FN}[[:space:]]*$" <<<"$ab" | head -1 | cut -d: -f1)
    if [[ -n "$ln_fn" && -n "$ln_del" && "$ln_fn" -gt "$ln_del" ]]; then
        ok "P3 DEB postrm $a) calls $FN after the nftban table deletion (line $ln_fn > $ln_del)"
    else
        no "P3 DEB postrm $a) call missing or before the table deletion (fn=${ln_fn:-none} del=${ln_del:-none})"
    fi
done
upg="$(arm "$POSTRM" 'upgrade|failed-upgrade|abort-install|abort-upgrade|disappear')"
if [ -z "$upg" ]; then
    no "P3b DEB postrm upgrade arm not found - arm extraction is vacuous"
elif grep -q "$FN" <<<"$upg"; then
    no "P3b DEB postrm upgrade arm must not clean raw rules (upgrade keeps protection)"
else
    ok "P3b DEB postrm upgrade/abort arm exists and does not call it"
fi
pb="$(code < "$POSTUN")"
blk0="$(awk '/^if \[ \$1 -eq 0 \]; then$/{i=1;next} i && /^fi$/{exit} i{print}' <<<"$pb")"
blk1="$(awk '/^if \[ \$1 -ge 1 \]; then$/{i=1;next} i && /^fi$/{exit} i{print}' <<<"$pb")"
ln_del=$(grep -n 'nft delete table ip6 nftban' <<<"$blk0" | head -1 | cut -d: -f1)
ln_fn=$(grep -n "^[[:space:]]*${FN}[[:space:]]*$" <<<"$blk0" | head -1 | cut -d: -f1)
if [[ -n "$ln_fn" && -n "$ln_del" && "$ln_fn" -gt "$ln_del" ]]; then
    ok "P4 RPM %postun (\$1 -eq 0) calls $FN after the nftban table deletion"
else
    no "P4 RPM %postun erase block call missing or misordered (fn=${ln_fn:-none} del=${ln_del:-none})"
fi
[[ -n "$blk1" ]] && ! grep -q "$FN" <<<"$blk1" \
    && ok "P4b RPM %postun upgrade block (\$1 -ge 1) does not call it" \
    || no "P4b RPM upgrade block missing or calls the raw cleanup"
def_ln=$(grep -n "^${FN}() {" <<<"$pb" | cut -d: -f1); call_ln=$(grep -n "^[[:space:]]*${FN}[[:space:]]*$" <<<"$pb" | head -1 | cut -d: -f1)
[[ -n "$def_ln" && -n "$call_ln" && "$def_ln" -lt "$call_ln" ]] \
    && ok "P4c RPM %postun defines the function before calling it" \
    || no "P4c RPM %postun definition/call order wrong (def=${def_ln:-none} call=${call_ln:-none})"
ub="$(awk '/^uninstall_nftables\(\) \{/{i=1;next} i && /^\}/{exit} i{print}' "$UNINST" | code)"
grep -qE "^[[:space:]]*${FN}[[:space:]]*$" <<<"$ub" \
    && ok "P5 uninstall.sh uninstall_nftables calls $FN (rpm -e --noscripts never runs %postun)" \
    || no "P5 uninstall.sh does not call $FN from uninstall_nftables"
grep -qE 'nftband\.service' <<<"$(arm "$PRERM" 'remove|deconfigure')" \
    && ok "P6 DEB prerm remove) stops nftband before files go (dpkg: prerm -> unpack removal -> postrm)" \
    || no "P6 DEB prerm remove arm does not stop nftband"
grep -qE 'nftband\.service' <<<"$(awk '/^%preun$/{n=1;next} n && /^%[a-z]+$/{exit} n{print}' "$SPEC")" \
    && ok "P6b RPM %preun (\$1 -eq 0) stops nftband before %postun" \
    || no "P6b RPM %preun does not stop nftband"
# Scope parity with the product's own remover (comment marker).
grep -qF "grep -i 'comment.*\"SYNPROXY:'" "$ROOT/cli/lib/nftban/lib/nft_fragment.sh" \
    && grep -qF 'tolower($0) ~ /comment.*"synproxy:/' "$W/fn.deb" \
    && ok "P7 marker scope == _nft_cleanup_synproxy_raw (case-insensitive comment.*\"SYNPROXY:)" \
    || no "P7 marker scope diverged from _nft_cleanup_synproxy_raw"

# -----------------------------------------------------------------------------
# (3) FUNCTIONAL: stateful fake kernel
# -----------------------------------------------------------------------------
FK="$W/fk"; mkdir -p "$FK/bin" "$FK/nonft"
cat >"$FK/bin/nft" <<'FAKENFT'
#!/usr/bin/env bash
# rules: $FK/<fam>.rules, "<handle>\t<chain>\t<text>"; table present iff file exists.
set -uo pipefail
FK="${FAKE_NFT_ROOT:?}"
printf 'argv: %s\n' "$*" >>"$FK/calls.log"
err(){ printf 'Error: %s\n' "$*" >&2; exit 1; }
a="$*"
case "$a" in
    "list tables")
        [ "${FAKE_LIST_TABLES_FAIL:-0}" = 1 ] && err "Operation not permitted"
        echo "table ip filter"
        for f in ip ip6; do [ -f "$FK/$f.rules" ] && echo "table $f raw"; done
        echo "table inet operator_misc"
        exit 0 ;;
    "-a list table "*" raw")
        f="${a#-a list table }"; f="${f% raw}"
        [ "${FAKE_LIST_RAW_FAIL:-}" = "$f" ] && err "Operation not permitted"
        [ -f "$FK/$f.rules" ] || err "No such file or directory"
        printf 'table %s raw { # handle 3\n' "$f"
        for ch in prerouting output; do
            printf '\tchain %s { # handle %s\n' "$ch" "${#ch}"
            printf '\t\ttype filter hook %s priority raw; policy accept;\n' "$ch"
            while IFS=$'\t' read -r h c t; do
                [ "$c" = "$ch" ] && printf '\t\t%s # handle %s\n' "$t" "$h"
            done <"$FK/$f.rules"
            printf '\t}\n'
        done
        printf '}\n'; exit 0 ;;
    "delete rule "*" raw prerouting handle "*)
        set -- $a; f="$3"; h="$7"
        [ "${FAKE_DELETE_FAIL:-}" = "$f:$h" ] && err "Device or resource busy"
        [ -f "$FK/$f.rules" ] || err "No such file or directory"
        awk -F'\t' -v h="$h" '$1==h && $2=="prerouting"{found=1} END{exit !found}' "$FK/$f.rules" || err "No such file or directory: handle $h"
        awk -F'\t' -v h="$h" '!($1==h && $2=="prerouting")' "$FK/$f.rules" >"$FK/$f.tmp" && mv "$FK/$f.tmp" "$FK/$f.rules"
        echo "deleted $f:$h" >>"$FK/deleted.log"; exit 0 ;;
esac
echo "UNEXPECTED: $a" >>"$FK/unexpected.log"
err "fake nft: unsupported: $a"
FAKENFT
chmod +x "$FK/bin/nft"
export FAKE_NFT_ROOT="$FK"
BASEPATH="/usr/bin:/bin"
NFT_OP='udp dport 53 notrack comment "operator: dns notrack"'
NFT_OP2='iifname "docker0" notrack'
NFT_NB='tcp dport { 80, 443 } tcp flags syn / syn,ack,fin,rst notrack comment "SYNPROXY: notrack SYN"'
NFT_OUT='tcp dport 25 notrack comment "SYNPROXY: output-chain rule"'
seed(){ # both families: operator, nftban, operator, output-chain
    rm -f "$FK"/*.rules "$FK"/*.log
    local f b=10
    for f in ip ip6; do
        printf '%s\tprerouting\t%s\n%s\tprerouting\t%s\n%s\tprerouting\t%s\n%s\toutput\t%s\n' \
            $((b+1)) "$NFT_OP" $((b+2)) "$NFT_NB" $((b+3)) "$NFT_OP2" $((b+4)) "$NFT_OUT" >"$FK/$f.rules"
        b=$((b+10))
    done
}
has(){ grep -qF -- "$2" "$FK/$1.rules" 2>/dev/null; }
RC=0; OUT=""; ERR=""
run_copy(){ # <copy> <shell-mode> [env...]
    local copy="$1" mode="$2"; shift 2
    local drv="$W/drv.$copy.$mode.sh" path="$FK/bin:$BASEPATH"
    [ "${NO_NFT:-0}" = 1 ] && path="$FK/nonft"
    if [ "$mode" = sh ]; then
        { echo 'set -e'; cat "$W/fn.$copy"; echo "$FN"; echo 'echo DRIVER_COMPLETED'; } >"$drv"
        RC=0; OUT="$(env -i PATH="$path" FAKE_NFT_ROOT="$FK" "$@" sh "$drv" 2>"$W/err")" || RC=$?
    else
        { echo 'set -Eeuo pipefail'; cat "$W/fn.$copy"; echo "$FN"; echo 'echo DRIVER_COMPLETED'; } >"$drv"
        RC=0; OUT="$(env -i PATH="$path" FAKE_NFT_ROOT="$FK" "$@" bash "$drv" 2>"$W/err")" || RC=$?
    fi
    ERR="$(cat "$W/err")"
    [[ "$OUT" == *DRIVER_COMPLETED* ]]
}
# nft-less PATH: ONLY the interpreters and awk (the host may ship a real nft in
# /usr/bin, so the base PATH cannot be reused). It must really have no nft.
for t in sh bash awk; do
    tp="$(command -v "$t" 2>/dev/null || true)"
    [ -n "$tp" ] && ln -sf "$tp" "$FK/nonft/$t"
done
if env -i PATH="$FK/nonft" sh -c 'command -v nft' >/dev/null 2>&1 || [ ! -x "$FK/nonft/awk" ]; then
    NO_NFT_OK=0
else
    NO_NFT_OK=1
fi

for copy in deb rpm uninst; do
  for mode in sh bash; do
    tag="$copy/$mode"
    # F1: the A7 arm - NFTBan rules removed, POSITIVE CONTROL survives
    seed
    if run_copy "$copy" "$mode"; then
        if [ "$RC" -eq 0 ] && ! has ip "$NFT_NB" && ! has ip6 "$NFT_NB" \
           && has ip "$NFT_OP" && has ip "$NFT_OP2" && has ip6 "$NFT_OP" && has ip "$NFT_OUT" && has ip6 "$NFT_OUT" \
           && [ -f "$FK/ip.rules" ] && [ -f "$FK/ip6.rules" ] && [ ! -s "$FK/unexpected.log" ]; then
            ok "F1 $tag UNINSTALL removes NFTBan SYNPROXY raw rules (ip,ip6); operator notrack rules + raw output chain + raw tables intact"
        else
            no "F1 $tag rc=$RC nb_ip=$(has ip "$NFT_NB" && echo y) op_ip=$(has ip "$NFT_OP" && echo y) out=$(has ip "$NFT_OUT" && echo y)" "$ERR $(cat "$FK/unexpected.log" 2>/dev/null)"
        fi
        n=$(grep -c . "$FK/deleted.log" 2>/dev/null || true)
        [ "$n" = 2 ] && grep -qx 'deleted ip:12' "$FK/deleted.log" && grep -qx 'deleted ip6:22' "$FK/deleted.log" \
            && ok "F1b $tag exactly two deletes, by handle (ip:12, ip6:22)" \
            || no "F1b $tag delete population wrong" "$(cat "$FK/deleted.log" 2>/dev/null)"
    else
        no "F1 $tag NOT_EXECUTED: driver did not complete (rc=$RC)" "$ERR"
    fi
    # F2: idempotent second run - nothing left, no deletes, no WARN
    if run_copy "$copy" "$mode"; then
        n=$(grep -c . "$FK/deleted.log" 2>/dev/null || true)
        [ "$RC" -eq 0 ] && [ "$n" = 2 ] && [ -z "$ERR" ] \
            && ok "F2 $tag second run is a silent no-op" || no "F2 $tag second run rc=$RC deletes=$n" "$ERR"
    else no "F2 $tag NOT_EXECUTED (rc=$RC)" "$ERR"; fi
    # F3: no raw tables at all -> no raw access beyond the inventory
    rm -f "$FK"/*.rules "$FK"/*.log
    if run_copy "$copy" "$mode"; then
        raw=$(grep -c ' raw' "$FK/calls.log" 2>/dev/null || true)
        [ "$RC" -eq 0 ] && [ "$raw" = 0 ] && [ -z "$ERR" ] \
            && ok "F3 $tag no raw tables -> only the inventory is read, no mutation" || no "F3 $tag rc=$RC raw_calls=$raw" "$ERR"
    else no "F3 $tag NOT_EXECUTED (rc=$RC)" "$ERR"; fi
    # F4: nft missing -> NOT_OBSERVED, rc 0
    seed
    if [ "$NO_NFT_OK" = 1 ] && NO_NFT=1 run_copy "$copy" "$mode"; then
        [ "$RC" -eq 0 ] && grep -q 'NOT_OBSERVED: nft not found' <<<"$ERR" && has ip "$NFT_NB" \
            && ok "F4 $tag nft missing -> NOT_OBSERVED reported on stderr, rc 0 (uninstall continues)" \
            || no "F4 $tag rc=$RC" "$ERR"
    else no "F4 $tag NOT_EXECUTED (nft-less PATH unavailable or driver failed, rc=$RC)" "$ERR"; fi
    # F5: inventory refused (EPERM) -> NOT_OBSERVED, nothing deleted
    seed
    if run_copy "$copy" "$mode" FAKE_LIST_TABLES_FAIL=1; then
        [ "$RC" -eq 0 ] && grep -q 'NOT_OBSERVED: nft list tables failed' <<<"$ERR" && [ ! -s "$FK/deleted.log" ] && has ip "$NFT_NB" \
            && ok "F5 $tag inventory EPERM -> NOT_OBSERVED, zero deletes, rc 0" || no "F5 $tag rc=$RC" "$ERR"
    else no "F5 $tag NOT_EXECUTED (rc=$RC)" "$ERR"; fi
    # F6: ip6 raw listing refused -> ip cleaned, ip6 reported
    seed
    if run_copy "$copy" "$mode" FAKE_LIST_RAW_FAIL=ip6; then
        [ "$RC" -eq 0 ] && grep -q 'NOT_OBSERVED (ip6 raw)' <<<"$ERR" && ! has ip "$NFT_NB" && has ip6 "$NFT_NB" \
            && ok "F6 $tag ip6 listing EPERM -> ip cleaned, ip6 NOT_OBSERVED reported, rc 0" || no "F6 $tag rc=$RC" "$ERR"
    else no "F6 $tag NOT_EXECUTED (rc=$RC)" "$ERR"; fi
    # F7: delete fails -> residue reported with count
    seed
    if run_copy "$copy" "$mode" FAKE_DELETE_FAIL=ip:12; then
        [ "$RC" -eq 0 ] && grep -q 'SYNPROXY raw notrack cleanup (ip): removed=0 failed=1 remaining=1' <<<"$ERR" && ! has ip6 "$NFT_NB" \
            && ok "F7 $tag failed delete -> residue (remaining=1) reported, rc 0" || no "F7 $tag rc=$RC" "$ERR"
    else no "F7 $tag NOT_EXECUTED (rc=$RC)" "$ERR"; fi
  done
done

# -----------------------------------------------------------------------------
# (4) NEGATIVE CONTROL: v1.233.0 has no raw cleanup in any uninstall path
# -----------------------------------------------------------------------------
H="$W/hist"; mkdir -p "$H"
if git -C "$ROOT" cat-file -e "${HIST_SHA}^{commit}" 2>/dev/null \
   && git -C "$ROOT" archive "$HIST_SHA" packaging/deb/postrm packaging/build_nftban.sh uninstall.sh | tar -x -C "$H" 2>/dev/null; then
    if ! grep -q "$FN\|raw prerouting" "$H/packaging/deb/postrm" "$H/packaging/build_nftban.sh" "$H/uninstall.sh"; then
        ok "N1 v1.233.0 postrm / spec / uninstall.sh carry no raw-SYNPROXY removal (the gap is real)"
    else
        no "N1 v1.233.0 already references raw prerouting - attribution wrong"
    fi
    seed
    while IFS= read -r s; do
        # shellcheck disable=SC2086
        env -i PATH="$FK/bin:$BASEPATH" FAKE_NFT_ROOT="$FK" nft ${s#nft } 2>/dev/null || true
    done < <(awk '/^    remove\)/{i=1;next} i&&/^        ;;/{exit} i{print}' "$H/packaging/deb/postrm" \
             | grep -E '^[[:space:]]*nft ' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*2>.*$//')
    has ip "$NFT_NB" && has ip6 "$NFT_NB" \
        && ok "N2 v1.233.0 DEB remove) statements leave the NFTBan raw rule in place - F1 discriminates" \
        || no "N2 v1.233.0 remove) removed the raw rule - F1 would be vacuous"
else
    no "N1 NOT_EXECUTED: v1.233.0 subject ${HIST_SHA:0:8} unavailable (shallow clone?) - negative control is not optional"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "uninstall synproxy raw cleanup PASSED"
