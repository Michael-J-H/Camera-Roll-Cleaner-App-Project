//
//  TypedDateParser.swift
//  Camera Roll Cleaner
//
//  Turns what the user types in the chat into a date range.
//

import Foundation

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
/// nothing, no third-party dependency, and gives the same answer every time.
/// Tries these passes in order, most specific first:
///
/// 1. Measured from a day — "two weeks before Christmas 2025", "the 3 days
///    after Nov 5th", "a week around Easter 2024".
/// 2. Moving the range already being discussed — "a week earlier",
///    "a month later", "back 3 days".
/// 3. The start or end of a month or year — "first two weeks of October
///    2025", "last 10 days of March", "first 3 months of 2025".
/// 4. A week or weekend within a month — "first weekend of October 2024",
///    "last week of March".
/// 5. The week containing a day — "week of November 5th 2025".
/// 6. A holiday on its own — "Easter 2024", "Christmas Eve".
/// 7. Seasons — "summer 2024", "winter".
/// 8. Relative to today — "today", "yesterday", "last month", "this year",
///    "past two weeks".
/// 9. Months and years with no day numbers — "October 2025", "2025",
///    "Sep – Nov 2025", "from October to December 2025".
/// 10. Anything else with specific days — "Oct 1, 2025 to Oct 4, 2025",
///    "Oct 1-4 2025", "10/1/2025" — handed to iOS's built-in date detector
///    (the same one that makes dates tappable in Messages).
///
/// Order matters: "last week of March" and "last 10 days of March" have to
/// be read as part of March before pass 8 can read "last week" / "last 10
/// days" as counting back from today; and "Easter 2024" has to be read as
/// the holiday before pass 9 can read "2024" as the whole year.
///
/// This is a fixed set of patterns, not real language understanding.
/// Apple's on-device AI model was tried for that and removed — see the
/// Decision Log in PROJECT_BRIEF.md. Whatever comes out, the chat reads it
/// back for confirmation before scanning, so a misread costs nothing.
enum TypedDateParser {
    /// - Parameter current: The range already being discussed, if any —
    ///   needed for "a week earlier" and the like.
    static func parse(_ input: String, current: DateInterval? = nil, now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        let text = input.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return parseMeasuredFromDay(text, now: now, calendar: calendar)
            ?? parseShift(text, current: current, calendar: calendar)
            ?? parseStartOrEndOfPeriod(text, now: now, calendar: calendar)
            ?? parseWeekOrWeekendOfMonth(text, now: now, calendar: calendar)
            ?? parseWeekOf(text, now: now, calendar: calendar)
            ?? parseHoliday(text, now: now, calendar: calendar)
            ?? parseSeason(text, now: now, calendar: calendar)
            ?? parseRelative(text, now: now, calendar: calendar)
            ?? parseMonthsAndYears(text, now: now, calendar: calendar)
            ?? parseWithDetector(input, calendar: calendar)
    }

    // MARK: - Pass 1: measured from a day

    /// "Two weeks before Christmas" means the 14 days up to and including
    /// Christmas Eve (Dec 11–24); "after" mirrors that, starting the day
    /// after. "Around" centers the span on the day.
    private static func parseMeasuredFromDay(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        let pattern = #"\b"# + countPattern + #"\s+(day|week|month|year)s?\s+(before|prior to|leading up to|after|following|around)\s+(.+)$"#
        guard let match = firstMatch(in: text, pattern),
              let amount = count(match[1]), let unit = component(named: match[2]),
              let reference = parseReferenceDay(match[4], now: now, calendar: calendar) else { return nil }

        switch match[3] {
        case "after", "following":
            guard let start = calendar.date(byAdding: .day, value: 1, to: reference),
                  let end = calendar.date(byAdding: unit, value: amount, to: reference) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)
        case "around":
            guard let spanEnd = calendar.date(byAdding: unit, value: amount, to: reference) else { return nil }
            let days = max(calendar.dateComponents([.day], from: reference, to: spanEnd).day ?? 1, 1)
            guard let start = calendar.date(byAdding: .day, value: -(days / 2), to: reference),
                  let end = calendar.date(byAdding: .day, value: days - 1, to: start) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)
        default: // before
            guard let end = calendar.date(byAdding: .day, value: -1, to: reference),
                  let start = calendar.date(byAdding: unit, value: -amount, to: reference) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)
        }
    }

    // MARK: - Pass 2: moving the current range

    private static func parseShift(_ text: String, current: DateInterval?, calendar: Calendar) -> DateInterval? {
        guard let current else { return nil }
        let unitPattern = #"(day|week|month|year)s?"#
        let amount: Int
        let unit: Calendar.Component
        let direction: String
        if let match = firstMatch(in: text, #"\b"# + countPattern + #"\s+"# + unitPattern + #"\s+(earlier|later|sooner|back|forward)\b"#),
           let n = count(match[1]), let u = component(named: match[2]) {
            (amount, unit, direction) = (n, u, match[3])
        } else if let match = firstMatch(in: text, #"\b(earlier|later|back|forward)\s+(?:by\s+)?"# + countPattern + #"\s+"# + unitPattern + #"\b"#),
                  let n = count(match[2]), let u = component(named: match[3]) {
            (amount, unit, direction) = (n, u, match[1])
        } else {
            return nil
        }
        let sign = ["earlier", "sooner", "back"].contains(direction) ? -1 : 1
        let lastDay = current.end.addingTimeInterval(-1)
        guard let start = calendar.date(byAdding: unit, value: sign * amount, to: current.start),
              let end = calendar.date(byAdding: unit, value: sign * amount, to: lastDay) else { return nil }
        return .wholeDays(from: start, through: end, calendar: calendar)
    }

    // MARK: - Pass 3: the start or end of a month or year

    /// Counted from the 1st or back from the last day: "first two weeks of
    /// October" = Oct 1–14, "last 10 days of March" = Mar 22–31, "first 3
    /// months of 2025" = Jan 1 – Mar 31.
    private static func parseStartOrEndOfPeriod(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        // Days or weeks of a month.
        let monthPart = #"\b(first|last)\s+"# + countPattern + #"\s+(day|week)s?\s+(?:of\s+|in\s+)?"# + monthPattern + #"\b"#
        if let match = firstMatch(in: text, monthPart),
           let amount = count(match[2]), let month = monthIndex[String(match[4].prefix(3))] {
            let year = yearMentioned(in: text) ?? mostRecentYear(forMonth: month, now: now, calendar: calendar)
            guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count else { return nil }
            let days = min(amount * (match[3] == "week" ? 7 : 1), daysInMonth)
            let firstDay = match[1] == "first" ? 1 : daysInMonth - days + 1
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: firstDay)),
                  let end = calendar.date(byAdding: .day, value: days - 1, to: start) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)
        }

        // Months of a year.
        let yearPart = #"\b(first|last)\s+"# + countPattern + #"\s+months?\s+(?:of\s+|in\s+)?((?:19|20)\d{2})\b"#
        if let match = firstMatch(in: text, yearPart),
           let amount = count(match[2]).map({ min($0, 12) }), let year = Int(match[3]) {
            let firstMonth = match[1] == "first" ? 1 : 13 - amount
            guard let start = calendar.date(from: DateComponents(year: year, month: firstMonth, day: 1)),
                  let afterEnd = calendar.date(byAdding: .month, value: amount, to: start),
                  let end = calendar.date(byAdding: .day, value: -1, to: afterEnd) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)
        }

        return nil
    }

    // MARK: - Pass 4: a week or weekend within a month

    /// Weekends are Saturday–Sunday, counted by their Saturday ("first
    /// weekend of October 2024" = Sat Oct 5 – Sun Oct 6). Weeks within a
    /// month are counted from the 1st: first = 1–7, second = 8–14, and so
    /// on; "last week" = the month's final 7 days.
    private static func parseWeekOrWeekendOfMonth(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        let pattern = #"\b(first|1st|second|2nd|third|3rd|fourth|4th|last)\s+(weekend|week)\s+(?:of\s+|in\s+)?"# + monthPattern + #"\b"#
        guard let match = firstMatch(in: text, pattern),
              let month = monthIndex[String(match[3].prefix(3))] else { return nil }
        let year = yearMentioned(in: text) ?? mostRecentYear(forMonth: month, now: now, calendar: calendar)
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let daysInMonth = calendar.range(of: .day, in: .month, for: monthStart)?.count else { return nil }
        let ordinal = ["first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2, "fourth": 3, "4th": 3][match[1]]

        if match[2] == "weekend" {
            let saturdays = (1...daysInMonth).compactMap { day -> Date? in
                guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
                return calendar.component(.weekday, from: date) == 7 ? date : nil
            }
            guard let saturday = ordinal.map({ $0 < saturdays.count ? saturdays[$0] : nil }) ?? saturdays.last,
                  let sunday = calendar.date(byAdding: .day, value: 1, to: saturday) else { return nil }
            return .wholeDays(from: saturday, through: sunday, calendar: calendar)
        }

        let firstDay = ordinal.map { $0 * 7 + 1 } ?? daysInMonth - 6
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: firstDay)),
              let end = calendar.date(byAdding: .day, value: 6, to: start) else { return nil }
        return .wholeDays(from: start, through: end, calendar: calendar)
    }

    // MARK: - Pass 5: the week containing a day

    /// "Week of November 5th 2025" = the calendar week containing Nov 5,
    /// starting on whatever day the phone's region settings use (Monday in
    /// most of Europe, Sunday in the US).
    private static func parseWeekOf(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        guard let match = firstMatch(in: text, #"\bweek of\s+(.+)$"#),
              let day = parseReferenceDay(match[1], now: now, calendar: calendar) else { return nil }
        return calendar.dateInterval(of: .weekOfYear, for: day)
    }

    // MARK: - Pass 6: a holiday on its own

    /// Just that day — "Easter 2024" = Sunday, Mar 31, 2024. (Phrases built
    /// around a holiday, like "a week before Easter" or "week of Christmas",
    /// are caught by earlier passes.)
    private static func parseHoliday(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        guard contains(text, holidayPattern),
              let day = parseReferenceDay(text, now: now, calendar: calendar) else { return nil }
        return .wholeDays(from: day, through: day, calendar: calendar)
    }

    // MARK: - Pass 7: seasons

    /// Spring = Mar–May, summer = Jun–Aug, autumn/fall = Sep–Nov, winter =
    /// Dec through Feb of the following year ("winter 2024" = Dec 2024 –
    /// Feb 2025). No year means the most recent one that has started.
    private static func parseSeason(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        guard let match = firstMatch(in: text, #"\b(spring|summer|autumn|fall|winter)\b"#) else { return nil }
        let startMonth = ["spring": 3, "summer": 6, "autumn": 9, "fall": 9, "winter": 12][match[1]] ?? 3
        func seasonStart(_ year: Int) -> Date? { calendar.date(from: DateComponents(year: year, month: startMonth, day: 1)) }

        var year = yearMentioned(in: text) ?? calendar.component(.year, from: now)
        if yearMentioned(in: text) == nil, let start = seasonStart(year), start > now { year -= 1 }

        guard let start = seasonStart(year),
              let nextSeason = calendar.date(byAdding: .month, value: 3, to: start),
              let end = calendar.date(byAdding: .day, value: -1, to: nextSeason) else { return nil }
        return .wholeDays(from: start, through: end, calendar: calendar)
    }

    // MARK: - Reading a single day ("Christmas 2025", "Nov 5th", "5 November 2025")

    /// No year given means the most recent one that isn't in the future —
    /// nobody has photos from next Christmas yet.
    private static func parseReferenceDay(_ text: String, now: Date, calendar: Calendar) -> Date? {
        if let holiday = firstMatch(in: text, holidayPattern) {
            if let year = yearMentioned(in: text) {
                return holidayDate(holiday[1], year: year, calendar: calendar)
            }
            let thisYear = calendar.component(.year, from: now)
            if let date = holidayDate(holiday[1], year: thisYear, calendar: calendar), date <= now { return date }
            return holidayDate(holiday[1], year: thisYear - 1, calendar: calendar)
        }

        var month: Int?
        var day: Int?
        if let match = firstMatch(in: text, #"\b"# + monthPattern + #"\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b"#) {
            (month, day) = (monthIndex[String(match[1].prefix(3))], Int(match[2]))
        } else if let match = firstMatch(in: text, #"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?"# + monthPattern + #"\b"#) {
            (month, day) = (monthIndex[String(match[2].prefix(3))], Int(match[1]))
        }
        if let month, let day {
            let year = yearMentioned(in: text) ?? mostRecentYear(forMonth: month, day: day, now: now, calendar: calendar)
            let components = DateComponents(year: year, month: month, day: day)
            guard components.isValidDate(in: calendar) else { return nil }
            return calendar.date(from: components)
        }

        // Numeric dates ("11/5/2025") — leave the day/month order to iOS,
        // which follows the phone's region settings.
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let date = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.date else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static let holidayPattern =
        #"\b(christmas eve|christmas|xmas|new year'?s eve|new year'?s(?: day)?|new year|halloween|valentine'?s(?: day)?|easter|thanksgiving)\b"#

    private static func holidayDate(_ name: String, year: Int, calendar: Calendar) -> Date? {
        let (month, day): (Int, Int)
        switch name {
        case "christmas eve": (month, day) = (12, 24)
        case "christmas", "xmas": (month, day) = (12, 25)
        case _ where name.hasPrefix("new year") && name.hasSuffix("eve"): (month, day) = (12, 31)
        case _ where name.hasPrefix("new year"): (month, day) = (1, 1)
        case "halloween": (month, day) = (10, 31)
        case _ where name.hasPrefix("valentine"): (month, day) = (2, 14)
        case "easter": (month, day) = easterSunday(year)
        case "thanksgiving": (month, day) = (11, usThanksgivingDay(year, calendar: calendar))
        default: return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Easter Sunday (Western), by the standard "anonymous Gregorian" formula.
    private static func easterSunday(_ year: Int) -> (Int, Int) {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return (month, day)
    }

    /// US Thanksgiving: the fourth Thursday of November.
    private static func usThanksgivingDay(_ year: Int, calendar: Calendar) -> Int {
        guard let nov1 = calendar.date(from: DateComponents(year: year, month: 11, day: 1)) else { return 22 }
        let firstThursday = 1 + (5 - calendar.component(.weekday, from: nov1) + 7) % 7
        return firstThursday + 21
    }

    // MARK: - Pass 8: relative to today

    private static func parseRelative(_ text: String, now: Date, calendar: Calendar) -> DateInterval? {
        if contains(text, #"\btoday\b"#) {
            return .wholeDays(from: now, through: now, calendar: calendar)
        }
        if contains(text, #"\byesterday\b"#), let yesterday = calendar.date(byAdding: .day, value: -1, to: now) {
            return .wholeDays(from: yesterday, through: yesterday, calendar: calendar)
        }

        // "past 3 weeks" / "last ten days" — a rolling window ending today.
        if let match = firstMatch(in: text, #"\b(?:last|past|previous)\s+"# + countPattern + #"\s+(day|week|month|year)s?\b"#),
           let n = count(match[1]), let unit = component(named: match[2]),
           let start = calendar.date(byAdding: unit, value: -n, to: now) {
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

    // MARK: - Pass 9: months and years

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
        // that to the date detector in pass 10 rather than guess here.
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

    // MARK: - Pass 10: iOS's date detector, for anything with specific days

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

    /// A count written as digits or words ("3", "three", "a", "a couple of").
    /// Longest alternatives first, so "a couple of" isn't read as just "a".
    private static var countPattern: String {
        let words = (numberWords.keys + ["an", "a"]).sorted { $0.count > $1.count }
        return #"(\d{1,3}|"# + words.joined(separator: "|") + ")"
    }

    private static func count(_ text: String) -> Int? {
        Int(text) ?? numberWords[text] ?? (text == "a" || text == "an" ? 1 : nil)
    }

    /// The first 4-digit year (1900–2099) anywhere in the text.
    private static func yearMentioned(in text: String) -> Int? {
        firstMatch(in: text, #"\b((?:19|20)\d{2})\b"#).flatMap { Int($0[1]) }
    }

    /// The most recent year in which this month (and day, if given) has
    /// already started — "October" typed in September 2026 means 2025.
    private static func mostRecentYear(forMonth month: Int, day: Int = 1, now: Date, calendar: Calendar) -> Int {
        let thisYear = calendar.component(.year, from: now)
        guard let thisYears = calendar.date(from: DateComponents(year: thisYear, month: month, day: day)) else { return thisYear }
        return thisYears > now ? thisYear - 1 : thisYear
    }

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
