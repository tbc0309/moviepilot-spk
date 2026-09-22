#!/usr/bin/env python3
"""Collect non-DSM ELF dependencies required by cross-compiled wheels."""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
import zipfile
from collections import deque
from pathlib import Path


BASELINE = re.compile(
    r"^(?:lib(?:c|m|pthread|dl|rt|resolv|util|nsl|anl|stdc\+\+|gcc_s|z)\.so\.|ld-linux|libpython)"
)


def elf_machine(path: Path) -> str | None:
    result = subprocess.run(["readelf", "-h", path], capture_output=True, text=True)
    if result.returncode:
        return None
    match = re.search(r"^\s*Machine:\s*(.+)$", result.stdout, re.MULTILINE)
    return match.group(1).strip() if match else None


def needed(path: Path) -> list[str]:
    result = subprocess.run(["readelf", "-d", path], capture_output=True, text=True)
    if result.returncode:
        return []
    return re.findall(r"\(NEEDED\).*?\[(.+?)\]", result.stdout)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: collect_spksrc_runtime_libraries.py SPKSRC_ROOT OUTPUT")
    root, output = map(Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    wheels = sorted(output.glob("*.whl"))
    if not wheels:
        return

    with tempfile.TemporaryDirectory() as directory:
        extracted = Path(directory)
        for wheel in wheels:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(extracted / wheel.stem)
        modules = [
            path for path in extracted.rglob("*.so*")
            if path.is_file() and elf_machine(path)
        ]
        if not modules:
            return
        machine = elf_machine(modules[0])
        if any(elf_machine(module) != machine for module in modules):
            raise SystemExit("Cross wheels contain mixed ELF architectures")

        index: dict[str, list[Path]] = {}
        for candidate in root.rglob("*.so*"):
            if candidate.is_file() and elf_machine(candidate) == machine:
                index.setdefault(candidate.name, []).append(candidate)

        queue = deque(modules)
        copied: dict[str, Path] = {}
        while queue:
            module = queue.popleft()
            for soname in needed(module):
                if BASELINE.match(soname) or soname in copied:
                    continue
                matches = index.get(soname, [])
                if not matches:
                    raise SystemExit(f"Missing spksrc runtime library {soname}, required by {module}")
                source = min(matches, key=lambda item: ("work-" not in str(item), len(str(item))))
                target = output / soname
                shutil.copy2(source.resolve(), target)
                copied[soname] = target
                queue.append(target)
                print(f"Bundled spksrc runtime library: {soname} from {source}", flush=True)


if __name__ == "__main__":
    main()
