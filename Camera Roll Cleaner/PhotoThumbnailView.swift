//
//  PhotoThumbnailView.swift
//  Camera Roll Cleaner
//
//  Loads and displays a single thumbnail image for a photo library asset.
//

import Photos
import SwiftUI

struct PhotoThumbnailView: View {
    let asset: PHAsset
    let targetSize: CGSize

    @State private var image: UIImage?

    // Shared across all thumbnails so Photos can cache and reuse decoded images.
    private static let imageManager = PHCachingImageManager()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
            }
        }
        .task(id: asset.localIdentifier) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true // needed for photos stored only in iCloud
        options.deliveryMode = .highQualityFormat // one callback per request, not several

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            Self.imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
        image = result
    }
}
