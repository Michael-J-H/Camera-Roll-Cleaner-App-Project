// Fixed list of typed date phrases with known-correct answers, for checking
// TypedDateParser after any change. Not part of the app. Run ./check.sh from
// this folder; it prints nothing but "All phrases match" if nothing changed.
// "Today" is pinned to Oct 11, 2026 so answers never drift.

import Foundation

let cal = Calendar.current
let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!
let f = DateIntervalFormatter(); f.dateStyle = .medium; f.timeStyle = .none
f.locale = Locale(identifier: "en_GB")
let oct14 = DateInterval.wholeDays(from: cal.date(from: DateComponents(year: 2025, month: 10, day: 1))!, through: cal.date(from: DateComponents(year: 2025, month: 10, day: 4))!)
let cases: [(String, DateInterval?)] = [
 ("Two weeks before Christmas 2025", nil), ("The two weeks before christmas 2025", nil),
 ("Two weeks before December 25 2025", nil), ("The two weeks before December 25 2025", nil),
 ("two weeks before christmas", nil), ("a week before Easter 2025", nil),
 ("the 3 days after New Year's 2025", nil), ("3 days after new years 2025", nil),
 ("a week around Nov 5th 2025", nil), ("10 days before 5 November 2025", nil),
 ("First weekend october 2024", nil), ("first weekend of October 2024", nil), ("last weekend of March 2025", nil),
 ("second week of June 2025", nil), ("last week of February 2024", nil), ("first week of october", nil),
 ("My birthday, week of november 5th for the year 2025", nil), ("week of Christmas 2025", nil),
 ("summer 2024", nil), ("winter 2024", nil), ("winter", nil), ("fall 2025", nil), ("this summer", nil),
 ("a week earlier", oct14), ("a month later", oct14), ("move it back 3 days", oct14), ("two weeks later", oct14), ("a week earlier", nil),
 ("Easter 2024", nil), ("easter", nil), ("Christmas Eve 2025", nil), ("christmas", nil), ("Halloween 2024", nil), ("Thanksgiving 2025", nil),
 ("The first two weeks of October 2025", nil), ("first 2 weeks of october 2025", nil), ("last 10 days of March 2025", nil), ("last ten days of march", nil),
 ("first three months of 2025", nil), ("last 2 months of 2024", nil), ("first week of October 2025", nil), ("last week of March", nil),
 // regressions
 ("October 2025", nil), ("Sep 2025 - Oct 2025", nil), ("October - December 2025", nil), ("from october to december 2025", nil),
 ("Nov to Feb 2026", nil), ("2025", nil), ("October", nil),
 ("last month", nil), ("this year", nil), ("last week", nil), ("past two weeks", nil), ("past 2 weeks", nil), ("last 10 days", nil),
 ("past a few months", nil), ("today", nil), ("yesterday", nil),
 ("Oct 1 to Oct 4, 2025", nil), ("Oct 1-4 2025", nil), ("between Sept 26 and Oct 4 2025", nil), ("Oct 3 2025", nil),
 ("hello", nil), ("my France trip", nil),
]
let combinations: [String] = ["first weekend of summer 2024", "the week after Easter 2025", "the weekend before Christmas 2025", "the weekend after Easter 2024",
 "first two weeks of summer 2025", "last week of winter 2024", "first 10 days of last month", "second week of last month",
 "the week before Halloween 2025", "3 days around new year's eve 2024", "weekend of July 4th 2025", "week of 5 November 2025",
 "Oct 1-4 2025", "1-4 October 2025", "Sep 26 - Oct 4, 2025", "Christmas Eve to New Year's 2025",
 "Easter to Christmas 2025", "first month of 2025", "last 3 months of 2025", "the day after Thanksgiving 2025",
 "may 2024", "10/1/2025", "two weeks before 12/25/2025", "last weekend", "this weekend", "the weekend before", "march 32 2025",]

// Things it must refuse ("not understood") rather than guess at, plus the
// legitimate uses of words that are only sometimes dates.
let refusals: [String] = [
 "my birthday", "on my birthday", "photos from my birthday", "my wedding", "when we went to Paris",
 "a while ago", "recently", "march of the penguins", "may I see the photos", "fall photos", "spring cleaning",
 "the 5th", "Sunday", "last Tuesday", "next week", "tomorrow", "around 3pm", "at 10.30", "weekend", "a week",
 "Christmas 2026", "the 3 days after New Year's 2027",
 "may", "in may", "May to July 2025", "march 3", "first week of march", "this fall", "fall 2025", "spring 2024",
 "my kid's birthday party in may", "my birthday is november 5", "1.10.2025",
]

// Weekdays, "… ago", and things it should ask about. (Pinned "today",
// Oct 11 2026, is a Sunday.)
let weekdays: [String] = [
 "this past Tuesday", "past Tuesday", "on Tuesday", "Tuesday", "Saturday", "this Tuesday", "this Saturday", "next Tuesday",
 "last Monday", "2 Tuesdays ago", "three Fridays ago", "a few Tuesdays ago", "several weeks ago", "some time ago",
 "3 days ago", "2 weeks ago", "a month ago", "a year ago", "a couple of weeks ago",
 "the Tuesday before Christmas 2025", "the Saturday after Easter 2024", "first Monday of March 2025",
 "last Friday of October 2025", "My birthday in 2024", "summer vacation", "my kid's birthday party in may", "photos from October 2025", "show me pictures from last month", "Our trip in March 2025", "my birthday, week of november 5th for the year 2025", "duplicates from the whole year 2025", "second Sunday of May 2025", "this past weekend", "winter", "winter 2025",
]

for (t, c) in cases + (combinations + refusals + weekdays).map({ ($0, nil) }) {
  func show(_ r: DateInterval) -> String { f.string(from: r.start, to: r.end.addingTimeInterval(-1)) }
  let res: String
  switch TypedDateParser.reading(of: t, current: c, now: now, calendar: cal) {
  case .range(let r): res = show(r)
  case .either(let a, let b): res = "ASKS: " + show(a) + "  OR  " + show(b)
  case .unsure(let r): res = "ASKS (unsure, offers): " + show(r)
  case .vague: res = "— (asks how far back)"
  case .notUnderstood: res = "— (not understood)"
  }
  print((t + (c == nil ? "" : "  [current: Oct 1–4 2025]")).padding(toLength: 56, withPad: " ", startingAt: 0), res)
}
