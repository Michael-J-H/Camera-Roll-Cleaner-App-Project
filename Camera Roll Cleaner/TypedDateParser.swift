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

    /// The final day in the range (`end` itself is midnight after it).
    var lastDay: Date { end.addingTimeInterval(-1) }
}

/// Turns free-typed text into a date range. Runs entirely on-device, costs
/// nothing, and gives the same answer every time.
///
/// It reads a date the way a person does, from broad to narrow. First it
/// picks out the pieces:
///
/// - **Moments and periods** ("mentions"): a year, a month, a season, a
///   holiday, a specific day, a run of days ("Oct 1–4"), or a period
///   relative to today ("last month", "past two weeks").
/// - **At most one modifier** wrapped around them: "two weeks before …",
///   "first 10 days of …", "second weekend of …", "week of …".
///
/// Then it combines them: a year only says which year the narrower pieces
/// are in ("Easter 2024" = Easter *in* 2024, not all of 2024); the narrowest
/// pieces define the period; several of them make a range ("October to
/// December 2025"); and the modifier is applied last ("first two weeks of"
/// + "March 2025" = Mar 1–14, 2025). Because pieces combine freely,
/// combinations nobody wrote a rule for still work — "first weekend of
/// summer 2024", "the week after Easter 2025".
///
/// Dates written with numbers only ("10/1/2025") are left to iOS's built-in
/// date detector, which follows the phone's region settings for day/month
/// order.
///
/// This is a fixed set of rules, not real language understanding. Apple's
/// on-device AI model was tried for that and removed — see the Decision Log
/// in PROJECT_BRIEF.md. Whatever comes out, the chat reads it back for
/// confirmation before scanning, so a misread costs nothing.
///
/// Conventions (all visible in that confirmation): a weekend is Sat–Sun;
/// "first week of October" is Oct 1–7; "week of Nov 5" is the calendar week
/// containing it; "two weeks before Christmas" is Dec 11–24; winter 2024 is
/// Dec 2024 – Feb 2025; no year given means the most recent one that has
/// already started.
enum TypedDateParser {
    /// - Parameter current: The range already being discussed, if any —
    ///   needed for "a week earlier" and the like.
    static func parse(_ input: String, current: DateInterval? = nil, now: Date = .now, calendar: Calendar = .current) -> DateInterval? {
        var scan = Scan(input.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))

        if let current, let shifted = shift(scan, current: current, calendar: calendar) {
            return shifted
        }

        let modifier = takeModifier(&scan)
        let textWithoutModifier = scan.text
        let mentions = takeMentions(&scan, now: now, calendar: calendar)

        // Leftover digits mean something was written that the rules above
        // don't recognize (most often a numbers-only date like "10/1/2025")
        // — let iOS's date detector read it instead of guessing.
        let base: DateInterval?
        if !mentions.isEmpty, !scan.hasLeftoverDigits {
            base = combine(mentions, calendar: calendar)
        } else {
            base = detectedDates(in: textWithoutModifier, calendar: calendar)
        }

        guard let base else { return nil }
        guard let modifier else { return base }
        return apply(modifier, to: base, calendar: calendar)
    }

    // MARK: - Moving the current range ("a week earlier")

    private static func shift(_ scan: Scan, current: DateInterval, calendar: Calendar) -> DateInterval? {
        let unit = #"(day|week|month|year)s?"#
        let amount: Int
        let component: Calendar.Component
        let direction: String
        if let match = scan.peek(#"\b"# + countPattern + #"\s+"# + unit + #"\s+(earlier|later|sooner|back|forward)\b"#),
           let n = count(match[1]), let c = Self.component(named: match[2]) {
            (amount, component, direction) = (n, c, match[3])
        } else if let match = scan.peek(#"\b(earlier|later|back|forward)\s+(?:by\s+)?"# + countPattern + #"\s+"# + unit + #"\b"#),
                  let n = count(match[2]), let c = Self.component(named: match[3]) {
            (amount, component, direction) = (n, c, match[1])
        } else {
            return nil
        }
        let sign = ["earlier", "sooner", "back"].contains(direction) ? -1 : 1
        guard let start = calendar.date(byAdding: component, value: sign * amount, to: current.start),
              let end = calendar.date(byAdding: component, value: sign * amount, to: current.lastDay) else { return nil }
        return .wholeDays(from: start, through: end, calendar: calendar)
    }

    // MARK: - The modifier

    private enum Modifier {
        /// "two weeks before …", "3 days after …", "a week around …"
        case offset(amount: Int, unit: Calendar.Component, direction: Direction)
        /// "the weekend before/after …"
        case adjacentWeekend(before: Bool)
        /// "first two weeks of …", "last 10 days of …", "first month of …"
        case span(fromStart: Bool, amount: Int, unit: Calendar.Component)
        /// "second week of …" (counted from 0)
        case nthWeek(Int)
        /// "first/last weekend of …" (counted from 0; nil = last)
        case nthWeekend(Int?)
        case weekOf
        case weekendOf
    }

    private enum Direction { case before, after, around }

    /// What has to follow "first/last …" for it to mean part of a period —
    /// so "last week of March" is read as part of March, while "last week"
    /// on its own is left to mean the previous week.
    private static var periodFollows: String {
        #"(?:(?:of|in)\s+|(?=(?:the\s+)?(?:"# + monthPattern + "|" + seasonNames + "|" + holidayNames
            + #"|(?:19|20)\d{2}|this\s|last\s)))"#
    }

    private static func takeModifier(_ scan: inout Scan) -> Modifier? {
        let ordinals = ["first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2, "fourth": 3, "4th": 3]

        if let match = scan.take(#"\b(?:the\s+)?(?:"# + countPattern + #"\s+)?(days?|weeks?|months?|years?|weekend)\s+(before|prior to|leading up to|after|following|around)\s+"#) {
            let direction: Direction = match[3] == "around" ? .around : (["after", "following"].contains(match[3]) ? .after : .before)
            if match[2] == "weekend" {
                return direction == .around ? .weekendOf : .adjacentWeekend(before: direction == .before)
            }
            guard let unit = component(named: match[2]) else { return nil }
            return .offset(amount: count(match[1]) ?? 1, unit: unit, direction: direction)
        }
        if let match = scan.take(#"\b(first|last)\s+(?:"# + countPattern + #"\s+)?(days?|weeks?|months?)\s+"# + periodFollows),
           let unit = component(named: match[3]) {
            return .span(fromStart: match[1] == "first", amount: count(match[2]) ?? 1, unit: unit)
        }
        if let match = scan.take(#"\b(second|2nd|third|3rd|fourth|4th)\s+week\s+"# + periodFollows), let index = ordinals[match[1]] {
            return .nthWeek(index)
        }
        if let match = scan.take(#"\b(first|1st|second|2nd|third|3rd|fourth|4th|last)\s+weekend\s+"# + periodFollows) {
            return .nthWeekend(ordinals[match[1]])
        }
        if let match = scan.take(#"\b(week|weekend)\s+of\s+"#) {
            return match[1] == "week" ? .weekOf : .weekendOf
        }
        return nil
    }

    private static func apply(_ modifier: Modifier, to base: DateInterval, calendar: Calendar) -> DateInterval? {
        let first = base.start
        let last = base.lastDay
        func days(_ n: Int, from date: Date) -> Date? { calendar.date(byAdding: .day, value: n, to: date) }

        switch modifier {
        case let .offset(amount, unit, .before):
            // "Two weeks before Christmas" = the 14 days up to Christmas Eve.
            guard let end = days(-1, from: first),
                  let start = calendar.date(byAdding: unit, value: -amount, to: first) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)

        case let .offset(amount, unit, .after):
            guard let start = days(1, from: last),
                  let end = calendar.date(byAdding: unit, value: amount, to: last) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)

        case let .offset(amount, unit, .around):
            // Centered on the day.
            guard let spanEnd = calendar.date(byAdding: unit, value: amount, to: first) else { return nil }
            let length = max(calendar.dateComponents([.day], from: first, to: spanEnd).day ?? 1, 1)
            guard let start = days(-(length / 2), from: first),
                  let end = days(length - 1, from: start) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)

        case let .adjacentWeekend(before):
            // The nearest Sat–Sun entirely before (or after) the period.
            var day = before ? days(-1, from: first) : days(1, from: last)
            let wanted = before ? 1 : 7 // Sunday when walking back, Saturday walking forward
            while let d = day, calendar.component(.weekday, from: d) != wanted {
                day = days(before ? -1 : 1, from: d)
            }
            guard let found = day, let saturday = before ? days(-1, from: found) : found,
                  let sunday = days(1, from: saturday) else { return nil }
            return .wholeDays(from: saturday, through: sunday, calendar: calendar)

        case let .span(fromStart, amount, unit):
            if fromStart {
                guard let afterEnd = calendar.date(byAdding: unit, value: amount, to: first),
                      let end = days(-1, from: afterEnd) else { return nil }
                return .wholeDays(from: first, through: min(end, last), calendar: calendar)
            }
            guard let dayAfterLast = days(1, from: last),
                  let start = calendar.date(byAdding: unit, value: -amount, to: dayAfterLast) else { return nil }
            return .wholeDays(from: max(start, first), through: last, calendar: calendar)

        case let .nthWeek(index):
            guard let start = days(index * 7, from: first), start <= last,
                  let end = days(6, from: start) else { return nil }
            return .wholeDays(from: start, through: min(end, last), calendar: calendar)

        case let .nthWeekend(index):
            var saturdays: [Date] = []
            var day: Date? = first
            while let d = day, d <= last {
                if calendar.component(.weekday, from: d) == 7 { saturdays.append(d) }
                day = days(1, from: d)
            }
            let saturday = index.map { $0 < saturdays.count ? saturdays[$0] : nil } ?? saturdays.last
            guard let saturday, let sunday = days(1, from: saturday) else { return nil }
            return .wholeDays(from: saturday, through: sunday, calendar: calendar)

        case .weekOf:
            // The calendar week containing the day, starting on whatever day
            // the phone's region settings use (Monday in most of Europe).
            return calendar.dateInterval(of: .weekOfYear, for: first)

        case .weekendOf:
            // A weekend day means its own weekend; a weekday, the next one.
            let weekday = calendar.component(.weekday, from: first)
            guard let saturday = days(weekday == 1 ? -1 : 7 - weekday, from: first),
                  let sunday = days(1, from: saturday) else { return nil }
            return .wholeDays(from: saturday, through: sunday, calendar: calendar)
        }
    }

    // MARK: - The moments and periods mentioned

    private struct Mention {
        enum Kind {
            case year
            case month(Int)
            case season(startMonth: Int)
            case holiday(String)
            case day(month: Int, day: Int)
            case days(month: Int, from: Int, to: Int)
            /// Already a definite period — "last month", "past two weeks".
            case fixed(DateInterval)
        }
        var kind: Kind
        var year: Int?
        let location: Int
        var yearCameFromLaterMention = false

        var needsYear: Bool {
            switch kind {
            case .year, .fixed: return false
            default: return true
            }
        }
    }

    /// Picks the pieces out of the text, most specific first, blanking each
    /// one out as it's found so it can't be read twice (the "4" and "2025"
    /// in "Oct 1-4, 2025" aren't also read as a day and a year on their own).
    private static func takeMentions(_ scan: inout Scan, now: Date, calendar: Calendar) -> [Mention] {
        var mentions = relativePeriods(&scan, now: now, calendar: calendar)
        let year = #"(?:\s*,?\s*((?:19|20)\d{2}))?"#
        let suffix = #"(?:st|nd|rd|th)?"#
        let through = #"\s*(?:-|–|—|to|through|thru|until)\s*"#

        while let match = scan.take(#"\b("# + holidayNames + #")\b"# + year) {
            mentions.append(Mention(kind: .holiday(match[1]), year: Int(match[2]), location: match.location))
        }
        // Runs of days: "Oct 1-4, 2025", "1-4 October 2025"
        while let match = scan.take(#"\b"# + monthPattern + #"\.?\s+(\d{1,2})"# + suffix + through + #"(\d{1,2})"# + suffix + #"\b"# + year),
              let month = monthNumber(match[1]), let from = Int(match[2]), let to = Int(match[3]) {
            mentions.append(Mention(kind: .days(month: month, from: from, to: to), year: Int(match[4]), location: match.location))
        }
        while let match = scan.take(#"\b(\d{1,2})"# + suffix + through + #"(\d{1,2})"# + suffix + #"\s+(?:of\s+)?"# + monthPattern + #"\b"# + year),
              let month = monthNumber(match[3]), let from = Int(match[1]), let to = Int(match[2]) {
            mentions.append(Mention(kind: .days(month: month, from: from, to: to), year: Int(match[4]), location: match.location))
        }
        // Single days: "Nov 5th, 2025", "5 November 2025"
        while let match = scan.take(#"\b"# + monthPattern + #"\.?\s+(\d{1,2})"# + suffix + #"\b"# + year),
              let month = monthNumber(match[1]), let day = Int(match[2]) {
            mentions.append(Mention(kind: .day(month: month, day: day), year: Int(match[3]), location: match.location))
        }
        while let match = scan.take(#"\b(\d{1,2})"# + suffix + #"\s+(?:of\s+)?"# + monthPattern + #"\b"# + year),
              let month = monthNumber(match[2]), let day = Int(match[1]) {
            mentions.append(Mention(kind: .day(month: month, day: day), year: Int(match[3]), location: match.location))
        }
        while let match = scan.take(#"\b("# + seasonNames + #")\b(?:\s+(?:of\s+)?((?:19|20)\d{2}))?"#) {
            let start = ["spring": 3, "summer": 6, "autumn": 9, "fall": 9, "winter": 12][match[1]] ?? 3
            mentions.append(Mention(kind: .season(startMonth: start), year: Int(match[2]), location: match.location))
        }
        while let match = scan.take(#"\b"# + monthPattern + #"\.?\b"# + year), let month = monthNumber(match[1]) {
            mentions.append(Mention(kind: .month(month), year: Int(match[2]), location: match.location))
        }

        // Years on their own. If anything narrower was mentioned they only
        // say which year it's in ("Easter 2024", "Nov 5th for the year
        // 2025"); otherwise they're the period themselves ("2025").
        var years: [Mention] = []
        while let match = scan.take(#"\b((?:19|20)\d{2})\b"#) {
            years.append(Mention(kind: .year, year: Int(match[1]), location: match.location))
        }
        let hasNarrower = mentions.contains { $0.needsYear }
        mentions = fillInYears(mentions.sorted { $0.location < $1.location },
                               standaloneYears: hasNarrower ? years : [], now: now, calendar: calendar)
        if !hasNarrower { mentions += years }
        return mentions.sorted { $0.location < $1.location }
    }

    /// "today", "yesterday", "this/last week|month|year", "this/last
    /// weekend", "past/last N days|weeks|…", "past week|month|year".
    private static func relativePeriods(_ scan: inout Scan, now: Date, calendar: Calendar) -> [Mention] {
        var found: [Mention] = []
        func add(_ interval: DateInterval?, at location: Int) {
            if let interval { found.append(Mention(kind: .fixed(interval), location: location)) }
        }
        func days(_ n: Int, from date: Date) -> Date? { calendar.date(byAdding: .day, value: n, to: date) }

        if let match = scan.take(#"\btoday\b"#) {
            add(.wholeDays(from: now, through: now, calendar: calendar), at: match.location)
        }
        if let match = scan.take(#"\byesterday\b"#), let yesterday = days(-1, from: now) {
            add(.wholeDays(from: yesterday, through: yesterday, calendar: calendar), at: match.location)
        }
        // "past 3 weeks" / "last ten days" — a rolling window ending today.
        if let match = scan.take(#"\b(?:last|past|previous)\s+"# + countPattern + #"\s+(days?|weeks?|months?|years?)\b"#),
           let n = count(match[1]), let unit = component(named: match[2]),
           let start = calendar.date(byAdding: unit, value: -n, to: now) {
            add(.wholeDays(from: start, through: now, calendar: calendar), at: match.location)
        }
        // "past week" (no number) — also rolling, since that's how people mean "past".
        if let match = scan.take(#"\bpast\s+(week|month|year)\b"#), let unit = component(named: match[1]),
           let start = calendar.date(byAdding: unit, value: -1, to: now) {
            add(.wholeDays(from: start, through: now, calendar: calendar), at: match.location)
        }
        // "this weekend" = Sat–Sun of this week; "last weekend" = the most
        // recent one that's over.
        if let match = scan.take(#"\b(this|last|previous)\s+weekend\b"#) {
            var sunday: Date?
            if match[1] == "this" {
                let weekday = calendar.component(.weekday, from: now)
                sunday = days(weekday == 1 ? 0 : 8 - weekday, from: now)
            } else {
                sunday = days(-1, from: now)
                while let d = sunday, calendar.component(.weekday, from: d) != 1 { sunday = days(-1, from: d) }
            }
            if let sunday, let saturday = days(-1, from: sunday) {
                add(.wholeDays(from: saturday, through: sunday, calendar: calendar), at: match.location)
            }
        }
        // "last month" / "this year" — a calendar period (all of September,
        // not "the 30 days before today").
        if let match = scan.take(#"\b(this|last|previous)\s+(week|month|year)\b"#),
           let unit = component(named: match[2]),
           let anchor = calendar.date(byAdding: unit, value: match[1] == "this" ? 0 : -1, to: now) {
            add(calendar.dateInterval(of: unit, for: anchor), at: match.location)
        }
        return found
    }

    /// Gives every mention that needs a year one: borrowed from the nearest
    /// later mention that has one ("October to December 2025" → October
    /// 2025), else the nearest earlier one, else the most recent year in
    /// which it has already started — nobody has photos from next Christmas.
    private static func fillInYears(_ mentions: [Mention], standaloneYears: [Mention], now: Date, calendar: Calendar) -> [Mention] {
        var result = mentions
        let donors = (mentions.filter { $0.year != nil } + standaloneYears).sorted { $0.location < $1.location }

        for i in result.indices where result[i].needsYear && result[i].year == nil {
            if let later = donors.first(where: { $0.location > result[i].location }) {
                result[i].year = later.year
                result[i].yearCameFromLaterMention = true
            } else if let earlier = donors.last(where: { $0.location < result[i].location }) {
                result[i].year = earlier.year
            } else {
                let thisYear = calendar.component(.year, from: now)
                var candidate = result[i]
                candidate.year = thisYear
                let started = interval(for: candidate, calendar: calendar).map { $0.start <= now } ?? true
                result[i].year = started ? thisYear : thisYear - 1
            }
        }

        // "November to February 2026" wraps over New Year: the borrowed 2026
        // puts November after February, so step it back a year.
        for i in result.indices.dropLast() where result[i].yearCameFromLaterMention {
            if let this = interval(for: result[i], calendar: calendar),
               let next = interval(for: result[i + 1], calendar: calendar), this.start > next.start {
                result[i].year? -= 1
            }
        }
        return result
    }

    private static func interval(for mention: Mention, calendar: Calendar) -> DateInterval? {
        if case let .fixed(interval) = mention.kind { return interval }
        guard let year = mention.year else { return nil }
        func date(_ month: Int, _ day: Int) -> Date? {
            let components = DateComponents(year: year, month: month, day: day)
            // Reject impossible dates like Feb 30 instead of rolling into March.
            return components.isValidDate(in: calendar) ? calendar.date(from: components) : nil
        }
        func oneDay(_ date: Date?) -> DateInterval? { date.map { .wholeDays(from: $0, through: $0, calendar: calendar) } }

        switch mention.kind {
        case .year:
            return date(1, 1).flatMap { calendar.dateInterval(of: .year, for: $0) }
        case let .month(month):
            return date(month, 1).flatMap { calendar.dateInterval(of: .month, for: $0) }
        case let .season(startMonth):
            // Spring = Mar–May, summer = Jun–Aug, autumn = Sep–Nov, winter =
            // Dec through Feb of the following year.
            guard let start = date(startMonth, 1),
                  let next = calendar.date(byAdding: .month, value: 3, to: start),
                  let end = calendar.date(byAdding: .day, value: -1, to: next) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)
        case let .holiday(name):
            return oneDay(holidayDate(name, year: year, calendar: calendar))
        case let .day(month, day):
            return oneDay(date(month, day))
        case let .days(month, from, to):
            guard let start = date(month, from), let end = date(month, to) else { return nil }
            return .wholeDays(from: start, through: end, calendar: calendar)
        case .fixed:
            return nil
        }
    }

    /// One mention is the period; several make a range from the earliest
    /// start to the latest end ("Sep 26 and Oct 4 2025", "2024 to 2025").
    private static func combine(_ mentions: [Mention], calendar: Calendar) -> DateInterval? {
        let intervals = mentions.compactMap { interval(for: $0, calendar: calendar) }
        guard intervals.count == mentions.count,
              let start = intervals.map(\.start).min(), let end = intervals.map(\.end).max() else { return nil }
        return DateInterval(start: start, end: end)
    }

    // MARK: - Numbers-only dates, via iOS's date detector

    /// The detector hands back times of day (usually noon) rather than whole
    /// days, so the earliest and latest dates it found are widened to cover
    /// their full days.
    private static func detectedDates(in text: String, calendar: Calendar) -> DateInterval? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let spans = matches.compactMap { match -> (Date, Date)? in
            guard let date = match.date else { return nil }
            return (date, date.addingTimeInterval(max(match.duration, 0)))
        }
        guard let first = spans.map(\.0).min(), let last = spans.map(\.1).max() else { return nil }
        return .wholeDays(from: first, through: last, calendar: calendar)
    }

    // MARK: - Holidays

    private static let holidayNames =
        #"christmas eve|christmas|xmas|new year'?s eve|new year'?s day|new year'?s|new year|halloween|valentine'?s day|valentine'?s|easter|thanksgiving"#

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

    // MARK: - Words and numbers

    private static let monthPattern =
        #"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#

    private static let seasonNames = "spring|summer|autumn|fall|winter"

    private static func monthNumber(_ name: String) -> Int? {
        ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
         "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12][String(name.prefix(3))]
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "a couple of": 2, "a couple": 2, "a few": 3
    ]

    /// A count written as digits or words ("3", "three", "a", "a couple of").
    /// Longest alternatives first, so "a couple of" isn't read as just "a".
    private static var countPattern: String {
        let words = (numberWords.keys + ["an", "a"]).sorted { $0.count > $1.count }
        return #"(\d{1,3}|"# + words.joined(separator: "|") + ")"
    }

    private static func count(_ text: String) -> Int? {
        Int(text) ?? numberWords[text] ?? (text == "a" || text == "an" ? 1 : nil)
    }

    /// "day"/"days" → .day, and so on.
    private static func component(named name: String) -> Calendar.Component? {
        switch name.hasSuffix("s") ? String(name.dropLast()) : name {
        case "day": return .day
        case "week": return .weekOfYear
        case "month": return .month
        case "year": return .year
        default: return nil
        }
    }
}

/// The text being read, with each recognized piece blanked out as it's
/// taken — so later rules only see what's left, and anything left at the
/// end shows what wasn't understood.
private struct Scan {
    private(set) var text: String

    init(_ text: String) { self.text = text }

    struct Match {
        let groups: [String]
        let location: Int
        subscript(i: Int) -> String { groups[i] }
    }

    /// Finds the first match without removing it.
    func peek(_ pattern: String) -> Match? {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) else { return nil }
        let groups = (0..<match.numberOfRanges).map { i -> String in
            let range = match.range(at: i)
            return range.location == NSNotFound ? "" : nsText.substring(with: range)
        }
        return Match(groups: groups, location: match.range.location)
    }

    /// Finds the first match and blanks it out — same length, so everything
    /// else keeps its position (used to keep mentions in the order typed).
    mutating func take(_ pattern: String) -> Match? {
        guard let match = peek(pattern) else { return nil }
        let length = (match[0] as NSString).length
        text = (text as NSString).replacingCharacters(
            in: NSRange(location: match.location, length: length),
            with: String(repeating: " ", count: length))
        return match
    }

    var hasLeftoverDigits: Bool { text.range(of: #"\d"#, options: .regularExpression) != nil }
}
