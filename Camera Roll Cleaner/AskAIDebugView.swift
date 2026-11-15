//
//  AskAIDebugView.swift
//  Camera Roll Cleaner
//
//  DEVELOPER TEST TOOL — not part of the shipping app. Opened from the
//  review's "Ask AI" button, it sends photos of the set on screen — the
//  phone's top few, or the whole set, optionally leaving out closed eyes —
//  to one or more AI models through OpenRouter (one account, many
//  AI companies) and shows what each model picked, so the developer can
//  choose a model by eye on their own photos. See the brief's "Cloud AI
//  integration" entry for the two tests this is for:
//  - Backstop test (preference left empty): should the phone's ★ stay, or
//    is it clearly bad and another shot clearly better?
//  - Preference test (preference typed): which photo best matches it?
//
//  The AI's answer is only shown here — it never moves the review's ★ or
//  changes any Keep/Delete choice.
//
//  Everything is inside `#if DEBUG`, so builds made for TestFlight / the App
//  Store (Release builds) don't contain any of it. Running from Xcode onto
//  the phone is a Debug build, so it shows up there. The brief's Before
//  TestFlight checklist still says to delete this file — the shipping app
//  calls one AI company directly, through our own relay server.
//
//  The OpenRouter key is pasted into this screen once and kept in the
//  phone's Keychain (iOS's encrypted password store), so it's never in a
//  project file and can't end up on GitHub by accident.
//

#if DEBUG

import Photos
import Security
import SwiftUI

// MARK: - The screen

struct AskAIDebugView: View {
    /// The phone's ranking of the set, best first, without deleted photos.
    /// Photo 1 is the current ★ top pick.
    let rankedPhotos: [PHAsset]
    /// Photos where the phone saw someone's eyes closed (same rule as its
    /// ranking).
    /// Apple's blink detector's result per photo (missing = it found no
    /// faces). Shown under each photo so the check can be judged by eye.
    let blinkChecks: [String: BlinkCheck]

    private func hasClosedEyes(_ asset: PHAsset) -> Bool {
        (blinkChecks[asset.localIdentifier]?.blinking ?? 0) > 0
    }
    let hasPeople: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var sendCount = 10 // default chosen by the developer (Oct 2026)
    @State private var sendAll = false
    @State private var dropClosedEyes = false
    @State private var preference = ""
    @State private var selectedModels: Set<String> = [testModels[0].id]
    @State private var otherModel = ""
    @State private var smallImages = false
    @State private var results: [ModelResult] = []
    /// How the last round's photos were actually sent (size, quality).
    @State private var sentSummary: String?
    @State private var viewerStart: ViewerStart?

    @State private var savedKey = OpenRouterKey.load()
    @State private var keyDraft = ""
    @State private var keyError: String?
    @State private var confirmingKeyRemoval = false

    private struct ViewerStart: Identifiable, Hashable {
        let index: Int
        var id: Int { index }
    }

    /// Even "the whole set" stops here, so a 100-shot burst can't turn
    /// into one enormous request.
    private let maxPhotos = 30

    /// Photos that may be sent: the phone's ranking, minus blinks if asked.
    /// The ★ always stays photo 1 — the phone ranks blinks last, so the ★
    /// only has closed eyes when (nearly) every photo does, and then
    /// nothing is left out.
    private var candidates: [PHAsset] {
        guard dropClosedEyes else { return rankedPhotos }
        let open = rankedPhotos.filter { !hasClosedEyes($0) }
        return open.count >= 2 ? open : rankedPhotos
    }

    private var sentPhotos: [PHAsset] {
        Array(candidates.prefix(sendAll ? maxPhotos : sendCount))
    }

    private var photosFooter: String {
        let closed = rankedPhotos.filter { hasClosedEyes($0) }.count
        var lines = ["Sending \(sentPhotos.count) of \(rankedPhotos.count) photos, in the phone's ranking order. Photo 1 is the phone's ★ pick."]
        if dropClosedEyes {
            lines.append(candidates.count == rankedPhotos.count
                         ? "Nothing left out for closed eyes\(closed > 0 ? " (that would leave fewer than 2)" : "")."
                         : "\(closed) left out for closed eyes.")
        }
        if sendAll && candidates.count > maxPhotos {
            lines.append("Capped at \(maxPhotos).")
        }
        if !hasPeople {
            lines.append("No faces in this set — the real AI step will only handle sets with people.")
        }
        lines.append("Tap a photo to see it full size. Images are sent at up to \(smallImages ? 512 : 1024)px — shrunk only if a request would be too big.")
        return lines.joined(separator: " ")
    }

    private var modelsToAsk: [String] {
        let other = otherModel.trimmingCharacters(in: .whitespaces)
        return testModels.map(\.id).filter { selectedModels.contains($0) } + (other.isEmpty ? [] : [other])
    }

    private var isRunning: Bool { results.contains { $0.outcome == nil } }

    var body: some View {
        NavigationStack {
            Form {
                if savedKey == nil {
                    keySection
                }
                photosSection
                preferenceSection
                modelsSection
                askSection
                if !results.isEmpty {
                    resultsSection
                }
                if savedKey != nil {
                    keySection
                }
            }
            .navigationTitle("Ask AI (test)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $viewerStart) { start in
                AssetDetailView(assets: sentPhotos, selectedIndex: start.index, topPickID: rankedPhotos.first?.localIdentifier)
            }
        }
    }

    // MARK: Sections

    private var photosSection: some View {
        Section {
            // A plain grid, not a sideways scroller — nothing in this form
            // competes for swipes.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(sentPhotos.enumerated()), id: \.element.localIdentifier) { offset, asset in
                    VStack(spacing: 2) {
                        numberedThumbnail(asset, number: offset + 1, side: 72)
                            .onTapGesture { viewerStart = ViewerStart(index: offset) }
                        eyeLabel(asset)
                    }
                }
            }
            Toggle("Send the whole set", isOn: $sendAll)
            if !sendAll {
                Stepper("Send the top \(min(sendCount, candidates.count))", value: $sendCount, in: 2...max(2, min(maxPhotos, candidates.count)))
                    .disabled(candidates.count <= 2)
            }
            Toggle("Leave out closed eyes", isOn: $dropClosedEyes)
            Toggle("Smaller images (512px)", isOn: $smallImages)
        } header: {
            Text("Photos sent")
        } footer: {
            Text(photosFooter)
        }
    }

    private var preferenceSection: some View {
        Section {
            TextField("e.g. both of us laughing", text: $preference, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("Preference (optional)")
        } footer: {
            Text(preference.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "Empty = backstop test: the AI keeps photo 1 unless it's clearly bad and another is clearly better."
                 : "Preference test: the AI picks the photo that best matches this.")
        }
    }

    private var modelsSection: some View {
        Section {
            ForEach(testModels) { model in
                Toggle(isOn: Binding(
                    get: { selectedModels.contains(model.id) },
                    set: { on in
                        if on { selectedModels.insert(model.id) } else { selectedModels.remove(model.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.id).font(.subheadline)
                        Text(model.price).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TextField("Other model (OpenRouter id)", text: $otherModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
        } header: {
            Text("Models")
        } footer: {
            Text("Prices per million tokens. Every model ticked gets the same photos and question, all at once.")
        }
    }

    private var askSection: some View {
        Section {
            Button {
                ask()
            } label: {
                Text(modelsToAsk.count <= 1 ? "Ask" : "Ask \(modelsToAsk.count) models")
                    .frame(maxWidth: .infinity)
            }
            .disabled(savedKey == nil || modelsToAsk.isEmpty || isRunning)
        }
    }

    private var resultsSection: some View {
        Section {
            ForEach(results) { result in
                resultRow(result)
            }
        } header: {
            Text("Results")
        } footer: {
            let spent = results.compactMap { $0.outcome?.answer?.cost }.reduce(0, +)
            Text((sentSummary.map { $0 + " " } ?? "")
                 + "This round cost about $\(String(format: "%.4f", spent)) (as reported by OpenRouter).")
        }
    }

    private var keySection: some View {
        Section {
            if savedKey == nil {
                SecureField("Paste your OpenRouter key", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save key") {
                    let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    keyError = OpenRouterKey.save(key)
                    savedKey = OpenRouterKey.load()
                    // Kept on failure, so it can be tried again without re-pasting.
                    if keyError == nil { keyDraft = "" }
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let keyError {
                    Text(keyError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } else {
                // Asks first: this button sits just under the results, where a
                // stray tap while scrolling once removed the key unnoticed.
                Button("Remove saved key", role: .destructive) {
                    confirmingKeyRemoval = true
                }
                .confirmationDialog("Remove the saved OpenRouter key?", isPresented: $confirmingKeyRemoval, titleVisibility: .visible) {
                    Button("Remove key", role: .destructive) {
                        OpenRouterKey.delete()
                        savedKey = nil
                        keyError = nil
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll need to paste it in again to use Ask AI. OpenRouter only shows a key once, so make sure you have a copy.")
                }
            }
        } header: {
            Text("OpenRouter key")
        } footer: {
            Text(savedKey == nil
                 ? "Needed once. Kept in this phone's Keychain only — never in the project or on GitHub."
                 : "A key is saved on this phone.")
        }
    }

    // MARK: Pieces

    private func numberedThumbnail(_ asset: PHAsset, number: Int, side: CGFloat) -> some View {
        PhotoThumbnailView(asset: asset, targetSize: CGSize(width: side * displayScale, height: side * displayScale))
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                Text(number == 1 ? "1 ★" : "\(number)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(3)
            }
    }

    /// "open 2/2" (faces with eyes open / faces found), "blink 1/2 ✕" in
    /// red, or "no face" when the blink detector found none.
    private func eyeLabel(_ asset: PHAsset) -> some View {
        let closed = hasClosedEyes(asset)
        let text = blinkChecks[asset.localIdentifier].map { check in
            closed ? "blink \(check.blinking)/\(check.faces) ✕" : "open \(check.faces)/\(check.faces)"
        } ?? "no face"
        return Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(closed ? Color.red : Color.secondary)
    }

    @ViewBuilder
    private func resultRow(_ result: ModelResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.model).font(.subheadline.bold())
            switch result.outcome {
            case nil:
                HStack {
                    ProgressView()
                    Text("Asking…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            case .answered(let answer):
                HStack(alignment: .top, spacing: 10) {
                    if let photo = answer.photo, (1...result.sent.count).contains(photo) {
                        numberedThumbnail(result.sent[photo - 1], number: photo, side: 56)
                            .onTapGesture { viewerStart = ViewerStart(index: photo - 1) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(answer.headline).font(.subheadline)
                        if !answer.reason.isEmpty {
                            Text(answer.reason).font(.footnote)
                        }
                    }
                }
                Text(answer.details).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Asking

    private func ask() {
        guard let key = savedKey else { return }
        let sent = sentPhotos
        let models = modelsToAsk
        let wish = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        let size: CGFloat = smallImages ? 512 : 1024
        results = models.map { ModelResult(model: $0, sent: sent) }
        sentSummary = nil

        Task {
            // Photos are prepared once and the same images go to every model.
            guard let prepared = await OpenRouterClient.prepareImages(sent, longestSide: size),
                  prepared.jpegs.count == sent.count else {
                for i in results.indices { results[i].outcome = .failed("Couldn't load every photo (iCloud?).") }
                return
            }
            sentSummary = prepared.summary
            let images = prepared.jpegs
            // One request per model, all running at the same time.
            for model in models {
                Task {
                    let outcome = await OpenRouterClient.ask(model: model, key: key, images: images, preference: wish)
                    if let i = results.firstIndex(where: { $0.model == model }) {
                        results[i].outcome = outcome
                    }
                }
            }
        }
    }
}

// MARK: - Results

private struct ModelResult: Identifiable {
    let model: String
    /// The photos this model was shown, in order (photo 1 first).
    let sent: [PHAsset]
    var outcome: OpenRouterClient.Outcome? // nil while waiting
    var id: String { model }
}

// MARK: - AI settings (automatic judging)

/// Testing-only settings for judging sets with people automatically after
/// a scan: on/off (a stand-in for the user's AI consent) and which model.
/// Opened from "AI" in the chat's top bar. Changes apply from the next scan.
struct AISettingsView: View {
    @State private var isOn = AIJudgeSettings.isOn
    @State private var model = AIJudgeSettings.model
    private let hasKey = OpenRouterKey.load() != nil

    var body: some View {
        Form {
            Section {
                Toggle("Judge sets with people automatically", isOn: $isOn)
                    .onChange(of: isOn) { AIJudgeSettings.isOn = isOn }
            } footer: {
                Text("Right after each scan, every set with people is sent to the AI — only photos with nobody's eyes closed, at most the phone's top 10. Its pick becomes the ★. Off = the phone's pick, as before (what declining AI will look like).")
            }
            Section {
                // Plain rows with a checkmark rather than a picker control.
                ForEach(testModels) { option in
                    Button {
                        model = option.id
                        AIJudgeSettings.model = option.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.id).font(.subheadline)
                                Text(option.price).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if option.id == model {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Applies from the next scan.")
            }
            Section {
                Text(hasKey ? "OpenRouter key saved on this phone." : "No OpenRouter key yet — add it on any set's Ask AI screen.")
                    .font(.footnote)
            }
        }
        .navigationTitle("AI (test)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
