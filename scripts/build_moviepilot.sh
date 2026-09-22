#!/usr/bin/env bash
set -Eeuo pipefail
version="${1:?version required}"; arch="${2:?arch required}"
dsm="${3:-7.2}"
case "$dsm" in
  7.1) node_version=18; os_min_ver=7.1-42661 ;;
  7.2) node_version=22; os_min_ver=7.2-64570 ;;
  *) echo "Unsupported DSM version: $dsm" >&2; exit 1 ;;
esac
[[ "$arch" == x86_64 || "$arch" == armv8 ]] || exit 1
repo="${GITHUB_WORKSPACE:-$(cd "$(dirname "$0")/.." && pwd)}"; work="$(mktemp -d)"
payload="${work}/payload"; outer="${work}/outer"; mkdir -p "$payload" "$outer" "$repo/dist/$dsm/$arch"
trap 'sudo rm -rf "$work"' EXIT

resolve_commit() {
  gh api "repos/$1/commits/$2" --jq .sha | grep -E '^[0-9a-f]{40}$'
}

download_release_asset() {
  local project="$1" tag="$2" asset="$3" output="$4" url digest actual
  IFS=$'\t' read -r url digest < <(
    gh api "repos/${project}/releases/tags/${tag}" \
      --jq ".assets[] | select(.name == \"${asset}\") | [.browser_download_url, .digest] | @tsv"
  )
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Missing SHA-256 digest for ${project}/${tag}/${asset}" >&2; exit 1; }
  curl -fsSL "$url" -o "$output"
  actual="$(sha256sum "$output" | cut -d ' ' -f1)"
  [[ "sha256:${actual}" == "$digest" ]] || { echo "Digest mismatch for ${asset}" >&2; exit 1; }
}

cp -a "$repo/packages/moviepilot/payload/." "$payload/"
cp -a "$repo/packages/moviepilot/outer/." "$outer/"
mkdir -p "$payload/logs" "$payload/tmp"
sed -i "s/Node.js_v22/Node.js_v${node_version}/g" "$outer/scripts/service-setup" "$payload/supervisord.conf"

source_commit="$(resolve_commit jxxghp/MoviePilot "v${version}")"
resources_commit="$(resolve_commit jxxghp/MoviePilot-Resources main)"
curl -fsSL "https://codeload.github.com/jxxghp/MoviePilot/tar.gz/${source_commit}" -o "$work/source.tgz"
mkdir "$work/source"; tar -xzf "$work/source.tgz" -C "$work/source" --strip-components=1
official_plugin_rules="$(python3 "$repo/scripts/official_plugin_rules.py" "$work/source/docker/Dockerfile")"
IFS=$'\t' read -r plugins_ref plugins_directory plugins_flag <<< "$official_plugin_rules"
plugins_commit="$(resolve_commit jxxghp/MoviePilot-Plugins "$plugins_ref")"
echo "Official plugin rules: ref=$plugins_ref directory=$plugins_directory common_flag=$plugins_flag"
cp -a "$work/source/." "$payload/moviepilot/"; cp -a "$work/source/config" "$payload/config"
frontend="$(sed -n "s/^FRONTEND_VERSION[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$work/source/version.py")"
test -n "$frontend"
download_release_asset jxxghp/MoviePilot-Frontend "$frontend" dist.zip "$work/dist.zip"
unzip -q "$work/dist.zip" -d "$work/frontend"; mkdir -p "$payload/public"; cp -a "$work/frontend/dist/." "$payload/public/"
(cd "$payload/public" && npm init -y >/dev/null && npm pkg set 'overrides.qs=6.16.0' && npm install --omit=dev --ignore-scripts --no-fund express@4.22.2 express-http-proxy@2.1.2 && npm audit --omit=dev --audit-level=moderate)

curl -fsSL "https://codeload.github.com/jxxghp/MoviePilot-Resources/tar.gz/${resources_commit}" -o "$work/resources.tgz"
mkdir "$work/resources"; tar -xzf "$work/resources.tgz" -C "$work/resources" --strip-components=1
site="$payload/moviepilot/app/application/site"; mkdir -p "$site"
if [ "$arch" = armv8 ]; then resource_arch=aarch64; else resource_arch=x86_64; fi
resource_dir="$work/resources/resources.v3"
site_so="sites.cpython-314-${resource_arch}-linux-gnu.so"
site_so_t="sites.cpython-314t-${resource_arch}-linux-gnu.so"
test -s "$site/sites.pyi" || { echo "MoviePilot source is missing app/application/site/sites.pyi" >&2; exit 1; }
for required in user.sites.v3.bin "$site_so" "$site_so_t"; do
  test -s "$resource_dir/$required" || { echo "Missing required site resource: $required" >&2; exit 1; }
done
rm -f "$site"/sites*.so
install -m 0644 "$resource_dir/user.sites.v3.bin" "$resource_dir/$site_so" \
  "$resource_dir/$site_so_t" "$site/"
if [ "$resource_arch" = aarch64 ]; then elf_machine='AArch64'; else elf_machine='Advanced Micro Devices X86-64'; fi
for module in "$site/$site_so" "$site/$site_so_t"; do
  readelf -h "$module" | grep -Fq "$elf_machine" || { echo "Wrong ELF architecture: $module" >&2; exit 1; }
done

curl -fsSL "https://codeload.github.com/jxxghp/MoviePilot-Plugins/tar.gz/${plugins_commit}" -o "$work/plugins.tgz"
mkdir "$work/plugins"; tar -xzf "$work/plugins.tgz" -C "$work/plugins" --strip-components=1
mkdir -p "$payload/moviepilot/app/plugins"
python3 "$repo/scripts/official_plugin_rules.py" "$work/source/docker/Dockerfile" \
  --source "$work/plugins" --destination "$payload/moviepilot/app/plugins"
find "$payload/moviepilot/app/plugins" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
  | LC_ALL=C sort > "$payload/moviepilot/app/plugins/.spk-bundled-plugins"

cp "$repo/scripts/test_plugin_dependencies.py" "$work/test_plugin_dependencies.py"
if [[ "$dsm" == 7.2 ]]; then
  mkdir -p "$work/native-plugin-wheels"
  cp "$repo/native-plugin-wheels/"av-12.3.0-*.whl "$work/native-plugin-wheels/"
fi
if [ "$dsm" = 7.1 ]; then
cp "$repo/scripts/bundle_runtime_libraries.py" "$work/bundle_runtime_libraries.py"
docker run --rm -v "$work:/work" -v "$repo:/repo:ro" -w /work/source "quay.io/pypa/manylinux2014_${resource_arch}:latest" bash -euxc '
  yum install -y libjpeg-turbo-devel
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
  source /root/.cargo/env
  /opt/python/cp314-cp314/bin/python -m pip install --disable-pip-version-check uv
  /opt/python/cp314-cp314/bin/python -m uv lock --upgrade-package numpy==2.4.2
  UV_PROJECT_ENVIRONMENT=/work/venv /opt/python/cp314-cp314/bin/python -m uv sync \
    --locked --no-default-groups --group runtime-standard --no-install-project \
    --no-install-package psycopg2-binary
  mkdir -p /tmp/psycopg-source /tmp/psycopg-wheel /tmp/psycopg-repaired /tmp/postgresql-source
  curl -fsSL https://ftp.postgresql.org/pub/source/v13.22/postgresql-13.22.tar.bz2 \
    | tar -xj -C /tmp/postgresql-source --strip-components=1
  cd /tmp/postgresql-source
  CFLAGS=-fPIC ./configure --prefix=/opt/libpq --without-readline --without-zlib
  make -C src/include -j2 install
  make -C src/port -j2 install
  make -C src/common -j2 install
  make -C src/interfaces/libpq -j2 install
  make -C src/bin/pg_config -j2 install
  cd /work/source
  curl -fsSL https://files.pythonhosted.org/packages/source/p/psycopg2/psycopg2-2.9.12.tar.gz \
    | tar -xz -C /tmp/psycopg-source --strip-components=1
  sed -i "s|^pg_config =.*$|pg_config = /opt/libpq/bin/pg_config|" /tmp/psycopg-source/setup.cfg
  sed -i "s/^static_libpq = 0$/static_libpq = 1/" /tmp/psycopg-source/setup.cfg
  sed -i "s/^libraries =.*$/libraries = pgcommon pgport/" /tmp/psycopg-source/setup.cfg
  /opt/python/cp314-cp314/bin/python -m pip wheel --no-deps \
    --wheel-dir /tmp/psycopg-wheel /tmp/psycopg-source
  auditwheel repair --wheel-dir /tmp/psycopg-repaired /tmp/psycopg-wheel/psycopg2-*.whl
  /opt/python/cp314-cp314/bin/python -m uv pip install \
    --python /work/venv/bin/python /tmp/psycopg-repaired/psycopg2-*.whl
  /work/venv/bin/python /work/source/app/doctor/dependencies.py --full
  /opt/python/cp314-cp314/bin/python -m uv pip install \
    --python /work/venv/bin/python --no-cache supervisor==4.3.0
  /work/venv/bin/python -c "import supervisor; import uvicorn; import fastapi"
  /work/venv/bin/python /work/bundle_runtime_libraries.py
  /opt/python/cp314-cp314/bin/python -m uv pip install \
    --python /work/venv/bin/python --reinstall --no-deps \
    /repo/cross-wheels-7.1/*.whl
  find /repo/cross-wheels-7.1 -maxdepth 1 -type f -name "*.so*" \
    -exec install -m 0644 {} /work/venv/lib/ \;
  strings /work/venv/lib/libstdc++.so.6 | grep -Fx CXXABI_1.3.9
  readelf -d /work/venv/lib/python3.14/site-packages/PIL/_imaging*.so | grep -F "libtiff.so.6"
  test -s /work/venv/lib/libtiff.so.6
'
else
docker run --rm -v "$work:/work" -w /work/source "quay.io/pypa/manylinux_2_28_${resource_arch}:latest" bash -euxc '
  /opt/python/cp314-cp314/bin/python -m pip install --disable-pip-version-check uv
  UV_PROJECT_ENVIRONMENT=/work/venv /opt/python/cp314-cp314/bin/python -m uv sync \
    --locked --no-default-groups --group runtime-standard --no-install-project
  /work/venv/bin/python /work/source/app/doctor/dependencies.py --full
  /opt/python/cp314-cp314/bin/python -m uv pip install \
    --python /work/venv/bin/python --no-cache supervisor==4.3.0
  /work/venv/bin/python -c "import supervisor; import uvicorn; import fastapi"
  /opt/python/cp314-cp314/bin/python -m uv pip install --python /work/venv/bin/python \
    --no-deps /work/native-plugin-wheels/av-12.3.0-*.whl
  /work/venv/bin/python -c "import av; assert av.__version__ == \"12.3.0\""
  /work/venv/bin/python /work/test_plugin_dependencies.py
  /work/venv/bin/python /work/source/app/doctor/dependencies.py --full
'
fi
sudo chown -R "$(id -u):$(id -g)" "$work"
cp -a "$work/venv/." "$payload/"

# Keep runtime files while dropping repository-only material from the installed app.
rm -rf "$payload/moviepilot/.github" "$payload/moviepilot/docs" \
  "$payload/moviepilot/tests" "$payload/moviepilot/skills" "$payload/moviepilot/docker"
rm -f "$payload/moviepilot/.dockerignore" "$payload/moviepilot/.gitattributes" \
  "$payload/moviepilot/.gitignore" "$payload/moviepilot/.pylintrc" \
  "$payload/moviepilot/AGENTS.md" "$payload/moviepilot/README"*
find "$payload" -type d -name __pycache__ -prune -exec rm -rf '{}' +
find "$payload" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
rm -f "$payload/.gitignore" "$payload/.lock" "$payload/CACHEDIR.TAG" \
  "$payload/bin/Activate.ps1" "$payload/bin/activate" "$payload/bin/activate.csh" \
  "$payload/bin/activate.bat" "$payload/bin/activate.nu" \
  "$payload/bin/activate.fish" "$payload/bin/deactivate.bat" "$payload/bin/pip" \
  "$payload/bin/pip3" "$payload/bin/pip3.14" "$payload/bin/𝜋thon" \
  "$payload/lib/python3.14/site-packages/_virtualenv.pth" \
  "$payload/lib/python3.14/site-packages/_virtualenv.py"
rm -rf "$payload/lib/python3.14/site-packages/pip" \
  "$payload"/lib/python3.14/site-packages/pip-*.dist-info
rm -f "$payload/bin/python" "$payload/bin/python3" "$payload/bin/python3.14"
ln -s /usr/local/bin/python3.14 "$payload/bin/python3.14"; ln -s python3.14 "$payload/bin/python3"; ln -s python3.14 "$payload/bin/python"

# uv creates console entry points with the temporary build path in their shebang.
# Normalize every affected entry point to the stable Synology package symlink.
while IFS= read -r -d '' entrypoint; do
  sed -i '1s|^#!/work/venv/bin/python.*$|#!/var/packages/MoviePilot/target/bin/python|' "$entrypoint"
done < <(grep -IlZ '^#!/work/venv/bin/python' "$payload/bin"/* 2>/dev/null || true)
if grep -Irn '/work/venv' "$payload/bin"; then
  echo "Temporary build path remains in a packaged command entry point" >&2
  exit 1
fi

uv_version="0.12.13"
if [ "$resource_arch" = aarch64 ]; then
  uv_sha256="2eaa5d94f5db7b3a1a092156b9420459e42ab0217d917fe74a876309cef9b5e9"
else
  uv_sha256="745765a3b6e360ad76743599ae5c42e9278c7edf8bbff9fc76d05bf2623a04dd"
fi
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${uv_version}/uv-${resource_arch}-unknown-linux-gnu.tar.gz" -o "$work/uv.tgz"
echo "${uv_sha256}  $work/uv.tgz" | sha256sum -c -
tar -xzf "$work/uv.tgz" -C "$work"; install -m 0755 "$work/uv-${resource_arch}-unknown-linux-gnu/uv" "$payload/bin/uv"; ln -sf uv "$payload/bin/uvx"

cat > "$payload/BUILD-METADATA" <<EOF
MoviePilot.version=${version}
MoviePilot.commit=${source_commit}
MoviePilot-Frontend.version=${frontend}
MoviePilot-Plugins.ref=${plugins_ref}
MoviePilot-Plugins.directory=${plugins_directory}
MoviePilot-Plugins.common_flag=${plugins_flag}
MoviePilot-Plugins.commit=${plugins_commit}
MoviePilot-Resources.commit=${resources_commit}
ffmpeg.package=ffmpeg8>=8.1.2-3
uv.version=${uv_version}
DSM.version=${dsm}
Node.js.version=${node_version}
EOF

python3 - "$outer/INFO" "$version" "$arch" "$node_version" "$os_min_ver" <<'PY'
import re, sys
p, version, arch, node_version, os_min_ver = sys.argv[1:]
s = open(p, encoding="utf-8").read()
values = {"version": version, "os_min_ver": os_min_ver, "arch": "rtd1296 rtd1619b armada37xx armv8" if arch == "armv8" else "apollolake avoton braswell broadwell broadwellnk broadwellnkv2 broadwellntbap bromolow cedarview denverton epyc7002 epyc7003 epyc7003ntb geminilake geminilakenk grantley icelaked kvmx64 purley r1000 r1000nk v1000 v1000nk x86 x86_64", "install_dep_packages": f"Node.js_v{node_version}:python314:ffmpeg8>=8.1.2-3", "changelog": f"更新 MoviePilot 到 v{version}，使用 Python 3.14、Node.js {node_version} 与 FFmpeg 8。"}
for k, v in values.items():
    s, n = re.subn(rf'(?m)^{k}="[^"]*"', f'{k}="{v}"', s, count=1)
    if n != 1: raise SystemExit(f"INFO missing {k}")
open(p, "w", encoding="utf-8", newline="\n").write(s.rstrip() + "\n")
PY
# 群晖安装时再按套件规则调整运行目录权限；归档内容统一使用 0755。
find "$payload" ! -type l -exec chmod 0755 '{}' + -exec chmod u-s,g-s,o-t '{}' +
find "$payload" -mindepth 1 -maxdepth 1 -printf '%P\0' | sort -z > "$work/payload-files"
XZ_OPT='-6 --check=crc64' tar --format=gnu --owner=0 --group=0 -cJf "$outer/package.tgz" -C "$payload" \
  --null --files-from="$work/payload-files"
xz --test "$outer/package.tgz"
checksum="$(md5sum "$outer/package.tgz" | cut -d' ' -f1)"
sed -i "s/^checksum=.*/checksum=\"${checksum}\"/" "$outer/INFO"
output="$repo/dist/$dsm/$arch/MoviePilot_v${version}_${arch}-Python3.14-DSM${dsm}.spk"
find "$outer" ! -type l -exec chmod 0755 '{}' + -exec chmod u-s,g-s,o-t '{}' +
find "$outer" -mindepth 1 -maxdepth 1 -printf '%P\0' | sort -z > "$work/outer-files"
tar --format=gnu --owner=0 --group=0 -cf "$output" -C "$outer" \
  --null --files-from="$work/outer-files"
tar -tf "$outer/package.tgz" > "$work/package-list"
if grep -Eq '^(\./|\.$)' "$work/package-list"; then
  echo "package.tgz contains an invalid dot-prefixed root" >&2
  exit 1
fi
for required_dir in logs tmp; do
  if ! grep -Eq "^${required_dir}/?$" "$work/package-list"; then
    echo "package.tgz is missing required directory: ${required_dir}" >&2
    exit 1
  fi
done
tar -tf "$output" > "$work/spk-list"
if grep -Eq '^(\./|\.$)' "$work/spk-list"; then
  echo "SPK contains an invalid dot-prefixed root" >&2
  exit 1
fi
grep -qx package.tgz "$work/spk-list"
echo "Built $output"
if [[ "$dsm" == 7.2 ]]; then
  mkdir -p "$repo/reports/$dsm/$arch"
  cp -a "$work/plugin-dependency-report/." "$repo/reports/$dsm/$arch/"
fi
