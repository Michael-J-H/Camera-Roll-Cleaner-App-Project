//
//  PhotoQualityScorer.swift
//  Camera Roll Cleaner
//
//  Estimates how "good" a photo is, on-device, so clustering can pick a
//  representative for a group of duplicates without asking the user or
//  calling any cloud AI. Two independent signals:
//
//  - Sharpness: how in-focus/blurry the photo is.
//  - Eyes-open: if there's a face, are the eyes open or closed (blinking)?
//
//  JUDGMENT CALL: Vision does not provide a built-in "how sharp is this
//  photo" score or an "are the eyes open" score — Apple doesn't ship
//  either as a request type. Both are implemented here using standard,
//  widely-used computer-vision heuristics, not an Apple-provided or
//  Apple-validated metric. The numbers these produce are only meaningful
//  compared against other photos in the same cluster (which is all this
//  app needs them for), not as some universal 0-100 "quality score".
//

import CoreGraphics
import UIKit
import Vision

enum PhotoQualityScorer {
    /// Higher = sharper. Only meaningful compared against another photo
    /// from the same cluster (same scene/lighting) — NOT a calibrated
    /// absolute scale where e.g. 500 always means "sharp".
    ///
    /// How it works: shrink the photo to a small fixed-size grayscale
    /// image, then measure how much pixel values jump around between
    /// neighbors using an edge-detecting filter (a "Laplacian"). A sharp,
    /// detailed photo has lots of hard edges, so neighboring pixels often
    /// differ a lot. A blurry photo has soft transitions, so neighboring
    /// pixels stay similar. "How much they differ, overall" is measured
    /// with variance (statistical spread). This is the standard
    /// "variance of Laplacian" blur-detection technique from computer
    /// vision (popularized via OpenCV), reimplemented by hand here in
    /// plain Swift since Vision doesn't expose it directly.
    static func sharpnessScore(for image: UIImage) -> Double {
        let side = 200
        guard let gray = grayscalePixels(from: image, side: side) else { return 0 }

        var edgeValues: [Double] = []
        edgeValues.reserveCapacity((side - 2) * (side - 2))
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let center = Double(gray[y * side + x])
                let up = Double(gray[(y - 1) * side + x])
                let down = Double(gray[(y + 1) * side + x])
                let left = Double(gray[y * side + x - 1])
                let right = Double(gray[y * side + x + 1])
                edgeValues.append(up + down + left + right - 4 * center)
            }
        }

        let mean = edgeValues.reduce(0, +) / Double(edgeValues.count)
        let variance = edgeValues.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(edgeValues.count)
        return variance
    }

    /// nil means no face was found in the photo (nothing to score — not
    /// the same as "eyes closed"). Otherwise, roughly: below ~0.15-0.2
    /// tends to mean closed/blinking, higher means open. The exact cutoff
    /// used elsewhere (see PhotoClusterEngine) is a judgment call, tuned
    /// by eye rather than measured against labeled photos.
    static func eyesOpenScore(from faceObservations: [VNFaceObservation]?) -> Double? {
        guard let faces = faceObservations, !faces.isEmpty else { return nil }

        var ratios: [Double] = []
        for face in faces {
            guard let landmarks = face.landmarks else { continue }
            if let left = landmarks.leftEye { ratios.append(eyeOpenRatio(left)) }
            if let right = landmarks.rightEye { ratios.append(eyeOpenRatio(right)) }
        }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Double(ratios.count)
    }

    /// Height-to-width ratio of the eye outline Vision detects. A wide,
    /// short shape (low ratio) reads as closed/squinting; a taller shape
    /// (higher ratio) reads as open. A simplified version of the "Eye
    /// Aspect Ratio" technique used in blink-detection research — not an
    /// Apple-provided calculation.
    private static func eyeOpenRatio(_ region: VNFaceLandmarkRegion2D) -> Double {
        let points = region.normalizedPoints
        guard points.count > 1 else { return 1.0 }
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 0 else { return 0 }
        return height / width
    }

    private static func grayscalePixels(from image: UIImage, side: Int) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        // Drawing into a smaller context both resizes and grayscale-converts
        // the photo in one step — exactly what this measurement needs, and
        // keeps the per-photo pixel loop above small and fast.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels
    }
}
