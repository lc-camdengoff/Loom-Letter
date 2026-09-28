#!/usr/bin/env python3
"""
Loom Letter - update manifest.

Writes Fusion/LoomLetter/manifest.txt, which the panel's updater compares against the copy
on GitHub to decide which files to download. Run it after changing anything under Fusion/
(CI fails if it is out of date):

    python3 tools/build_manifest.py

Format:
    version 0.2.0
    <sha1>  <path relative to the Fusion folder>
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FUSION = ROOT / "Fusion"
SCRIPT = FUSION / "Scripts" / "Utility" / "Loom Letter.lua"
MANIFEST = FUSION / "LoomLetter" / "manifest.txt"

INCLUDE = [
    "Scripts/Utility/Loom Letter.lua",
    "Templates/Edit/Titles/Loom Letter/*.setting",
    "LoomLetter/previews/*.png",
]


def main():
    version = re.search(r'LL\.VERSION = "([^"]+)"', SCRIPT.read_text(encoding="utf-8")).group(1)
    lines = [f"version {version}"]
    for pattern in INCLUDE:
        for path in sorted(FUSION.glob(pattern)):
            digest = hashlib.sha1(path.read_bytes()).hexdigest()
            lines.append(f"{digest}  {path.relative_to(FUSION).as_posix()}")
    MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {MANIFEST.relative_to(ROOT)} ({len(lines) - 1} files, version {version})")


if __name__ == "__main__":
    main()
