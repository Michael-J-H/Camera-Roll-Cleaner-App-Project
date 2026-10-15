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
/// **It refuses rather than guesses.** Anything it can't place returns nil,
/// and the chat says it couldn't pick out a date. In particular: words that
/// are only sometimes dates ("may", "march", "fall", "spring") count only
/// where a date makes sense; iOS's detector is only trusted with full
/// numeric dates (left alone, it reads "Sunday", "tomorrow" or "3pm" as
/// dates); and a period that hasn't started yet is refused, since there
/// can't be photos from it.
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
    enum Reading: Equatable {
        case range(DateInterval)
        /// Two sensible readings — the chat asks which one was meant
        /// ("last Tuesday" mid-week; "winter 2024").
        case either(DateInterval, DateInterval)
        /// A broad period plus words it didn't understand ("my birthday in
        /// 2024") — the period is only a fallback, so the chat asks rather
        /// than quietly scanning the whole year.
        case unsure(DateInterval)
        /// A vague amount ("a few Tuesdays ago", "a while ago") — the chat
        /// asks how far back rather than picking a number.
        case vague
        case notUnderstood
    }

    /// - Parameter current: The range already being discussed, if any —
    ///   needed for "a week earlier" and the like.
    static func reading(of input: String, current: DateInterval? = nil, now: Date = .now, calendar: Calendar = .current) -> Reading {
        var scan = Scan(fixingMonthTypos(in: input.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")))
        dropAmbiguousWords(&scan)

        if scan.peek(#"\b(?:a few|several|some|some time|sometime|a while|a bit|a little while)\s+(?:(?:days?|weeks?|months?|years?|"# + weekdayNames + #")s?\s+)?ago\b"#) != nil {
            return .vague
        }

        // Only periods that have already started — there can't be photos
        // from the future.
        let (readings, onlyBroad) = read(&scan, current: current, calendar: calendar, now: now)
        var options: [DateInterval] = []
        for option in readings where option.start <= now && !options.contains(option) {
            options.append(option)
        }
        switch options.count {
        case 0: return .notUnderstood
        case 1:
            // Only a lone month, season or year was given, alongside words it
            // didn't understand ("my birthday in 2024") — the period is just
            // a backdrop for something it can't place, so ask. Specific dates
            // ("Let's search Sep 26 to Oct 4 2025") never ask, whatever
            // other words are around them.
            return onlyBroad && !unknownWords(in: scan.text).isEmpty ? .unsure(options[0]) : .range(options[0])
        default: return .either(options[0], options[1])
        }
    }

    /// Everyday words that don't change the meaning of a date request —
    /// "show me photos from …", and conversational corrections like "sorry,
    /// I meant …" or "actually, make it …". Anything else left over after
    /// reading the dates is something the parser didn't understand.
    private static let fillerWords: Set<String> = [
        "browse", "get", "pull", "review", "search", "searching", "through", "up",
        "actually", "ah", "change", "do", "go", "hm", "hmm", "how", "instead", "it's", "let", "make",
        "mean", "meant", "no", "nope", "oh", "ok", "okay", "oops", "rather", "right", "should", "so",
        "sorry", "switch", "than", "then", "typo", "uh", "um", "wait", "we", "well", "what", "yes", "yeah",
        "a", "about", "all", "an", "and", "any", "around", "at", "be", "between", "can", "check", "clean",
        "cleanup", "could", "date", "dates", "did", "do", "duplicate", "duplicates", "during", "entire",
        "everything", "find", "for", "from", "full", "go", "i", "i'd", "i'm", "images", "in", "is", "it",
        "just", "let's", "lets", "like", "look", "looking", "me", "my", "of", "on", "only", "our", "period",
        "photo", "photos", "pic", "pics", "picture", "pictures", "please", "range", "scan", "see", "shots",
        "show", "some", "taken", "that", "the", "these", "this", "those", "time", "to", "try", "up", "use",
        "videos", "want", "was", "were", "whole", "with", "would", "year", "you",
    ]

    private static func unknownWords(in leftover: String) -> [String] {
        leftover.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { $0.count > 1 && !fillerWords.contains($0) }
    }

    /// One reading, or two when a mention could fairly mean either — plus
    /// whether the only date information was a lone month, season or year.
    private static func read(_ scan: inout Scan, current: DateInterval?, calendar: Calendar, now: Date) -> ([DateInterval], onlyBroad: Bool) {
        if let current, let shifted = shift(scan, current: current, calendar: calendar) {
            return ([shifted], false)
        }

        let modifier = takeModifier(&scan)
        let textWithoutModifier = scan.text
        let mentions = takeMentions(&scan, now: now, calendar: calendar)

        // Leftover digits mean something was written that the rules above
        // don't recognize (most often a numbers-only date like "10/1/2025")
        // — let iOS's date detector read it instead of guessing.
        var bases: [DateInterval?]
        if !mentions.isEmpty, !scan.hasLeftoverDigits {
            bases = [combine(mentions, calendar: calendar)]
            // An ambiguous mention gives a second reading, built the same way.
            if let i = mentions.firstIndex(where: { $0.alternativeYear != nil || $0.alternative != nil }) {
                var other = mentions
                if let year = other[i].alternativeYear { other[i].year = year }
                if let interval = other[i].alternative { other[i].kind = .fixed(interval) }
                bases.append(combine(other, calendar: calendar))
            }
        } else {
            bases = [detectedDates(in: textWithoutModifier, calendar: calendar)]
        }

        let readings = bases.compactMap { base -> DateInterval? in
            guard let base else { return nil }
            guard let modifier else { return base }
            return apply(modifier, to: base, calendar: calendar)
        }
        let onlyBroad = modifier == nil && mentions.count == 1 && mentions[0].isBroad
        return (readings, onlyBroad)
    }

    // MARK: - Misspelled months

    private static let monthNames = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Rewrites a misspelled month ("septemebr 26", "octobr 2025") to the
    /// real name — but only where a date is obviously meant: the word must
    /// be directly followed by a day number or year, and be within one
    /// typo of a month name (two for longer words; swapped letters count
    /// as one) or start with a month's first three letters. Careful with
    /// March and May, which are also everyday words ("match 3", "mark 3"
    /// and "maybe 2025" stay as they are), and "member 2" never becomes
    /// "December". Without this, an unrecognized "26" left
    /// over from a misspelled month made the whole message unreadable.
    private static func fixingMonthTypos(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b([a-z]{4,})\.?(?=\s*,?\s*\d)"#) else { return text }
        var result = text as NSString
        // Back to front, so earlier positions stay valid after replacements.
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let range = match.range(at: 1)
            let word = result.substring(with: range)
            // Already a month (or accepted short form like "sept")? Leave it.
            guard word.range(of: "^" + monthPattern + "$", options: .regularExpression) == nil else { continue }
            if let month = closeMonth(to: word) ?? monthByFirstThreeLetters(word) {
                result = result.replacingCharacters(in: range, with: month) as NSString
            }
        }
        return result as String
    }

    /// Within one typo of a month name (two for longer words). Never March
    /// — "match", "marsh" are everyday words a letter away.
    private static func closeMonth(to word: String) -> String? {
        let allowed = word.count >= 7 ? 2 : 1
        let close = monthNames.filter { $0.count >= 4 && $0 != "march" && typoDistance(word, $0) <= allowed }
        let best = close.min { typoDistance(word, $0) < typoDistance(word, $1) }
        // Two months equally close: too unclear to pick one.
        guard let best, close.filter({ typoDistance(word, $0) == typoDistance(word, best) }).count == 1 else { return nil }
        return best
    }

    /// Bigger typos ("septmbre", "octbr"): no two months share their first
    /// three letters, so those identify the month. Except "mar" and "may",
    /// which start everyday words ("mark", "maybe") — those must still be
    /// within one typo of March or May ("marhc" yes, "mark" no).
    private static func monthByFirstThreeLetters(_ word: String) -> String? {
        guard let month = monthNames.first(where: { word.hasPrefix($0.prefix(3)) }) else { return nil }
        if month == "march" || month == "may" {
            return typoDistance(word, month) <= 1 ? month : nil
        }
        return month
    }

    /// How many single-letter changes (add, remove, replace, or swap two
    /// neighbours) turn one word into the other.
    private static func typoDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in stride(from: 1, through: a.count, by: 1) {
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    // MARK: - Words that are only sometimes dates

    /// "May", "March", "fall" and "spring" are also ordinary words ("may I
    /// see…", "march of the penguins", "fall photos"). They only count as
    /// dates when something around them says so: a day or year next to them
    /// ("May 2025", "March 3"), a date word before them ("in May", "this
    /// fall", "first week of March"), a range ("May to July"), or being the
    /// whole message ("May"). Otherwise they're blanked out before reading.
    private static func dropAmbiguousWords(_ scan: inout Scan) {
        let message = scan.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let datey = #"(?:in|of|during|from|since|until|till|through|thru|to|and|between|early|late|mid|this|last|before|after|around|-|–|—)\s+$"#
        var searchFrom = 0
        while let match = scan.peek(#"\b(may|march|mar|fall|spring)\b"#, from: searchFrom) {
            let word = match[1]
            let before = (scan.text as NSString).substring(to: match.location)
            let after = (scan.text as NSString).substring(from: match.location + (word as NSString).length)
            let keep = message == word
                || after.range(of: #"^\.?\s*,?\s*(?:of\s+)?\d"#, options: .regularExpression) != nil
                || after.range(of: #"^\s*(?:-|–|—|(?:to|through|thru|until|and)\b)"#, options: .regularExpression) != nil
                || before.range(of: datey, options: .regularExpression) != nil
            if keep {
                searchFrom = match.location + (word as NSString).length
            } else {
                scan.blank(at: match.location, length: (word as NSString).length)
            }
        }
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
        /// "the Tuesday before/after …"
        case adjacentWeekday(Int, before: Bool)
        /// "first Monday of …" (counted from 0; nil = last)
        case nthWeekday(Int?, weekday: Int)
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

        if let match = scan.take(#"\b(?:the\s+)?("# + weekdayNames + #")\s+(before|prior to|after|following)\s+"#),
           let weekday = weekdayNumber(match[1]) {
            return .adjacentWeekday(weekday, before: !["after", "following"].contains(match[2]))
        }
        if let match = scan.take(#"\b(first|1st|second|2nd|third|3rd|fourth|4th|last)\s+("# + weekdayNames + #")\s+"# + periodFollows),
           let weekday = weekdayNumber(match[2]) {
            return .nthWeekday(ordinals[match[1]], weekday: weekday)
        }

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

        case let .adjacentWeekday(weekday, before):
            var day = before ? days(-1, from: first) : days(1, from: last)
            while let d = day, calendar.component(.weekday, from: d) != weekday {
                day = days(before ? -1 : 1, from: d)
            }
            return day.map { .wholeDays(from: $0, through: $0, calendar: calendar) }

        case let .nthWeekday(index, weekday):
            var matches: [Date] = []
            var day: Date? = first
            while let d = day, d <= last {
                if calendar.component(.weekday, from: d) == weekday { matches.append(d) }
                day = days(1, from: d)
            }
            let found = index.map { $0 < matches.count ? matches[$0] : nil } ?? matches.last
            return found.map { .wholeDays(from: $0, through: $0, calendar: calendar) }

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
        /// A second fair reading, which makes the chat ask: "winter 2024"
        /// could be the winter starting or ending in 2024 (alternativeYear),
        /// and mid-week "last Tuesday" could be this week's or last week's
        /// (alternative).
        var alternativeYear: Int?
        var alternative: DateInterval?

        /// A whole month, season or year — the kind of period that's often
        /// just a backdrop for something more specific.
        var isBroad: Bool {
            switch kind {
            case .year, .month, .season: return true
            default: return false
            }
        }

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
            var season = Mention(kind: .season(startMonth: start), year: Int(match[2]), location: match.location)
            // Winter spans New Year, so "winter 2024" could be either side.
            if start == 12, let year = season.year { season.alternativeYear = year - 1 }
            mentions.append(season)
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

        // "2 Tuesdays ago" — counting back from the most recent Tuesday.
        if let match = scan.take(#"\b"# + countPattern + #"\s+("# + weekdayNames + #")s?\s+ago\b"#),
           let n = count(match[1]), let weekday = weekdayNumber(match[2]),
           let recent = mostRecent(weekday, before: now, calendar: calendar),
           let day = days(-7 * (n - 1), from: recent) {
            add(.wholeDays(from: day, through: day, calendar: calendar), at: match.location)
        }
        // "3 days ago" = that day; "2 weeks ago" = that calendar week; and so on.
        if let match = scan.take(#"\b"# + countPattern + #"\s+(days?|weeks?|months?|years?)\s+ago\b"#),
           let n = count(match[1]), let unit = component(named: match[2]),
           let then = calendar.date(byAdding: unit, value: -n, to: now) {
            add(unit == .day ? .wholeDays(from: then, through: then, calendar: calendar)
                             : calendar.dateInterval(of: unit, for: then), at: match.location)
        }
        // Weekdays. "Last Tuesday" mid-week could mean this week's or last
        // week's, so both are offered; "this past Tuesday" means the most
        // recent; "this Tuesday" is this week's; a bare "Tuesday" is the most
        // recent one, today included. "Next Tuesday" is in the future, so it's
        // read only to be refused.
        if let match = scan.take(#"\b(this past|past|previous|last|this|next|on)?\s*\b("# + weekdayNames + #")\b"#),
           let weekday = weekdayNumber(match[2]) {
            switch match[1] {
            case "next":
                let day = mostRecent(weekday, before: now, calendar: calendar).flatMap { days(14, from: $0) }
                add(day.map { .wholeDays(from: $0, through: $0, calendar: calendar) }, at: match.location)
            case "this":
                let todayWeekday = calendar.component(.weekday, from: now)
                let offset = (weekday - calendar.firstWeekday + 7) % 7 - (todayWeekday - calendar.firstWeekday + 7) % 7
                let day = days(offset, from: now)
                add(day.map { .wholeDays(from: $0, through: $0, calendar: calendar) }, at: match.location)
            case "last":
                if let recent = mostRecent(weekday, before: now, calendar: calendar) {
                    var mention = Mention(kind: .fixed(.wholeDays(from: recent, through: recent, calendar: calendar)), location: match.location)
                    if calendar.isDate(recent, equalTo: now, toGranularity: .weekOfYear), let weekEarlier = days(-7, from: recent) {
                        mention.alternative = .wholeDays(from: weekEarlier, through: weekEarlier, calendar: calendar)
                    }
                    found.append(mention)
                }
            case "this past", "past", "previous":
                add(mostRecent(weekday, before: now, calendar: calendar).map { .wholeDays(from: $0, through: $0, calendar: calendar) },
                    at: match.location)
            default:
                let day = calendar.component(.weekday, from: now) == weekday ? now : mostRecent(weekday, before: now, calendar: calendar)
                add(day.map { .wholeDays(from: $0, through: $0, calendar: calendar) }, at: match.location)
            }
        }

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
        if let match = scan.take(#"\b(this past|past|this|last|previous)\s+weekend\b"#) {
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
        // puts November after February, so step it back a year. (Dates
        // typed backwards — "October 4 to September 26 2025" — also land
        // here and read as a year-long range; left that way by choice for
        // now, see the brief's Decision Log.)
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

    /// Only full numeric dates (day, month and year: "10/1/2025",
    /// "1.10.2025") are accepted from the detector — left alone it also reads
    /// weekdays, "tomorrow" and times of day as dates, usually guessing
    /// forward in time. The detector hands back times of day (usually noon)
    /// rather than whole days, so the earliest and latest dates it found are
    /// widened to cover their full days.
    private static func detectedDates(in text: String, calendar: Calendar) -> DateInterval? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let spans = matches.compactMap { match -> (Date, Date)? in
            guard let range = Range(match.range, in: text),
                  text[range].range(of: #"\d{1,4}[/.\-]\d{1,2}[/.\-]\d{2,4}"#, options: .regularExpression) != nil,
                  let date = match.date else { return nil }
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

    private static let weekdayNames = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"

    /// iOS's numbering: Sunday = 1 … Saturday = 7.
    private static func weekdayNumber(_ name: String) -> Int? {
        ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7][name]
    }

    /// The latest such weekday strictly before today.
    private static func mostRecent(_ weekday: Int, before now: Date, calendar: Calendar) -> Date? {
        var day = calendar.date(byAdding: .day, value: -1, to: now)
        while let d = day, calendar.component(.weekday, from: d) != weekday {
            day = calendar.date(byAdding: .day, value: -1, to: d)
        }
        return day
    }

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

    /// Finds the first match (at or after `from`) without removing it.
    func peek(_ pattern: String, from start: Int = 0) -> Match? {
        let nsText = text as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(location: start, length: nsText.length - start)) else { return nil }
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
        blank(at: match.location, length: (match[0] as NSString).length)
        return match
    }

    mutating func blank(at location: Int, length: Int) {
        text = (text as NSString).replacingCharacters(
            in: NSRange(location: location, length: length),
            with: String(repeating: " ", count: length))
    }

    var hasLeftoverDigits: Bool { text.range(of: #"\d"#, options: .regularExpression) != nil }
}
