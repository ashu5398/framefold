# Third-party notices

FrameFold itself is MIT-licensed (see [LICENSE](LICENSE)). It uses, bundles or downloads the
components below, each under its own licence.

## Bundled in FrameFold.app

### AuraFace-v1 (face recognition)
- Source: https://huggingface.co/fal/AuraFace-v1 (revision `af6d057c9b0ec4071d4c49c80e3539258798b609`, file `glintr100.onnx`)
- Authors: fal.ai
- Licence: Apache License 2.0. The full text ships as `AuraFace-LICENSE.md` next to the model in the app bundle and in `Resources/Models/`.
- Modifications: converted from ONNX to Core ML (FP16, with the input scaling folded in) by `scripts/convert_face_model.py`. The weights are otherwise unchanged.
- Note: the model card says the model was trained on commercially available data. Review it yourself if you redistribute FrameFold commercially.

## Downloaded by the user at setup (not shipped with FrameFold)

### Ollaya runtime
- Source: https://github.com/ollaya-dev/ollaya, installed with https://ollaya.dev/install.sh
- Licence: Apache License 2.0

### d1 3B Vision (`d1:3b-vision`)
- Source: https://huggingface.co/ollaya-dev/d1 (packaging) and https://huggingface.co/LiquidAI/d1-3B-GGUF (weights)
- Authors: Liquid AI
- Licence: LFM Open License v1.0. Read it at the source before using the model commercially.

## Build tools (used only to build from source)
- coremltools (BSD-3-Clause), PyTorch (BSD-3-Clause), torchvision (BSD-3-Clause), ONNX (Apache-2.0),
  onnx2torch (Apache-2.0), Pillow (MIT-CMU), NumPy (BSD-3-Clause). Installed into a private virtual
  environment by `scripts/make-face-model.sh`; none of them ship in the app.

## Documentation assets
- Sample photos in `docs/screenshots` are from Unsplash (https://unsplash.com/license) via Lorem Picsum
  (https://picsum.photos). Photographers are credited in `docs/screenshots/PHOTO-CREDITS.txt`.

## Trademarks
iPhone, iCloud, macOS and Photos are trademarks of Apple Inc. FrameFold is not affiliated with or
endorsed by Apple.
