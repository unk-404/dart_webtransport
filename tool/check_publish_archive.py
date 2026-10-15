#!/usr/bin/env python3
"""Assert that the archive `dart pub publish` would upload is complete.

`dart pub publish --dry-run` prints the file tree it would upload. That tree is
the *authoritative* answer to "what will consumers get", so this script rebuilds
the full paths from the tree and checks that every part of the package a
consumer needs is present -- and that nothing which must not ship is in there.

This exists because a missing file does **not** fail `pub publish`: the release
publishes, pub.dev scores it, and only a consumer's compiler notices. A
`.pubignore`/`.gitignore` pattern without a leading `/` matches at *every* depth
(`build/` also excludes `lib/src/build/`), which is exactly how a whole source
directory can silently disappear.

Usage:
    dart pub publish --dry-run > dryrun.txt 2>&1   # exit 65 on warnings, ignore it
    python3 tool/check_publish_archive.py dryrun.txt

Exit codes: 0 ok, 1 assertion failed, 2 the tree could not be parsed.
"""

from __future__ import annotations

import re
import sys

# ---------------------------------------------------------------------------
# What the published package must contain.
# ---------------------------------------------------------------------------
REQUIRED: tuple[str, ...] = (
    # metadata
    "LICENSE",
    "CHANGELOG.md",
    "README.md",
    "pubspec.yaml",
    # the public Dart surface
    "lib/webtransport.dart",
    "lib/webtransport_ffi.dart",
    "lib/webtransport_bindings_generated.dart",
    "lib/src/api.dart",
    "lib/src/native/memory.dart",
    "lib/src/native/runtime.dart",
    "lib/src/native/transport.dart",
    "lib/src/native/session.dart",
    "lib/src/native/server.dart",
    "lib/src/native/isolate_backend.dart",
    "lib/src/web/transport.dart",
    "lib/src/platform/factory_native.dart",
    "lib/src/platform/factory_stub.dart",
    "lib/src/platform/factory_web.dart",
    # build hook, codegen inputs and the ABI contract
    "hook/build.dart",
    "ffigen.yaml",
    "src/webtransport.h",
    "tool/generate_bindings.dart",
    "tool/check_publish_archive.py",
    "tool/check_hooks_compile.py",
    # the Rust crate the hook compiles
    "Cargo.toml",
    "Cargo.lock",
    "rust/Cargo.toml",
    "rust/cbindgen.toml",
    "rust/rust-toolchain.toml",
    "rust/src/lib.rs",
    "rust/src/status.rs",
    "rust/src/ffi.rs",
    "rust/src/handle.rs",
    "rust/src/buffer.rs",
    "rust/src/runtime.rs",
    "rust/src/types.rs",
    "rust/src/config.rs",
    "rust/src/client.rs",
    "rust/src/server.rs",
    "rust/src/connection.rs",
    "rust/src/stream.rs",
    # the example is what users see on pub.dev
    "example/pubspec.yaml",
    "example/lib/main.dart",
)

# Paths that must never reach the archive: scratch space, build output and
# generated caches. Checked as directory prefixes and as interior components.
FORBIDDEN_PREFIXES: tuple[str, ...] = (
    ".agent",
    ".dart_tool",
    "build",
    "target",
    "coverage",
)

FORBIDDEN_COMPONENTS: tuple[str, ...] = (
    "build",
    "target",
    "ephemeral",
    ".dart_tool",
    ".agent",
    ".gradle",
)

# A tree line looks like `│   ├── name (12 KB)` or `├── name`.
_GLYPHS = ("├", "└")
_SIZE_SUFFIX = re.compile(r" \((\d+(?:\.\d+)?\s*[KMG]?B|<1 KB)\)$")

MINIMUM_FILES = 80


def parse_tree(text: str) -> dict[str, int]:
    """Reproduces full paths from the box drawing tree printed by pub.

    Returns a mapping of path to depth; directories are included so that
    forbidden prefixes can be detected even when empty.
    """
    paths: dict[str, int] = {}
    stack: list[str] = []

    for raw in text.splitlines():
        corner = -1
        for glyph in _GLYPHS:
            index = raw.find(glyph)
            if index != -1 and (corner == -1 or index < corner):
                corner = index
        if corner == -1:
            continue

        depth = corner // 4 + 1  # each level is exactly 4 characters
        name = raw[corner + 4 :].strip()
        if not name:
            continue
        name = _SIZE_SUFFIX.sub("", name)
        if not name:
            continue

        del stack[depth - 1 :]
        stack.append(name)
        paths["/".join(stack)] = depth

    return paths


TREE_MARKER = "Total compressed archive size"


def read_output(path: str | None) -> str:
    """Reads the pub output, tolerating whatever encoding the shell wrote.

    `dart pub publish --dry-run > file` produces UTF-8 under bash but UTF-16LE
    under Windows PowerShell 5.1, and PowerShell may even transcode the box
    drawing characters through the console code page. Rather than trusting a
    BOM, every candidate codec is tried and the first one that yields the
    marker line wins; a plain ASCII line survives any of them, which makes this
    self-validating.
    """
    data = (
        sys.stdin.buffer.read()
        if path in (None, "-")
        else open(path, "rb").read()
    )

    fallback: str | None = None
    for encoding in ("utf-8-sig", "utf-8", "utf-16", "latin-1"):
        try:
            text = data.decode(encoding)
        except (UnicodeDecodeError, ValueError):
            continue
        if TREE_MARKER in text:
            return text
        if fallback is None:
            fallback = text
    if fallback is not None:
        return fallback
    return data.decode("utf-8", errors="replace")


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print("usage: check_publish_archive.py [dryrun-output.txt]", file=sys.stderr)
        return 2

    text = read_output(argv[1] if len(argv) == 2 else None)

    if TREE_MARKER not in text:
        print(
            "could not parse the pub output: the tree is missing.\n"
            "Did `dart pub publish --dry-run` run in the package root?",
            file=sys.stderr,
        )
        return 2

    archive = parse_tree(text)
    if len(archive) < MINIMUM_FILES:
        print(
            f"parsed only {len(archive)} entries (expected at least "
            f"{MINIMUM_FILES}); the tree format probably changed",
            file=sys.stderr,
        )
        return 2

    failures: list[str] = []

    for path in REQUIRED:
        if path not in archive:
            parent = path.rsplit("/", 1)[0] if "/" in path else "."
            hint = ""
            if parent not in archive:
                hint = f"  (and the whole directory '{parent}' is missing)"
            failures.append(f"MISSING  {path}{hint}")

    for path in sorted(archive):
        parts = path.split("/")
        if parts[0] in FORBIDDEN_PREFIXES:
            failures.append(f"SHIPPED  {path}  (top level must not ship)")
            continue
        for component in parts[1:]:
            if component in FORBIDDEN_COMPONENTS:
                failures.append(
                    f"SHIPPED  {path}  ('{component}' must not ship)"
                )
                break

    if failures:
        print("publish archive check FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        print(
            "\nIf a directory is missing, look for a .pubignore/.gitignore "
            "pattern without a leading '/': it matches at every depth.",
            file=sys.stderr,
        )
        return 1

    size = re.search(r"Total compressed archive size: (.+)\.", text)
    print(
        f"publish archive check OK: {len(archive)} entries, "
        f"{len(REQUIRED)} required paths present, none forbidden"
        + (f", archive {size.group(1)}" if size else "")
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
