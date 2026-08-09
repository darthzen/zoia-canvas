#!/usr/bin/env python3
"""Regenerate Tests/ZoiaCanvasTests/Corpus/manifest.json.

The manifest is ground truth for PatchDecoderTests.matchesPythonOracle: each
corpus patch parsed by zoia_lib's Python decoder, reduced to the fields the
Swift decoder is compared against. Files zoia_lib's own parser fails on are
listed on stderr and omitted from the manifest (the Swift tests know which
ones those are and why).

Usage: build_manifest.py /path/to/zoia_lib/clone
"""

import glob
import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    sys.path.insert(0, sys.argv[1])
    from zoia_lib.backend.patch_binary import PatchBinary

    parser = PatchBinary()
    root = os.path.join(os.path.dirname(__file__), "..",
                        "Tests", "ZoiaCanvasTests", "Corpus")
    root = os.path.abspath(root)

    manifest = {}
    failures = []
    for path in sorted(glob.glob(root + "/**/*.bin", recursive=True)):
        rel = os.path.relpath(path, root)
        try:
            with open(path, "rb") as fh:
                parsed = parser.parse_data(fh.read())
        except Exception as exc:  # noqa: BLE001 - report and continue
            failures.append((rel, repr(exc)))
            continue
        manifest[rel] = {
            "name": parsed["name"],
            "size": parsed["size"],
            "n_modules": parsed["meta"]["n_modules"],
            "n_connections": parsed["meta"]["n_connections"],
            "n_starred": parsed["meta"]["n_starred"],
            "module_ids": [m["mod_idx"] for m in parsed["modules"]],
        }

    with open(os.path.join(root, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)

    print(f"manifest: {len(manifest)} patches", file=sys.stderr)
    for rel, err in failures:
        print(f"zoia_lib failed on {rel}: {err}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
