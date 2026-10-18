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

// MARK: - Models to try

/// Vision-capable models listed on OpenRouter (checked Oct 18, 2026, from
/// openrouter.ai/api/v1/models). Prices are per million tokens; a photo at
/// 1024px is roughly 1,000 tokens, so even the dearest here is well under a
/// cent per photo. Anything else can be typed into "Other model".
private struct TestModel: Identifiable, Hashable {
    let id: String // OpenRouter's model id
    let price: String
}

private let testModels = [
    TestModel(id: "anthropic/claude-haiku-5.5", price: "$0.10 in / $0.50 out"),
    TestModel(id: "anthropic/claude-sonnet-5.5", price: "$2 in / $10 out"),
    TestModel(id: "openai/gpt-6-luna-pro", price: "$0.10 in / $0.50 out"),
    TestModel(id: "google/gemini-3.8-flash", price: "$0.83 in / $4.12 out"),
    TestModel(id: "qwen/qwen3.8-flash", price: "$0.15 in / $0.47 out"),
]

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

    @State private var sendCount = 5
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
                Stepper("Send the top \(min(sendCount, candidates.count))", value: $sendCount, in: 2...max(2, min(8, candidates.count)))
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
                    OpenRouterKey.save(key)
                    savedKey = OpenRouterKey.load()
                    keyDraft = ""
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("Remove saved key", role: .destructive) {
                    OpenRouterKey.delete()
                    savedKey = nil
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
            guard let prepared = await AskAIClient.prepareImages(sent, longestSide: size),
                  prepared.jpegs.count == sent.count else {
                for i in results.indices { results[i].outcome = .failed("Couldn't load every photo (iCloud?).") }
                return
            }
            sentSummary = prepared.summary
            let images = prepared.jpegs
            // One request per model, all running at the same time.
            for model in models {
                Task {
                    let outcome = await AskAIClient.ask(model: model, key: key, images: images, preference: wish)
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
    var outcome: AskAIClient.Outcome? // nil while waiting
    var id: String { model }
}

// MARK: - Talking to OpenRouter

private enum AskAIClient {
    enum Outcome: Equatable {
        case answered(Answer)
        case failed(String)

        var answer: Answer? {
            if case .answered(let a) = self { return a }
            return nil
        }
    }

    struct Answer: Equatable {
        let photo: Int? // 1-based; nil if the reply couldn't be read
        let verdict: String
        let reason: String
        let seconds: Double
        let cost: Double?
        let inputTokens: Int?
        let outputTokens: Int?

        var headline: String {
            guard let photo else { return "Couldn't read the answer:" }
            switch verdict {
            case "confirm": return "Keeps photo \(photo)" + (photo == 1 ? " ★ (confirms)" : "")
            case "override": return "Picks photo \(photo) instead" + (photo == 1 ? " (says override, but it's ★)" : "")
            default: return "Picks photo \(photo)"
            }
        }

        var details: String {
            var parts = [String(format: "%.1fs", seconds)]
            if let inputTokens, let outputTokens { parts.append("\(inputTokens) in / \(outputTokens) out tokens") }
            if let cost { parts.append("$" + String(format: "%.5f", cost)) }
            return parts.joined(separator: " · ")
        }
    }

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    private static let systemPrompt = """
    You help someone clean up near-duplicate photos on their iPhone. You'll see a few shots \
    of the same moment, numbered. Photo 1 is the phone's current top pick, chosen \
    automatically from face and image-quality scores.
    """

    private static func question(preference: String) -> String {
        if preference.isEmpty {
            return """
            Should photo 1 stay the top pick? Several of these photos may be equally good — \
            that's fine, and then photo 1 stays. Answer "confirm" with photo 1 unless photo 1 \
            has a clear flaw AND another photo is clearly better. Clear flaws: someone's eyes \
            are closed; someone isn't looking at the camera while the others are; an awkward \
            expression or pose; someone's head or body cut off by the edge of the frame; \
            someone blocked by another person or an object; motion blur or out of focus. A \
            clearly crooked horizon or frame is a minor flaw — it's easy to straighten later — \
            so let it decide only between photos that are otherwise equally good. Small \
            differences in composition or framing are a matter of taste, not flaws. Only when \
            photo 1 has a clear flaw and another photo is clearly better, answer "override" \
            with that photo's number. In "reason", say in one or two short sentences what you \
            saw.
            """
        }
        return """
        The person says what they want from this moment: "\(preference)". Pick the photo that \
        best matches that. Answer "confirm" if it's photo 1, otherwise "override" with that \
        photo's number. Don't pick a photo with a clear flaw (closed eyes, blur, someone cut \
        off by the frame) if another matches nearly as well. In "reason", say in one or two short sentences why.
        """
    }

    /// Asks for the answer as JSON in this exact shape ("structured
    /// output"), so the app can read it reliably instead of parsing prose.
    /// The reason comes first so the model explains before it commits.
    private static let answerSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "reason": ["type": "string", "description": "One or two short sentences."],
            "verdict": ["type": "string", "enum": ["confirm", "override"]],
            "photo": ["type": "integer", "description": "The chosen photo's number."],
        ],
        "required": ["reason", "verdict", "photo"],
        "additionalProperties": false,
    ]

    /// The photos as sent, and how they ended up being sent.
    struct PreparedImages {
        let jpegs: [Data]
        let longestSide: Int
        let quality: Double
        /// The photos' share of the request once encoded as text (base64).
        var requestBytes: Int { jpegs.reduce(0) { $0 + ($1.count + 2) / 3 * 4 } }
        var summary: String {
            "Sent \(jpegs.count) photos at \(longestSide)px, JPEG quality \(String(format: "%.2f", quality)) — "
                + ByteCountFormatter.string(fromByteCount: Int64(requestBytes), countStyle: .file) + " of photos in the request."
        }
    }

    /// JUDGMENT CALL: whole sets at 1024px failed through OpenRouter — even
    /// sent to Anthropic itself — with "media_type: Input should be
    /// 'image/jpeg'…", while the same photos at 512px, or fewer photos at
    /// 1024px, worked. So it depends on request size, inside OpenRouter's
    /// conversion (the app always labels photos image/jpeg, and Anthropic's
    /// own limit is 32 MB). The real line isn't published; 4 MB is a guess
    /// below what failed — the summary shown after each run is how to find
    /// out. Photos are only shrunk when a request would go over it.
    private static let requestBudget = 4_000_000

    /// Loads each photo, turns it upright and shrinks it so its longest side
    /// is `longestSide` pixels, then encodes it as JPEG. Upright matters:
    /// iPhone photos are often stored sideways with a "rotate when
    /// displaying" tag, which an AI model may ignore. If all of them
    /// together go over `requestBudget`, lower JPEG quality is tried first,
    /// then smaller sizes, until they fit.
    static func prepareImages(_ assets: [PHAsset], longestSide: CGFloat) async -> PreparedImages? {
        var uprights: [UIImage] = []
        for asset in assets {
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true // photos stored only in iCloud
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: longestSide, height: longestSide),
                    contentMode: .aspectFit,
                    options: options
                ) { image, _ in
                    continuation.resume(returning: image)
                }
            }
            guard let image else { return nil }
            uprights.append(resized(image, longestSide: longestSide))
        }

        let steps: [(side: CGFloat, quality: Double)] = [
            (longestSide, 0.8), (longestSide, 0.6), (896, 0.6), (768, 0.6), (640, 0.6), (512, 0.6),
        ].filter { $0.side <= longestSide }
        var prepared: PreparedImages?
        for step in steps {
            let images = step.side == longestSide ? uprights : uprights.map { resized($0, longestSide: step.side) }
            prepared = PreparedImages(jpegs: images.compactMap { $0.jpegData(compressionQuality: step.quality) },
                                      longestSide: Int(step.side), quality: step.quality)
            if let prepared, prepared.requestBytes <= requestBudget { break }
        }
        return prepared // the smallest step, if even that didn't fit
    }

    /// Redrawn upright (orientation tag applied) with the longest side at
    /// most `longestSide` pixels.
    private static func resized(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let scale = min(1, longestSide / max(image.size.width, image.size.height))
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// One request to one model. Written from OpenRouter's docs (Oct 2026):
    /// an OpenAI-style chat request, text first, then each image as a
    /// base64 "data URL". No temperature or other sampling settings — some
    /// current models (e.g. Claude Haiku 5.5) reject them.
    static func ask(model: String, key: String, images: [Data], preference: String) async -> Outcome {
        var content: [[String: Any]] = [["type": "text", "text": question(preference: preference)]]
        for (i, jpeg) in images.enumerated() {
            content.append(["type": "text", "text": "Photo \(i + 1):"])
            content.append(["type": "image_url",
                            "image_url": ["url": "data:image/jpeg;base64," + jpeg.base64EncodedString()]])
        }
        // Only send to a provider of this model that supports the
        // structured-output setting below, rather than one that ignores it.
        var provider: [String: Any] = ["require_parameters": true]
        if model.hasPrefix("anthropic/") {
            // Claude only from Anthropic itself. OpenRouter also sends Claude
            // to Google's and Amazon's cloud copies of it, and Google's
            // rejected whole sets ("media_type: Input should be
            // 'image/jpeg'…") that Anthropic's own limits allow. The shipping
            // app will call Anthropic directly, so this also tests what we'll
            // actually use. If Anthropic is down, the request fails rather
            // than quietly going elsewhere.
            provider["only"] = ["anthropic"]
        }
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": content],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "photo_choice", "strict": true, "schema": answerSchema],
            ],
            "provider": provider,
        ]

        var request = URLRequest(url: endpoint, timeoutInterval: 180) // whole sets take a while
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Camera Roll Cleaner (dev test)", forHTTPHeaderField: "X-Title")

        let start = Date()
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            let seconds = Date().timeIntervalSince(start)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

            if let error = json["error"] as? [String: Any] {
                return .failed(describe(error))
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return .failed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
            }

            let message = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]) ?? [:]
            let text = message["content"] as? String ?? ""
            let usage = json["usage"] as? [String: Any] ?? [:]
            let cost = (usage["cost"] as? NSNumber)?.doubleValue
            let inputTokens = (usage["prompt_tokens"] as? NSNumber)?.intValue
            let outputTokens = (usage["completion_tokens"] as? NSNumber)?.intValue

            // Some models wrap JSON in ``` fences even when asked not to.
            let cleaned = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any]
            guard let parsed, let photo = (parsed["photo"] as? NSNumber)?.intValue else {
                // Show whatever came back, so a bad reply is still useful to see.
                return .answered(Answer(photo: nil, verdict: "", reason: text.isEmpty ? "(empty reply)" : text,
                                        seconds: seconds, cost: cost, inputTokens: inputTokens, outputTokens: outputTokens))
            }
            return .answered(Answer(photo: photo,
                                    verdict: parsed["verdict"] as? String ?? "",
                                    reason: parsed["reason"] as? String ?? "",
                                    seconds: seconds, cost: cost, inputTokens: inputTokens, outputTokens: outputTokens))
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

extension AskAIClient {
    /// OpenRouter's error, plus the details it keeps in "metadata": which
    /// company's server failed, its own error code, and its exact message
    /// ("raw"). "Provider returned error" on its own says nothing useful —
    /// the reason is in those details.
    fileprivate static func describe(_ error: [String: Any]) -> String {
        var lines = ["OpenRouter: \(error["message"] as? String ?? "unknown error")"
                     + ((error["code"] as? NSNumber).map { " (\($0))" } ?? "")]
        let metadata = error["metadata"] as? [String: Any] ?? [:]
        for (label, key) in [("Provider", "provider_name"), ("Type", "error_type"), ("Provider code", "provider_code")] {
            if let value = metadata[key] { lines.append("\(label): \(value)") }
        }
        if let raw = metadata["raw"] {
            let text: String
            if let string = raw as? String {
                text = string
            } else if let data = try? JSONSerialization.data(withJSONObject: raw) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = "\(raw)"
            }
            lines.append("Details: \(text.prefix(600))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Key storage (Keychain)

/// The OpenRouter key, kept in the phone's Keychain. It survives deleting
/// and reinstalling the app (handy with the free account's 7-day expiry).
private enum OpenRouterKey {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "CameraRollCleaner.OpenRouterTestKey",
    ]

    static func load() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

#endif
