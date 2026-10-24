#!/bin/sh
# Downloads AuraFace-v1 (fal.ai, Apache-2.0) and converts its recognition network to Core ML:
#   Resources/Models/AuraFace.mlpackage   (bundled into the app by build-app.sh)
#   Resources/Models/AuraFace-LICENSE.md
# Everything runs in its own virtual environment under build/face-model (about 1 GB, reused on
# later runs); any Python 3.9+ works, including the one that comes with macOS.
set -eu

cd "$(dirname "$0")/.."
REVISION=af6d057c9b0ec4071d4c49c80e3539258798b609
SHA256=a7933ea5330113b01c9b60351d8f4c33003f145d8470ac5f0e52ee2effe25c60
BASE=https://huggingface.co/fal/AuraFace-v1/resolve/$REVISION
WORK=build/face-model

# Newest Python 3.9+ available, unless PYTHON is set.
if [ -z "${PYTHON:-}" ]; then
    for candidate in python3.13 python3.12 python3.11 python3.10 python3 /usr/bin/python3; do
        if command -v "$candidate" >/dev/null 2>&1 \
            && "$candidate" -c 'import sys; sys.exit(0 if (3, 9) <= sys.version_info[:2] <= (3, 13) else 1)' 2>/dev/null; then
            PYTHON=$(command -v "$candidate")
            break
        fi
    done
fi
[ -n "${PYTHON:-}" ] || { echo "error: Python 3.9 to 3.13 is needed (install the Xcode Command Line Tools: xcode-select --install)" >&2; exit 1; }
echo "Using $PYTHON ($("$PYTHON" -c 'import platform; print(platform.python_version())'))"

mkdir -p "$WORK" Resources/Models
if [ ! -x "$WORK/venv/bin/python" ]; then
    "$PYTHON" -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install -q --upgrade pip
    "$WORK/venv/bin/pip" install -q coremltools==9.0 torch==2.7.0 torchvision==0.22.0 onnx onnx2torch pillow numpy
fi

if [ ! -f "$WORK/glintr100.onnx" ] || ! echo "$SHA256  $WORK/glintr100.onnx" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "Downloading AuraFace-v1 (261 MB)…"
    curl -fL --progress-bar -o "$WORK/glintr100.onnx" "$BASE/glintr100.onnx"
    echo "$SHA256  $WORK/glintr100.onnx" | shasum -a 256 -c -
fi
curl -fsSL -o Resources/Models/AuraFace-LICENSE.md "$BASE/LICENSE.md"

echo "Converting to Core ML…"
rm -rf Resources/Models/AuraFace.mlpackage
"$WORK/venv/bin/python" -I scripts/convert_face_model.py "$WORK/glintr100.onnx" Resources/Models/AuraFace.mlpackage
echo "Wrote Resources/Models/AuraFace.mlpackage"
