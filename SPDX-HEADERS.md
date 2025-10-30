# SPDX Header Templates

Use these headers at the **top of each file**. Pick the one that matches the content.

## A) Core Source Files (MPL‑2.0)
```
# Copyright (c) 2024–2026 NFTBAN Project / Antonios Voulvoulis
# SPDX-License-Identifier: MPL-2.0
```

## B) Pro / Proprietary Source Files
For proprietary code, use an SPDX LicenseRef and reference your Pro license file:

```
# Copyright (c) 2024–2026 NFTBAN Project / Antonios Voulvoulis
# SPDX-License-Identifier: LicenseRef-NFTBAN-Pro-Commercial
```

Place a copy of the **nftban Pro Commercial License Agreement** in `licenses/NFTBAN-Pro-Commercial.md`
and add this clarifying line where possible:

```
# This file is licensed under the nftban Pro Commercial License Agreement.
# Unauthorized copying or distribution is prohibited.
```

## C) Documentation or Brand Assets (All Rights Reserved)
```
# Copyright (c) 2024–2026 NFTBAN Project / Antonios Voulvoulis
# SPDX-License-Identifier: LicenseRef-NFTBAN-Docs
```

Create a short `licenses/NFTBAN-Docs.txt` that states “All rights reserved. See TRADEMARK.md and BRANDING guidelines.”

## D) Third‑Party Files
Do **not** remove upstream headers. Add an additional line referencing their SPDX identifier where appropriate.