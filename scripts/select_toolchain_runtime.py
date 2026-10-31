"""只选择目标架构的真实工具链动态库，排除调试脚本和宿主机文件。"""
import argparse
import re
import shutil
import subprocess
from pathlib import Path


def select(root, library, arch):
    machine = 'Advanced Micro Devices X86-64' if arch == 'x64' else 'AArch64'
    candidates = []
    for path in sorted(root.rglob(library + '*')):
        if not re.fullmatch(re.escape(library) + r'(?:\.[0-9]+)*', path.name) or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        header = subprocess.run(['readelf', '-h', str(path)], capture_output=True, text=True, check=True).stdout
        dynamic = subprocess.run(['readelf', '-d', str(path)], capture_output=True, text=True, check=True).stdout
        if re.search(r'Machine:\s*' + re.escape(machine) + r'\s*$', header, re.M) and f'[{library}]' in dynamic:
            candidates.append(path)
    if not candidates:
        raise RuntimeError(f'未找到有效的 {arch} 工具链动态库：{library}')
    return candidates[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('arch', choices=['x64', 'rtd1296'])
    args = parser.parse_args()
    for library in ('libstdc++.so.6', 'libgcc_s.so.1'):
        source = select(args.root, library, args.arch)
        shutil.copy2(source.resolve(), args.output / library)
        print(f'已核验工具链动态库：{source} -> {args.output / library}', flush=True)
