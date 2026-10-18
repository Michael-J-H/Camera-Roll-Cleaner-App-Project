//
//  ReviewView.swift
//  Camera Roll Cleaner
//
//  Going through duplicate sets one at a time, choosing what to keep, and
//  deleting the rest. In each set the top pick starts as Keep and every
//  other photo as Delete (trimming duplicates is the point of the app);
//  tapping a photo switches it.
//
//  Delete only ever affects the set on screen. Deleting everything marked
//  across many sets at once was considered and rejected: it's hard to
//  remember what was marked in sets you're no longer looking at, and users
//  may only have time for a few sets anyway. Next simply leaves a set as it
//  is.
//
//  Deleting goes through iOS's own confirmation dialog — the app can't
//  skip or fake it — and deleted photos go to the Photos app's Recently
//  Deleted album for 30 days, where they can still be recovered.
//

import Combine
import Photos
import SwiftUI

/// Keep/Delete choices and what's been deleted, for one scan. Lives as long
/// as the scan's results in the chat, so closing and reopening the review
/// keeps everything.
@MainActor
final class ReviewSession: ObservableObject {
    let sets: [PhotoCluster]

    /// Photos the user switched away from the default (asset id → keep?).
    @Published private var choices: [String: Bool] = [:]
    /// Photos already deleted — no longer shown anywhere in the review.
    @Published private(set) var deletedIDs: Set<String> = []
    @Published private(set) var deletedBytes: Int64 = 0

    private var sizeCache: [String: Int64] = [:]

    init(sets: [PhotoCluster]) {
        self.sets = sets
    }

    /// Sets that still have photos. A set whose photos were all deleted
    /// drops out of the review and the chat's row.
    var visibleSets: [PhotoCluster] {
        sets.filter { !photos(in: $0).isEmpty }
    }

    /// Sets the user has marked as done. Only the user marks a set done —
    /// the app never infers it: someone partway through a big set (some
    /// deleted, some still to decide) would otherwise see it marked done
    /// before they'd finished.
    @Published private var doneIDs: Set<UUID> = []

    func isDone(_ set: PhotoCluster) -> Bool { doneIDs.contains(set.id) }

    func setDone(_ set: PhotoCluster, _ done: Bool) {
        if done { doneIDs.insert(set.id) } else { doneIDs.remove(set.id) }
    }

    /// When "Mark as done" is worth nudging: something's been deleted and
    /// nothing left is marked for deletion. A hint only — never applied
    /// automatically.
    func looksFinished(_ set: PhotoCluster) -> Bool {
        deletedCount(in: set) > 0 && marked(in: set).isEmpty
    }

    /// The set's current top pick: the best-ranked photo not yet deleted.
    /// If the top pick is deleted, the ★ moves to the next best. It moves
    /// only on an actual delete — not while photos are merely marked — so
    /// it doesn't jump around while the user is still deciding.
    func topPick(in set: PhotoCluster) -> PHAsset? {
        set.ranked.map(\.asset).first { !deletedIDs.contains($0.localIdentifier) }
    }

    /// The set's photos still in the library: top pick first, then the rest
    /// in the order they were taken.
    func photos(in set: PhotoCluster) -> [PHAsset] {
        guard let pick = topPick(in: set) else { return [] }
        let rest = set.members.map(\.asset).filter {
            $0.localIdentifier != pick.localIdentifier && !deletedIDs.contains($0.localIdentifier)
        }
        return [pick] + rest
    }

    /// The current top pick starts as Keep, everything else as Delete,
    /// unless the user switched it.
    func isKept(_ asset: PHAsset, in set: PhotoCluster) -> Bool {
        choices[asset.localIdentifier] ?? (asset.localIdentifier == topPick(in: set)?.localIdentifier)
    }

    func toggle(_ asset: PHAsset, in set: PhotoCluster) {
        choices[asset.localIdentifier] = !isKept(asset, in: set)
    }

    func marked(in set: PhotoCluster) -> [PHAsset] {
        photos(in: set).filter { !isKept($0, in: set) }
    }

    func markedBytes(in set: PhotoCluster) -> Int64 {
        marked(in: set).reduce(0) { $0 + bytes(for: $1) }
    }

    func deletedCount(in set: PhotoCluster) -> Int {
        set.members.filter { deletedIDs.contains($0.asset.localIdentifier) }.count
    }

    /// Asks iOS to delete this set's marked photos. iOS shows its own
    /// confirmation; if the user cancels there, nothing changes. Returns
    /// a message to show if something went wrong, nil otherwise.
    func deleteMarked(in set: PhotoCluster) async -> String? {
        let assets = marked(in: set)
        guard !assets.isEmpty else { return nil }
        let bytes = assets.reduce(Int64(0)) { $0 + self.bytes(for: $1) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            deletedIDs.formUnion(assets.map(\.localIdentifier))
            deletedBytes += bytes
            return nil
        } catch let error as PHPhotosError where error.code == .userCancelled {
            return nil // they tapped Don't Allow in iOS's dialog — fine, nothing happens
        } catch {
            return "Couldn't delete those photos: \(error.localizedDescription)"
        }
    }

    /// JUDGMENT CALL: Apple has no documented way to read a photo's file
    /// size. This reads the "fileSize" value Photos keeps on each of a
    /// photo's underlying files (including the video half of a Live Photo
    /// and any saved edits) — widely used and reliable, but not officially
    /// documented, so App Store review could in principle flag it. If it's
    /// ever unavailable, the photo counts as 0 bytes rather than crashing; a
    /// fallback would be an estimate from pixel dimensions.
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
    @State private var isDeleting = false
    @State private var confirmingDeleteAll = false
    @State private var errorMessage: String?
    #if DEBUG
    @State private var askingAI = false
    #endif
    @Environment(\.displayScale) private var displayScale

    private struct ViewerStart: Identifiable, Hashable {
        let index: Int
        var id: Int { index }
    }

    // Index into the sets that still have photos, so a set emptied by a
    // delete drops out and the next one moves into its place.
    private var sets: [PhotoCluster] { session.visibleSets }
    private var set: PhotoCluster { sets[min(index, sets.count - 1)] }
    private var photos: [PHAsset] { session.photos(in: set) }

    var body: some View {
        if sets.isEmpty {
            // Every set emptied — nothing left to review.
            Color.clear.onAppear(perform: onClose)
        } else {
            review
        }
    }

    private var review: some View {
        NavigationStack {
            grid
                .navigationTitle("Set \(min(index, sets.count - 1) + 1) of \(sets.count)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: onClose)
                    }
                    #if DEBUG
                    // Developer test tool only — see AskAIDebugView.swift.
                    // Not in Release (TestFlight / App Store) builds.
                    ToolbarItem(placement: .primaryAction) {
                        Button("Ask AI", systemImage: "sparkles") { askingAI = true }
                    }
                    #endif
                }
                #if DEBUG
                .sheet(isPresented: $askingAI) {
                    AskAIDebugView(
                        rankedPhotos: set.ranked.map(\.asset).filter { !session.deletedIDs.contains($0.localIdentifier) },
                        blinkChecks: Dictionary(uniqueKeysWithValues: set.ranked.compactMap { c in
                            c.blinkCheck.map { (c.asset.localIdentifier, $0) }
                        }),
                        hasPeople: set.ranked.contains { !$0.faceQualities.isEmpty }
                    )
                }
                #endif
                .safeAreaInset(edge: .bottom) { bottomBar }
                .navigationDestination(item: $viewerStart) { start in
                    AssetDetailView(
                        assets: photos,
                        selectedIndex: start.index,
                        topPickID: session.topPick(in: set)?.localIdentifier,
                        accessory: { asset in AnyView(ReviewToggle(session: session, set: set, asset: asset)) }
                    )
                }
                .alert("Something went wrong", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }

    // MARK: Photos

    private var grid: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2
            let side = (geometry.size.width - spacing * 2) / 3
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(headline)
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

    private var headline: String {
        let deleted = session.deletedCount(in: set)
        if deleted > 0 {
            return "Deleted \(deleted) photo\(deleted == 1 ? "" : "s") from this set. Tap a photo to keep or delete it."
        }
        return "Tap a photo to keep or delete it. Tap ⤢ to see it full size."
    }

    private func cell(_ asset: PHAsset, offset: Int, side: CGFloat) -> some View {
        let kept = session.isKept(asset, in: set)
        return PhotoThumbnailView(asset: asset, targetSize: CGSize(width: side * displayScale, height: side * displayScale))
            .frame(width: side, height: side)
            .clipped()
            .overlay { if !kept { Color.black.opacity(0.45) } }
            .overlay(alignment: .topLeading) {
                if asset.localIdentifier == session.topPick(in: set)?.localIdentifier {
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

    /// The user — not the app — marks a set done. Marking it moves on to
    /// the next set; tapping again on a done set undoes it.
    @ViewBuilder
    private var doneButton: some View {
        if session.isDone(set) {
            Button("✓ Done · Undo") { session.setDone(set, false) }
                .tint(.green)
        } else {
            let mark = Button("Mark as done") {
                session.setDone(set, true)
                if min(index, sets.count - 1) < sets.count - 1 { index = min(index, sets.count - 1) + 1 }
            }
            if session.looksFinished(set) {
                mark.buttonStyle(.borderedProminent)
            } else {
                mark
            }
        }
    }

    private var bottomBar: some View {
        let marked = session.marked(in: set).count
        return VStack(spacing: 10) {
            HStack {
                Button("Back", systemImage: "chevron.left") { index = min(index, sets.count - 1) - 1 }
                    .disabled(min(index, sets.count - 1) == 0)
                Spacer()
                doneButton
                Spacer()
                if min(index, sets.count - 1) < sets.count - 1 {
                    Button("Next", systemImage: "chevron.right") { index = min(index, sets.count - 1) + 1 }
                        .labelStyle(TrailingIconLabelStyle())
                } else {
                    // "Finish", not "Done": "done" only ever means a set is finished.
                    Button("Finish", action: onClose)
                }
            }
            .buttonStyle(.bordered)

            Divider()

            VStack(spacing: 4) {
                Text(marked == 0
                     ? "This set: nothing marked for deletion"
                     : "This set: \(marked) of \(photos.count) photos marked for deletion · about \(size(session.markedBytes(in: set)))")
                    .font(.subheadline.bold())
                if marked > 0 && marked == photos.count {
                    Text("None of this moment will be kept.")
                        .font(.footnote.bold())
                        .foregroundStyle(.red)
                }
                if !session.deletedIDs.isEmpty {
                    Text("Deleted so far: \(session.deletedIDs.count) photo\(session.deletedIDs.count == 1 ? "" : "s") · about \(size(session.deletedBytes))")
                        .font(.footnote)
                }
                Text("Deleted photos stay in Recently Deleted for 30 days before the space is freed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Centered, so wrapped lines line up.
            .multilineTextAlignment(.center)

            Button {
                // Deleting every photo of a moment gets one extra question
                // first; otherwise straight to iOS's own confirmation.
                if marked == photos.count {
                    confirmingDeleteAll = true
                } else {
                    deleteMarked()
                }
            } label: {
                Text(marked == 0 ? "Delete" : "Delete \(marked) photo\(marked == 1 ? "" : "s") from this set")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(marked == 0 || isDeleting)
            .confirmationDialog("Delete every photo of this moment?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
                Button("Delete all \(marked)", role: .destructive) { deleteMarked() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("None of the \(marked) photos in this set will be kept.")
            }
        }
        .padding()
        .background(.bar)
    }

    private func deleteMarked() {
        isDeleting = true
        Task {
            errorMessage = await session.deleteMarked(in: set)
            isDeleting = false
        }
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
