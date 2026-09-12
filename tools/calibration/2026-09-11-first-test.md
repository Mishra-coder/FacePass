# Calibration run 1 — 2026-09-11

**Setup:** MacBook Pro built-in FaceTime HD camera, indoor office light. Owner enrolled in Face Lab; tests recorded as a screen recording (`screen.mov`, 179 s). Frames were extracted from the recording, cropped to the Face Lab preview and un-mirrored, so they are lower quality than live camera frames.

**Template:** mean embedding of frames at 18.9 s, 23.4 s and 36.8 s (owner, facing camera).

## Identity scores (cosine to template)

| Time | Subject | OpenCV reference¹ | FacePass pipeline² | Real face | Quality | Yaw |
|---|---|---|---|---|---|---|
| 18.9 s | Owner | 0.960 | 0.963 | 97% | 0.61 | +2° |
| 23.4 s | Owner | 0.923 | 0.920 | 100% | 0.53 | +20° |
| 36.8 s | Owner | 0.933 | 0.928 | 100% | 0.63 | −10° |
| 157.7 s | Owner | 0.865 | 0.874 | 98% | 0.54 | −4° |
| 50.2 s | Owner, head turned | 0.853 | 0.849 | 99% | 0.56 | +31° |
| 27.9 s | Owner, head turned | 0.817 | 0.782 | 100% | 0.39 | +47° |
| 126.3 s | Owner's video on phone | 0.884 | 0.896 | 0% | 0.43 | +7° |
| 130.8 s | Owner's video on phone | 0.889 | 0.880 | 0% | 0.53 | +6° |
| 139.8 s | Owner's video on phone | 0.872 | 0.873 | 0% | 0.44 | +6° |
| 68.1 s | **Other person's photo on phone** | 0.423 | 0.467 | 2% | 0.20 | −3° |
| 72.6 s | **Other person's photo on phone** | 0.721 | 0.735 | 0% | 0.61 | −5° |
| 77.1 s | **Other person's photo on phone** | 0.737 | 0.717 | 0% | 0.57 | −4° |
| 81.6 s | **Other person's photo on phone** | 0.742 | 0.723 | 0% | 0.56 | −2° |
| 166.6 s | **Other person, live** | 0.126 | 0.128 | 100% | 0.41 | −5° |

¹ YuNet detector + `FaceRecognizerSF.alignCrop` + SFace ONNX (OpenCV 5.0).
² `tools/face_eval.sh`: Vision landmarks + `FaceCropper` + SFace Core ML — the app's real code.

## Findings

1. **The FacePass pipeline matches the OpenCV reference** (differences ≤ 0.04), so detection, alignment, preprocessing and the Core ML conversion are correct.
2. **SFace's margin is thin.** A different person's photo reached 0.74 while the owner with a turned head scored 0.78–0.85. OpenCV's default threshold (0.363) would accept that photo on identity alone.
3. **Liveness separates cleanly:** live faces 97–100%, phone photos and videos 0–2%.
4. Head pose matters: owner scores within ±25° yaw were 0.87–0.96.

## Provisional policy (`FacePass/Face/UnlockPolicy.swift`)

| Check | Threshold |
|---|---|
| Identity cosine | ≥ 0.82 |
| Real-face probability | ≥ 0.80 |
| Capture quality | ≥ 0.40 |
| Yaw | within ±25° |
| Consecutive passing frames | 3 |

## Stronger model check: AuraFace-v1

AuraFace-v1 (fal, Apache-2.0, ResNet100, 512-d, 260 MB ONNX) is the strongest face-recognition model found with a redistributable weights license. It was scored on the same OpenCV-aligned crops (RGB, `(x − 127.5) / 127.5`):

| Subject | SFace (OpenCV) | AuraFace-v1 |
|---|---|---|
| Owner, facing camera | 0.865–0.960 | 0.891–0.948 |
| Owner, head turned 32° / 46° | 0.853 / 0.817 | 0.835 / 0.739 |
| Owner's video on phone | 0.872–0.889 | 0.888–0.899 |
| Other person's photo on phone | 0.423–0.742 | 0.374–0.771 |
| Other person, live | 0.126 | 0.059 |

**Result:** no better margin between the owner and the other person's photo, and 7× larger. **Decision: keep SFace.** The high photo score appears in both models, which points to a similar-looking face degraded by the phone screen and screen recording, not a model defect. Protection against it comes from liveness and the combined policy, not from identity alone.

## Limits of this run

- Only two people besides the owner, one of them only as a photo.
- Frames came from a screen recording, not the raw camera.
- Needs repeat runs: more people (ideally relatives), different lighting, glasses, and raw-camera captures before thresholds are final. A stronger permissively licensed recognition model is being evaluated.
