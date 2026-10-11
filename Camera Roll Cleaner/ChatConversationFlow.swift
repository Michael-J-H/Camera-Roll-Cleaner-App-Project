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
    case confirmingDates(DateInterval)
    case clustering
    case showingResults
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
