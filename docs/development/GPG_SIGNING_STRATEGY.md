# NFTBan - GPG Package Signing Strategy

**Document Type:** Developer Reference
**Purpose:** Complete GPG signing implementation guide for future releases
**Based on:** ChatGPT discussion (Auto_sign_GIT_CHAT)
**Status:** For v0.10.1+ implementation

---

## 🎯 OVERVIEW

This document describes NFTBan's package signing strategy for ensuring package authenticity and integrity.

### Version Timeline

| Version | Verification Method | Status |
|---------|-------------------|---------|
| v0.10.0 | SHA256 checksums only | ✅ Current |
| v0.10.1+ | SHA256 + GPG signatures | 📋 Planned |

---

## 🔐 WHAT IS PACKAGE SIGNING?

### Definition
Package signing is a cryptographic signature added to RPM/DEB packages to prove:
- **Authenticity:** Package comes from NFTBan project, not a malicious actor
- **Integrity:** Package wasn't modified after we built it
- **Trust:** Enterprise users require signed packages

### How It Works

```
1. Developer has GPG private key (secret)
2. Build process signs packages with private key
3. Public key is distributed to users
4. Users import public key
5. Package manager verifies signature automatically
```

---

## 🚫 WHY NOT v0.10.0?

We decided to skip signing for v0.10.0 because:

1. **Complexity:** GPG key management, distribution, CI/CD integration
2. **Not Critical:** GitHub Releases + checksums provide adequate verification initially
3. **Key Infrastructure:** Need proper key management before signing
4. **COPR/PPA Requirement:** Signing is more critical when we have repositories

### v0.10.0 Approach (Current)

```bash
# User downloads package
wget https://github.com/itcmsgr/nftban/releases/download/v0.10.0/nftban-0.10.0-1.el9.x86_64.rpm

# User downloads checksums
wget https://github.com/itcmsgr/nftban/releases/download/v0.10.0/SHA256SUMS

# User verifies integrity
sha256sum -c SHA256SUMS
# Output: nftban-0.10.0-1.el9.x86_64.rpm: OK

# This verifies:
# ✓ File not corrupted
# ✓ File not modified
# ✗ Doesn't prove source (but GitHub Release URL does)
```

---

## ✅ IMPLEMENTATION PLAN (v0.10.1+)

### Phase 1: GPG Key Creation

```bash
# Generate signing key (one-time setup)
gpg --quick-generate-key "NFTBan Release <contact@nftban.com>" rsa3072 sign 0

# Set key to never expire (or set expiration date)
# Export public key for distribution
gpg --export --armor contact@nftban.com > RELEASES.KEY

# Export fingerprint
gpg --fingerprint contact@nftban.com | grep "Key fingerprint" | cut -d'=' -f2 > KEY.FPR

# Backup private key (SECURE STORAGE!)
gpg --export-secret-keys --armor contact@nftban.com > nftban-release-private.key.asc
# Store in password manager, not in git!
```

---

### Phase 2: GitHub Secrets Setup

Store these as GitHub repository secrets:

**Secret 1: GPG_PRIVATE_KEY_B64**
```bash
# Export private key as base64
gpg --export-secret-keys --armor contact@nftban.com | base64 -w0 > /tmp/key.b64
cat /tmp/key.b64
# Copy this to GitHub Settings → Secrets → GPG_PRIVATE_KEY_B64
rm /tmp/key.b64
```

**Secret 2: GPG_PASSPHRASE**
```
The passphrase you used when creating the key
Copy to GitHub Settings → Secrets → GPG_PASSPHRASE
```

---

### Phase 3: GitHub Actions Integration

The workflow blocks are already in `.github/workflows/release.yml` (commented out).

To enable signing:

1. **Uncomment GPG blocks** in release.yml:
   ```yaml
   # Change this:
   # - name: Import GPG key
   #   if: false  # Enable when ready: change to 'true'

   # To this:
   - name: Import GPG key
     if: true  # ENABLED
   ```

2. **Import GPG key** (workflow step):
   ```yaml
   - name: Import GPG private key
     run: |
       echo "$GPG_PRIVATE_KEY_B64" | base64 -d > /tmp/private.key.asc
       gpg --batch --yes --import /tmp/private.key.asc
       KEYID=$(gpg --list-secret-keys --keyid-format=long | awk '/sec/{print $2}' | sed 's|.*/||' | head -n1)
       echo "KEYID=$KEYID" >> $GITHUB_ENV
     env:
       GPG_PRIVATE_KEY_B64: ${{ secrets.GPG_PRIVATE_KEY_B64 }}
   ```

3. **Configure RPM signing** (workflow step):
   ```yaml
   - name: Configure RPM signing macros
     run: |
       mkdir -p ~/.rpmmacros.d
       cat > ~/.rpmmacros <<EOF
       %_gpg_name $KEYID
       %_signature gpg
       %_gpg_path ~/.gnupg
       %_gpgbin /usr/bin/gpg
       %__gpg /usr/bin/gpg
       EOF
   ```

4. **Sign RPM packages** (workflow step):
   ```yaml
   - name: Sign RPM packages
     working-directory: dist
     env:
       GPG_PASSPHRASE: ${{ secrets.GPG_PASSPHRASE }}
     run: |
       # Configure gpg-agent for batch mode
       mkdir -p ~/.gnupg
       echo "allow-loopback-pinentry" >> ~/.gnupg/gpg-agent.conf
       echo "use-agent" >> ~/.gnupg/gpg.conf
       gpgconf --kill gpg-agent || true

       # Sign all RPM files
       for f in *.rpm; do
         echo "$GPG_PASSPHRASE" | rpmsign --addsign \
           --define "_gpg_digest_algo sha256" \
           --passphrase-fd 0 "$f"

         # Verify signature
         rpm --checksig "$f"
       done
   ```

5. **Sign DEB packages** (workflow step):
   ```yaml
   - name: Sign DEB packages
     working-directory: dist
     env:
       GPG_PASSPHRASE: ${{ secrets.GPG_PASSPHRASE }}
     run: |
       for f in *.deb; do
         echo "$GPG_PASSPHRASE" | dpkg-sig --batch \
           --passphrase-fd 0 --sign builder "$f"

         # Verify signature
         dpkg-sig --verify "$f"
       done
   ```

6. **Upload public key** (workflow step):
   ```yaml
   - name: Upload public key and fingerprint
     uses: softprops/action-gh-release@v2
     with:
       files: |
         RELEASES.KEY
         KEY.FPR
     env:
       GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
   ```

---

### Phase 4: User Instructions Update

Update `VERIFY.txt` to include signature verification:

```
═══════════════════════════════════════════════════════════════
  NFTBan v0.10.1+ - Package Verification (with GPG signatures)
═══════════════════════════════════════════════════════════════

## STEP 1: Import NFTBan public key (one-time)

wget https://github.com/itcmsgr/nftban/releases/download/v0.10.1/RELEASES.KEY
gpg --import RELEASES.KEY

# Optional: Verify fingerprint
wget https://github.com/itcmsgr/nftban/releases/download/v0.10.1/KEY.FPR
gpg --fingerprint contact@nftban.com
# Compare with KEY.FPR

## STEP 2: Verify RPM signature

rpm --checksig nftban-0.10.1-1.el9.x86_64.rpm
# Expected output:
# nftban-0.10.1-1.el9.x86_64.rpm: digests signatures OK

## STEP 3: Verify DEB signature

dpkg-sig --verify nftban_0.10.1-1_amd64.deb
# Expected output:
# GOODSIG _gpgbuilder [...]

## STEP 4: Install with confidence

sudo dnf install ./nftban-0.10.1-1.el9.x86_64.rpm
# OR
sudo apt install ./nftban_0.10.1-1_amd64.deb
```

---

## 📦 RPM SIGNING DETAILS

### Signing Command
```bash
# Manual signing (local development)
rpmsign --addsign --define "_gpg_digest_algo sha256" nftban-0.10.1-1.el9.x86_64.rpm
```

### Verification Command
```bash
# Verify signature
rpm --checksig nftban-0.10.1-1.el9.x86_64.rpm

# Detailed verification
rpm -qip nftban-0.10.1-1.el9.x86_64.rpm --qf "%{SIGPGP:pgpsig}\n"
```

### RPM Macros Required
```
%_gpg_name [KEY_ID]
%_signature gpg
%_gpg_path ~/.gnupg
%_gpgbin /usr/bin/gpg
%__gpg /usr/bin/gpg
```

---

## 📦 DEB SIGNING DETAILS

### Signing Command
```bash
# Manual signing (local development)
dpkg-sig --sign builder nftban_0.10.1-1_amd64.deb
```

### Verification Command
```bash
# Verify signature
dpkg-sig --verify nftban_0.10.1-1_amd64.deb

# Detailed info
dpkg-deb --info nftban_0.10.1-1_amd64.deb
```

---

## 🔑 KEY MANAGEMENT BEST PRACTICES

### Security Requirements

1. **Private Key Storage:**
   - ❌ NEVER commit to git
   - ✅ Store in password manager
   - ✅ Use strong passphrase
   - ✅ Backup securely (encrypted)

2. **GitHub Secrets:**
   - ✅ Use repository secrets (not environment secrets)
   - ✅ Limit access to maintainers only
   - ✅ Rotate passphrase annually

3. **Key Rotation:**
   - Set expiration date (recommend 2 years)
   - Plan key rotation before expiration
   - Sign new key with old key (trust chain)

### Key Revocation Plan

If private key is compromised:

```bash
# 1. Revoke key immediately
gpg --gen-revoke contact@nftban.com > revocation.asc
gpg --import revocation.asc

# 2. Upload revocation certificate
gpg --keyserver keys.openpgp.org --send-keys [KEY_ID]

# 3. Announce on GitHub, website, social media

# 4. Generate new key (see Phase 1)

# 5. Re-sign all packages with new key

# 6. Update GitHub secrets

# 7. Publish new RELEASES.KEY
```

---

## 🌐 PUBLIC KEY DISTRIBUTION

### Primary Distribution Channels

1. **GitHub Releases** (primary)
   - RELEASES.KEY in every release
   - KEY.FPR for fingerprint verification

2. **Public Keyservers** (recommended)
   ```bash
   gpg --keyserver keys.openpgp.org --send-keys [KEY_ID]
   gpg --keyserver keyserver.ubuntu.com --send-keys [KEY_ID]
   ```

3. **Website** (if available)
   - https://nftban.com/RELEASES.KEY
   - Fingerprint displayed prominently

4. **Repository metadata** (COPR/PPA)
   - Automatically handled by COPR/PPA
   - Users trust repo, repo trusts our key

---

## 🧪 TESTING PROCEDURE

Before enabling signing in production:

### Test 1: Local Signing
```bash
# Generate test key
gpg --quick-generate-key "Test Key" rsa3072 sign 1y

# Sign test package
rpmsign --addsign test.rpm
dpkg-sig --sign builder test.deb

# Verify
rpm --checksig test.rpm
dpkg-sig --verify test.deb
```

### Test 2: CI/CD Signing
```bash
# Create test tag
git tag v0.10.0-test-gpg
git push origin v0.10.0-test-gpg

# Watch GitHub Actions
# Verify artifacts are signed
```

### Test 3: User Verification
```bash
# Fresh system
gpg --import RELEASES.KEY
rpm --checksig downloaded.rpm
# Should show: signatures OK
```

---

## 📋 CHECKLIST FOR v0.10.1

Before enabling GPG signing:

- [ ] Generate production GPG key
- [ ] Backup private key securely
- [ ] Add GPG_PRIVATE_KEY_B64 to GitHub secrets
- [ ] Add GPG_PASSPHRASE to GitHub secrets
- [ ] Uncomment GPG blocks in .github/workflows/release.yml
- [ ] Test with test tag (v0.10.0-test-gpg)
- [ ] Verify signatures work on clean systems
- [ ] Update VERIFY.txt with signature instructions
- [ ] Upload RELEASES.KEY to keyservers
- [ ] Publish fingerprint on website/README
- [ ] Document key rotation schedule
- [ ] Create key revocation certificate (backup)
- [ ] Test RPM signature on Rocky 9
- [ ] Test DEB signature on Ubuntu 22.04
- [ ] Update user documentation
- [ ] Announce GPG signing in release notes

---

## 🔗 REFERENCES

### Tools Used
- **gpg:** GNU Privacy Guard
- **rpmsign:** RPM signing utility
- **dpkg-sig:** Debian package signing utility
- **GitHub Actions:** CI/CD automation

### Documentation
- GPG Manual: https://gnupg.org/documentation/
- RPM Signing: https://rpm-packaging-guide.github.io/
- DEB Signing: https://www.debian.org/doc/debian-policy/
- GitHub Actions: https://docs.github.com/en/actions

### Security Resources
- Key Management: https://wiki.debian.org/DebianRepository/UseThirdParty
- COPR Signing: https://docs.pagure.org/copr.copr/user_documentation.html
- PPA Signing: https://help.launchpad.net/Packaging/PPA

---

## 💡 FUTURE ENHANCEMENTS

### Possible Improvements (v0.11.0+)

1. **Automated Key Rotation**
   - Generate new key automatically before expiration
   - Sign with old key for trust chain

2. **Reproducible Builds**
   - Bit-for-bit identical builds
   - Anyone can verify package matches source

3. **Notary/TUF Integration**
   - The Update Framework for secure updates
   - Timestamped trust

4. **In-toto Attestations**
   - Supply chain attestation
   - Build provenance verification

5. **SLSA Provenance**
   - Supply-chain Levels for Software Artifacts
   - Level 3 or 4 compliance

---

## ⚠️  IMPORTANT NOTES

### Do NOT Enable Until:
1. COPR/PPA repositories are ready (v0.10.1+)
2. Key management infrastructure is in place
3. Revocation plan is documented
4. Testing is complete

### Why This Matters:
- Once enabled, users will expect signatures
- Disabling later breaks trust
- Key compromise requires immediate action
- Enterprise users require signing

---

**Document Status:** Complete and ready for v0.10.1 implementation
**Last Updated:** 2025-10-28
**Next Review:** Before v0.10.1 release
