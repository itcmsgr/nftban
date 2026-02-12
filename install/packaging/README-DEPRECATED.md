# DEPRECATED - DO NOT USE

This directory is NOT used by the build system.

The single source of truth for packaging is:

    packaging/build_nftban.sh

This generates DEB control/spec files INLINE.

These files are kept temporarily for reference and will be removed in a future release.

## Why these files exist

Historical accumulation from earlier development. The build script was refactored
to generate all packaging metadata inline, making these standalone files obsolete.

## What to do

- **For packaging changes**: Edit `packaging/build_nftban.sh` directly
- **For DEB scripts**: Use `packaging/deb/postinst`, `packaging/deb/postrm`, etc.
- **Do NOT edit files in this directory** - they have no effect on builds
