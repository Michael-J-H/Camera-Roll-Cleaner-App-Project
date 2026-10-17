//
//  DuplicateSetsRow.swift
//  Camera Roll Cleaner
//
//  The scan results shown right in the chat: one photo per duplicate set,
//  in a sideways-scrolling row, so the user can check at a glance that the
//  scan found the right trip. Tapping a photo — or "Review sets" — opens the
//  review (ReviewView) as a sheet over the chat, at that set, where photos
//  are marked Keep or Delete.
//
//  Why a sheet rather than pushing a new screen: the row lives inside the
//  chat's scrolling message list, which only keeps on-screen messages in
//  memory. A navigation link in there left the chat frozen after coming
//  back on device. A sheet never navigates the chat away, so there's
//  nothing to come back to.
//
//  The photo shown for each set is its current top pick — today the
//  sharpest, eyes-open shot, picked on the phone during the scan
//  (`PhotoCluster.representative`); later possibly re-picked by Claude to
//  match the user's taste (see the brief's Decision Log). In the set's
//  review it comes first with a ★ and starts as Keep. Photos with no
//  duplicates aren't shown at all.
//

import Photos
import SwiftUI

struct DuplicateSetsRow: View {
    let result: ClusteringResult

    private let side: CGFloat = 96
    @Environment(\.displayScale) private var displayScale
    /// Keep/Delete choices for this scan — kept here so closing and
    /// reopening the review doesn't lose them.
    @StateObject private var review: ReviewSession
    @State private var openAt: ReviewStart?

    private struct ReviewStart: Identifiable {
        let index: Int
        var id: Int { index }
    }

    init(result: ClusteringResult) {
        self.result = result
        _review = StateObject(wrappedValue: ReviewSession(sets: result.duplicateClusters))
    }

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
                            openAt = ReviewStart(index: index)
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

            Button {
                openAt = ReviewStart(index: 0)
            } label: {
                Label("Review sets", systemImage: "checkmark.rectangle.stack")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .sheet(item: $openAt) { start in
            ReviewView(session: review, index: start.index) { openAt = nil }
        }
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
