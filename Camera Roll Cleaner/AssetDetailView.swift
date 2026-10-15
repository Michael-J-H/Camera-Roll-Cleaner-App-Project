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
                ZoomableImageView(image: image)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
    }
}

/// Pinch to zoom, drag around while zoomed, double-tap to zoom in or back
/// out — like the Photos app. Built on UIKit's scroll view rather than
/// SwiftUI gestures because it already handles zooming smoothly and, while
/// the photo isn't zoomed, lets sideways swipes through to the page view
/// so swiping between photos keeps working.
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomingScrollView {
        let view = ZoomingScrollView()
        view.imageView.image = image
        return view
    }

    func updateUIView(_ view: ZoomingScrollView, context: Context) {
        if view.imageView.image !== image {
            view.imageView.image = image
            view.setZoomScale(1, animated: false)
        }
    }
}

private final class ZoomingScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // At normal size the photo fills the screen (fitted, like before).
        if zoomScale == minimumZoomScale {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            // Zoom in around the spot that was tapped.
            let point = gesture.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        }
    }
}

/// Full-screen, swipeable view over a list of assets, starting at whichever
/// one was tapped. Reused for both cluster detail and the unmatched-photos
/// folder — anywhere AssetGridView is used.
struct AssetDetailView: View {
    let assets: [PHAsset]
    @State var selectedIndex: Int
    /// The duplicate set's current top pick, if any — shown with a ★ badge
    /// while it's the photo on screen.
    var topPickID: String? = nil

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
        // On the viewer, not on each page: pages get recreated as you swipe
        // (see FullResolutionImageView), the viewer doesn't.
        .overlay(alignment: .top) {
            if assets.indices.contains(selectedIndex), assets[selectedIndex].localIdentifier == topPickID {
                Label("Top pick", systemImage: "star.fill")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.yellow, in: Capsule())
                    .foregroundStyle(.black)
                    .padding(.top, 8)
            }
        }
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
