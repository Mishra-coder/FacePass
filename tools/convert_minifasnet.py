#!/usr/bin/env python3
"""Convert Minivision Silent-Face MiniFASNet anti-spoofing models (Apache-2.0) to Core ML.

Each model takes an 80x80 BGR crop (raw 0-255) centred on the face box, scaled by
2.7x (V2) or 4.0x (V1SE), and returns softmax `probs` over 3 classes, where
index 1 = real face. The app averages both models' probabilities.

Run with the Python 3.12 env:  tools/.venv312/bin/python tools/convert_minifasnet.py
"""
import hashlib
import pathlib
import sys

import coremltools as ct
import numpy as np
import torch
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
MODELS = HERE / "models"
sys.path.insert(0, str(MODELS / "minifasnet_src"))
from MiniFASNet import MiniFASNetV1SE, MiniFASNetV2  # noqa: E402

DST = HERE.parent / "FacePass" / "Resources" / "Models"
SPECS = [
    # (source weights, sha256, constructor, output name, crop scale)
    ("2.7_80x80_MiniFASNetV2.pth",
     "a5eb02e1843f19b5386b953cc4c9f011c3f985d0ee2bb9819eea9a142099bec0",
     MiniFASNetV2, "LivenessV2", 2.7),
    ("4_0_0_80x80_MiniFASNetV1SE.pth",
     "84ee1d37d96894d5e82de5a57df044ef80a58be2b218b5ed7cdfd875ec2f5990",
     MiniFASNetV1SE, "LivenessV1SE", 4.0),
]


class WithSoftmax(torch.nn.Module):
    def __init__(self, net: torch.nn.Module):
        super().__init__()
        self.net = net

    def forward(self, x):
        return torch.softmax(self.net(x), dim=1)


def load(path: pathlib.Path, sha256: str, constructor) -> torch.nn.Module:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != sha256:
        sys.exit(f"{path.name} checksum mismatch: {digest}")
    net = constructor(conv6_kernel=(5, 5))  # get_kernel(80, 80) in upstream utility.py
    state = torch.load(path, map_location="cpu", weights_only=True)
    state = {k.removeprefix("module."): v for k, v in state.items()}
    net.load_state_dict(state)
    return WithSoftmax(net).eval()


def main() -> None:
    DST.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(11)
    for filename, sha256, constructor, name, scale in SPECS:
        model = load(MODELS / filename, sha256, constructor)
        traced = torch.jit.trace(model, torch.rand(1, 3, 80, 80) * 255.0)
        mlmodel = ct.convert(
            traced,
            inputs=[ct.ImageType(name="image", shape=(1, 3, 80, 80),
                                 color_layout=ct.colorlayout.BGR, scale=1.0)],
            outputs=[ct.TensorType(name="probs")],
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=ct.precision.FLOAT32,
        )
        mlmodel.author = "Minivision Silent-Face-Anti-Spoofing - converted for FacePass"
        mlmodel.license = "Apache-2.0"
        mlmodel.short_description = f"Face anti-spoofing, 80x80 BGR crop at {scale}x face box; probs[1] = real."
        mlmodel.version = f"{filename.removesuffix('.pth')}-1"

        worst = 0.0
        for _ in range(8):
            bgr = rng.integers(0, 256, size=(80, 80, 3), dtype=np.uint8)
            with torch.no_grad():
                reference = model(torch.from_numpy(bgr.transpose(2, 0, 1)[None].astype(np.float32)))[0].numpy()
            rgb = bgr[:, :, ::-1].copy()  # PIL images are RGB; Core ML reorders to BGR
            predicted = mlmodel.predict({"image": Image.fromarray(rgb)})["probs"].reshape(-1)
            worst = max(worst, float(np.abs(reference - predicted).max()))
        print(f"{name}: max |prob diff| vs PyTorch = {worst:.6f}")
        if worst > 1e-3:
            sys.exit(f"{name}: conversion mismatch - refusing to write model")

        out = DST / f"{name}.mlpackage"
        mlmodel.save(str(out))
        print(f"saved {out}")


if __name__ == "__main__":
    main()
