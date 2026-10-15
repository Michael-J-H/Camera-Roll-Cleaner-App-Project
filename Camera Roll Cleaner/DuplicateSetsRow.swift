//
//  DuplicateSetsRow.swift
//  Camera Roll Cleaner
//
//  The scan results shown right in the chat: one photo per duplicate set,
//  in a sideways-scrolling row, so the user can check at a glance that the
//  scan found the right trip. Tapping a photo opens every shot in that set
//  as a sheet over the chat (the brief's "pop-out grid").
//
//  Why a sheet rather than pushing a new screen: the row lives inside the
//  chat's scrolling message list, which only keeps on-screen messages in
//  memory. A navigation link in there left the chat frozen after coming
//  back on device. A sheet never navigates the chat away, so there's
//  nothing to come back to.
//
//  Per PROJECT_BRIEF.md: the photo shown for each set is its sharpest,
//  eyes-open shot (picked during the scan — `PhotoCluster.representative`),
//  and photos with no duplicates aren't shown at all. Choosing what to keep
//  is a later, separate step.
//

import SwiftUI

struct DuplicateSetsRow: View {
    let result: ClusteringResult

    private let side: CGFloat = 96
    @Environment(\.displayScale) private var displayScale
    @State private var openSet: PhotoCluster?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary)
                .font(.subheadline.bold())

            // Lazy: only the thumbnails on (or near) screen are loaded, so a
            // scan with hundreds of sets costs about the same as one with ten.
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(result.duplicateClusters.enumerated()), id: \.element.id) { index, cluster in
                        Button {
                            openSet = cluster
                        } label: {
                            thumbnail(for: cluster)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Set \(index + 1), \(cluster.members.count) photos")
                    }
                }
            }

            Text("Tap a photo to see every shot in that set.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: $openSet) { cluster in
            NavigationStack {
                AssetGridView(assets: cluster.members.map { $0.asset })
                    .navigationTitle(title(for: cluster))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // Same ✕ as the calendar sheet, so closing looks the same everywhere.
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { openSet = nil }
                        }
                    }
            }
        }
    }

    private func title(for cluster: PhotoCluster) -> String {
        let number = (result.duplicateClusters.firstIndex { $0.id == cluster.id } ?? 0) + 1
        return "Set \(number) of \(setCount) · \(cluster.members.count) photos"
    }

    private func thumbnail(for cluster: PhotoCluster) -> some View {
        // Thumbnails are requested in pixels, so scale up from on-screen
        // points to keep them sharp on the phone's high-resolution display.
        PhotoThumbnailView(asset: cluster.representative.asset,
                           targetSize: CGSize(width: side * displayScale, height: side * displayScale))
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                Text("\(cluster.members.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(5)
            }
    }

    private var setCount: Int { result.duplicateClusters.count }

    private var summary: String {
        let photos = result.duplicateClusters.reduce(0) { $0 + $1.members.count }
        return "\(setCount) duplicate set\(setCount == 1 ? "" : "s") · \(photos) photos"
    }
}
