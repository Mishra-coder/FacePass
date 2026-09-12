#!/bin/zsh
# Builds FaceEval (FacePass's real face pipeline as a CLI) and compiles the Core ML models for it.
# Usage: tools/face_eval.sh <template-images…> -- <probe-images…>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/FaceEval"
mkdir -p "$OUT/models" "$OUT/aligned"

for model in SFace LivenessV2 LivenessV1SE; do
  if [[ ! -d "$OUT/models/$model.mlmodelc" || "$ROOT/FacePass/Resources/Models/$model.mlpackage" -nt "$OUT/models/$model.mlmodelc" ]]; then
    rm -rf "$OUT/models/$model.mlmodelc"
    xcrun coremlcompiler compile "$ROOT/FacePass/Resources/Models/$model.mlpackage" "$OUT/models" >/dev/null
  fi
done

swiftc -O -module-name FaceEval -target arm64-apple-macos15.0 \
  "$ROOT/FacePass/Face/FaceAnalyzer.swift" \
  "$ROOT/FacePass/Face/FaceCropper.swift" \
  "$ROOT/FacePass/Face/FaceModels.swift" \
  "$ROOT/tools/FaceEval/main.swift" \
  -o "$OUT/FaceEval"

"$OUT/FaceEval" "$OUT/models" "$OUT/aligned" "$@"
