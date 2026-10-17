//
//  ReviewView.swift
//  Camera Roll Cleaner
//
//  Going through duplicate sets one at a time and marking what to keep.
//  In each set the top pick starts as Keep and every other photo as Delete
//  (trimming duplicates is the point of the app); tapping a photo switches
//  it. A running total shows how many photos are marked and roughly how
//  much space they take up.
//
//  Deleting can happen at any point — the user may only have time for a
//  few sets — so only sets they've actually looked at count. Sets not yet
//  opened are never included, even though their extra shots are pre-marked.
//  Skip leaves a looked-at set out.
//
//  STEP 1 OF 2: this file contains no delete code. The Delete button is
//  shown but not wired up yet; that's the next step.
//

import Combine
import Photos
import SwiftUI

/// What's marked across all sets in one scan. Lives as long as the scan's
/// results in the chat, so closing and reopening the review keeps choices.
@MainActor
final class ReviewSession: ObservableObject {
    let sets: [PhotoCluster]

    /// Sets the user has looked at (and not skipped) — the only ones whose
    /// marks count.
    @Published private(set) var lookedAt: Set<UUID> = []
    @Published private(set) var skipped: Set<UUID> = []
    /// Photos the user switched away from the default (asset id → keep?).
    @Published private var choices: [String: Bool] = [:]

    private var sizeCache: [String: Int64] = [:]

    init(sets: [PhotoCluster]) {
        self.sets = sets
    }

    func isKept(_ asset: PHAsset, in set: PhotoCluster) -> Bool {
        choices[asset.localIdentifier] ?? (asset.localIdentifier == set.representative.asset.localIdentifier)
    }

    func toggle(_ asset: PHAsset, in set: PhotoCluster) {
        choices[asset.localIdentifier] = !isKept(asset, in: set)
        include(set) // changing something in a set clearly means it's been looked at
    }

    func include(_ set: PhotoCluster) {
        lookedAt.insert(set.id)
        skipped.remove(set.id)
    }

    func skip(_ set: PhotoCluster) {
        lookedAt.remove(set.id)
        skipped.insert(set.id)
    }

    func isSkipped(_ set: PhotoCluster) -> Bool { skipped.contains(set.id) }

    /// Every photo marked Delete in sets the user has looked at.
    var markedForDeletion: [PHAsset] {
        sets.filter { lookedAt.contains($0.id) }
            .flatMap { set in set.members.map(\.asset).filter { !isKept($0, in: set) } }
    }

    func markedCount(in set: PhotoCluster) -> Int {
        set.members.filter { !isKept($0.asset, in: set) }.count
    }

    /// Roughly how much storage the marked photos use, including the
    /// video half of Live Photos and any saved edits.
    var markedBytes: Int64 {
        markedForDeletion.reduce(0) { $0 + bytes(for: $1) }
    }

    /// Same, for one set only.
    func markedBytes(in set: PhotoCluster) -> Int64 {
        set.members.map(\.asset).filter { !isKept($0, in: set) }.reduce(0) { $0 + bytes(for: $1) }
    }

    /// JUDGMENT CALL: Apple has no documented way to read a photo's file
    /// size. This reads the "fileSize" value Photos keeps on each of a
    /// photo's underlying files — widely used and reliable, but not
    /// officially documented, so App Store review could in principle flag
    /// it. If it's ever unavailable, the photo counts as 0 bytes rather than
    /// crashing; a fallback would be an estimate from pixel dimensions.
    private func bytes(for asset: PHAsset) -> Int64 {
        if let cached = sizeCache[asset.localIdentifier] { return cached }
        let total = PHAssetResource.assetResources(for: asset).reduce(Int64(0)) { sum, resource in
            sum + ((resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0)
        }
        sizeCache[asset.localIdentifier] = total
        return total
    }
}

struct ReviewView: View {
    @ObservedObject var session: ReviewSession
    @State var index: Int
    let onClose: () -> Void

    @State private var viewerStart: ViewerStart?
    @Environment(\.displayScale) private var displayScale

    private struct ViewerStart: Identifiable, Hashable {
        let index: Int
        var id: Int { index }
    }

    private var set: PhotoCluster { session.sets[index] }

    /// Top pick first, then the rest in the order they were taken.
    private var photos: [PHAsset] {
        let pick = set.representative.asset
        return [pick] + set.members.map(\.asset).filter { $0.localIdentifier != pick.localIdentifier }
    }

    var body: some View {
        NavigationStack {
            grid
                .navigationTitle("Set \(index + 1) of \(session.sets.count)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: onClose)
                    }
                }
                .safeAreaInset(edge: .bottom) { bottomBar }
                .navigationDestination(item: $viewerStart) { start in
                    AssetDetailView(
                        assets: photos,
                        selectedIndex: start.index,
                        topPickID: set.representative.asset.localIdentifier,
                        accessory: { asset in AnyView(ReviewToggle(session: session, set: set, asset: asset)) }
                    )
                }
        }
        // Opening a set counts as looking at it (unless it was skipped).
        .onAppear { includeUnlessSkipped() }
        .onChange(of: index) { _, _ in includeUnlessSkipped() }
    }

    private func includeUnlessSkipped() {
        if !session.isSkipped(set) { session.include(set) }
    }

    // MARK: Photos

    private var grid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let side = (geometry.size.width - spacing * 2) / 3
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.isSkipped(set)
                         ? "Skipped — nothing in this set will be deleted."
                         : "Tap a photo to keep or delete it. Tap ⤢ to see it full size.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: spacing), count: 3), spacing: spacing) {
                        ForEach(Array(photos.enumerated()), id: \.element.localIdentifier) { offset, asset in
                            cell(asset, offset: offset, side: side)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ asset: PHAsset, offset: Int, side: CGFloat) -> some View {
        let kept = session.isKept(asset, in: set)
        let dimmed = !kept && !session.isSkipped(set)
        return PhotoThumbnailView(asset: asset, targetSize: CGSize(width: side * displayScale, height: side * displayScale))
            .frame(width: side, height: side)
            .clipped()
            .overlay { if dimmed { Color.black.opacity(0.45) } }
            .overlay(alignment: .topLeading) {
                if asset.localIdentifier == set.representative.asset.localIdentifier {
                    Image(systemName: "star.fill")
                        .font(.caption.bold())
                        .padding(5)
                        .background(.yellow, in: Circle())
                        .foregroundStyle(.black)
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Label(kept ? "Keep" : "Delete", systemImage: kept ? "checkmark.circle.fill" : "trash.fill")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(kept ? Color.green : Color.red, in: Capsule())
                    .foregroundStyle(.white)
                    .padding(5)
                    .opacity(session.isSkipped(set) ? 0.4 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    viewerStart = ViewerStart(index: offset)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold())
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(5)
                .accessibilityLabel("See full size")
            }
            .contentShape(Rectangle())
            .onTapGesture { session.toggle(asset, in: set) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(kept ? "Photo, keep" : "Photo, delete")
            .accessibilityHint("Double-tap to switch between keep and delete")
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Back", systemImage: "chevron.left") { index -= 1 }
                    .disabled(index == 0)
                Spacer()
                Button(session.isSkipped(set) ? "Include" : "Skip") {
                    if session.isSkipped(set) {
                        session.include(set)
                    } else {
                        session.skip(set)
                        if index < session.sets.count - 1 { index += 1 }
                    }
                }
                Spacer()
                if index < session.sets.count - 1 {
                    Button("Next", systemImage: "chevron.right") { index += 1 }
                        .labelStyle(TrailingIconLabelStyle())
                } else {
                    Button("Done", action: onClose)
                }
            }
            .buttonStyle(.bordered)

            Divider()

            // This set first — that's what's on screen. The total across
            // every set looked at so far comes second, smaller: shown alone
            // it read as a mistake (24 marked in a set of 22).
            let count = session.markedForDeletion.count
            let inSet = session.markedCount(in: set)
            VStack(spacing: 4) {
                Text(session.isSkipped(set)
                     ? "This set: skipped"
                     : "This set: \(inSet) of \(set.members.count) photos marked for deletion · about \(size(session.markedBytes(in: set)))")
                    .font(.subheadline.bold())
                Text(count == 0
                     ? "Nothing marked for deletion yet in the sets you've looked at."
                     : "All sets you've looked at: \(count) photo\(count == 1 ? "" : "s") marked for deletion · about \(size(session.markedBytes))")
                    .font(.footnote)
                Text("Deleted photos stay in Recently Deleted for 30 days before the space is freed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // All three lines centered, so wrapped lines line up.
            .multilineTextAlignment(.center)

            // Step 2 wires this up to iOS's own delete confirmation.
            Button {
            } label: {
                Text(count == 0 ? "Delete" : "Delete \(count) photo\(count == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(true)
            Text("Deleting is coming in the next step.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.bar)
    }
}

private func size(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// Keep / Delete button shown under a full-size photo in review.
private struct ReviewToggle: View {
    @ObservedObject var session: ReviewSession
    let set: PhotoCluster
    let asset: PHAsset

    var body: some View {
        let kept = session.isKept(asset, in: set)
        Button {
            session.toggle(asset, in: set)
        } label: {
            Label(kept ? "Keep — tap to delete" : "Delete — tap to keep",
                  systemImage: kept ? "checkmark.circle.fill" : "trash.fill")
                .font(.subheadline.bold())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(kept ? Color.green : Color.red, in: Capsule())
                .foregroundStyle(.white)
        }
    }
}

/// "Next ›" with the arrow after the text.
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}
