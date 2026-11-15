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

    /// The AI's pick per set (set id → photo id), for sets it judged. See
    /// topPick(in:).
    @Published private var aiPicks: [UUID: String] = [:]

    init(sets: [PhotoCluster]) {
        self.sets = sets
        #if DEBUG
        startJudging()
        #else
        readyOrder = sets.map(\.id) // no AI in Release builds yet — everything is ready
        #endif
    }

    /// Sets ready to show, in the order they became ready. Sets with people
    /// wait for the AI's judgment, so the user never sees an unjudged set;
    /// everything else is ready at once. Ready sets are only ever added at
    /// the end, so nothing already on screen shifts position (the review
    /// counts sets by position).
    @Published private var readyOrder: [UUID] = []

    /// Sets that are ready and still have photos. A set whose photos were
    /// all deleted drops out of the review and the chat's row.
    var visibleSets: [PhotoCluster] {
        readyOrder.compactMap { id in sets.first { $0.id == id } }
            .filter { !photos(in: $0).isEmpty }
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

    /// The set's current top pick: the AI's pick if it judged the set,
    /// otherwise the phone's best-ranked photo — either way, only if not
    /// yet deleted. If the top pick is deleted, the ★ moves to the next best
    /// in the phone's ranking. It moves only on an actual delete — not while
    /// photos are merely marked — so it doesn't jump around while the user
    /// is still deciding.
    func topPick(in set: PhotoCluster) -> PHAsset? {
        if let id = aiPicks[set.id], !deletedIDs.contains(id),
           let pick = set.members.first(where: { $0.asset.localIdentifier == id }) {
            return pick.asset
        }
        return set.ranked.map(\.asset).first { !deletedIDs.contains($0.localIdentifier) }
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

    #if DEBUG
    // MARK: Automatic AI judging (testing through OpenRouter)

    /// What the AI said about each set it judged — shown in the review so
    /// the developer can see its reasoning while testing.
    @Published private(set) var aiNotes: [UUID: String] = [:]
    /// Sets with people sent to the AI, and how many have come back.
    @Published private(set) var aiTotal = 0
    @Published private(set) var aiFinished = 0
    @Published private(set) var aiSpent: Double = 0
    /// Why judging didn't run at all (switched off, no key), if it didn't.
    @Published private(set) var aiSkippedReason: String?

    private var aiQueue: [(set: PhotoCluster, photos: [PHAsset])] = []
    /// A few sets at a time: fast enough, without firing every request at once.
    private let aiWorkers = 5

    /// Sends every set with people to the AI, right after the scan (see the
    /// brief: "Which sets the AI judges, and how many photos"). Only photos
    /// that pass the phone's checks go — today, nobody's eyes closed — at
    /// most the phone's top 10, in its ranking order, so photo 1 is always
    /// the phone's ★. If fewer than 2 pass there's nothing to choose
    /// between, so no AI call: the phone's pick stands. Sets without people
    /// keep the phone's pick.
    private func startJudging() {
        guard AIJudgeSettings.isOn, let key = OpenRouterKey.load() else {
            aiSkippedReason = AIJudgeSettings.isOn
                ? "No OpenRouter key saved — add it in Ask AI."
                : "AI judging is off (AI settings)."
            readyOrder = sets.map(\.id)
            return
        }
        aiQueue = sets.compactMap { set in
            guard set.ranked.contains(where: { !$0.faceQualities.isEmpty }) else { return nil }
            let passing = set.ranked.filter { ($0.blinkCheck?.blinking ?? 0) == 0 }.prefix(10).map(\.asset)
            return passing.count >= 2 ? (set, Array(passing)) : nil
        }
        aiTotal = aiQueue.count
        // Sets the AI won't judge are ready now; the rest join as they're judged.
        let waiting = Set(aiQueue.map(\.set.id))
        readyOrder = sets.map(\.id).filter { !waiting.contains($0) }
        let model = AIJudgeSettings.model
        for _ in 0..<min(aiWorkers, aiQueue.count) {
            Task {
                while !aiQueue.isEmpty {
                    let job = aiQueue.removeFirst()
                    await judge(job.set, photos: job.photos, model: model, key: key)
                    aiFinished += 1
                    readyOrder.append(job.set.id) // judged (or failed — phone's pick stands): show it
                }
            }
        }
    }

    private func judge(_ set: PhotoCluster, photos: [PHAsset], model: String, key: String) async {
        guard let prepared = await OpenRouterClient.prepareImages(photos, longestSide: 1024),
              prepared.jpegs.count == photos.count else {
            aiNotes[set.id] = "AI: couldn't load the photos (iCloud?) — phone's pick kept."
            return
        }
        let outcome = await OpenRouterClient.ask(model: model, key: key, images: prepared.jpegs, preference: "")
        switch outcome {
        case .failed(let message):
            aiNotes[set.id] = "AI failed — phone's pick kept. \(message)"
        case .answered(let answer):
            aiSpent += answer.cost ?? 0
            guard let number = answer.photo, (1...photos.count).contains(number) else {
                aiNotes[set.id] = "AI's answer couldn't be read — phone's pick kept. \(answer.reason)"
                return
            }
            let name = model.split(separator: "/").last.map(String.init) ?? model
            let verdict = number == 1 ? "kept the phone's ★" : "picked photo \(number) of \(photos.count) sent"
            // Never move the ★ under someone who has already started on this
            // set: a choice, a delete or "done" means they're deciding.
            if isUntouched(set) {
                aiPicks[set.id] = photos[number - 1].localIdentifier
                aiNotes[set.id] = "AI (\(name)) \(verdict): \(answer.reason)"
            } else {
                aiNotes[set.id] = "AI (\(name)) \(verdict), not applied — you'd already started on this set. \(answer.reason)"
            }
        }
    }

    private func isUntouched(_ set: PhotoCluster) -> Bool {
        deletedCount(in: set) == 0 && !isDone(set)
            && !set.members.contains { choices[$0.asset.localIdentifier] != nil }
    }
    #endif

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
                    #if DEBUG
                    // Testing only: what the AI said about this set.
                    if let note = session.aiNotes[set.id] {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    #endif

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
