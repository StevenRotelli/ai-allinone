#!/usr/bin/env python3
"""Assert every pack in node_packs.txt actually landed in custom_nodes.

The clone loop in the Dockerfile swallows failures with `WARN: clone failed`,
on purpose - one unreachable repo should not kill a 40-minute build. The cost
of that choice is that a renamed or deleted repo ships a silently incomplete
image, and the first sign is a workflow failing to load on a pod. This turns
that into a build failure instead.

Directory name is derived from the URL the same way `git clone` does it.
"""
import os
import sys


def dirname_for(url):
    name = url.rstrip("/").rsplit("/", 1)[-1]
    return name[:-4] if name.endswith(".git") else name


def main(manifest, custom_nodes):
    urls = []
    with open(manifest, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#"):
                urls.append(line)
    missing = []
    for url in urls:
        d = os.path.join(custom_nodes, dirname_for(url))
        if not os.path.isdir(d):
            missing.append((url, d))
    print(f"node packs declared: {len(urls)}, present: {len(urls) - len(missing)}")
    if missing:
        print("MISSING NODE PACKS (clone failed or repo renamed):", file=sys.stderr)
        for url, d in missing:
            print(f"  {url}  ->  {d}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: check_node_packs.py <node_packs.txt> <custom_nodes dir>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
