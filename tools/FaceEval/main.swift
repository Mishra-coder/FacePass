// Runs FacePass's real face pipeline (Vision landmarks → FaceCropper → Core ML) on
// still images, so match scores can be compared against the OpenCV reference.
//
// Build: see tools/face_eval.sh
// Usage: FaceEval <compiled-model-dir> <output-dir> <template-images…> -- <probe-images…>

import AppKit
import CoreGraphics
import CoreVideo
import Foundation

func loadCGImage(_ path: String) -> CGImage? {
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}

func savePNG(_ image: CGImage, to path: String) {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    try? data?.write(to: URL(fileURLWithPath: path))
}

struct Evaluation {
    let embedding: [Float]
    let real: Float?
    let quality: Float
    let yaw: Double
}

func evaluate(_ path: String, models: FaceModels, outputDirectory: String) -> Evaluation? {
    guard let image = loadCGImage(path), let buffer = pixelBuffer(from: image),
          let face = try? FaceAnalyzer.largestFace(in: buffer),
          let aligned = FaceCropper.aligned(image, points: face.landmarks),
          let embedding = try? models.embedding(forAligned: aligned) else {
        return nil
    }
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    savePNG(aligned, to: "\(outputDirectory)/\(name).png")

    var real: Float?
    if let v2 = FaceCropper.livenessCrop(image, faceBox: face.boundingBox, scale: FaceModels.livenessV2Scale),
       let v1se = FaceCropper.livenessCrop(image, faceBox: face.boundingBox, scale: FaceModels.livenessV1SEScale) {
        real = try? models.realProbability(v2Crop: v2, v1seCrop: v1se)
    }
    return Evaluation(embedding: embedding, real: real, quality: face.captureQuality, yaw: face.yaw * 180 / .pi)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 4, let separator = arguments.firstIndex(of: "--") else {
    print("usage: FaceEval <model-dir> <output-dir> <template-images…> -- <probe-images…>")
    exit(2)
}
let models = try FaceModels(modelDirectory: URL(fileURLWithPath: arguments[0]))
let outputDirectory = arguments[1]
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

let templateSamples = arguments[2..<separator].compactMap { evaluate($0, models: models, outputDirectory: outputDirectory)?.embedding }
guard let template = FaceMath.meanTemplate(templateSamples) else {
    print("no faces in template images")
    exit(1)
}
print("FacePass pipeline (Vision + FaceCropper + Core ML), template from \(templateSamples.count) images")
for path in arguments[(separator + 1)...] {
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard let result = evaluate(path, models: models, outputDirectory: outputDirectory) else {
        print("  \(name)  no face")
        continue
    }
    let cosine = FaceMath.cosine(template, result.embedding)
    print(String(format: "  %@  cos=%.3f  real=%@  quality=%.2f  yaw=%+.0f°", name, cosine,
                 result.real.map { String(format: "%.0f%%", $0 * 100) } ?? "—", result.quality, result.yaw))
}
