//
//  PhotoQualityScorer.swift
//  Camera Roll Cleaner
//
//  Estimates how "good" a photo is, on-device, so clustering can pick a
//  representative for a group of duplicates without asking the user or
//  calling any cloud AI. Two independent signals:
//
//  - Sharpness: how in-focus/blurry the photo is.
//  - Blinks: is anyone's eye closed? This uses Apple's own blink detector
//    (Core Image), not a rule of ours — see blinkCheck.
//
//  JUDGMENT CALL: Apple doesn't ship a "how sharp is this photo" score, so
//  sharpness is a standard, widely-used computer-vision technique written
//  here by hand. Its numbers are only meaningful compared against other
//  photos in the same cluster (which is all this app needs), not as some
//  universal 0-100 "quality score".
//

import CoreGraphics
import CoreImage
import UIKit

/// What Apple's blink detector found in one photo.
nonisolated struct BlinkCheck: Sendable {
    /// Faces it found (it can miss faces Vision finds, e.g. side-on ones).
    let faces: Int
    /// Of those, faces with at least one eye closed.
    let blinking: Int
}

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

    /// Apple's own blink detector — Core Image's face detector with its
    /// eye-blink option — run on the photo the right way up. nil if it found
    /// no faces (for example everyone turned away), which is not the same
    /// as "eyes closed".
    ///
    /// This replaced a hand-made rule (height ÷ width of the eye outline
    /// from Vision, under 0.2 = closed) that misread real photos: a smile
    /// squints the eyes, so smiling at the camera scored 0.18 ("closed"),
    /// while eyes seen side-on, looking at each other, scored 0.34
    /// ("open") — which pushed the best shot of the lake set to the bottom.
    static func blinkCheck(in cgImage: CGImage, orientation: CGImagePropertyOrientation) -> BlinkCheck? {
        let faces = (blinkDetector?.features(in: CIImage(cgImage: cgImage), options: [
            CIDetectorImageOrientation: Int(orientation.rawValue), // EXIF number, which Core Image expects
            CIDetectorEyeBlink: true,
        ]) ?? []).compactMap { $0 as? CIFaceFeature }
        guard !faces.isEmpty else { return nil }
        return BlinkCheck(faces: faces.count, blinking: faces.filter { $0.leftEyeClosed || $0.rightEyeClosed }.count)
    }

    /// Made once and reused — setting up the detector is the slow part.
    private static let blinkDetector = CIDetector(
        ofType: CIDetectorTypeFace, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )

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
