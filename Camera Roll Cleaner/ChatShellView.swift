//
//  ChatShellView.swift
//  Camera Roll Cleaner
//
//  Chat UI — guides the user through a greeting, picking a date range
//  (typed or via calendar), confirming it, running the real on-device
//  clustering engine, and showing a results summary. No AI involved yet —
//  that's a later checklist item (see PROJECT_BRIEF.md).
//

import Combine
import SwiftUI

// MARK: - Data model

/// A single message in the conversation. `.text` covers plain replies;
/// the other cases are the interactive steps of the guided date-range flow.
struct ChatMessage: Identifiable {
    enum Sender: Equatable {
        case user
        case assistant
    }

    enum Content {
        case text(String)
        case dateEntryChoice                                       // "type it or use my calendar?" buttons
        case datePicker                                             // "Open calendar" button (the calendar itself is a sheet)
        case confirmationChoice                                     // "want me to go ahead?" Yes / Change dates
        case rangeChoice([DateInterval])                            // "which did you mean?" one button per reading
        case clusterResults(ClusteringResult, dateRange: DateInterval) // row of one photo per duplicate set
    }

    let id = UUID()
    let sender: Sender
    let content: Content
    let timestamp: Date = Date()
}

// MARK: - Conversation state + logic — knows nothing about colors or shapes

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draftText: String = ""
    @Published private(set) var stage: ConversationStage = .awaitingDateEntryMethod
    @Published var isShowingCalendar = false
    /// The range most recently read back to the user, so a follow-up like
    /// "a week earlier" has something to adjust.
    private var currentRange: DateInterval?

    init() {
        showGreeting()
    }

    private func showGreeting() {
        append(.assistant, .text("""
        Looks like you're ready to clean up your camera roll. I can help you find \
        near-duplicate photos — like a burst of shots from the same moment — so you \
        can pick the one to keep and clear out the rest.

        To get started, what date range should I look at? You can type it — like \
        "Oct 1 to Oct 4, 2026", "October 2026", or "last month" — or pick it from a \
        calendar.
        """))
        append(.assistant, .dateEntryChoice)
    }

    // MARK: - User actions

    /// Called when the user taps "I'll type them" or "Use your calendar".
    func chooseDateEntry(useCalendar: Bool) {
        guard stage != .clustering else { return }
        if useCalendar {
            append(.assistant, .datePicker)
            openCalendar()
        } else {
            stage = .awaitingTypedDates
            append(.assistant, .text("Go ahead — something like \"Oct 1 to Oct 4, 2026\", \"October 2026\", or \"last month\" works."))
        }
    }

    /// Called when the user finishes picking dates in the calendar control.
    /// Also reachable from any earlier "Open calendar" bubble, so picking a
    /// new range after a scan works the same as picking the first one.
    func openCalendar() {
        guard stage != .clustering else { return }
        stage = .awaitingPickedDates
        isShowingCalendar = true
    }

    /// Ignored unless the chat is actually waiting on the calendar — every
    /// earlier calendar bubble stays on screen and tappable, and an old one
    /// shouldn't be able to restart things mid-scan.
    func submitPickedDates(_ interval: DateInterval) {
        guard stage == .awaitingPickedDates else { return }
        isShowingCalendar = false
        confirmDates(interval)
    }

    /// Called when the user taps one of the readings offered for an
    /// ambiguous request. Ignored unless the chat is still waiting on that
    /// choice, so an old set of buttons can't jump back in later.
    func chooseRange(_ interval: DateInterval) {
        guard case .choosingBetween(let options) = stage, options.contains(interval) else { return }
        confirmDates(interval)
    }

    /// Called when the user taps "Change dates" at the confirmation step.
    /// Re-shows the original choice rather than silently resetting, so the
    /// conversation reads as a normal back-and-forth, not a jump cut.
    func restartDateEntry() {
        stage = .awaitingDateEntryMethod
        append(.assistant, .text("No problem — let's try again."))
        append(.assistant, .dateEntryChoice)
    }

    func sendDraft() {
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        append(.user, .text(trimmed))
        draftText = ""
        handleTyped(trimmed)
    }

    /// Every stage gets a real response here, so typing at an unexpected
    /// moment (e.g. while the calendar is showing) still gets a sensible
    /// reply instead of silently doing nothing. Typing a new range at any
    /// point ("actually, November 2025") switches to it, just as it would in
    /// conversation — no need to find the "Change dates" button first.
    private func handleTyped(_ text: String) {
        if stage == .clustering {
            append(.assistant, .text("Still scanning — one moment."))
            return
        }
        if case .confirmingDates = stage, AffirmativeReply.matches(text) {
            Task { await confirmAndRunClustering() }
            return
        }
        if ChangeDatesRequest.matches(text) {
            restartDateEntry()
            return
        }

        // currentRange lets follow-ups like "a week earlier" adjust it.
        switch TypedDateParser.reading(of: text, current: currentRange) {
        case .range(let interval):
            confirmDates(interval)

        case .either(let first, let second):
            stage = .choosingBetween([first, second])
            append(.assistant, .text("\"\(text)\" could mean either of these — which did you mean?"))
            append(.assistant, .rangeChoice([first, second]))

        case .unsure(let interval):
            stage = .choosingBetween([interval])
            append(.assistant, .text("I'm not sure when \"\(text)\" was, so all I can go on is \(Self.describe(interval)). Want me to look at all of that, or tell me the exact dates?"))
            append(.assistant, .rangeChoice([interval]))

        case .vague:
            append(.assistant, .text("How far back? Give me a number — like \"3 Tuesdays ago\" or \"2 weeks ago\" — or a date, or tap below to use the calendar."))
            append(.assistant, .dateEntryChoice)
            stage = .awaitingDateEntryMethod

        case .notUnderstood:
            switch stage {
            case .confirmingDates:
                append(.assistant, .text("Just let me know — tap below, or type \"yes\" to go ahead. You can also type a different date range, or a change like \"a week earlier\"."))
            case .showingResults:
                append(.assistant, .text("That's everything from this scan. To look at a different stretch of time, just type a new date range — like \"November 2025\", \"last month\", or \"a week earlier\"."))
            default:
                append(.assistant, .text("I couldn't pick out a date there. Try something like \"Oct 1 to Oct 4, 2026\", \"October 2026\", or \"last month\" — or tap below to use the calendar instead."))
                append(.assistant, .dateEntryChoice)
                stage = .awaitingDateEntryMethod
            }
        }
    }

    // MARK: - Flow

    /// Always read the interpreted range back to the user before doing real
    /// work. Cheap, and it catches misread dates before scanning hundreds
    /// of photos.
    private func confirmDates(_ interval: DateInterval) {
        stage = .confirmingDates(interval)
        currentRange = interval
        let formatted = Self.describe(interval)
        append(.assistant, .text("Got it — I'm looking at \(formatted). Want me to go ahead?"))
        append(.assistant, .confirmationChoice)
    }

    func confirmAndRunClustering() async {
        guard case .confirmingDates(let interval) = stage else { return }
        stage = .clustering
        append(.assistant, .text("Scanning now — this can take a moment."))

        let result = await PhotoClusterEngine.run(in: interval)

        stage = .showingResults
        let formatted = Self.describe(interval)
        if result.duplicateClusters.isEmpty {
            append(.assistant, .text("I looked through \(result.totalScanned) photos from \(formatted) and didn't find any duplicates."))
        } else {
            append(.assistant, .text("""
            I looked through \(result.totalScanned) photos from \(formatted) and found \
            \(result.duplicateClusters.count) set\(result.duplicateClusters.count == 1 ? "" : "s") of duplicates. \
            Here's my top pick from each — tap a set to see all its shots and whether you agree.
            """))
            append(.assistant, .clusterResults(result, dateRange: interval))
        }
    }

    // MARK: - Helpers

    private func append(_ sender: ChatMessage.Sender, _ content: ChatMessage.Content) {
        messages.append(ChatMessage(sender: sender, content: content))
    }

    /// Ranges end at midnight *after* the last day (see
    /// `DateInterval.wholeDays`), so step back a moment before displaying —
    /// otherwise all of October would read as "Oct 1 – Nov 1". A single day
    /// includes its weekday ("Tue, Oct 6, 2026"), which matters most when
    /// the request was a weekday.
    static func describe(_ interval: DateInterval) -> String {
        if Calendar.current.isDate(interval.start, inSameDayAs: interval.lastDay) {
            return interval.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        }
        return rangeFormatter.string(from: interval.start, to: interval.lastDay)
    }

    private static let rangeFormatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Visual layer — THE ONLY PLACE that knows it looks like iMessage.
// Swap this one view later and nothing above or below it has to change.

struct ChatBubbleView: View {
    let message: ChatMessage
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        // Scan results are photos, shown full width like images in a chat
        // app rather than squeezed into a grey bubble.
        if case .clusterResults(let result, _) = message.content {
            DuplicateSetsRow(result: result)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 40) }

            bubbleContent
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.sender == .user ? Color.blue : Color(.systemGray5))
                .foregroundColor(message.sender == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18))

            if message.sender == .assistant { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.content {
        case .text(let text):
            Text(text)

        case .dateEntryChoice:
            VStack(alignment: .leading, spacing: 8) {
                Button("I'll type them") { viewModel.chooseDateEntry(useCalendar: false) }
                Button("Use my calendar") { viewModel.chooseDateEntry(useCalendar: true) }
            }
            .buttonStyle(.bordered)

        case .datePicker:
            Button {
                viewModel.openCalendar()
            } label: {
                Label("Open calendar", systemImage: "calendar")
            }
            .buttonStyle(.bordered)

        case .rangeChoice(let options):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(options, id: \.self) { option in
                    Button(ChatViewModel.describe(option)) { viewModel.chooseRange(option) }
                }
            }
            .buttonStyle(.bordered)

        case .confirmationChoice:
            HStack {
                Button("Yes, scan them") { Task { await viewModel.confirmAndRunClustering() } }
                    .buttonStyle(.borderedProminent)
                Button("Change dates") { viewModel.restartDateEntry() }
                    .buttonStyle(.bordered)
            }

        case .clusterResults:
            EmptyView() // drawn by DuplicateSetsRow instead (see body)
        }
    }
}

/// The date-range picker, shown in a sheet over the chat: one calendar,
/// like a hotel or flight booking app. The first tap picks the start day,
/// the second tap picks the end day, and the days between are highlighted.
///
/// Why it's built this way — lessons from five earlier versions that all
/// worked in the simulator but broke on the phone:
/// - It's plain stacks of views, with no scrolling list or settings-style
///   Form around it. Every earlier bug was a tap or swipe going to the
///   wrong place because a calendar sat inside one of those.
/// - It doesn't use Apple's built-in calendar, which hides the days
///   behind a month/year wheel that's hard to get back out of.
/// - Nothing but the ✓ button submits. Tapping days never closes the sheet.
/// - Everything the calendar depends on (today's date, the selection, the
///   month on screen) is stored once in @State, never recalculated on each
///   redraw — recalculating made earlier calendars reset mid-interaction.
private struct RangeCalendarSheet: View {
    let onSubmit: (DateInterval) -> Void
    let onCancel: () -> Void

    @State private var today = Date.now
    @State private var start: Date?
    @State private var end: Date?
    /// The first day of the month currently on screen.
    @State private var shownMonth = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            selectionSummary
            header
            weekdayLabels
            dayGrid
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Date Range")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    guard let start else { return }
                    onSubmit(.wholeDays(from: start, through: end ?? start))
                }
                .disabled(start == nil)
            }
        }
    }

    // MARK: Selection

    /// First tap: start. Second tap: end (or, if it's before the start, a
    /// new start instead). Any tap after a full range begins a new one.
    private func tap(_ day: Date) {
        if let start, end == nil {
            if day < start {
                self.start = day
            } else {
                end = day
            }
        } else {
            start = day
            end = nil
        }
    }

    /// Start → End boxes, like a booking app, so it's obvious up front that
    /// two dates are being picked. The box that the next tap will fill is
    /// outlined. Display-only on purpose: tapping a box does nothing, since
    /// letting it switch which date is being edited is the kind of
    /// interaction that broke earlier calendars.
    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                dateBox("Start", date: start, isNext: start == nil || end != nil)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                dateBox("End", date: end, isNext: start != nil && end == nil)
            }
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var hint: String {
        if start != nil && end != nil {
            return "Tap ✓ to use these dates, or tap a day to start over."
        } else if start != nil {
            return "Now tap the last day — or tap ✓ for just this one day."
        } else {
            return "Tap the first day, then the last day."
        }
    }

    private func dateBox(_ label: String, date: Date?, isNext: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption.bold())
                .foregroundStyle(isNext ? Color.accentColor : Color.secondary)
            if let date {
                Text(date, format: .dateTime.day().month(.abbreviated).year())
                    .font(.headline)
                    .foregroundStyle(.primary)
            } else {
                Text("Pick a day")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isNext ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Header — Month and Year menus, plus ‹ › arrows

    private var header: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(1...12, id: \.self) { month in
                    Button(calendar.monthSymbols[month - 1]) { show(month: month, year: shownYear) }
                }
            } label: {
                menuLabel(calendar.monthSymbols[shownMonthNumber - 1])
            }

            Menu {
                ForEach(selectableYears.reversed(), id: \.self) { year in
                    Button(String(year)) { show(month: shownMonthNumber, year: year) }
                }
            } label: {
                menuLabel(String(shownYear))
            }

            Spacer()

            Button { step(by: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            Button { step(by: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(!canStepForward)
        }
        .font(.headline)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
            Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .foregroundStyle(Color.primary)
    }

    private var weekdayLabels: some View {
        // Start the week on whatever day the phone's region settings use.
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Days

    private var dayGrid: some View {
        VStack(spacing: 4) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isStart = start.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let isEnd = end.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let isBetween = start.flatMap { s in end.map { e in day > s && day < e } } ?? false
        let isEndpoint = isStart || isEnd
        let isFuture = day > today
        let isToday = calendar.isDateInToday(day)

        return Button {
            tap(day)
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.body.weight(isEndpoint || isToday ? .semibold : .regular))
                .foregroundStyle(
                    isEndpoint ? Color.white
                    : isFuture ? Color.secondary.opacity(0.4)
                    : isToday ? Color.accentColor
                    : Color.primary
                )
                .frame(width: 40, height: 40)
                .background(Circle().fill(isEndpoint ? Color.accentColor : Color.clear))
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .background(isBetween ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(Text(day, format: .dateTime.day().month(.wide).year()))
        .accessibilityAddTraits(isEndpoint ? .isSelected : [])
    }

    /// The shown month as rows of 7: blanks (nil) before the 1st so it
    /// lands under the right weekday, then one date per day, then blanks to
    /// fill out the last row.
    private var weeks: [[Date?]] {
        guard let days = calendar.range(of: .day, in: .month, for: shownMonth) else { return [] }
        let leadingBlanks = (calendar.component(.weekday, from: shownMonth) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
        cells += days.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: shownMonth) }
        cells += Array(repeating: nil, count: (7 - cells.count % 7) % 7)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    // MARK: Navigation

    private var shownMonthNumber: Int { calendar.component(.month, from: shownMonth) }
    private var shownYear: Int { calendar.component(.year, from: shownMonth) }
    private var thisMonth: Date { calendar.dateInterval(of: .month, for: today)?.start ?? today }

    /// Back 30 years — plenty for a camera roll, without an endless menu.
    private var selectableYears: [Int] {
        let thisYear = calendar.component(.year, from: today)
        return Array((thisYear - 30)...thisYear)
    }

    private var canStepForward: Bool { shownMonth < thisMonth }

    /// Never shows a month that's entirely in the future — e.g. picking
    /// December in the current year lands on this month instead.
    private func show(month: Int, year: Int) {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return }
        shownMonth = min(date, thisMonth)
    }

    private func step(by months: Int) {
        guard let date = calendar.date(byAdding: .month, value: months, to: shownMonth) else { return }
        shownMonth = min(date, thisMonth)
    }
}

// MARK: - The screen itself

struct ChatShellView: View {
    @StateObject private var viewModel = ChatViewModel()
    @FocusState private var isTyping: Bool

    var body: some View {
        // Chat is the app's landing screen, so this is the one place that
        // owns the NavigationStack — Camera Roll and the debug screen are
        // both reached by pushing onto it, not the other way around.
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        // A plain (not lazy) stack: a chat has dozens of
                        // messages at most, and a lazy one re-measured
                        // off-screen messages after a sheet closed, which
                        // shifted the scroll position up. (The photo row
                        // inside is still lazy, so thumbnails load on demand.)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.messages) { message in
                                ChatBubbleView(message: message, viewModel: viewModel)
                                    .id(message.id)
                            }
                        }
                        .padding()
                    }
                    // Like Messages: when anything changes size, keep the
                    // bottom of the chat where it is.
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .onChange(of: viewModel.messages.count) { _, _ in
                        guard let lastID = viewModel.messages.last?.id else { return }
                        withAnimation { scrollProxy.scrollTo(lastID, anchor: .bottom) }
                    }
                }

                Divider()

                HStack {
                    // Grows to show up to 5 lines (then scrolls), like Messages,
                    // so a longer request can be read back before sending.
                    //
                    // The whole box responds to a tap, and it's at least 44pt
                    // tall (Apple's minimum for anything tappable). With the
                    // built-in rounded style, only the line of text itself
                    // responded — taps near the box's edges did nothing, so it
                    // took a few tries to start typing.
                    TextField("Message", text: $viewModel.draftText, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($isTyping)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color(.separator))
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { isTyping = true }
                    Button("Send") { viewModel.sendDraft() }
                        .disabled(viewModel.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding()
            }
            .navigationTitle("Chat")
            .sheet(isPresented: $viewModel.isShowingCalendar) {
                NavigationStack {
                    RangeCalendarSheet(
                        onSubmit: { viewModel.submitPickedDates($0) },
                        onCancel: { viewModel.isShowingCalendar = false }
                    )
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    NavigationLink("Camera Roll") {
                        PhotoGridView()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink("Debug: Clustering") {
                        ClusteringDebugView()
                    }
                }
            }
        }
    }
}

#Preview {
    ChatShellView()
}
