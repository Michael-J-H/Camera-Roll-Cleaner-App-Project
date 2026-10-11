//
//  ChatConversationFlow.swift
//  Camera Roll Cleaner
//
//  Supporting pieces for the guided date-range conversation in
//  ChatShellView.swift: what stage the chat is in, and how it makes sense
//  of whatever the user typed.
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

extension DateInterval {
    /// Every photo taken on any day from `first` through `last`, inclusive —
    /// midnight at the start of `first` up to (not including) midnight after
    /// `last`. Everything that produces a range goes through this, so a
    /// range can never accidentally start or stop partway through a day
    /// (e.g. at noon, or at whatever time it was when the user tapped the
    /// calendar) and quietly skip photos from the edge days.
    static func wholeDays(from first: Date, through last: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: min(first, last))
        let lastDayStart = calendar.startOfDay(for: max(first, last))
        let end = calendar.date(byAdding: .day, value: 1, to: lastDayStart) ?? lastDayStart
        return DateInterval(start: start, end: end)
    }
}

/// Turns free-typed text into a date range. Runs entirely on-device, costs
/// nothing, no third-party dependency. Three passes, most specific first:
///
/// 1. Relative phrases — "today", "yesterday", "last month", "this year",
///    "past 2 weeks".
/// 2. Months and years with no day numbers — "October 2025", "Oct 2025",
///    "2025", "Sep – Nov 2025", "from October to December 2025". Each
///    mention covers its whole month/year. Handled here by hand because
///    iOS's built-in date detector (pass 3) doesn't recognize these at all.
/// 3. Anything with specific days — "Oct 1, 2025 to Oct 4, 2025",
///    "Oct 1-4 2025", "10/1/2025" — handed to iOS's built-in date detector
///    (the same one that makes dates tappable in Messages).
///
/// This is deliberately a fixed set of patterns, not real language
/// understanding — phrases like "my France trip" need the AI step planned
/// in PROJECT_BRIEF.md. Whatever comes out, the chat reads it back for
/// confirmation before scanning, so a misread is caught before it costs
/// anything.
enum TypedDateParser {
    static func parse(_ input: String, now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        let text = input.lowercased()
        return parseRelative(text, now: now, calendar: calendar)
            ?? parseMonthsAndYears(text, now: now, calendar: calendar)
            ?? parseWithDetector(input, calendar: calendar)
    }

    // MARK: - Pass 1: relative phrases

    private static func parseRelative(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        if contains(text, #"\btoday\b"#) {
            return .wholeDays(from: now, through: now, calendar: calendar)
        }
        if contains(text, #"\byesterday\b"#), let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            return .wholeDays(from: yesterday, through: yesterday, calendar: calendar)
        }

        // "past 3 weeks" / "last ten days" — a rolling window ending today.
        let countPattern = #"(\d{1,3}|"# + numberWords.keys.joined(separator: "|") + ")"
        if let match = firstMatch(in: text, #"\b(?:last|past|previous)\s+"# + countPattern + #"\s+(day|week|month|year)s?\b"#),
           let count = Int(match[1]) ?? numberWords[match[1]], let unit = component(named: match[2]),
           let start = calendar.date(byAdding: unit, value: -count, to: now) {
            return .wholeDays(from: start, through: now, calendar: calendar)
        }

        // "past week" / "past month" (no number) — also a rolling window, since
        // that's how people tend to mean "past".
        if let match = firstMatch(in: text, #"\bpast\s+(week|month|year)\b"#),
           let unit = component(named: match[1]),
           let start = calendar.date(byAdding: unit, value: -1, to: now) {
            return .wholeDays(from: start, through: now, calendar: calendar)
        }

        // "last month" / "this year" — a calendar period (all of September,
        // not "the 30 days before today").
        if let match = firstMatch(in: text, #"\b(this|last|previous)\s+(week|month|year)\b"#),
           let unit = component(named: match[2]) {
            let offset = match[1] == "this" ? 0 : -1
            guard let anchor = calendar.date(byAdding: unit, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: unit, for: anchor)
        }

        return nil
    }

    // MARK: - Pass 2: months and years

    /// One month or year the user mentioned. `year` is nil when they didn't
    /// say one ("October" in "October to December 2025") and it has to be
    /// filled in from the rest of the sentence or from today's date.
    private struct Mention {
        var month: Int?
        var year: Int?
        var yearCameFromLaterMention = false
    }

    private static let monthPattern =
        #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#

    private static let monthIndex: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
    ]

    private static func parseMonthsAndYears(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        // A month name with an optional year after it, or a year on its own.
        let pattern = #"\b"# + monthPattern + #"\.?(?:\s*,?\s*((?:19|20)\d{2}))?\b|\b((?:19|20)\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return nil }

        // If any digits are left over once the months/years are removed
        // (the "1" in "Oct 1 2025"), the user named specific days — leave
        // that to the date detector in pass 3 rather than guess here.
        let leftover = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsText.length), withTemplate: " ")
        guard leftover.range(of: #"\d"#, options: .regularExpression) == nil else { return nil }

        var mentions: [Mention] = matches.map { match in
            func group(_ i: Int) -> String? {
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : nsText.substring(with: range)
            }
            if let monthName = group(1) {
                return Mention(month: monthIndex[String(monthName.prefix(3))], year: group(2).flatMap { Int($0) })
            }
            return Mention(month: nil, year: group(3).flatMap { Int($0) })
        }

        // Fill in missing years: "October to December 2025" means October
        // *2025*, so borrow from the next mention that has a year, then the
        // previous one. With no year anywhere ("October"), use the most
        // recent October that isn't in the future — nobody has photos from
        // next month yet.
        for i in mentions.indices where mentions[i].year == nil {
            if let later = mentions[(i + 1)...].first(where: { $0.year != nil })?.year {
                mentions[i].year = later
                mentions[i].yearCameFromLaterMention = true
            } else if let earlier = mentions[..<i].last(where: { $0.year != nil })?.year {
                mentions[i].year = earlier
            } else if let month = mentions[i].month {
                let thisYear = calendar.component(.year, from: now)
                let thisMonth = calendar.component(.month, from: now)
                mentions[i].year = month > thisMonth ? thisYear - 1 : thisYear
            }
        }

        // "November to February 2026" wraps over New Year: the borrowed
        // 2026 makes November come *after* February, so step it back a year.
        if mentions.count >= 2, mentions[0].yearCameFromLaterMention,
           let firstMonth = mentions[0].month, let lastMonth = mentions[mentions.count - 1].month,
           mentions[0].year == mentions[mentions.count - 1].year, firstMonth > lastMonth {
            mentions[0].year? -= 1
        }

        let intervals = mentions.compactMap { interval(for: $0, calendar: calendar) }
        guard let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    private static func interval(for mention: Mention, calendar: Calendar) -> DateInterval? {
        guard let year = mention.year else { return nil }
        let components = DateComponents(year: year, month: mention.month ?? 1, day: 1)
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.dateInterval(of: mention.month == nil ? .year : .month, for: date)
    }

    // MARK: - Pass 3: iOS's date detector, for anything with specific days

    /// The detector hands back times of day (usually noon) rather than whole
    /// days, so the earliest and latest dates it found are widened to cover
    /// their full days.
    private static func parseWithDetector(_ input: String, calendar: Calendar) -> DateInterval? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let matches = detector.matches(in: input, range: NSRange(input.startIndex..., in: input))
        let spans = matches.compactMap { match -> (Date, Date)? in
            guard let date = match.date else { return nil }
            return (date, date.addingTimeInterval(max(match.duration, 0)))
        }
        guard let first = spans.map(\.0).min(), let last = spans.map(\.1).max() else { return nil }
        return .wholeDays(from: first, through: last, calendar: calendar)
    }

    // MARK: - Helpers

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "a couple of": 2, "a couple": 2, "a few": 3
    ]

    private static func contains(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The whole match plus each capture group, as strings.
    private static func firstMatch(in text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func component(named name: String) -> Calendar.Component? {
        switch name {
        case "day": return .day
        case "week": return .weekOfYear
        case "month": return .month
        case "year": return .year
        default: return nil
        }
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
