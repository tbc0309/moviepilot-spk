#!/usr/bin/env bash
set -Eeuo pipefail
version="${1:?version required}"; arch="${2:?arch required}"
repo="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"; work="$(mktemp -d)"
payload="${work}/payload"; outer="${work}/outer"; mkdir -p "$payload" "$outer" "$repo/dist/$arch"
trap 'rm -rf "$work"' EXIT
cp -a "$repo/packages/moviepilot/payload/." "$payload/"
cp -a "$repo/packages/moviepilot/outer/." "$outer/"
mkdir -p "$payload/logs" "$payload/tmp"

curl -fsSL "https://github.com/jxxghp/MoviePilot/archive/refs/tags/v${version}.tar.gz" -o "$work/source.tgz"
mkdir "$work/source"; tar -xzf "$work/source.tgz" -C "$work/source" --strip-components=1
cp -a "$work/source/." "$payload/moviepilot/"; cp -a "$work/source/config" "$payload/config"
frontend="$(sed -n "s/^FRONTEND_VERSION[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$work/source/version.py")"
test -n "$frontend"
curl -fsSL "https://github.com/jxxghp/MoviePilot-Frontend/releases/download/${frontend}/dist.zip" -o "$work/dist.zip"
unzip -q "$work/dist.zip" -d "$work/frontend"; mkdir -p "$payload/public"; cp -a "$work/frontend/dist/." "$payload/public/"
(cd "$payload/public" && npm init -y >/dev/null && npm pkg set 'overrides.qs=6.16.0' && npm install --omit=dev --ignore-scripts --no-fund express@4.22.2 express-http-proxy@2.1.2 && npm audit --omit=dev --audit-level=moderate)

curl -fsSL https://github.com/jxxghp/MoviePilot-Resources/archive/refs/heads/main.tar.gz -o "$work/resources.tgz"
mkdir "$work/resources"; tar -xzf "$work/resources.tgz" -C "$work/resources" --strip-components=1
site="$payload/moviepilot/app/application/site"; mkdir -p "$site"; cp "$work/resources/resources.v3/user.sites.v3.bin" "$site/"
if [ "$arch" = armv8 ]; then resource_arch=aarch64; else resource_arch=x86_64; fi
find "$work/resources/resources.v3" -maxdepth 1 -type f \( -name "sites.cpython-314-${resource_arch}-linux-gnu.so" -o -name "sites.cpython-314t-${resource_arch}-linux-gnu.so" -o -name sites.pyi \) -exec cp '{}' "$site/" ';'

curl -fsSL https://github.com/jxxghp/MoviePilot-Plugins/archive/refs/heads/main.tar.gz -o "$work/plugins.tgz"
mkdir "$work/plugins"; tar -xzf "$work/plugins.tgz" -C "$work/plugins" --strip-components=1
test -d "$work/plugins/plugins.v3"
mkdir -p "$payload/moviepilot/app/plugins"
cp -a "$work/plugins/plugins.v3/." "$payload/moviepilot/app/plugins/"

docker run --rm -v "$work:/work" -w /work/source "quay.io/pypa/manylinux_2_28_${resource_arch}:latest" bash -euxc '
  /opt/python/cp314-cp314/bin/python -m pip install --disable-pip-version-check uv
  UV_PROJECT_ENVIRONMENT=/work/venv /opt/python/cp314-cp314/bin/python -m uv sync \
    --locked --no-dev --no-install-project --group runtime-standard
  /opt/python/cp314-cp314/bin/python -m uv pip install \
    --python /work/venv/bin/python --no-cache supervisor==4.3.0
'
sudo chown -R "$(id -u):$(id -g)" "$work"
cp -a "$work/venv/." "$payload/"
find "$payload" -type d -name __pycache__ -prune -exec rm -rf '{}' +
find "$payload" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
rm -f "$payload/.gitignore" "$payload/bin/Activate.ps1" "$payload/bin/activate" \
  "$payload/bin/activate.csh" "$payload/bin/activate.fish" "$payload/bin/pip" \
  "$payload/bin/pip3" "$payload/bin/pip3.14" "$payload/bin/𝜋thon"
rm -rf "$payload/lib/python3.14/site-packages/pip" \
  "$payload"/lib/python3.14/site-packages/pip-*.dist-info
rm -f "$payload/bin/python" "$payload/bin/python3" "$payload/bin/python3.14"
ln -s /usr/local/bin/python3.14 "$payload/bin/python3.14"; ln -s python3.14 "$payload/bin/python3"; ln -s python3.14 "$payload/bin/python"
curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-${resource_arch}-unknown-linux-gnu.tar.gz" -o "$work/uv.tgz"
tar -xzf "$work/uv.tgz" -C "$work"; install -m 0755 "$work/uv-${resource_arch}-unknown-linux-gnu/uv" "$payload/bin/uv"; ln -sf uv "$payload/bin/uvx"

python3 - "$outer/INFO" "$version" "$arch" <<'PY'
import re, sys
p, version, arch = sys.argv[1:]
s = open(p, encoding="utf-8").read()
values = {"version": version, "arch": "rtd1296 rtd1619b armada37xx armv8" if arch == "armv8" else "apollolake avoton braswell broadwell broadwellnk broadwellnkv2 broadwellntbap bromolow cedarview denverton epyc7002 geminilake geminilakenk grantley kvmx64 purley r1000 r1000nk v1000 v1000nk x86 x86_64", "install_dep_packages": "Node.js_v22:python314", "changelog": f"更新MoviePilot到v{version}，使用Python 3.14与Node.js 22。"}
for k, v in values.items():
    s, n = re.subn(rf'(?m)^{k}="[^"]*"', f'{k}="{v}"', s, count=1)
    if n != 1: raise SystemExit(f"INFO missing {k}")
open(p, "w", encoding="utf-8", newline="\n").write(s)
PY
find "$payload" -type d -exec chmod 755 '{}' +
find "$payload" -mindepth 1 -maxdepth 1 -printf '%P\0' | sort -z > "$work/payload-files"
tar --format=gnu --owner=0 --group=0 -czf "$outer/package.tgz" -C "$payload" \
  --null --files-from="$work/payload-files"
output="$repo/dist/$arch/MoviePilot_v${version}_${arch}-Python3.14-DSM7.2.spk"
find "$outer" -mindepth 1 -maxdepth 1 -printf '%P\0' | sort -z > "$work/outer-files"
tar --format=gnu --owner=0 --group=0 -cf "$output" -C "$outer" \
  --null --files-from="$work/outer-files"
if tar -tf "$outer/package.tgz" | grep -Eq '^(\./|\.$)'; then
  echo "package.tgz contains an invalid dot-prefixed root" >&2
  exit 1
fi
for required_dir in logs/ tmp/; do
  if ! tar -tf "$outer/package.tgz" | grep -qx "${required_dir}"; then
    echo "package.tgz is missing required directory: ${required_dir}" >&2
    exit 1
  fi
done
if tar -tf "$output" | grep -Eq '^(\./|\.$)'; then
  echo "SPK contains an invalid dot-prefixed root" >&2
  exit 1
fi
tar -tf "$output" | grep -qx package.tgz
sha256sum "$output" > "$output.sha256"
echo "Built $output"
