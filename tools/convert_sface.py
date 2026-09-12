#!/usr/bin/env python3
"""Convert OpenCV Zoo SFace (Apache-2.0) ONNX to a Core ML package.

Input  : `image`     112x112 RGB, raw 0-255 (the model normalises internally)
Output : `embedding` 128 floats (not L2-normalised; the app normalises)

Run with the Python 3.12 env:  tools/.venv312/bin/python tools/convert_sface.py
"""
import hashlib
import pathlib
import sys

import coremltools as ct
import numpy as np
import onnx
import onnx2torch
import onnxruntime as ort
import torch
from PIL import Image

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE / "models" / "face_recognition_sface_2021dec.onnx"
DST = HERE.parent / "FacePass" / "Resources" / "Models" / "SFace.mlpackage"
SRC_SHA256 = "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79"


def load_clean_onnx() -> onnx.ModelProto:
    digest = hashlib.sha256(SRC.read_bytes()).hexdigest()
    if digest != SRC_SHA256:
        sys.exit(f"SFace checksum mismatch: {digest}")
    model = onnx.load(str(SRC))
    # The exporter listed every weight as a graph input; keep only real inputs.
    init_names = {i.name for i in model.graph.initializer}
    real_inputs = [i for i in model.graph.input if i.name not in init_names]
    del model.graph.input[:]
    model.graph.input.extend(real_inputs)
    return model


def main() -> None:
    onnx_model = load_clean_onnx()
    torch_model = onnx2torch.convert(onnx_model).eval()

    example = torch.rand(1, 3, 112, 112) * 255.0
    traced = torch.jit.trace(torch_model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 112, 112),
                             color_layout=ct.colorlayout.RGB, scale=1.0)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.author = "OpenCV Zoo (SFace, Zhong et al. 2021) - converted for FacePass"
    mlmodel.license = "Apache-2.0"
    mlmodel.short_description = "Face identity embedding (128-d) for 5-point aligned 112x112 RGB faces."
    mlmodel.version = "sface-2021dec-1"

    # Verify Core ML output matches ONNX Runtime on several inputs.
    session = ort.InferenceSession(onnx_model.SerializeToString())
    rng = np.random.default_rng(7)
    worst = 1.0
    for _ in range(8):
        pixels = rng.integers(0, 256, size=(112, 112, 3), dtype=np.uint8)
        reference = session.run(None, {"data": pixels.transpose(2, 0, 1)[None].astype(np.float32)})[0][0]
        predicted = mlmodel.predict({"image": Image.fromarray(pixels)})["embedding"].reshape(-1)
        cosine = float(np.dot(reference, predicted) / (np.linalg.norm(reference) * np.linalg.norm(predicted)))
        worst = min(worst, cosine)
    print(f"worst cosine vs ONNX: {worst:.6f}")
    if worst < 0.9999:
        sys.exit("Conversion mismatch - refusing to write model")

    DST.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(DST))
    print(f"saved {DST}")


if __name__ == "__main__":
    main()
