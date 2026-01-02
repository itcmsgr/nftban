#!/usr/bin/env python3
"""
Bundle NFTBan repository for Gemini API analysis.
Respects .gitignore and wraps files in XML structure.

Usage:
    python3 bundle_repo.py [repo_root] [output_file]

Example:
    python3 bundle_repo.py /home/gituser/github/nftban /tmp/nftban_bundle.txt
"""

import os
import pathlib
from pathlib import Path
import fnmatch
import sys

def should_ignore(path, gitignore_patterns):
    """Check if path matches .gitignore patterns."""
    # Always ignore these
    ignore_defaults = [
        '.git/', 'node_modules/', '__pycache__/', '*.pyc',
        '*.lock', 'package-lock.json', 'go.sum', '*.log',
        '.env', '.env.*', 'vendor/', 'dist/', 'build/',
        '*.so', '*.a', '*.o', 'bin/', 'tmp/', '.cache/',
        '*.swp', '*.swo', '*~', '.DS_Store',

        # IGNORE GUI/WEB FILES (known issues, not needed for analysis)
        '*.html', '*.htm', '*.css', '*.scss', '*.sass',
        '*.js', '*.jsx', '*.ts', '*.tsx', '*.json',
        'cmd/nftban-ui/', 'cmd/nftban-ui-auth/',
        'web/', 'ui/', 'static/', 'assets/',
        'pkg/ui/', 'pkg/web/', 'pkg/api/',
    ]

    for pattern in ignore_defaults + gitignore_patterns:
        if fnmatch.fnmatch(str(path), pattern) or fnmatch.fnmatch(path.name, pattern):
            return True
    return False

def load_gitignore(repo_root):
    """Load .gitignore patterns."""
    gitignore_path = repo_root / '.gitignore'
    if not gitignore_path.exists():
        return []

    patterns = []
    with open(gitignore_path, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                patterns.append(line)
    return patterns

def is_text_file(path):
    """Check if file is UTF-8 text."""
    try:
        with open(path, 'r', encoding='utf-8') as f:
            f.read(1024)  # Try reading first 1KB
        return True
    except (UnicodeDecodeError, IOError):
        return False

def bundle_repo(repo_root, output_file):
    """Bundle repository into XML-wrapped text file."""
    repo_root = Path(repo_root).resolve()
    gitignore_patterns = load_gitignore(repo_root)

    print(f"📦 Bundling repository: {repo_root}")
    print(f"📄 Output file: {output_file}\n")

    with open(output_file, 'w', encoding='utf-8') as out:
        # Write header
        out.write("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        out.write(f"<repository name=\"nftban\" root=\"{repo_root}\">\n\n")

        file_count = 0
        total_lines = 0

        # Walk directory tree
        for root, dirs, files in os.walk(repo_root):
            root_path = Path(root)

            # Filter ignored directories
            dirs[:] = [d for d in dirs if not should_ignore(root_path / d, gitignore_patterns)]

            for filename in sorted(files):
                file_path = root_path / filename
                relative_path = file_path.relative_to(repo_root)

                # Skip ignored files
                if should_ignore(relative_path, gitignore_patterns):
                    continue

                # Skip non-text files
                if not is_text_file(file_path):
                    print(f"⏭️  Skipping binary: {relative_path}")
                    continue

                # Read and wrap file
                try:
                    with open(file_path, 'r', encoding='utf-8') as f:
                        content = f.read()

                    out.write(f'<file path="{relative_path}">\n')
                    out.write(content)
                    if not content.endswith('\n'):
                        out.write('\n')
                    out.write('</file>\n\n')

                    file_count += 1
                    lines = content.count('\n')
                    total_lines += lines
                    print(f"✅ Bundled: {relative_path} ({lines:,} lines)")

                except Exception as e:
                    print(f"❌ Error reading {relative_path}: {e}")

        out.write("</repository>\n")

    print(f"\n{'='*70}")
    print(f"✅ Bundle complete!")
    print(f"{'='*70}")
    print(f"   Files: {file_count:,}")
    print(f"   Lines: {total_lines:,}")
    print(f"   Output: {output_file}")
    print(f"   Size: {Path(output_file).stat().st_size / 1024 / 1024:.2f} MB")
    print(f"{'='*70}\n")

if __name__ == "__main__":
    repo_root = sys.argv[1] if len(sys.argv) > 1 else "."
    output_file = sys.argv[2] if len(sys.argv) > 2 else "repo_bundle.txt"

    bundle_repo(repo_root, output_file)
