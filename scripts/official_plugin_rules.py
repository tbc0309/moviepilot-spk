"""Read (never execute) the upstream Dockerfile's plugin packaging rules."""
import argparse
import json
import re
import shutil
from pathlib import Path


def rules(text):
    stages = re.findall(r'(?ms)^FROM[^\n]*\sAS prepare_plugins\s*\n(.*?)(?=^FROM|\Z)', text)
    if len(stages) != 1:
        raise ValueError('Cannot identify official prepare_plugins stage')
    stage = stages[0]
    refs = re.findall(r'(?m)^ARG MOVIEPILOT_PLUGINS_REF="([A-Za-z0-9_./-]+)"', stage)
    directories = re.findall(r'cp -a "\$\{plugin_root\}/(plugins\.v\d+)/\." /plugins/;?', stage)
    flags = re.findall(r'select\(\.value\.(v\d+) == true\)', stage)
    if len(refs) != 1 or len(directories) != 1 or len(flags) > 1:
        raise ValueError('Official plugin rules changed: review required; refusing a v2/v3 fallback')
    # Reject additional commands: unknown changes must not silently use stale rules.
    known = [
        r'ARG MOVIEPILOT_PLUGINS_REF="[A-Za-z0-9_./-]+"', r'RUN set -eu;',
        r'test -n "\$\{MOVIEPILOT_PLUGINS_REF\}";',
        r'curl -fsSL "https://github.com/jxxghp/MoviePilot-Plugins/archive/\$\{MOVIEPILOT_PLUGINS_REF\}.zip" -o /tmp/plugins.zip;',
        r'busybox unzip -q /tmp/plugins.zip -d /tmp/plugins-src;',
        r'plugin_root="\$\(find /tmp/plugins-src -mindepth 1 -maxdepth 1 -type d -print -quit\)";',
        r'test -n "\$\{plugin_root\}";', r'mkdir -p /plugins;',
        r'cp -a "\$\{plugin_root\}/plugins\.v\d+/\." /plugins/;?',
        r"jq -r 'to_entries\[\] \| select\(\.value\.v\d+ == true\) \| \.key' \"\$\{plugin_root\}/package.json\" \| awk '\{print tolower\(\$0\)\}' \|",
        r'while read -r plugin_id; do', r'if \[ ! -d "/plugins/\$\{plugin_id\}" \]; then',
        r'cp -a "\$\{plugin_root\}/plugins/\$\{plugin_id\}" /plugins/;', r'fi;', r'done',
    ]
    for line in stage.splitlines():
        line = line.strip().removesuffix('\\').strip()
        if line and not line.startswith('#') and not any(re.fullmatch(p, line) for p in known):
            raise ValueError(f'Unrecognized official plugin instruction: {line}')
    if bool(flags) != ('while read -r plugin_id; do' in stage):
        raise ValueError('Incomplete official common-plugin selection rule')
    return refs[0], directories[0], flags[0] if flags else '-'


def copy_plugins(source, destination, directory, flag):
    if not (source / directory).is_dir():
        raise ValueError(f'Official plugin directory missing: {directory}')
    shutil.copytree(source / directory, destination, dirs_exist_ok=True)
    if flag != '-':
        packages = json.loads((source / 'package.json').read_text(encoding='utf-8'))
        for name, metadata in packages.items():
            if metadata.get(flag) is not True:
                continue
            plugin_id = name.lower()
            if not re.fullmatch(r'[a-z0-9_-]+', plugin_id):
                raise ValueError(f'Unsafe plugin id: {name}')
            if not (destination / plugin_id).is_dir():
                shutil.copytree(source / 'plugins' / plugin_id, destination / plugin_id)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('dockerfile', type=Path)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--destination', type=Path)
    args = parser.parse_args()
    ref, directory, flag = rules(args.dockerfile.read_text(encoding='utf-8'))
    if args.source or args.destination:
        if not (args.source and args.destination):
            parser.error('Both source and destination are required')
        copy_plugins(args.source, args.destination, directory, flag)
    print(ref, directory, flag, sep='\t')
