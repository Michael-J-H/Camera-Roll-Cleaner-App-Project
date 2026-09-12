//
//  AssetDetailView.swift
//  Camera Roll Cleaner
//
//  Full-screen, swipeable photo viewer — reused wherever a grid of assets
//  (a cluster, or the unmatched-photos folder) needs "tap a thumbnail to
//  actually see the photo" instead of just a small square preview.
//

import Photos
import SwiftUI

/// Same target size and request options for every full-resolution request.
private func fullResolutionTargetSize() -> CGSize {
    let scale = UIScreen.main.scale
    let bounds = UIScreen.main.bounds
    return CGSize(width: bounds.width * scale, height: bounds.height * scale)
}

private func fullResolutionRequestOptions() -> PHImageRequestOptions {
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    return options
}

/// Purely a renderer — no loading logic of its own. Earlier this view owned
/// its own @State and fetched its own image via .task, but SwiftUI's paged
/// TabView creates and destroys individual page views as you swipe away
/// from and back toward them, which reset that per-page @State to nil each
/// time regardless of how "warm" the underlying photo cache already was.
/// That's what caused the hang on a light/slow swipe (enough time to see
/// the placeholder) but not an aggressive one (swipes past it too fast to
/// notice) — the image genuinely had to be re-populated into that
/// freshly-recreated page's own state. Moving the loaded image up to
/// AssetDetailView (which never gets torn down while the viewer is open)
/// fixes this: this view just displays whatever it's handed.
private struct FullResolutionImageView: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

/// Full-screen, swipeable view over a list of assets, starting at whichever
/// one was tapped. Reused for both cluster detail and the unmatched-photos
/// folder — anywhere AssetGridView is used.
struct AssetDetailView: View {
    let assets: [PHAsset]
    @State var selectedIndex: Int

    @State private var imageCache = PHCachingImageManager()
    // Keyed by asset id rather than index, and owned here rather than by
    // each page — this is what actually survives SwiftUI recreating
    // individual TabView pages as you swipe around. A page just looks
    // itself up here; it doesn't fetch anything on its own.
    @State private var loadedImages: [String: UIImage] = [:]
    // Which indices currently have a load in flight or complete, so a
    // swipe only starts/stops the photos that actually enter or leave the
    // window — leaving anything already cached or mid-fetch alone.
    @State private var trackedIndices: Set<Int> = []

    // Below this size, just warm the entire cluster up front instead of a
    // sliding window — simpler, and removes any chance of a hang entirely
    // for the cluster sizes we actually see today (biggest so far: 22).
    // Not raised further without good reason: holding every photo in a
    // cluster in memory at once doesn't scale to a hypothetical much
    // larger cluster later (e.g. once clustering runs against the whole
    // library instead of a 9-day test range) — a burst of iCloud downloads
    // or a memory spike would be a worse outcome than an occasional hang.
    private static let eagerLoadCountCap = 40

    private var shouldEagerLoadWholeCluster: Bool {
        assets.count <= Self.eagerLoadCountCap
    }

    var body: some View {
        TabView(selection: $selectedIndex) {
            ForEach(Array(assets.enumerated()), id: \.offset) { index, asset in
                FullResolutionImageView(image: loadedImages[asset.localIdentifier])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .background(Color.black)
        .navigationTitle("\(selectedIndex + 1) of \(assets.count)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if shouldEagerLoadWholeCluster {
                loadAll(assets)
            } else {
                updateWindow(around: selectedIndex)
            }
        }
        .onChange(of: selectedIndex) { _, newIndex in
            // Nothing to do if we already loaded everything on appear —
            // this only matters for the sliding-window (large cluster) path.
            guard !shouldEagerLoadWholeCluster else { return }
            updateWindow(around: newIndex)
        }
        .onDisappear {
            imageCache.stopCachingImagesForAllAssets()
        }
    }

    private func loadAll(_ assetsToLoad: [PHAsset]) {
        trackedIndices = Set(assets.indices)
        for asset in assetsToLoad {
            loadImage(asset)
        }
    }

    // Apple's own Photos app prefetches neighboring photos so a swipe never
    // has to wait on a cold fetch — without this, each page only starts
    // loading once you've actually swiped to it. Only the indices that
    // actually enter or leave the window are started/stopped, so photos
    // already loaded or mid-fetch aren't disturbed by a one-step swipe.
    private func updateWindow(around index: Int) {
        let windowRadius = 2
        let lowerBound = max(0, index - windowRadius)
        let upperBound = min(assets.count - 1, index + windowRadius)
        let newIndices = Set(lowerBound...upperBound)

        let indicesToDrop = trackedIndices.subtracting(newIndices)
        let indicesToLoad = newIndices.subtracting(trackedIndices)

        if !indicesToDrop.isEmpty {
            let assetsToDrop = indicesToDrop.map { assets[$0] }
            imageCache.stopCachingImages(
                for: assetsToDrop,
                targetSize: fullResolutionTargetSize(),
                contentMode: .aspectFit,
                options: fullResolutionRequestOptions()
            )
            for asset in assetsToDrop {
                loadedImages.removeValue(forKey: asset.localIdentifier)
            }
        }
        for index in indicesToLoad {
            loadImage(assets[index])
        }

        trackedIndices = newIndices
    }

    private func loadImage(_ asset: PHAsset) {
        guard loadedImages[asset.localIdentifier] == nil else { return }
        Task {
            let image = await withCheckedContinuation { continuation in
                imageCache.requestImage(
                    for: asset,
                    targetSize: fullResolutionTargetSize(),
                    contentMode: .aspectFit,
                    options: fullResolutionRequestOptions()
                ) { image, _ in
                    continuation.resume(returning: image)
                }
            }
            if let image {
                loadedImages[asset.localIdentifier] = image
            }
        }
    }
}
