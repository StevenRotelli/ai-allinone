#!/usr/bin/env python3
"""Assert at least one .ttf is directly inside /usr/share/fonts/truetype.

ComfyUI_Comfyroll_CustomNodes builds its font dropdown with a non-recursive
`os.listdir("/usr/share/fonts/truetype")` inside `INPUT_TYPES`, with no
try/except (nodes/nodes_graphics_text.py). Two ways that bites:

* No fonts at all -> FileNotFoundError raised while ComfyUI is answering
  /object_info, and the node is silently dropped from the UI. The image
  shipped this way until 2026-11-18; `CR Select Font` was simply absent.
* Fonts only in subdirectories (apt's layout: truetype/dejavu/, and so on)
  -> listdir returns directory names, `os.path.isfile` filters them all out,
  and the dropdown is empty.

So the invariant is specifically "a .ttf you can stat directly in that
directory", not "fonts are installed somewhere".
"""
import os
import sys

FONT_DIR = "/usr/share/fonts/truetype"


def main():
    if not os.path.isdir(FONT_DIR):
        print(f"FAIL: {FONT_DIR} does not exist", file=sys.stderr)
        return 1
    fonts = [
        f for f in os.listdir(FONT_DIR)
        if os.path.isfile(os.path.join(FONT_DIR, f)) and f.lower().endswith(".ttf")
    ]
    print(f"fonts visible to a non-recursive listdir of {FONT_DIR}: {len(fonts)}")
    if not fonts:
        print("FAIL: no .ttf directly in that directory; Comfyroll text nodes "
              "will be dropped from /object_info", file=sys.stderr)
        return 1
    for f in sorted(fonts)[:4]:
        print(f"  {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
