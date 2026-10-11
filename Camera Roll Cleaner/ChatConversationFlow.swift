//
//  ChatConversationFlow.swift
//  Camera Roll Cleaner
//
//  Supporting pieces for the guided date-range conversation in
//  ChatShellView.swift: what stage the chat is in, and recognizing "yes".
//  Reading typed dates lives in TypedDateParser.swift.
//

import Foundation

/// The stages of the guided conversation. Keeping this as an explicit list
/// (rather than scattered if-statements) makes it obvious what the chat is
/// waiting for, and lets `sendDraft()` decide how to interpret whatever the
/// user just typed based on where they are — and makes new stages easy to
/// add later without untangling existing conditionals.
enum ConversationStage: Equatable {
    case awaitingDateEntryMethod   // greeting shown; waiting for type-vs-calendar, or a typed date
    case awaitingTypedDates        // user chose to type
    case awaitingPickedDates       // user chose the calendar
    case choosingBetween([DateInterval])  // "last Tuesday" — which one? (buttons)
    case confirmingDates(DateInterval)
    case clustering
    case showingResults
}

/// Recognizes asking to pick different dates ("new dates", "start over")
/// at any point in the conversation — so the chat never leaves the user
/// stuck answering a question they no longer care about.
enum ChangeDatesRequest {
    private static let phrases: Set<String> = [
        "new dates", "change dates", "change the dates", "different dates", "other dates",
        "start over", "restart", "never mind", "nevermind", "go back", "change date", "new date",
    ]

    static func matches(_ input: String) -> Bool {
        let cleaned = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return phrases.contains(cleaned)
    }
}

/// Loose match on common ways of typing "yes". Only used as a convenience at
/// the confirm-before-scanning step — the primary path there is a tappable
/// button, since parsing free text is too unreliable to be the only way to
/// greenlight an actual scan.
enum AffirmativeReply {
    private static let phrases: Set<String> = [
        "yes", "y", "yea", "yeah", "yep", "yup", "sure", "ok", "okay",
        "go", "go ahead", "do it", "confirm", "sounds good", "correct"
    ]

    static func matches(_ input: String) -> Bool {
        phrases.contains(input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
