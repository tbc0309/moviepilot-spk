#!/usr/bin/env python3
import json
import os
import urllib.request
from pathlib import Path

config = json.loads(Path("packages.json").read_text(encoding="utf-8"))
token = os.environ.get("GITHUB_TOKEN", "")
headers = {"Accept": "application/vnd.github+json", "User-Agent": "spk-auto-builder"}
if token:
    headers["Authorization"] = f"Bearer {token}"

updates = []
for name, package in config.items():
    if not package.get("enabled"):
        continue
    req = urllib.request.Request(
        f"https://api.github.com/repos/{package['upstream']}/releases/latest", headers=headers
    )
    with urllib.request.urlopen(req) as response:
        release = json.load(response)
    version = release["tag_name"].lstrip("v")
    release_tag = f"{name}-v{version}"
    check = urllib.request.Request(
        f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/releases/tags/{release_tag}",
        headers=headers,
    )
    try:
        urllib.request.urlopen(check).close()
        exists = True
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        exists = False
    if not exists:
        updates.append({"package": name, "version": version, "tag": release["tag_name"]})

output = json.dumps(updates, separators=(",", ":"))
print(output)
with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
    stream.write(f"updates={output}\n")
    stream.write(f"has_updates={'true' if updates else 'false'}\n")

