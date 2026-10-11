# PhotoCleanup — Project Brief

## What this app does
An iOS app with an AI chat interface that helps the user clean up their camera roll.
The user chats about a set of photos (e.g. "my hiking trip in France from June 2026"),
describes what they want to keep vs. don't want, and the AI recommends which near-duplicate
or low-quality photos to delete. The user reviews and confirms before anything is deleted.

## Goal
Eventually publish on the App Store. Currently in early prototyping — building and testing
on the developer's own iPhone (16e) via a free Apple ID (no paid Developer Program yet; that
gets added later, only when ready for TestFlight or App Store submission).

## Hard constraints (not up for debate — imposed by iOS itself)
- **Deletion is never silent.** iOS shows its own system confirmation dialog whenever an app
  requests photo deletion via PhotosKit (`PHPhotoLibrary` / `PHAssetChangeRequest`). The app
  can *recommend* a batch to delete; the user always gets the final native confirmation tap.
  Design the chat/review flow around this — e.g., "AI proposes a batch → user reviews →
  user taps delete → iOS confirms" — not around any illusion of full automation.
- Reading the photo library requires the `NSPhotoLibraryUsageDescription` permission string
  in Info.plist and a runtime permission prompt. Deleting requires a *separate* write-access
  permission, requested later (see "Photo access strategy" below).

## Photo access strategy (decided)
Read and write access are being requested **separately, not together**:
- **Now:** request read-only access only. This is all the current milestone (photo grid) needs.
- **Later:** request write access only once the deletion feature is actually being built.
This follows Apple's "least privilege" principle — ask for only what the current feature
needs, when it needs it — and results in a cleaner permission-prompt experience for the user
(they aren't asked to allow deletion before the app has shown them anything). Confirmed there
is no performance difference either way; this is a privacy/UX choice only, not a technical one.

## Chat + photo review UX (decided)
The existing `PhotoGridView` (raw scrolling grid, no dates, not tappable) was built purely as
scaffolding to prove photo access worked — it is NOT the intended final UI and should be
expected to be rebuilt/repurposed, not polished as-is.

The actual planned UX:
- **Main interface is chat-first.** The user never manually browses/selects photos from their
  full camera roll. They describe what they want in natural language (e.g. "my France hiking
  trip from June"), and the app finds matching photos itself using metadata (date taken,
  and GPS location where available).
- **Results are shown as an inline, horizontally-scrollable row of thumbnails inside the chat**
  (not a separate grid screen, not rigid "cards" — plain conversational feel, similar to how
  images appear in familiar chat-AI interfaces). No hard cap on count for v1; scrolling handles
  large result sets. This may need revisiting after real testing if very large batches feel
  unwieldy.
- **The preview row shows ONE representative photo per duplicate cluster, not every photo.**
  E.g. if a search matches 50 photos across ~8 duplicate batches, the row shows ~8 thumbnails,
  one per batch, not all 50. The representative photo for each cluster is chosen by
  **sharpest/best on-device quality estimate** (via Vision framework — blur detection, open
  eyes if a face is present), not earliest-taken or AI-selected — goal at this stage is
  confirming relevance/coverage, not picking a final "best" photo yet.
- **A full pop-out grid (modal/sheet, reusing the existing PhotoGridView code) is available**
  for deeper review — e.g. tapping into a specific cluster to see every photo in it. This is
  the "let me actually look closely" option, not the default view.
- **Singles (clusters of exactly 1 photo, i.e. no duplicates found) are excluded entirely from
  the whole review/deletion flow for v1** — never shown in previews, never flagged, never
  touched. This app's v1 scope is trimming duplicates only, not judging standalone photo
  quality (that's a possible future feature, out of scope now). Since clustering already
  distinguishes single-photo clusters, this exclusion requires no new logic, just a filter.

## AI architecture (planned, two-stage, for cost efficiency)
1. **On-device clustering (free, offline):** Use Apple's Vision framework to generate feature
   prints for each photo and compare them, combined with timestamp/location metadata, to group
   likely-duplicate photos into clusters. No API calls, no cost, works offline.
2. **Cloud AI judgment (paid, only for ambiguous clusters):** For clusters where it's genuinely
   hard to tell algorithmically which photo is "best," send just that small cluster (a handful
   of images) to a vision-capable Claude model for comparison, informed by what the user said
   they want in the chat. Starting point: a cost-efficient model tier (e.g. Claude Haiku) rather
   than a flagship model, since we're only calling it on small clusters, not the whole library.
   Model choice/pricing should be re-verified against current Anthropic docs when this part is
   actually built, since both change over time.
4. **Cost guardrails (decided, in response to developer's concern about runaway token usage):**
   cloud AI is only invoked at actual decision points (comparing a specific cluster), never
   for general back-and-forth chat; send small/thumbnail-sized images, not full-resolution
   originals; don't re-send or re-judge a cluster already evaluated earlier in the conversation;
   consider a visible usage indicator so cost is never a surprise.
3. Open-source/offline-only models were considered as an alternative to cloud AI for the judgment
   step (better privacy, no per-use cost) but were deprioritized in favor of prototyping with
   cloud AI first to establish a quality baseline, revisiting later if cost or privacy warrants it.

## Toolchain
- **Xcode** — required, used to create/build/run/debug the project and (later) submit to the
  App Store. The `.xcodeproj` should always be created via Xcode's own "New Project" wizard,
  not hand-written — its file format is fragile to generate from scratch.
- **Claude Code** (Claude Desktop app, Code tab) — does the actual file editing/building inside
  this project folder, on a Claude Pro account.
- **GitHub** — version control / backup. Repo is private. Connected via GitHub CLI authentication
  (installed through Homebrew).
- **Apple Developer Program ($99/yr)** — NOT needed yet. Only required later for TestFlight
  beta distribution or App Store submission. Free Apple ID is sufficient for building and
  testing on the developer's own device during development (7-day app expiry, reinstall as needed).
- **Anthropic API account** — will be needed once we wire up the cloud AI step; not yet set up.

## Status so far
- [x] Xcode installed, Claude Code installed and running in this folder
- [x] GitHub account exists
- [x] Blank Xcode project created and run successfully ("hello world" milestone — confirmed on
      real device, iPhone 16e, after working through a simulator first-boot issue)
- [x] Project connected to GitHub (private repo, pushed via Claude Code + GitHub CLI)
- [x] Photos framework integration — thumbnail grid, tested on real device (iPhone 16e),
      merged via PR #1 on GitHub. Note: iOS has no true "read-only" tier (see below), so the
      app requests `.readWrite` — but contains zero delete code, so this poses no more risk
      than originally planned.
- [x] On-device duplicate clustering — Vision feature-print similarity + timestamp +
      location, tuned against a hand-audited real date range (similarity threshold raised
      0.3 → 0.45 after auditing misses). Debug UI lets you drill into any cluster or the
      unmatched-photos folder and view full-size photos with swipe. Two known v1
      limitations documented directly in code (not fixed, deliberate): portrait/landscape
      orientation mismatches, and same-background-but-content-changed cases (e.g. a person
      walking into/out of frame) — see Decision Log and code comments in
      `PhotoClusterEngine.swift` for the reasoning. Apple's `PHAssetCollection.fetchMoments`
      was evaluated as a possible cross-check signal and rejected (see Decision Log).
- [x] Chat UI shell (basic text in/out) — `ChatShellView.swift`, iMessage-style bubbles,
      placeholder canned replies only, no real logic wired in yet.
- [x] Date-range selection wired into chat, tested on device — the chat is now the app's
      home screen and runs: pick a date range → confirm → run clustering on that range →
      see the duplicate sets found. Two ways to give the range:
      - **Typed** (`TypedDateParser` in `ChatConversationFlow.swift`): month/year phrases
        ("October 2025", "Sep - Nov 2025"), relative phrases ("last month", "past two
        weeks"), and specific days ("Oct 1 to Oct 4, 2025"). A new range can be typed at
        the confirm step or after a scan to switch to it.
      - **Calendar** (`RangeCalendarSheet` in `ChatShellView.swift`): one range calendar
        in a sheet — first tap = start, second tap = end, Start → End boxes on top. See
        Decision Log for why it ended up this way.
      All ranges cover whole days (midnight to midnight) — an earlier version could start
      or end mid-day and silently skip photos.
- [x] Typed dates fully handled, tested on device — the parser reads dates broad-to-narrow
      (pieces like year/month/holiday/day, then one modifier like "two weeks before" or
      "first weekend of"), so free combinations work: holidays, "two weeks before …",
      "week of …", "first two weeks of …", seasons, "a week earlier", and more. Checked
      against 91 phrases with known answers (`DateParserChecks/check.sh`). Apple's
      on-device model was tried for this and removed (see Decision Log). The chat's message
      box now grows to 5 lines so longer requests are readable. **Date step is done.**
- [ ] In-chat preview row (one best photo per duplicate set) + pop-out grid — NEXT UP
- [ ] Cloud AI integration for judgment calls
- [ ] Write-access permission + review/confirm/delete flow

## Decision log
- **Apple's Moments API rejected as a session-grouping signal.** Checked
  `PHAssetCollection.fetchMoments` (the grouping behind the Photos app's old "Moments"
  view) as a possible way to help group/cross-check photos. Rejected after testing against
  real data: it groups by whole outing (hours-wide, town-wide — e.g. one single 49-photo
  Moment spanning 6 hours across an entire visit to Cortina d'Ampezzo), not by individual
  stop/shot. Too coarse-grained to help with near-duplicate detection, which needs
  second-by-second, meter-by-meter precision.
- **Calendar ended up as a single range calendar, built by hand.** Six designs were tried.
  The first five all worked in the simulator but broke on the real phone: two pop-up
  pickers in a chat bubble (taps went to the wrong picker), a full calendar in a chat
  bubble (the chat's scrolling stole swipes), the same in a sheet (the calendar reset
  itself mid-use), a Calendar-app-style Starts/Ends form (closed early, or couldn't get
  back from the month/year wheel), and a custom calendar inside that form (Ends month
  couldn't change). Common causes: calendars placed inside scrolling lists or forms, and
  Apple's built-in calendar hiding the days behind its month/year wheel. The working
  version is a plain one-calendar range picker (like hotel/flight booking apps) with
  Month/Year menus, nothing scrolling around it, and only ✓ confirming. Lesson: for this
  app, on-device testing is the real check for UI — simulator passes weren't reliable.
- **Date phrases are parsed by hand, not just with iOS's date detector.** The built-in
  detector (the one that makes dates tappable in Messages) doesn't recognize month- or
  year-only text like "October 2025" or "2025", and returns times of day (often noon)
  rather than whole days. So month/year and relative phrases are handled by our own
  patterns, and everything is widened to whole days.
- **Apple's on-device model tried for understanding typed dates, then removed (Oct 2026).**
  Apple's Foundation Models framework (the on-device model behind Apple Intelligence) was
  picked because it's free, offline and private, and Claude would need the backend relay
  (below) plus per-message cost. In testing it handled easy phrases ("October 2025",
  "summer 2024") but failed exactly the hard ones it was there for: asked for dates
  directly, it answered "two weeks before Christmas 2025" with Dec 24 – Jan 7 (after,
  not before); asked only to *describe* the period so the app could do the counting, it
  named today instead of Christmas as the reference day, and read "past two weeks" as
  2 days. It also only runs when Apple Intelligence is on, which switched off twice
  during testing without the developer knowing why. Replaced by extending the
  hand-written patterns (see next entry). Could be revisited later — or Claude used for
  truly free-form requests once the relay exists.
- **Typed dates are read broad-to-narrow, by hand-written rules** (`TypedDateParser.swift`).
  The parser first picks out the *pieces* — a year, month, season, holiday (Christmas,
  Christmas Eve, New Year's, New Year's Eve, Easter, Halloween, Valentine's, US
  Thanksgiving), specific day or run of days, a period relative to today ("last month",
  "past two weeks") — plus at most one *modifier* ("two weeks before …", "first 10 days
  of …", "second weekend of …", "week of …"). Then it combines them: a year only says which
  year the narrower pieces are in ("Easter 2024" = Easter *in* 2024, not all of 2024),
  the narrowest pieces define the period, several make a range ("October to December
  2025"), and the modifier is applied last. Because pieces combine freely, combinations
  nobody wrote a rule for still work ("first weekend of summer 2024", "the week after
  Easter 2025"). This replaced an earlier ordered checklist of whole-phrase patterns,
  where the first match won — that design misread "Easter 2024" as all of 2024 because
  no pattern covered a lone holiday. Numbers-only dates ("10/1/2025") go to iOS's date
  detector, which uses the phone's region for day/month order. "A week earlier"-style
  changes move the range already being discussed. Same answer every time, works on every
  iPhone, and checked on the Mac against a fixed list of phrases with known answers (64
  everyday phrases plus 27 combinations) — re-run it after any change with
  `DateParserChecks/check.sh` (prints "All phrases match" if nothing changed). Conventions
  (all shown in the confirmation step before any scan): a weekend is Sat–Sun; "first week
  of October" is Oct 1–7; "week of Nov 5" is the calendar week containing it; "two weeks
  before Christmas" is Dec 11–24; winter 2024 is Dec 2024 – Feb 2025; no year given means
  the most recent one that has already started.
- **Claude API key will live behind a small backend relay, not in the app.** An API key
  built into an app can be extracted, so the shipping app will call a small server of
  ours (e.g. a Cloudflare Worker / serverless function) that holds the key and forwards
  requests. The relay also needs abuse protection — Apple's App Attest to confirm requests
  come from the real app, plus per-user rate limits. Planned as the first task of the
  cloud AI milestone; required before TestFlight/App Store. For development on the
  developer's own phone only, a local, never-committed key is acceptable.

## Notes for Claude Code
The developer (project owner) is not a coder. Prioritize:
- **Always explain what code does and why, in plain language** — not just what it does, but
  why it's done that way, especially when there were alternative approaches.
- **Clearly flag what's required vs. what's a suggestion/preference** whenever presenting a
  choice or writing code a particular way — don't let optional stylistic choices read as if
  they were mandatory, and vice versa.
- Small, testable milestones over large batches of untested code.
- **The developer tests UI changes on their own iPhone.** Claude Code should confirm the
  project builds and give a short test checklist, not drive the simulator. Commit each
  known-good state before tweaking further, so it can be rolled back.
- If an explanation would benefit from a slower, teaching-style walkthrough, it's fine to keep
  the in-tool explanation brief and note that the developer will ask their Claude.ai chat for
  a deeper explanation separately — the two are used together deliberately.
