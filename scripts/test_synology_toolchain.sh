#!/usr/bin/env bash
set -euo pipefail

platform="${1:?platform required}"
version="${2:-7.1}"
work="${RUNNER_TEMP:-/tmp}/synology-${platform}-${version}"
rm -rf "${work}"
mkdir -p "${work}/toolkit"
git clone --depth 1 --branch "DSM${version}" \
  https://github.com/SynologyOpenSource/pkgscripts-ng.git "${work}/toolkit/pkgscripts-ng"
sudo "${work}/toolkit/pkgscripts-ng/EnvDeploy" -v "${version}" -p "${platform}"
toolchain="${work}/toolkit/build_env/ds.${platform}-${version}"
test -d "${toolchain}"

case "${platform}" in
  avoton) triple="x86_64-pc-linux-gnu" ;;
  rtd1296) triple="aarch64-unknown-linux-gnu" ;;
  *) echo "Unsupported test platform: ${platform}" >&2; exit 1 ;;
esac
cc="${toolchain}/usr/local/${triple}/bin/${triple}-gcc"
cxx="${toolchain}/usr/local/${triple}/bin/${triple}-g++"
test -x "${cc}" && test -x "${cxx}"
sysroot="$(${cc} -print-sysroot)"
cat > "${work}/probe.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("Synology DSM toolchain probe"); return 0; }
EOF
cat > "${work}/probe.cpp" <<'EOF'
#include <string>
extern "C" const char *synology_cpp_probe(void) {
    static std::string value("Synology DSM C++ toolchain probe");
    return value.c_str();
}
EOF
"${cc}" --sysroot="${sysroot}" -O2 "${work}/probe.c" -o "${work}/probe"
"${cxx}" --sysroot="${sysroot}" -O2 -fPIC -shared "${work}/probe.cpp" -o "${work}/libprobe.so"
echo "compiler=${cc}"
echo "cxx=${cxx}"
echo "sysroot=${sysroot}"
"${cc}" -dumpmachine
file "${work}/probe" "${work}/libprobe.so"
readelf -h "${work}/probe"
readelf --version-info "${work}/probe" || true
readelf --version-info "${work}/libprobe.so" || true
