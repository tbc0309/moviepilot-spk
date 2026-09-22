#!/usr/bin/env bash
set -euo pipefail
arch="${1:?spksrc architecture required}"
tcversion="${2:?DSM toolchain version required}"
version="${3:-3.0.5}"
work="${GITHUB_WORKSPACE}/.spksrc-cache/${arch}-${tcversion}"
source_dir="${RUNNER_TEMP:-/tmp}/moviepilot-source-${version}"
spksrc_commit="e69c641e3f26b53e587f551b3b6edef27792632e"

rm -rf "${source_dir}" "${GITHUB_WORKSPACE}/cross-wheels-${tcversion}"
mkdir -p "${source_dir}"
curl -fsSL "https://codeload.github.com/jxxghp/MoviePilot/tar.gz/refs/tags/v${version}" -o "${RUNNER_TEMP}/moviepilot.tgz"
tar -xzf "${RUNNER_TEMP}/moviepilot.tgz" -C "${source_dir}" --strip-components=1
test -s "${source_dir}/uv.lock"
docker run --rm -v "${source_dir}:/src" -w /src python:3.14-bookworm bash -euc '
  python -m pip install --disable-pip-version-check --upgrade uv
  python -m uv export --frozen --no-default-groups --group runtime-standard \
    --no-emit-project --no-hashes -o /src/requirements-crossenv.txt
'
sudo chown "$(id -u):$(id -g)" "${source_dir}/requirements-crossenv.txt"
printf '\nsupervisor==4.3.0\n' >> "${source_dir}/requirements-crossenv.txt"
case "${arch}" in x64) target_arch="x86_64" ;; *) target_arch="armv8" ;; esac
docker run --rm -v "${GITHUB_WORKSPACE}:/repo:ro" -v "${source_dir}:/src" -w /src python:3.14-bookworm bash -euc '
  python -m pip install --disable-pip-version-check packaging
  python /repo/scripts/select_spksrc_candidates.py /src/requirements-crossenv.txt '"${target_arch}"' '"${tcversion}"' /src/spksrc-candidates.txt /src/dependency-report.json
'
sudo chown -R "$(id -u):$(id -g)" "${source_dir}"

out="${GITHUB_WORKSPACE}/cross-wheels-${tcversion}"
mkdir -p "${out}"
cp "${source_dir}/spksrc-candidates.txt" "${source_dir}/dependency-report.json" "${out}/"
if [ ! -s "${source_dir}/spksrc-candidates.txt" ]; then
  echo "All locked dependencies have compatible wheels; spksrc compilation is unnecessary."
  exit 0
fi
if [ ! -d "${work}/.git" ]; then
  mkdir -p "$(dirname "${work}")"
  git clone --filter=blob:none --no-checkout https://github.com/SynoCommunity/spksrc.git "${work}"
fi
git -C "${work}" checkout -f "${spksrc_commit}"
rm -rf "${work}/spk/codex-moviepilot-full"
mkdir -p "${work}/spk/codex-moviepilot-full/src"
cp "${source_dir}/spksrc-candidates.txt" "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt"
# DSM 7.1 packaging already builds psycopg2 against a static libpq explicitly.
# Keep that proven path instead of sending psycopg2-binary through generic crossenv.
sed -i '/^psycopg2-binary==/Id' "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt"
cat > "${work}/spk/codex-moviepilot-full/Makefile" <<'EOF'
SPK_NAME = codex-moviepilot-full
SPK_VERS = 1.0
SPK_REV = 1
PYTHON_PACKAGE = python314
MAINTAINER = Codex
DESCRIPTION = Full MoviePilot dependency build with Synology toolchain
STARTABLE = no
DISPLAY_NAME = MoviePilot full dependency build
HOMEPAGE = https://github.com/tbc0309/moviepilot-spk
LICENSE = MIT
WHEELS = src/requirements-crossenv.txt
WHEELS_PURE_PYTHON_PACKAGING_ENABLE = 1
include ../../mk/spksrc.spk-meta.mk
EOF

update_python_recipe() {
  local recipe="$1" package="$2" version="$3"
  python3 - "${work}/python/${recipe}" "${package}" "${version}" <<'PY'
import difflib, hashlib, io, json, re, sys, tarfile, urllib.request
from pathlib import Path

recipe, package, version = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
request = urllib.request.Request(
    f"https://pypi.org/pypi/{package}/{version}/json",
    headers={"User-Agent": "moviepilot-spk-recipe-sync/1"},
)
with urllib.request.urlopen(request, timeout=60) as response:
    files = json.load(response)["urls"]
sdist = next(item for item in files if item["packagetype"] == "sdist")
with urllib.request.urlopen(sdist["url"], timeout=120) as response:
    data = response.read()
makefile = recipe / "Makefile"
text = makefile.read_text(encoding="utf-8")
text, count = re.subn(r"(?m)^PKG_VERS\s*=.*$", f"PKG_VERS = {version}", text, count=1)
if count != 1:
    raise SystemExit(f"PKG_VERS missing from {makefile}")
makefile.write_text(text, encoding="utf-8")
name = sdist["filename"]
(recipe / "digests").write_text(
    f"{name} SHA1 {hashlib.sha1(data).hexdigest()}\n"
    f"{name} SHA256 {hashlib.sha256(data).hexdigest()}\n"
    f"{name} MD5 {hashlib.md5(data).hexdigest()}\n",
    encoding="utf-8",
)
if package == "numpy":
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = {member.name: member for member in archive.getmembers()}
        def source(suffix):
            matches = [name for name in members if name.endswith(suffix)]
            name = min(matches, key=lambda item: item.count("/"))
            return archive.extractfile(members[name]).read().decode("utf-8")

        meson = source("/meson.build")
        compat = re.sub(
            r"cc\.version\(\)\.version_compare\('>=\d+\.\d+'\)",
            "cc.version().version_compare('>=8.5')", meson, count=1,
        )
        compat = re.sub(
            r"error\('NumPy requires GCC >= \d+\.\d+'\)",
            "error('NumPy requires GCC >= 8.5')", compat, count=1,
        )
        if compat == meson:
            raise SystemExit("Could not generate NumPy GCC 8.5 compatibility patch")
        patch = "".join(difflib.unified_diff(
            meson.splitlines(True), compat.splitlines(True),
            fromfile="meson.build", tofile="meson.build",
        ))
        (recipe / "patches/001-downgrade-gcc-minimum-version-to-85.patch").write_text(
            patch, encoding="utf-8",
        )

        loops = source("/numpy/_core/src/umath/loops_autovec.dispatch.c.src")
        needle = """NPY_NO_EXPORT void NPY_CPU_DISPATCH_CURFX(@TYPE@_bitwise_count)
(char **args, npy_intp const *dimensions, npy_intp const *steps, void *NPY_UNUSED(func))
{
    UNARY_LOOP_FAST(@type@, npy_ubyte, *out = npy_popcount@c@(in));
}
"""
        replacement = "#pragma GCC optimize (\"0\")\n" + needle + "#pragma GCC reset_options\n"
        if needle not in loops:
            raise SystemExit("Could not generate NumPy DSM 7.1 ARM GCC workaround")
        arm_compat = loops.replace(needle, replacement, 1)
        arm_patch = "".join(difflib.unified_diff(
            loops.splitlines(True), arm_compat.splitlines(True),
            fromfile="numpy/_core/src/umath/loops_autovec.dispatch.c.src",
            tofile="numpy/_core/src/umath/loops_autovec.dispatch.c.src",
        ))
        arm_dir = recipe / "patches/aarch64-7.1"
        arm_dir.mkdir(parents=True, exist_ok=True)
        for old in arm_dir.glob("*.patch"):
            old.unlink()
        (arm_dir / "001-disable-bitwise-count-optimization.patch").write_text(
            arm_patch, encoding="utf-8",
        )
PY
}

if grep -Eqi '^numpy==' "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt"; then
  numpy_version="$(sed -n 's/^numpy==//Ip' "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt")"
  update_python_recipe numpy-latest numpy "${numpy_version}"
  sed -i 's/^build:Cython==[^[:space:]]*/build:Cython==3.1.4/' \
    "${work}/spk/python314/crossenv/requirements-default.txt"
  sed -i '/^numpy==/Id' "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt"
  sed -i '/include ..\/..\/mk\/spksrc.spk-meta.mk/i DEPENDS += python/numpy-latest' "${work}/spk/codex-moviepilot-full/Makefile"
  # spksrc currently stores the DSM 7.1 aarch64 GCC workaround under an
  # unrecognised group name.  Its patch loader uses "armv8", so expose the
  # same upstream patch under the directory it actually scans.
  if [ "${tcversion}" = 7.1 ] && [ "${arch}" != x64 ]; then
    mkdir -p "${work}/python/numpy-latest/patches/armv8-7.1"
    cp "${work}/python/numpy-latest/patches/aarch64-7.1/"*.patch \
      "${work}/python/numpy-latest/patches/armv8-7.1/"
  fi
fi
if grep -Eqi '^pillow==' "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt"; then
  pillow_version="$(sed -n 's/^pillow==//Ip' "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt")"
  update_python_recipe pillow pillow "${pillow_version}"
  # Pillow 12.3+ uses a custom PEP 517 backend which imports pybind11 while
  # determining build requirements.  spksrc builds with --no-isolation, so
  # explicitly provide the upstream-declared build dependency in crossenv.
  grep -Eq '^build:pybind11([=<>!~]|$)' \
    "${work}/spk/python314/crossenv/requirements-default.txt" || \
    printf 'build:pybind11\n' >> \
      "${work}/spk/python314/crossenv/requirements-default.txt"
  sed -i '/^pillow==/Id' "${work}/spk/codex-moviepilot-full/src/requirements-crossenv.txt"
  sed -i '/include ..\/..\/mk\/spksrc.spk-meta.mk/i DEPENDS += python/pillow' "${work}/spk/codex-moviepilot-full/Makefile"
fi
printf 'rsc:share/wheelhouse\n' > "${work}/spk/codex-moviepilot-full/PLIST"
docker run --rm --platform linux/amd64 -v "${work}:/spksrc" -w /spksrc \
  ghcr.io/synocommunity/spksrc:latest bash -euc "
    git config --global --add safe.directory /spksrc
    make -C spk/codex-moviepilot-full -j2 arch-${arch}-${tcversion}
  "

sudo chown -R "$(id -u):$(id -g)" "${work}"

if [ "${tcversion}" = 7.1 ]; then
  for library in libstdc++.so.6 libgcc_s.so.1; do
    source="$(find "${work}" -type f \( -name "${library}" -o -name "${library}.*" \) -print -quit)"
    [ -n "${source}" ] || { echo "Missing toolchain runtime ${library}" >&2; exit 1; }
    cp -Lv "${source}" "${out}/${library}"
  done
fi

while IFS= read -r requirement; do
  name="${requirement%%==*}"; version="${requirement#*==}"
  [ "${name,,}" = psycopg2-binary ] && continue
  normalized="$(printf '%s' "${name}" | tr '[:upper:]-' '[:lower:]_')"
  wheel="$(find "${work}" -type f -path '*/wheelhouse/*' \
    -iname "${normalized}-${version}-*.whl" ! -name '*_pc_linux_gnu.whl' \
    -print -quit)"
  if [ -z "${wheel}" ]; then
    wheel="$(find "${work}" -type f -path '*/wheelhouse/*' \
      -iname "${normalized}-${version}-*.whl" -print -quit)"
  fi
  [ -n "${wheel}" ] || { echo "Missing exact wheel for ${requirement}" >&2; exit 1; }
  cp -v "${wheel}" "${out}/"
done < "${source_dir}/spksrc-candidates.txt"
test -n "$(find "${out}" -maxdepth 1 -name '*.whl' -print -quit)"
python3 "${GITHUB_WORKSPACE}/scripts/collect_spksrc_runtime_libraries.py" "${work}" "${out}"
cp "${source_dir}/spksrc-candidates.txt" "${out}/requirements.txt"
while IFS= read -r requirement; do
  name="${requirement%%==*}"; version="${requirement#*==}"
  [ "${name,,}" = psycopg2-binary ] && continue
  find "${out}" -maxdepth 1 -type f -iname "${name//-/_}-${version}-*.whl" -print -quit | grep -q . || {
    echo "Missing exact wheel for ${requirement}" >&2
    exit 1
  }
done < "${source_dir}/spksrc-candidates.txt"
echo "Built $(find "${out}" -maxdepth 1 -name '*.whl' | wc -l) wheels"
