#!/usr/bin/env python3
"""Compile every build hook in the current resolution.

Why this exists
---------------
pub.dev's "downgrade" analysis resolves the *lowest* version of every dependency
that the constraints allow, then compiles each package's build hook. A hook is
**compiled, never analyzed**: a breakage inside it never shows up in
`dart analyze` (which is green), it only appears as `[pub-downgrade-failed]` on
the score page with the actual error hidden.

So the useful gate is to reproduce that compilation locally, under
`dart pub downgrade`, and read the compiler output directly:

    dart pub downgrade --no-example
    python3 tool/check_hooks_compile.py
    dart pub upgrade

Exit codes: 0 every hook compiled, 1 at least one failed, 2 the environment is
unusable (no package config / no dart).
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse

PACKAGE_CONFIG = ".dart_tool/package_config.json"


def dart_executable() -> tuple[str, bool]:
    """Returns (executable, needs_shell).

    On Windows `dart` is often `dart.bat`, which `subprocess` cannot execute
    without a shell, so prefer the `.exe` sitting next to it.
    """
    found = shutil.which("dart")
    if found is None:
        return "dart", False
    if os.name == "nt" and found.lower().endswith((".bat", ".cmd")):
        sibling = pathlib.Path(found).with_suffix(".exe")
        if sibling.is_file():
            return str(sibling), False
        return found, True
    return found, False


def package_roots(config: pathlib.Path):
    """Yields (package name, package root) for every entry in the config."""
    data = json.loads(config.read_text(encoding="utf-8"))
    base = config.parent
    for package in data.get("packages", []):
        uri = package.get("rootUri", "")
        if uri.startswith("file:"):
            path = unquote(urlparse(uri).path)
            # file:///D:/x -> /D:/x on Windows
            if os.name == "nt" and len(path) > 2 and path[0] == "/" and path[2] == ":":
                path = path[1:]
            root = pathlib.Path(path)
        else:
            root = (base / uri).resolve()
        yield package["name"], root


def main() -> int:
    config = pathlib.Path(PACKAGE_CONFIG)
    if not config.is_file():
        print(f"{PACKAGE_CONFIG} is missing: run `dart pub get` first", file=sys.stderr)
        return 2

    dart, needs_shell = dart_executable()
    root = pathlib.Path.cwd()

    hooks = [
        (name, package_root, package_root / "hook" / "build.dart")
        for name, package_root in package_roots(config)
    ]
    hooks = [(n, r, h) for n, r, h in hooks if h.is_file()]
    if not hooks:
        print("no build hooks in this resolution", file=sys.stderr)
        return 2

    # A hook outside this package cannot see our `.dart_tool/package_config.json`
    # (resolution walks up from the *script*), so such a hook is copied into our
    # own tree first. That is also how our resolution would compile it, which is
    # exactly what pub.dev's downgrade analysis does.
    mirror = root / ".dart_tool" / "hookcheck"
    if mirror.exists():
        shutil.rmtree(mirror, ignore_errors=True)

    print(f"compiling {len(hooks)} build hook(s) with {dart}")
    failures: list[tuple[str, str]] = []
    skipped: list[str] = []

    with tempfile.TemporaryDirectory() as workdir:
        out = pathlib.Path(workdir) / "hook.dill"
        for name, package_root, hook in sorted(hooks):
            target = hook
            try:
                if root not in hook.resolve().parents:
                    target = mirror / name / "hook" / "build.dart"
                    target.parent.mkdir(parents=True, exist_ok=True)
                    for source in hook.parent.glob("*.dart"):
                        shutil.copy2(source, target.parent / source.name)
            except OSError as error:
                skipped.append(f"{name}: could not stage the hook ({error})")
                continue

            result = subprocess.run(
                [dart, "compile", "kernel", str(target.resolve()), "-o", str(out)],
                cwd=str(root),
                capture_output=True,
                text=True,
                shell=needs_shell,
            )
            output = (result.stderr or result.stdout).strip()
            if result.returncode == 0:
                print(f"  ok    {name}")
                continue
            if "Couldn't resolve the package" in output or "Not found:" in output:
                # Only meaningful for a staged copy: the hook may import files
                # relative to its own package, which a copy cannot provide.
                skipped.append(f"{name}: unresolved import (staged copy)")
                continue
            print(f"  FAIL  {name}", file=sys.stderr)
            failures.append((name, output))

    if skipped:
        for note in skipped:
            print(f"  skip  {note}")

    if failures:
        print(
            "\nat least one build hook does not compile at the current "
            "resolution.\nUnder `dart pub downgrade` this is what pub.dev "
            "reports as [pub-downgrade-failed];\nfix it by adding a floor to "
            "the offending dependency in pubspec.yaml.",
            file=sys.stderr,
        )
        for name, output in failures:
            print(f"\n--- {name} ---\n{output}", file=sys.stderr)
        return 1

    print("all reachable build hooks compiled")
    return 0


if __name__ == "__main__":
    sys.exit(main())
