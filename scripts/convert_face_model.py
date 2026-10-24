import sys, numpy as np, torch, onnx, coremltools as ct
from onnx2torch import convert
from PIL import Image
src, out = sys.argv[1], sys.argv[2]
model = convert(onnx.load(src)).eval()
example = torch.rand(1, 3, 112, 112) * 2 - 1
traced = torch.jit.trace(model, example)
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), scale=1 / 127.5, bias=[-1, -1, -1], color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="embedding")],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS14,
)
mlmodel.author = "fal.ai (AuraFace-v1), converted for FrameFold"
mlmodel.license = "Apache-2.0"
mlmodel.short_description = "AuraFace-v1 face recognition (ResNet-100, ArcFace loss). 112x112 aligned RGB face -> 512-d embedding."
mlmodel.save(out)
# Check: same random faces through torch (fp32) and Core ML (fp16).
sims = []
for _ in range(5):
    pixels = np.random.randint(0, 256, (112, 112, 3), dtype=np.uint8)
    x = torch.from_numpy(pixels).permute(2, 0, 1).float().unsqueeze(0) / 127.5 - 1
    ref = model(x).detach().numpy()[0]
    got = mlmodel.predict({"face": Image.fromarray(pixels)})["embedding"].reshape(-1)
    sims.append(float(np.dot(ref, got) / np.linalg.norm(ref) / np.linalg.norm(got)))
print("cosine(torch, coreml):", [round(s, 5) for s in sims])
