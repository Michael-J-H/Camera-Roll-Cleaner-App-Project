//
//  ChatShellView.swift
//  Camera Roll Cleaner
//
//  Chat UI shell — UI only for now, per the project brief's ordering
//  (chat shell before wiring in real clustering/AI logic). A separate
//  screen alongside the existing debug/cluster screens, not a replacement.
//

import Combine
import SwiftUI

// MARK: - Data model

/// A single message in the conversation. Built with room for more than plain text later
/// (e.g. a message containing a photo grid) — only `.text` is used for now, but adding
/// a new case later won't require restructuring existing messages.
struct ChatMessage: Identifiable {
    enum Sender: Equatable {
        case user
        case assistant
    }

    enum Content {
        case text(String)
        // Future: case photoGrid([PHAsset])
    }

    let id = UUID()
    let sender: Sender
    let content: Content
    let timestamp: Date = Date()
}

// MARK: - Conversation state + logic — knows nothing about colors or shapes

final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draftText: String = ""

    func sendDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(ChatMessage(sender: .user, content: .text(trimmed)))
        draftText = ""

        // Placeholder reply for the shell — real logic (clustering + AI) gets
        // wired in during the next two checklist items, not here.
        let reply = ChatMessage(sender: .assistant, content: .text(
            "Got it — I can't act on that yet, but I heard: \"\(trimmed)\""
        ))
        messages.append(reply)
    }
}

// MARK: - Visual layer — THE ONLY PLACE that knows it looks like iMessage.
// Swap this one view later and nothing above or below it has to change.

struct ChatBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 40) }

            switch message.content {
            case .text(let text):
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(message.sender == .user ? Color.blue : Color(.systemGray5))
                    .foregroundColor(message.sender == .user ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            if message.sender == .assistant { Spacer(minLength: 40) }
        }
    }
}

// MARK: - The screen itself

struct ChatShellView: View {
    @StateObject private var viewModel = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.messages) { message in
                            ChatBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    guard let lastID = viewModel.messages.last?.id else { return }
                    withAnimation { scrollProxy.scrollTo(lastID, anchor: .bottom) }
                }
            }

            Divider()

            HStack {
                TextField("Message", text: $viewModel.draftText)
                    .textFieldStyle(.roundedBorder)
                Button("Send") { viewModel.sendDraft() }
                    .disabled(viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .navigationTitle("Chat")
    }
}
