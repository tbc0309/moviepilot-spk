"""Test bundled plugin dependencies without changing pinned application packages."""
import importlib.metadata
import json
import os
import re
from pathlib import Path
import subprocess
import sys

root = Path('/work')
plugins = root / 'payload/moviepilot/app/plugins'
report_dir = root / 'plugin-dependency-report'
report_dir.mkdir(exist_ok=True)
constraints = report_dir / 'application-constraints.txt'
constraints.write_text('\n'.join(sorted(
    f'{d.metadata["Name"]}=={d.version}' for d in importlib.metadata.distributions()
    if d.metadata.get('Name')
)) + '\n')
results = []
spksrc_candidates = set()
for plugin in sorted(plugins.iterdir()):
    if not plugin.is_dir():
        continue
    manifest = next((plugin / name for name in ('pyproject.toml', 'requirements.txt')
                     if (plugin / name).is_file()), None)
    if manifest is None:
        continue
    command = ['/opt/python/cp314-cp314/bin/python', '-m', 'uv', 'pip', 'install', '--python', sys.executable,
               '-c', str(constraints), '-r', str(manifest)]
    wheels = plugin / 'wheels'
    if wheels.is_dir():
        command += ['--find-links', str(wheels)]
    # Resolve first: an incompatible plugin must not downgrade core dependencies.
    preinstalled = []
    try:
        resolved = subprocess.run(command + ['--dry-run'], capture_output=True, text=True,
                                  timeout=300, env={**os.environ, 'UV_HTTP_TIMEOUT': '60'})
        output = resolved.stdout + resolved.stderr
        status = 'incompatible' if resolved.returncode else 'resolved'
        if resolved.returncode == 0:
            wheel_dir = root / 'plugin-wheels' / plugin.name
            wheel_dir.mkdir(parents=True, exist_ok=True)
            pip = ['/opt/python/cp314-cp314/bin/python', '-m', 'pip']
            args = ['-c', str(constraints), '-r', str(manifest)]
            # pip runs in the build interpreter, not the application venv.
            # Reuse approved wheels rather than rebuilding already bundled PyAV.
            approved_wheels = root / 'native-plugin-wheels'
            if approved_wheels.is_dir():
                args += ['--find-links', str(approved_wheels)]
            if wheels.is_dir():
                args += ['--find-links', str(wheels)]
            binary = subprocess.run(pip + ['download', '--only-binary=:all:', '-d',
                                    str(wheel_dir)] + args, capture_output=True, text=True, timeout=600)
            output += '\nBINARY CHECK\n' + binary.stdout + binary.stderr
            status = 'direct_install_available'
            if binary.returncode:
                # Isolated build environments must respect the same NumPy/tooling
                # versions; runtime constraints alone do not constrain build dependencies.
                built = subprocess.run(pip + ['wheel', '--build-constraint', str(constraints),
                                              '--wheel-dir', str(wheel_dir)] + args,
                                       capture_output=True, text=True, timeout=1200)
                build_log = built.stdout + built.stderr
                output += '\nSOURCE BUILD\n' + build_log
                status = 'build_failed' if built.returncode else 'source_is_pure_python'
                if built.returncode == 0:
                    names = {n.lower().replace('-', '_') for n in
                             re.findall(r'Building wheel for ([A-Za-z0-9_.-]+)', build_log)}
                    native = [w for w in wheel_dir.glob('*.whl')
                              if w.name.split('-')[0].lower().replace('-', '_') in names
                              and not w.name.endswith('-any.whl')]
                    # Do not preinstall a native package just because this older
                    # build image lacks wheels: real DSM can install spaCy directly.
                    if native:
                        status = 'source_native_requires_spksrc'
                        for wheel in native:
                            parts = wheel.name.split('-')
                            if len(parts) >= 2:
                                spksrc_candidates.add(f'{parts[0]}=={parts[1]}')
                    native = [w for w in native if w.name.startswith('av-')]
                    if native:
                        # Preinstall only source-built native distributions, not downloadable dependencies.
                        install = subprocess.run(command[:9] + ['--no-deps'] + [str(w) for w in native],
                                                 capture_output=True, text=True, timeout=300)
                        output += '\nPREINSTALL\n' + install.stdout + install.stderr
                        status = 'preinstalled_native' if install.returncode == 0 else 'preinstall_failed'
                        if install.returncode == 0:
                            preinstalled = [{'name': w.name.split('-')[0],
                                             'version': w.name.split('-')[1],
                                             'wheel': w.name} for w in native]
    except subprocess.TimeoutExpired as error:
        status = 'timeout'
        output = str(error)
    (report_dir / f'{plugin.name}.log').write_text(output)
    results.append({'plugin': plugin.name, 'manifest': manifest.name, 'status': status,
                    'preinstalled': preinstalled})
    if status in ('build_failed', 'incompatible', 'preinstall_failed', 'timeout'):
        print(output[-10000:], flush=True)
    print(f'PLUGIN {plugin.name}: {status}', flush=True)
(report_dir / 'results.json').write_text(json.dumps(results, indent=2, ensure_ascii=False))
(report_dir / 'spksrc-candidates.txt').write_text(
    '\n'.join(sorted(spksrc_candidates)) + ('\n' if spksrc_candidates else '')
)
print(f'SPKSRC candidates: {len(spksrc_candidates)}', flush=True)
for candidate in sorted(spksrc_candidates):
    print(f'SPKSRC {candidate}', flush=True)
print(json.dumps(results, indent=2), flush=True)
# Failures remain visible in the report; still package the successful subset for testing.
