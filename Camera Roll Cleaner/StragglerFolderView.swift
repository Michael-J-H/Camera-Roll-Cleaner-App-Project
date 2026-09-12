//
//  StragglerFolderView.swift
//  Camera Roll Cleaner
//
//  Shows every photo that didn't get placed in a cluster. Internally these
//  are called "stragglers" (matching PhotoClusterEngine's `singles`), but
//  always labeled "Unmatched Photos" to the user. Per the decision to stop
//  fine-tuning clustering thresholds for now: rather than chase every last
//  edge case, unmatched photos get their own browsable folder instead.
//

import Photos
import SwiftUI

/// A scrollable grid of thumbnails for a specific, already-known list of
/// assets — distinct from the app's PhotoGridView (the top-level Camera
/// Roll screen, which owns its own permission handling and fetches the
/// whole library itself). This one just renders whatever list it's given.
struct AssetGridView: View {
    let assets: [PHAsset]
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        // Same fix as the main Camera Roll grid (PhotoGridView): lock every
        // cell to an identical square size computed from screen width,
        // rather than letting aspectRatio(_, .fit) size each cell from its
        // own photo — that let portrait/landscape/mixed photos each come
        // out a slightly different size, which showed up as misaligned rows.
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let cellSide = (geometry.size.width - spacing * 2) / 3

            ScrollView {
                LazyVGrid(columns: columns, spacing: spacing) {
                    ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { index, asset in
                        NavigationLink {
                            AssetDetailView(assets: assets, selectedIndex: index)
                        } label: {
                            PhotoThumbnailView(asset: asset, targetSize: CGSize(width: cellSide, height: cellSide))
                                .frame(width: cellSide, height: cellSide)
                                .clipped()
                        }
                        .buttonStyle(.plain) // otherwise NavigationLink tints the thumbnail blue
                    }
                }
            }
        }
        .navigationTitle("\(assets.count) photo\(assets.count == 1 ? "" : "s")")
    }
}

/// Shows every unmatched photo so the user can browse and decide what to do
/// with them manually, instead of the app forcing them into a cluster.
struct StragglerFolderView: View {
    let stragglerAssets: [PHAsset]

    var body: some View {
        Group {
            if stragglerAssets.isEmpty {
                ContentUnavailableView(
                    "No Unmatched Photos",
                    systemImage: "checkmark.circle",
                    description: Text("Every photo in this range matched a cluster.")
                )
            } else {
                AssetGridView(assets: stragglerAssets)
            }
        }
        .navigationTitle("Unmatched Photos")
    }
}
