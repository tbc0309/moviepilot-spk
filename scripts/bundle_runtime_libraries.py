"""Bundle container-only ELF dependencies, excluding DSM's libc/loader baseline."""
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

# DSM supplies these ABI foundations. Never shadow them with CentOS 7 copies.
BASELINE = re.compile(r'^(?:lib(?:c|m|pthread|dl|rt|resolv|util|nsl|anl|stdc\+\+|gcc_s|z)\.so\.|ld-linux|libpython)')
venv, payload = Path('/work/venv'), Path('/work/payload')
destination = venv / 'lib'
libraries = {}
for root in (venv, payload):
    for module in root.rglob('*.so*'):
        if not module.is_file():
            continue
        with module.open('rb') as stream:
            if stream.read(4) != b'\x7fELF':
                continue
        result = subprocess.run(['ldd', str(module)], capture_output=True, text=True)
        if result.returncode or '=> not found' in result.stdout:
            raise RuntimeError(f'Unresolved ELF dependencies: {module}\n{result.stdout}\n{result.stderr}')
        for name, path in re.findall(r'^\s*(\S+)\s+=>\s+(/\S+)\s+\(', result.stdout, re.M):
            if BASELINE.match(name):
                continue
            source = Path(path).resolve()
            if source.is_relative_to(venv) or source.is_relative_to(payload):
                continue
            if name in libraries and libraries[name].read_bytes() != source.read_bytes():
                raise RuntimeError(f'Conflicting runtime library: {name}')
            libraries[name] = source
for name, source in sorted(libraries.items()):
    shutil.copy2(source, destination / name)
    print(f'Bundled runtime library: {name} from {source}', flush=True)
assert (destination / 'libjpeg.so.62').is_file(), 'Expected JPEG runtime library missing'
for forbidden in ('libz.so.1', 'libc.so.6'):
    assert not (destination / forbidden).exists(), f'Unexpected system ABI library: {forbidden}'
manifest = {name: hashlib.sha256((destination / name).read_bytes()).hexdigest() for name in sorted(libraries)}
(venv / 'RUNTIME-LIBRARIES.json').write_text(json.dumps(manifest, indent=2) + '\n')
env = dict(os.environ, LD_LIBRARY_PATH=str(destination))
subprocess.run([str(venv / 'bin/python'), '-c',
    'import io; from PIL import Image; b=io.BytesIO(); Image.new("RGB", (8,8)).save(b, format="JPEG"); b.seek(0); Image.open(b).load(); print("Pillow JPEG encode/decode OK")'], env=env, check=True)
