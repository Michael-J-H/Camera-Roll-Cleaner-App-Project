//
//  OpenRouterClient.swift
//  Camera Roll Cleaner
//
//  DEVELOPER TESTING ONLY — the one place the app talks to an AI. Used by
//  the "Ask AI" test screen (AskAIDebugView) and by automatic judging of
//  people sets after a scan (ReviewSession). Goes through OpenRouter (one
//  key, many AI companies' models) so models can be compared on the
//  developer's phone. Before TestFlight this is replaced by a call to our
//  relay server, which talks to Anthropic directly (see the brief's Before
//  TestFlight checklist) — keeping every AI call in this one file is what
//  makes that switch a contained change.
//
//  Everything is inside `#if DEBUG`, so Release builds contain none of it.
//

#if DEBUG

import Photos
import Security
import UIKit

// MARK: - Models to try

/// Vision-capable models listed on OpenRouter (checked Oct 18, 2026, from
/// openrouter.ai/api/v1/models). Prices are per million tokens; a photo at
/// 1024px is roughly 1,000 tokens, so even the dearest here is well under a
/// cent per photo. Anything else can be typed into "Other model".
struct TestModel: Identifiable, Hashable {
    let id: String // OpenRouter's model id
    let price: String
}

let testModels = [
    TestModel(id: "anthropic/claude-haiku-5.5", price: "$0.10 in / $0.50 out"),
    TestModel(id: "anthropic/claude-sonnet-5.5", price: "$2 in / $10 out"),
    TestModel(id: "openai/gpt-6-luna-pro", price: "$0.10 in / $0.50 out"),
    TestModel(id: "google/gemini-3.8-flash", price: "$0.83 in / $4.12 out"),
    TestModel(id: "qwen/qwen3.8-flash", price: "$0.15 in / $0.47 out"),
]

// MARK: - Talking to OpenRouter

enum OpenRouterClient {
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

extension OpenRouterClient {
    /// OpenRouter's error, plus the details it keeps in "metadata": which
    /// company's server failed, its own error code, and its exact message
    /// ("raw"). "Provider returned error" on its own says nothing useful —
    /// the reason is in those details.
    private static func describe(_ error: [String: Any]) -> String {
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
enum OpenRouterKey {
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

    /// Saves the key, then reads it back to be sure. Returns a message to
    /// show if that failed, nil if it worked.
    static func save(_ key: String) -> String? {
        delete()
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "unknown reason"
            return "Couldn't save the key (Keychain error \(status): \(reason)). Try again."
        }
        guard load() == key else {
            return "The key seemed to save but couldn't be read back. Try again."
        }
        return nil
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Automatic judging settings

/// Developer settings for judging people sets automatically after a scan
/// (changed on the "AI settings" screen). Stand-ins for the real thing: the
/// user's AI consent, and the model chosen after testing with friends.
enum AIJudgeSettings {
    private static let onKey = "aiJudge.isOn"
    private static let modelKey = "aiJudge.model"

    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: onKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: onKey) }
    }

    /// OpenRouter model id. Defaults to the cheapest Claude in the list.
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? testModels[0].id }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
}

#endif
