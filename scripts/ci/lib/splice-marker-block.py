#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
"""Replace the body between a NFTBAN-GENERATED marker pair with a block file.

Argv: <target_file> <medium> <family_label_or_empty> <block_file>
Exit: 0 spliced · 3 marker pair not found (fail loudly; a silently missing
      marker would leave a stale hand-edited projection looking authoritative).
"""
import sys
import re

path, medium, fam, blockfile = sys.argv[1:5]
block = open(blockfile).read().rstrip('\n').split('\n')
src = open(path).read().split('\n')

beg = re.compile(r'^\s*#\s*>>> NFTBAN-GENERATED connlimit %s \(family %s\)'
                 % (re.escape(medium), re.escape(fam)))
end = re.compile(r'^\s*#\s*<<< NFTBAN-GENERATED connlimit %s \(family %s\)'
                 % (re.escape(medium), re.escape(fam)))

start = stop = None
for i, line in enumerate(src):
    if beg.match(line):
        start = i
    elif start is not None and end.match(line):
        stop = i
        break

if start is None or stop is None:
    sys.stderr.write("NO MARKER PAIR for medium=%s family=%s in %s\n"
                     % (medium, fam, path))
    sys.exit(3)

src[start + 1:stop] = block
open(path, 'w').write('\n'.join(src))
