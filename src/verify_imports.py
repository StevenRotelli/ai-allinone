#!/usr/bin/env python3
"""Assert that every top-level import of the given entrypoints resolves.

For a vendored repo we do not pip-install, this is the contract that actually
matters. MatAnyone is the case in point: it has no requirements.txt, and its
pyproject.toml lists the training and GUI stack (PySide6, gradio, cchardet,
netifaces, pycocotools, a git-sourced thinplate) for an inference entrypoint
that imports none of it. Installing that list would add hundreds of megabytes
and a package that does not build on current Python; checking the imports it
really has is both cheaper and a tighter guarantee.

Parses with ast rather than importing the module, so __main__ side effects and
argparse do not run. Relative imports (level > 0) are the repo's own packages
and are covered by importing the top-level package itself.
"""
import ast
import importlib
import os
import sys


def top_level_imports(path):
    with open(path, encoding="utf-8") as fh:
        tree = ast.parse(fh.read(), filename=path)
    mods = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                mods.add(alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            if node.module and node.level == 0:
                mods.add(node.module.split(".")[0])
    return mods


def main(paths):
    failed = False
    for path in paths:
        if not os.path.isfile(path):
            print(f"MISSING ENTRYPOINT {path}", file=sys.stderr)
            failed = True
            continue
        # The repo's own packages are importable only from its root.
        root = os.path.dirname(os.path.abspath(path))
        if root not in sys.path:
            sys.path.insert(0, root)
        missing = []
        for mod in sorted(top_level_imports(path)):
            if mod in sys.builtin_module_names:
                continue
            try:
                importlib.import_module(mod)
            except Exception as exc:                # noqa: BLE001 - report anything
                missing.append(f"{mod} ({type(exc).__name__})")
        if missing:
            print(f"FAIL {path}: unresolved -> {', '.join(missing)}", file=sys.stderr)
            failed = True
        else:
            print(f"ok   {path}: all top-level imports resolve")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: verify_imports.py <entrypoint.py> [...]", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1:]))
