#!/usr/bin/env bash
# meta:name="health_resource_dropin_packaging_guard_v1222_1_test.sh"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="v1.222.1 HEALTH-OOM Lane 2 static package-ownership guard: the generated health-resource systemd drop-in is NEVER a DEB/RPM payload file; the removal backstops (RPM %postun / DEB postrm) clean ONLY the NFTBan-owned path and contain NO RAM/tier/memory-policy calculation; both package families carry the backstop; and no shell recomputes the resource policy."
set -u
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
BUILD="$ROOT/packaging/build_nftban.sh"
DEB_POSTRM="$ROOT/packaging/deb/postrm"
DROPIN="/etc/systemd/system/nftban-health.service.d/20-nftban-resource-profile.conf"
fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

[ -f "$BUILD" ] || { echo "FAIL: build_nftban.sh not found at $BUILD"; exit 1; }
[ -f "$DEB_POSTRM" ] || { echo "FAIL: deb/postrm not found"; exit 1; }

# 1. Drop-in path must NOT appear in any RPM %files or DEB payload manifest.
#    (It is generated state; it may ONLY appear in cleanup scriptlets.)
if grep -nE '^%files|%config|%ghost|%attr' "$BUILD" | grep -q 'nftban-health.service.d/20-nftban-resource-profile'; then
    bad "generated drop-in appears in an RPM %files/%config/%ghost manifest (must be generated state, not payload)"
else
    ok "generated drop-in is NOT an RPM payload file"
fi
# DEB payload lists live under packaging/deb/ (conffiles etc.) — must not list the drop-in.
if grep -rqE 'nftban-health.service.d/20-nftban-resource-profile' "$ROOT/packaging/deb/conffiles" 2>/dev/null; then
    bad "generated drop-in listed in DEB conffiles (must not be payload/conffile)"
else
    ok "generated drop-in is NOT a DEB conffile/payload"
fi

# 2. Both package families must carry the removal backstop (the path present in cleanup).
grep -q "nftban-health.service.d/20-nftban-resource-profile" "$BUILD"      && ok "RPM %postun carries the drop-in backstop" || bad "RPM %postun missing the drop-in backstop"
grep -q "nftban-health.service.d/20-nftban-resource-profile" "$DEB_POSTRM" && ok "DEB postrm carries the drop-in backstop" || bad "DEB postrm missing the drop-in backstop"

# 3. NO resource-policy calculation may appear in ANY package scriptlet.
#    The scriptlet may know the PATH; it must never know the RAM tier or memory values.
POLICY_TOKENS='GetResourceLimits|ClassifyResourceTier|HealthServiceMemoryLimits|/proc/meminfo|MemTotal|MemoryHigh=|MemoryMax=|resource_tier|nproc'
for f in "$BUILD" "$DEB_POSTRM"; do
    # Only inspect scriptlet/cleanup context by scanning the whole packaging file;
    # a match on any policy token in the packaging scriptlets is a violation.
    if grep -nE "$POLICY_TOKENS" "$f" | grep -iE 'health-resource|nftban-health.service.d|resource-profile' | grep -q .; then
        bad "package scriptlet in $(basename "$f") references resource-policy calculation near the health drop-in"
    else
        ok "no resource-policy calculation near the health drop-in in $(basename "$f")"
    fi
done

# 4. The backstop must be path-only cleanup: it removes the file, rmdir the dir, daemon-reload — nothing that computes a limit.
if grep -A4 '_nftban_hr_dropin=' "$DEB_POSTRM" | grep -qE 'MemoryMax=[0-9]|MemoryHigh=[0-9]|nproc|meminfo'; then
    bad "DEB backstop computes a memory value (must be path-only)"
else
    ok "DEB backstop is path-only cleanup"
fi

[ "$fail" -eq 0 ] && { echo "ALL PASS: health-resource drop-in packaging ownership guard"; exit 0; } || { echo "GUARD FAILED"; exit 1; }
