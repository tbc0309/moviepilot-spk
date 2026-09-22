#!/usr/bin/env python3
"""Select locked requirements that have no DSM-compatible binary wheel."""
import argparse
import io
import json
import re
import tarfile
import time
import urllib.request
import zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from packaging.markers import default_environment
from packaging.requirements import Requirement
from packaging.tags import Tag, compatible_tags, cpython_tags
from packaging.utils import parse_wheel_filename


def fetch(url, timeout=60, attempts=4):
    request = urllib.request.Request(url, headers={"User-Agent": "moviepilot-spk-dependency-check/1"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read()
        except Exception:
            if attempt + 1 == attempts:
                raise
            time.sleep(2 ** attempt)


def requirement_lines(path: Path):
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("-"):
            continue
        try:
            req = Requirement(line)
        except Exception:
            continue
        if req.url or len(req.specifier) != 1:
            continue
        spec = next(iter(req.specifier))
        if spec.operator != "==" or spec.version.endswith(".*"):
            continue
        yield req, spec.version


def target_tags(arch: str, dsm: str):
    machine = "x86_64" if arch == "x86_64" else "aarch64"
    top = 17 if dsm == "7.1" else 28
    platforms = [f"manylinux_2_{minor}_{machine}" for minor in range(top, 4, -1)]
    platforms += [f"manylinux2014_{machine}", f"manylinux2010_{machine}",
                  f"manylinux1_{machine}", f"linux_{machine}"]
    return set(cpython_tags((3, 14), platforms=platforms)) | set(
        compatible_tags((3, 14), interpreter="cp314", platforms=platforms)
    )


def source_contains_native(files):
    source = next((item for item in files if item.get("packagetype") == "sdist"), None)
    if not source:
        return True
    data = fetch(source["url"])
    names = []
    try:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            names = archive.getnames()
    except tarfile.TarError:
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as archive:
                names = archive.namelist()
        except zipfile.BadZipFile:
            return True
    native_suffixes = (".c", ".cc", ".cpp", ".cxx", ".pyx", ".rs", ".s", ".S")
    return any(name.endswith(native_suffixes) or name.endswith("Cargo.toml") for name in names)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("requirements", type=Path)
    parser.add_argument("arch", choices=("x86_64", "armv8"))
    parser.add_argument("dsm", choices=("7.1", "7.2"))
    parser.add_argument("candidates", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    tags = target_tags(args.arch, args.dsm)
    env = default_environment()
    env.update({
        "python_version": "3.14", "python_full_version": "3.14.0",
        "sys_platform": "linux", "platform_system": "Linux",
        "platform_machine": "x86_64" if args.arch == "x86_64" else "aarch64",
        "implementation_name": "cpython", "platform_python_implementation": "CPython",
    })
    active = [(req, version) for req, version in requirement_lines(args.requirements)
              if not req.marker or req.marker.evaluate(env)]

    def inspect(item):
        req, version = item
        normalized = re.sub(r"[-_.]+", "-", req.name).lower()
        url = f"https://pypi.org/pypi/{normalized}/{version}/json"
        try:
            files = json.loads(fetch(url, timeout=30)).get("urls", [])
        except Exception as error:
            return {"requirement": str(req), "status": "metadata_error", "detail": str(error)}
        compatible = []
        for item in files:
            filename = item.get("filename", "")
            if not filename.endswith(".whl"):
                continue
            try:
                _, _, _, wheel_tags = parse_wheel_filename(filename)
            except Exception:
                continue
            if wheel_tags & tags:
                compatible.append(filename)
        if compatible:
            return {"requirement": str(req), "status": "downloadable", "wheels": compatible}
        if not source_contains_native(files):
            return {"requirement": str(req), "status": "source_installable"}
        return {"requirement": str(req), "candidate": f"{req.name}=={version}",
                "status": "spksrc_candidate"}

    with ThreadPoolExecutor(max_workers=16) as pool:
        report = list(pool.map(inspect, active))
    candidates = [item["candidate"] for item in report if "candidate" in item]
    args.candidates.write_text("\n".join(candidates) + ("\n" if candidates else ""), encoding="utf-8")
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    errors = [item for item in report if item["status"] == "metadata_error"]
    if errors:
        raise SystemExit("PyPI metadata lookup failed after retries: " +
                         ", ".join(item["requirement"] for item in errors))
    print(f"downloadable={sum(x['status'] == 'downloadable' for x in report)} candidates={len(candidates)}")
    for candidate in candidates:
        print(f"SPKSRC {candidate}")


if __name__ == "__main__":
    main()
