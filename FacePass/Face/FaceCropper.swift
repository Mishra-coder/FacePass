import CoreGraphics

/// Produces the exact crops the Core ML models were trained on.
enum FaceCropper {
    static let alignedSize = 112
    static let livenessSize = 80

    /// ArcFace/SFace 5-point template for a 112×112 crop (top-left origin).
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// 112×112 face warped so the five landmarks land on the SFace template.
    static func aligned(_ image: CGImage, points: FivePoints) -> CGImage? {
        // Vision points and CGContext both use a bottom-left origin, so flip only the template.
        let size = CGFloat(alignedSize)
        let destination = template.map { CGPoint(x: $0.x, y: size - $0.y) }
        guard let transform = similarityTransform(from: points.all, to: destination),
              let context = rgbContext(width: alignedSize, height: alignedSize) else {
            return nil
        }
        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Square-ish crop around the face box scaled by `scale`, shifted to stay inside
    /// the image, resized to 80×80. Mirrors Silent-Face-Anti-Spoofing's CropImage.
    static func livenessCrop(_ image: CGImage, faceBox: CGRect, scale requestedScale: CGFloat) -> CGImage? {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        // Face box arrives bottom-left origin; CGImage cropping uses top-left.
        let box = CGRect(x: faceBox.minX, y: imageHeight - faceBox.maxY, width: faceBox.width, height: faceBox.height)
        guard box.width > 1, box.height > 1 else { return nil }

        let scale = min((imageHeight - 1) / box.height, (imageWidth - 1) / box.width, requestedScale)
        let newWidth = box.width * scale
        let newHeight = box.height * scale
        var left = box.midX - newWidth / 2
        var top = box.midY - newHeight / 2
        var right = box.midX + newWidth / 2
        var bottom = box.midY + newHeight / 2

        if left < 0 { right -= left; left = 0 }
        if top < 0 { bottom -= top; top = 0 }
        if right > imageWidth - 1 { left -= right - imageWidth + 1; right = imageWidth - 1 }
        if bottom > imageHeight - 1 { top -= bottom - imageHeight + 1; bottom = imageHeight - 1 }

        let cropRect = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1).integral
        guard let cropped = image.cropping(to: cropRect),
              let context = rgbContext(width: livenessSize, height: livenessSize) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: livenessSize, height: livenessSize))
        return context.makeImage()
    }

    /// Least-squares rotation + uniform scale + translation (no reflection).
    static func similarityTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == destination.count, !source.isEmpty else { return nil }
        let count = CGFloat(source.count)
        let sourceMean = source.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / count, y: $0.y + $1.y / count) }
        let destinationMean = destination.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / count, y: $0.y + $1.y / count) }

        var dot: CGFloat = 0
        var cross: CGFloat = 0
        var norm: CGFloat = 0
        for (p, q) in zip(source, destination) {
            let px = p.x - sourceMean.x, py = p.y - sourceMean.y
            let qx = q.x - destinationMean.x, qy = q.y - destinationMean.y
            dot += px * qx + py * qy
            cross += px * qy - py * qx
            norm += px * px + py * py
        }
        guard norm > 1e-6 else { return nil }

        let c = dot / norm // scale·cosθ
        let s = cross / norm // scale·sinθ
        let tx = destinationMean.x - (c * sourceMean.x - s * sourceMean.y)
        let ty = destinationMean.y - (s * sourceMean.x + c * sourceMean.y)
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: tx, ty: ty)
    }

    private static func rgbContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }
}
