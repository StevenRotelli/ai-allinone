#!/usr/bin/env python3
"""Assert exactly one opencv provider is installed, and that it is headless.

opencv-python, opencv-contrib-python, opencv-python-headless and
opencv-contrib-python-headless all install the same `cv2` module. Installing
more than one leaves whichever pip wrote last in place, silently.

This image runs headless. The GUI builds link Qt5/GTK and pull an X stack that
is useless in a container and can fail to import outright on a slim host. They
arrive as TRANSITIVE dependencies - ultralytics, scenedetect, pixeloe,
transparent-background and mediapipe each require one - so filtering
requirements.txt lines cannot prevent this and a post-install assert is the
only reliable check.
"""
import importlib.metadata as md
import sys


def main():
    names = sorted(
        str(d.metadata["Name"])
        for d in md.distributions()
        if str(d.metadata["Name"]).lower().startswith("opencv")
    )
    print(f"opencv distributions installed: {names}")
    if len(names) != 1:
        print(f"FAIL: expected exactly one opencv provider, found {len(names)}", file=sys.stderr)
        return 1

    import cv2
    info = cv2.getBuildInformation()
    gui_lines = [l.strip() for l in info.splitlines() if l.strip().startswith("GUI")]
    print(f"cv2 {cv2.__version__} from {cv2.__file__}")
    for l in gui_lines:
        print(f"  {l}")
    blob = " ".join(gui_lines).upper()
    for toolkit in ("QT", "GTK", "COCOA", "WIN32UI"):
        if f"{toolkit}:" in blob.replace(" ", "") or f" {toolkit}" in blob:
            if "NO" not in blob.split(toolkit, 1)[1][:12].upper():
                print(f"FAIL: cv2 is a GUI build ({toolkit})", file=sys.stderr)
                return 1

    import numpy as np
    out = cv2.resize(np.zeros((32, 32, 3), np.uint8), (64, 64))
    assert out.shape == (64, 64, 3)
    print("cv2 headless and functional")
    return 0


if __name__ == "__main__":
    sys.exit(main())
