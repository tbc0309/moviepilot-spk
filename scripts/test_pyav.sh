#!/bin/bash
set -euo pipefail
mkdir -p /work/pyav-report /work/pyav-wheels
exec > >(tee /work/pyav-report/build.log) 2>&1
curl --fail --location --retry 3 https://ffmpeg.org/releases/ffmpeg-6.1.2.tar.xz -o /work/ffmpeg.tar.xz
tar -xf /work/ffmpeg.tar.xz -C /work
cd /work/ffmpeg-6.1.2
./configure --prefix=/work/ffmpeg-dev --enable-shared --disable-static --disable-programs --disable-doc --disable-x86asm --disable-autodetect
make -j2
make install
export PKG_CONFIG_PATH=/work/ffmpeg-dev/lib/pkgconfig
export LD_LIBRARY_PATH=/work/ffmpeg-dev/lib
python=/opt/python/cp314-cp314/bin/python
"$python" -m pip wheel --no-deps --wheel-dir /work/pyav-wheels av==12.3.0
for wheel in /work/pyav-wheels/*.whl; do
  auditwheel repair "$wheel" -w /work/pyav-report
done
"$python" -m pip install --no-deps /work/pyav-report/*.whl
"$python" -c 'import av; print("PYAV_IMPORT_OK", av.__version__, av.library_versions)'
"$python" - <<'PY'
import av, io, wave
data = io.BytesIO()
with wave.open(data, 'wb') as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(16000)
    output.writeframes(b'\0\0' * 16000)
data.seek(0)
with av.open(data) as media:
    samples = sum(frame.samples for frame in media.decode(audio=0))
assert samples == 16000, samples
print('PYAV_AUDIO_DECODE_OK', samples)
PY
