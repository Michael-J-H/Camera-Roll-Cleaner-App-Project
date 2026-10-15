//
//  PhotoClusterEngine.swift
//  Camera Roll Cleaner
//
//  The actual duplicate-detection logic: fetch photos in a date range,
//  measure how visually similar every pair is, and group the similar
//  ones together. This is plain, non-UI logic on purpose, so it can be
//  checked and trusted on its own before any chat UI is built on top of
//  it (per the project brief's ordering — clustering before chat).
//
//  `nonisolated` matters here: this project defaults every type to the
//  main actor (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor is set in the
//  Xcode project's build settings — not something this feature added).
//  That default is normally right for SwiftUI code, but this file does
//  CPU-heavy work (Vision requests, manual pixel math) that can take
//  several seconds for a batch of photos. Running that on the main actor
//  would freeze the UI, so `nonisolated` opts this file back out, which
//  lets it run on a background thread instead.
//

import CoreLocation
import Photos
import UIKit
import Vision

struct ClusterCandidate {
    let asset: PHAsset
    let featurePrint: VNFeaturePrintObservation
    let sharpness: Double
    let eyesOpenScore: Double? // nil = no face detected in this photo
    /// Apple's face capture quality (0–1, higher = better) for each face
    /// found — empty when there are no faces. See pickRepresentative.
    let faceQualities: [Double]
    let creationDate: Date?
    let location: CLLocation?
}

struct PhotoCluster: Identifiable {
    let id = UUID()
    let members: [ClusterCandidate]
    let representative: ClusterCandidate
}

/// TEMPORARY diagnostic type — a pair of photos that landed in different
/// clusters but were one condition away from matching (exactly one of the
/// three gates — visual similarity / time / location — blocked them, not
/// two or three at once). That "exactly one" is deliberate: a pair failing
/// on every count was never a real candidate, and showing it would just be
/// noise. Not part of the shipped clustering behavior.
struct NearMissPair: Identifiable {
    let id = UUID()
    let a: ClusterCandidate
    let b: ClusterCandidate
    let featurePrintDistance: Float?
    let timeGapSeconds: TimeInterval
    let locationDistanceMeters: Double?
    let passedSimilarity: Bool
    let passedTime: Bool
    let passedLocation: Bool
}

/// TEMPORARY diagnostic type — a photo that never made it into a candidate
/// at all (image failed to load, or Vision couldn't process it), so it's
/// silently missing from every cluster AND every near-miss pair. Without
/// this, a photo lost at this stage would look identical to "correctly
/// judged not a duplicate."
struct FailedAsset: Identifiable {
    let id = UUID()
    let asset: PHAsset
    let reason: String
}

struct ClusteringResult {
    let totalScanned: Int
    let duplicateClusters: [PhotoCluster]
    let singles: [ClusterCandidate]
    let nearMisses: [NearMissPair]
    let failedAssets: [FailedAsset]
}

nonisolated enum PhotoClusterEngine {
    // JUDGMENT CALLS — Apple doesn't publish "this counts as a duplicate"
    // thresholds for any of these; there's no built-in Vision API that
    // says "these two photos are duplicates". Chosen empirically, easy to
    // retune here in one place after checking real results on the debug
    // screen against photos the developer actually remembers taking.
    // Raised from an initial 0.3 after auditing real results against a
    // hand-checked date range: 0.3 was too strict for photos that are the
    // same moment but reframed/zoomed/recomposed slightly (the visual
    // content shifts more than a plain burst retake, even though a person
    // would call them duplicates). 0.45 recovers most of those without
    // (as far as tested) pulling in genuinely unrelated photos — but like
    // the other constants here, it's still an empirical guess, not a
    // derived or Apple-published number.
    private static let featurePrintDistanceThreshold: Float = 0.45
    private static let maxTimeGapSeconds: TimeInterval = 60
    private static let maxLocationDistanceMeters: Double = 100
    private static let closedEyeThreshold: Double = 0.2
    private static let workingImageSize = CGSize(width: 512, height: 512)
    /// Photos with faces get their faces re-checked at this larger size: in
    /// a wide shot, faces at 512px are only ~20–30px across — too small to
    /// tell open eyes from closed, or for Apple's face quality score to be
    /// reliable. Only photos with people pay for the extra load.
    private static let faceDetailImageSize = CGSize(width: 2048, height: 2048)

    /// The fixed window ClusteringDebugView checks against (Sep 26 – Oct 4,
    /// 2025 inclusive, in the device's local calendar) — kept as a named
    /// constant now that `run` takes any interval, so the debug screen can
    /// keep testing against the exact same known range it always has.
    static let debugRange = DateInterval(
        start: dateAt(year: 2025, month: 9, day: 26),
        end: dateAt(year: 2025, month: 10, day: 5) // exclusive, covers all of Oct 4
    )

    static func run(in interval: DateInterval) async -> ClusteringResult {
        let assets = fetchAssets(in: interval)
        print("[Clustering] \(assets.count) photos found in \(interval.start) – \(interval.end)")

        var candidates: [ClusterCandidate] = []
        var failedAssets: [FailedAsset] = []
        for asset in assets {
            guard let image = await loadImage(for: asset, targetSize: workingImageSize) else {
                failedAssets.append(FailedAsset(asset: asset, reason: "Could not load image data"))
                continue
            }
            guard let cgImage = image.cgImage else {
                failedAssets.append(FailedAsset(asset: asset, reason: "Loaded image had no underlying CGImage"))
                continue
            }

            // One handler, two requests — cheaper than decoding the image twice.
            // NOTE: VNGenerateImageFeaturePrintRequest needs real device hardware
            // (the Neural Engine) — it fails on the iOS Simulator with "Failed to
            // create espresso context", a known Apple platform limitation, not a
            // bug in this code. This has to be tested on a real iPhone.
            let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
            let faceRequest = VNDetectFaceLandmarksRequest()
            let faceQualityRequest = VNDetectFaceCaptureQualityRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([featurePrintRequest, faceRequest, faceQualityRequest])
            } catch {
                failedAssets.append(FailedAsset(asset: asset, reason: "Vision request failed: \(error.localizedDescription)"))
                print("[Clustering] Vision failed for \(asset.localIdentifier): \(error)")
                continue
            }
            guard let featurePrint = featurePrintRequest.results?.first as? VNFeaturePrintObservation else {
                failedAssets.append(FailedAsset(asset: asset, reason: "Vision produced no feature print"))
                continue
            }

            // Faces found: judge them again on a larger copy (see
            // faceDetailImageSize). If that fails for any reason, keep the
            // small-image results rather than dropping the photo.
            var faceResults = faceRequest.results
            var faceQualityResults = faceQualityRequest.results
            if !(faceResults ?? []).isEmpty,
               let detailed = await loadImage(for: asset, targetSize: faceDetailImageSize)?.cgImage {
                let detailFaces = VNDetectFaceLandmarksRequest()
                let detailQuality = VNDetectFaceCaptureQualityRequest()
                if (try? VNImageRequestHandler(cgImage: detailed, options: [:]).perform([detailFaces, detailQuality])) != nil {
                    faceResults = detailFaces.results
                    faceQualityResults = detailQuality.results
                }
            }

            candidates.append(
                ClusterCandidate(
                    asset: asset,
                    featurePrint: featurePrint,
                    sharpness: PhotoQualityScorer.sharpnessScore(for: image),
                    eyesOpenScore: PhotoQualityScorer.eyesOpenScore(from: faceResults),
                    faceQualities: (faceQualityResults ?? []).compactMap { $0.faceCaptureQuality.map(Double.init) },
                    creationDate: asset.creationDate,
                    location: asset.location
                )
            )
        }

        let groups = groupIntoClusters(candidates)

        var duplicateClusters: [PhotoCluster] = []
        var singles: [ClusterCandidate] = []
        for group in groups {
            if group.count > 1 {
                duplicateClusters.append(
                    PhotoCluster(members: group, representative: pickRepresentative(group))
                )
            } else if let only = group.first {
                singles.append(only)
            }
        }
        duplicateClusters.sort {
            ($0.members.first?.creationDate ?? .distantPast) < ($1.members.first?.creationDate ?? .distantPast)
        }

        let nearMisses = findNearMisses(candidates, groups: groups)

        print("[Clustering] \(duplicateClusters.count) duplicate clusters, \(singles.count) singles excluded")
        for (index, cluster) in duplicateClusters.enumerated() {
            print("  Cluster \(index + 1): \(cluster.members.count) photos — representative \(cluster.representative.asset.localIdentifier)")
        }
        print("[Clustering] \(nearMisses.count) near-miss pairs, \(failedAssets.count) photos failed to process")

        return ClusteringResult(
            totalScanned: assets.count,
            duplicateClusters: duplicateClusters,
            singles: singles,
            nearMisses: nearMisses,
            failedAssets: failedAssets
        )
    }

    // MARK: - Near-miss diagnostics (TEMPORARY — for tuning, not shipped behavior)

    /// For every pair of photos taken close together in time that landed in
    /// different clusters, records which gate(s) actually blocked them. Any
    /// pair shown here failed at least one gate — if all three had passed,
    /// union-find would have already merged them.
    private static func findNearMisses(_ candidates: [ClusterCandidate], groups: [[ClusterCandidate]]) -> [NearMissPair] {
        var clusterIndex: [String: Int] = [:]
        for (index, group) in groups.enumerated() {
            for candidate in group {
                clusterIndex[candidate.asset.localIdentifier] = index
            }
        }

        var nearMisses: [NearMissPair] = []
        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                let a = candidates[i], b = candidates[j]
                guard clusterIndex[a.asset.localIdentifier] != clusterIndex[b.asset.localIdentifier] else { continue }
                guard let dateA = a.creationDate, let dateB = b.creationDate else { continue }
                let gap = abs(dateA.timeIntervalSince(dateB))

                var distance: Float = 0
                let distanceComputed = (try? a.featurePrint.computeDistance(&distance, to: b.featurePrint)) != nil
                let passedSimilarity = distanceComputed && distance <= featurePrintDistanceThreshold
                let passedTime = gap <= maxTimeGapSeconds

                var locationMeters: Double?
                var passedLocation = true
                if let locA = a.location, let locB = b.location {
                    let meters = locA.distance(from: locB)
                    locationMeters = meters
                    passedLocation = meters <= maxLocationDistanceMeters
                }

                // The point of this diagnostic is "which pairs were one
                // condition away from clustering" — not every photo pair
                // that happens to exist. A pair failing two or three gates
                // at once (different subject, different time, different
                // place) was never a real candidate; showing it is just
                // noise. Only pairs failing EXACTLY one gate are shown.
                let failedGateCount = [passedSimilarity, passedTime, passedLocation].filter { !$0 }.count
                guard failedGateCount == 1 else { continue }

                nearMisses.append(
                    NearMissPair(
                        a: a,
                        b: b,
                        featurePrintDistance: distanceComputed ? distance : nil,
                        timeGapSeconds: gap,
                        locationDistanceMeters: locationMeters,
                        passedSimilarity: passedSimilarity,
                        passedTime: passedTime,
                        passedLocation: passedLocation
                    )
                )
            }
        }
        return nearMisses.sorted { $0.timeGapSeconds < $1.timeGapSeconds }
    }

    // MARK: - Fetching

    private static func fetchAssets(in interval: DateInterval) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@",
            interval.start as NSDate,
            interval.end as NSDate
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private static func loadImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true // photo may only exist in iCloud
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func dateAt(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components) ?? .distantPast
    }

    // MARK: - Grouping

    /// Connects every pair of photos where Vision + timestamp + location
    /// agree they're "the same moment", then groups by connected
    /// component — so if A matches B and B matches C, all three land in
    /// one cluster even though A and C were never directly compared.
    /// This transitive grouping is itself a judgment call: it's what
    /// makes a burst of 5+ near-identical shots collapse into a single
    /// cluster instead of a chain of separate pairs, matching how people
    /// actually think about "a batch of duplicates."
    private static func groupIntoClusters(_ candidates: [ClusterCandidate]) -> [[ClusterCandidate]] {
        guard candidates.count > 1 else { return candidates.map { [$0] } }

        var parent = Array(0..<candidates.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a), rootB = find(b)
            if rootA != rootB { parent[rootB] = rootA }
        }

        for i in 0..<candidates.count {
            for j in (i + 1)..<candidates.count {
                if isLikelyDuplicate(candidates[i], candidates[j]) {
                    union(i, j)
                }
            }
        }

        var groupsByRoot: [Int: [ClusterCandidate]] = [:]
        for i in 0..<candidates.count {
            groupsByRoot[find(i), default: []].append(candidates[i])
        }
        return Array(groupsByRoot.values)
    }

    /// Three gates, all must agree:
    ///  1. Visually similar (Vision feature-print distance).
    ///  2. Taken close together in time — duplicates are almost always
    ///     burst/near-instant retakes, not the same scene revisited hours
    ///     apart. Skipped if either photo is missing a timestamp.
    ///  3. Not contradicted by location — if both photos have GPS data
    ///     and it places them far apart, that overrides visual similarity
    ///     (guards against two different-but-similar-looking scenes, e.g.
    ///     the same style of building in two different places). Skipped
    ///     if either photo lacks location data (many photos do — no
    ///     separate permission needed for this either way: it's read from
    ///     the same photo metadata already covered by Photos access).
    // KNOWN LIMITATION (accepted for v1, not being fixed right now): two
    // photos of the same subject/moment where one is portrait and the other
    // landscape will generally NOT match here. Rotating the phone changes
    // the actual framing enough that Vision's feature print treats them as
    // meaningfully different images, not merely a blurrier/sharper version
    // of the same shot. Catching this properly would mean comparing against
    // rotated copies of each photo — real added complexity that isn't worth
    // it yet; confirmed against real test results and decided to live with
    // it for now rather than build for it.
    //
    // KNOWN LIMITATION #2 (also accepted for v1): two photos with the same
    // background/composition where the actual content changed — most
    // commonly a person walking into or out of frame between shots — will
    // generally NOT match either. Unlike a reframe/zoom, this isn't Vision
    // being oversensitive: the image genuinely is more different, since a
    // meaningful part of it now shows something that wasn't there before.
    // No threshold adjustment fixes this without also risking merges of
    // photos that just happen to share a backdrop but aren't duplicates at
    // all — confirmed against real test results and decided to live with
    // it rather than chase it with thresholds.
    private static func isLikelyDuplicate(_ a: ClusterCandidate, _ b: ClusterCandidate) -> Bool {
        var distance: Float = 0
        do {
            try a.featurePrint.computeDistance(&distance, to: b.featurePrint)
        } catch {
            return false
        }
        guard distance <= featurePrintDistanceThreshold else { return false }

        if let dateA = a.creationDate, let dateB = b.creationDate {
            guard abs(dateA.timeIntervalSince(dateB)) <= maxTimeGapSeconds else { return false }
        }

        if let locA = a.location, let locB = b.location {
            guard locA.distance(from: locB) <= maxLocationDistanceMeters else { return false }
        }

        return true
    }

    // MARK: - Representative selection

    /// Step by step, not a blended score — easier to explain and check by
    /// eye than an arbitrary blend of unrelated numbers:
    ///
    /// 1. Rule out photos where anyone's eyes are clearly closed (unless
    ///    that would rule out the whole set — a flawed photo beats no
    ///    candidate at all).
    /// 2. **Sets with people:** pick the best combined face capture quality.
    ///    That's Apple's own on-device score, made for choosing the best of
    ///    several shots of the same people — it weighs pose (facing the
    ///    camera), expression, focus and lighting. Sharpness alone picked a
    ///    sharp but awkward mid-movement shot of a couple sliding off a rock
    ///    over the ones of them sitting and smiling at the camera. Each
    ///    photo's face scores are summed and divided by the most faces any
    ///    photo in the set has, so a face that's missing in one photo
    ///    (someone turned away) counts as zero there rather than being
    ///    quietly skipped. Sharpness only breaks ties.
    /// 3. **Sets without people:** the sharpest photo.
    private static func pickRepresentative(_ members: [ClusterCandidate]) -> ClusterCandidate {
        let eyesOpenEnough = members.filter { ($0.eyesOpenScore ?? 1.0) >= closedEyeThreshold }
        let pool = eyesOpenEnough.isEmpty ? members : eyesOpenEnough

        let mostFaces = members.map(\.faceQualities.count).max() ?? 0
        if mostFaces > 0 {
            func faceScore(_ c: ClusterCandidate) -> Double { c.faceQualities.reduce(0, +) / Double(mostFaces) }
            return pool.max {
                (faceScore($0), $0.sharpness) < (faceScore($1), $1.sharpness)
            } ?? members[0]
        }
        return pool.max { $0.sharpness < $1.sharpness } ?? members[0]
    }
}
