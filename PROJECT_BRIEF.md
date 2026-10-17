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
  in Info.plist and a runtime permission prompt. iOS has only two photo access levels —
  "add only" and "read and write" — so there is no read-only option: reading at all means
  asking for read/write (see "Photo access strategy" below).

## Photo access strategy (decided, revised)
The original plan was to ask for read-only access now and a separate write permission later,
following Apple's "least privilege" principle. That turned out not to be possible: iOS has no
read-only tier (only "add only" and "read and write"), so the app asks for **read and write
access once, up front** (`PHPhotoLibrary.requestAuthorization(for: .readWrite)` in
`PhotoLibraryManager.swift`), and the user sees a single permission prompt.
- **There will be no second permission prompt** at the deletion milestone — the app already
  has the access level deletion needs.
- **The safeguards are elsewhere instead:** the app contains no delete code until the
  deletion milestone, and even then iOS shows its own confirmation dialog for every deletion
  (see "Deletion is never silent" above), so nothing can be removed without the user's tap.
- The user may choose "Limited Access" (only photos they pick) in the prompt; the app
  already handles that, including the case of zero photos selected.

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
Everything checked off below is committed **and merged into `main`** on GitHub. Each
milestone is built on its own branch (e.g. `preview-row`) and merged into `main` as soon as
it's tested on device, so `main` always has all finished work; a leftover branch is only a
record, not unmerged work.

- [x] Xcode installed, Claude Code installed and running in this folder
- [x] GitHub account exists
- [x] Blank Xcode project created and run successfully ("hello world" milestone — confirmed on
      real device, iPhone 16e, after working through a simulator first-boot issue)
- [x] Project connected to GitHub (private repo, pushed via Claude Code + GitHub CLI)
- [x] Photos framework integration — thumbnail grid, tested on real device (iPhone 16e),
      merged via PR #1 on GitHub. The app requests `.readWrite` because iOS has no read-only
      tier (see "Photo access strategy") — it contains zero delete code so far.
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
      "week of …", "first two weeks of …", seasons, weekdays, "a week earlier", and more; asks
      when a request has two readings and refuses rather than guesses. Checked
      against 197 phrases with known answers (`DateParserChecks/check.sh`). Apple's
      on-device model was tried for this and removed (see Decision Log). The chat's message
      box now grows to 5 lines so longer requests are readable. **Date step is done.**
- [x] In-chat preview row + pop-out grid, tested on device — after a scan the chat shows
      "N duplicate sets · N photos" and a sideways row with each set's best shot (with a
      photo-count badge), full width rather than in a bubble (`DuplicateSetsRow.swift`). All
      sets show at once, to check it's the right trip; a "See all" grid can be added if very
      large scans feel unwieldy. Tapping a set opens all its photos as a sheet (✕ or swipe
      down to close) — a sheet rather than a pushed screen, because a navigation link inside
      the chat's message list left the chat frozen after coming back. The chat stays
      anchored to the bottom when sizes change.
- [x] Review/confirm/delete flow, tested on device (`ReviewView.swift`).
      "Review sets" (or tapping a set in the chat's photo row) opens the sets one at a time.
      The top pick starts as Keep, every other photo as Delete (trimming duplicates is the
      point of the app); tapping a photo switches it, and ⤢ opens it full size (with zoom)
      with a Keep/Delete button. **Delete removes only the set on screen** ("Delete 3 photos
      from this set") through iOS's own confirmation; cancelling there changes nothing.
      Deleting everything marked across many sets was rejected — it's hard to remember what
      was marked in sets no longer on screen, and users may only have time for a few. Next
      leaves a set as it is. Shown: "This set: N of M photos marked for deletion · about X
      MB", and a running "Deleted so far" total. Sizes come from a value Photos keeps per file
      that Apple doesn't officially document (small App Store review risk; fallback: estimate
      from pixel dimensions); the UI says space only comes back after Recently Deleted's 30
      days. Choices and deletions survive closing and reopening the review. The chat's
      photo row updates live: counts reflect deletions, a set with every photo deleted drops
      out (of the row and the review), and a set the user marks done shows a ✓ Done badge
      ("3 duplicate sets · 1 done"). **Done is only ever set by the user** ("Mark as done" in
      the review; tap again to undo) — inferring it was tried and wrongly marked a big set
      done partway through. The button is highlighted, as a hint only, once something's been
      deleted and nothing left is marked for deletion. The last set's button says "Finish"
      so "done" always means a finished set.
      **Next best:** the scan ranks every photo in a set (same rules as the top pick), so if
      the top pick is deleted the ★ moves to the next best, which starts as Keep and becomes
      the set's cover in the chat. It moves only on an actual delete, not while photos are
      merely marked, and never overrides a choice the user made.
      **Deleting every photo in a set** shows a red "None of this moment will be kept" line
      and asks once more ("Delete every photo of this moment?") before iOS's own
      confirmation; sets with at least one photo kept go straight to iOS's confirmation.
      **Recovering deleted photos is left to iOS (decided).** Apps can't see or restore items
      in Recently Deleted, and the developer chose not to add an in-app hint pointing there —
      users can find Photos → Albums → Recently Deleted themselves.
      Background (no new permission needed — read/write is
      already granted; iOS confirms every deletion itself). First step: rank *every* photo
      in each set (today only the single best is picked — see below), check the picks
      against the developer's own judgment on the test range, then build the per-set review
      screen.
      **What exists now:** during the scan each set gets one "top pick"
      (`PhotoClusterEngine.pickRepresentative`): photos where *anyone's* eyes are closed are
      set aside (unless every photo has that problem) — checked per person, since averaging
      everyone's eyes let one person's open eyes hide another's blink; then, **in sets with people**, the photo with the
      best combined *face capture quality* wins — Apple's on-device score for choosing the
      best of several shots of the same people (pose, expression, focus, lighting); a face
      missing from one photo counts as zero there; near-equal face scores (within 0.05) are
      decided by Apple's aesthetics score. **In sets without people**, Apple's *aesthetics
      score* wins (its built-in model judging composition, lighting and subject, -1 to 1;
      iOS 18+), with sharpness (variance-of-Laplacian, `PhotoQualityScorer.swift`) breaking
      ties — chosen over hand-coded composition rules like the golden ratio, which good
      photos often break on purpose and which barely vary within a burst. Horizon-tilt
      detection was left out for now (the aesthetics score already weighs it).
      **Orientation:** iPhone photos are often stored sideways with a "rotate when
      displaying" tag; the scan had been dropping it, so portrait photos were judged lying on
      their side (the aesthetics score then favoured the landscape shot of the same scene).
      The quality checks (eyes, face quality, aesthetics) now get the tag. On-device check
      (Sep 26 – Oct 4, 2025): aesthetics scoring looked better but not perfect; the effect of
      the orientation fix was hard to judge by eye — kept because it's correct regardless. **Open item:** the
      grouping step (feature prints) still ignores it, unchanged so far because fixing it
      could change which photos count as duplicates — it may be behind the known
      portrait/landscape mismatch limitation. Needs its own before/after check on the debug
      screen.
      Sharpness-only picking was replaced for people photos after it chose a sharp but
      awkward mid-movement shot (a couple sliding off a rock) over ones of them sitting and
      smiling at the camera. Faces are judged on a larger copy of the photo (2048px instead
      of the 512px used for grouping), since faces in wide shots were too small to read
      eyes reliably. **Known limit:** nothing on-device understands gestures or awkward
      poses (e.g. a hand pointed at the camera) — that judgment is a job for the AI step.
      **Offline pick is deliberately paused here.** A "prefer everyone facing the camera"
      rule (Apple reports head direction) was considered and rejected: the phone can't tell
      an intentional look — a couple looking at each other on purpose — from a glance
      away, so it would trade posed-shot mistakes for candid-shot ones. Choosing between
      good shots is taste and intent, left to the AI step; until then the chat frames the
      pick as "my top pick … whether you agree".
      Not yet: an order for the rest of the set, landscape/framing
      signals, or a check across many sets that the pick matches what the user would keep.
- [ ] Cloud AI integration for judgment calls (first task: the backend relay for the API key)

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
  iPhone, and checked on the Mac against a fixed list of phrases with known answers (197
  phrases: everyday ones, combinations, weekdays, and refusal/ambiguity cases) — re-run it after any
  change with `DateParserChecks/check.sh` (prints "All phrases match" if nothing changed).
  **Misspelled months are tolerated where a date is obvious:** if a day number or year
  follows a word, it's read as a month when it's within one typo of a month name (two for
  longer words; swapped letters count as one) — "septemebr 26", "octobr 2025" — or starts
  with a month's first three letters, which are all different ("septmbre 26", "octbr 4").
  March and May are also everyday words, so "mar…"/"may…" words must still be within one
  typo ("marhc 3" yes; "match 3", "mark 3", "maybe 2025" no). Accepted cost: an unlikely
  "junk 2024" or "novel 5" reads as June 2024 / Nov 5 — the confirmation step shows it.
  **Dates typed backwards are left as-is for now (deliberate).** A borrowed year that puts
  the first date after the second is read as wrapping over New Year ("Nov to Feb 2026" =
  Nov 2025 – Feb 2026). So "Oct 4 to Sep 26 2025" reads as Oct 4, 2024 – Sep 26, 2025, not
  the reversed week. A fix was built (take the much shorter reading; ask when close) and
  then dropped by the developer's choice as an edge case — the confirmation step shows the
  long range before any scan. Revisit if it comes up in real use.
  **It refuses rather than guesses:** anything it can't place gets "I couldn't pick out a
  date" plus the calendar option. Specifically: "may", "march", "fall" and "spring" only
  count as dates in a date-like position ("in May", "May 2025", "this fall", "May to July")
  — not in "may I see…" or "fall photos"; iOS's date detector is only trusted with full
  numeric dates (left alone it read "Sunday" and "tomorrow" as future dates and "3pm" as
  today); and any period that hasn't started yet is refused ("next Tuesday", "Christmas
  2026"). Personal events without a date ("my birthday", "our Paris trip") are refused —
  that kind of free-form request is a job for the later AI milestone. **Guiding principle — listen for the
  dates, not the sentence.** Like following a conversation in a language you're still
  learning: you seize on the part that answers your question (the yes/no, the date) and let
  the rest wash past. So when a message contains a specific date or range, the surrounding
  words are ignored entirely, however they're phrased. The wording only matters when the
  dates alone don't pin down a period. **If the only date given is a broad
  period** — a lone month, season or year — **alongside words it doesn't understand** ("my
  birthday in 2024", "summer vacation", "our trip in March 2025"), it doesn't silently scan
  the whole period: it says it isn't sure and offers the period as a button, or asks for
  exact dates. Specific dates never trigger this, whatever words surround them ("Let's
  search Sep 26 to Oct 4 2025", "the wedding weekend of June 14 2025"). (An earlier version
  asked whenever *any* unrecognized word appeared next to a long period, which misfired on
  everyday wording like "sorry, I meant…" and "let's search…" — a word list can't keep up.)
  At any point, "new dates", "change dates", "start over" or "never
  mind" go back to choosing dates, so a question can never leave the user stuck.
  **It asks when a request genuinely has two readings,** with a button for each:
  "last Tuesday" mid-week (this week's or the week before's) and "winter 2024" (the winter
  ending in 2024 or starting in it). **It asks "how far back?"** for vague amounts ("a few
  Tuesdays ago", "a while ago") instead of picking a number.
  **Where to stop:** a phrase is only worth supporting if people would realistically type
  it to find photos *and* it maps to one clear period (or a choice of two). Weekdays are
  supported: "Tuesday" / "this past Tuesday" (most recent), "2 Tuesdays ago", "the Tuesday
  before Christmas 2025", "first Monday of March 2025"; as are "3 days ago" (that day),
  "2 weeks ago" (that calendar week), "a month ago" (that calendar month).
  Conventions (all shown in the confirmation step before any scan): a weekend is Sat–Sun;
  "first week of October" is Oct 1–7; "week of Nov 5" is the calendar week containing it; "two weeks
  before Christmas" is Dec 11–24; winter 2024 is Dec 2024 – Feb 2025; no year given means
  the most recent one that has already started.
- **Claude API key will live behind a small backend relay, not in the app.** An API key
  built into an app can be extracted, so the shipping app will call a small server of
  ours (e.g. a Cloudflare Worker / serverless function) that holds the key and forwards
  requests. The relay also needs abuse protection — Apple's App Attest to confirm requests
  come from the real app, plus per-user rate limits. Planned as the first task of the
  cloud AI milestone; required before TestFlight/App Store. For development on the
  developer's own phone only, a local, never-committed key is acceptable.
- **"Top pick": offline by default, Claude on request (direction agreed; details open).**
  Each duplicate set shows one *top pick* — today chosen on the phone (sharpest, eyes
  open). In the set's sheet it's first with a ★ "Top pick" badge; the chat says "Here's my
  top pick from each — … whether you agree." It's labelled "top pick", not "best",
  because the choice may later come from Claude and the user's stated taste.
  - **Offline pick = the free default and the gate.** It handles objective flaws (blur,
    blinks), costs nothing, works for everyone, and is enough for most bursts. The UI
    doesn't explain *why* a photo was picked; a short explanation can live in an in-app
    FAQ, and if a user asks in the chat "why this one?" the app must be able to answer
    (the scan already records sharpness and eyes-open data per photo).
  - **Claude = taste, only when asked** — e.g. "I want photos with better landscapes".
    Claude re-picks using the stated preference and the ★ moves to its choices. This
    conversation needs the cloud AI milestone (and its relay server); today's chat is
    scripted and only understands dates.
  - **Open questions:** (1) should Claude ever step in automatically on near-ties?
    (suggested: no for v1 — only on request, so cost stays zero unless asked);
    (2) when a preference is stated, which sets does it apply to — all, the open one, or
    ask? Telling "landscape" sets from "selfie with nature behind" sets needs judgment.
    Idea to evaluate: a free on-device first pass (Apple Vision's image classification
    labels like beach/mountain/sky, plus the face detection already run — a face filling
    the frame = selfie) narrows the sets, then Claude ranks only those; (3) should stated
    preferences be remembered across scans?
  - **Cost estimate (re-verify against Anthropic's pricing/image-token docs when
    building):** small thumbnails cost roughly 50–350 input tokens each; at Claude Haiku
    5.5's listed $0.10 per million input tokens, ranking ~100 thumbnails is well under one
    cent (a few cents on Sonnet 5.5). The "reasoning" isn't the expensive part — the
    number of photos sent is, so the design should send only sets that match.

## Notes for Claude Code
The developer (project owner) is not a coder. Prioritize:
- **Always explain what code does and why, in plain language** — not just what it does, but
  why it's done that way, especially when there were alternative approaches.
- **Clearly flag what's required vs. what's a suggestion/preference** whenever presenting a
  choice or writing code a particular way — don't let optional stylistic choices read as if
  they were mandatory, and vice versa.
- Small, testable milestones over large batches of untested code.
- **Before hand-building any photo judgment, check what Apple's Vision framework already
  ships** (e.g. face capture quality, aesthetics scores, saliency, horizon detection) — its
  models are trained on far more photos than any rule we'd write. Missed once: the top pick
  went through several rounds of fixes (sharpness, eyes, face quality) before the built-in
  aesthetics score was considered.
- **The developer tests UI changes on their own iPhone.** Claude Code should confirm the
  project builds and give a short test checklist, not drive the simulator. Commit each
  known-good state before tweaking further, so it can be rolled back.
- If an explanation would benefit from a slower, teaching-style walkthrough, it's fine to keep
  the in-tool explanation brief and note that the developer will ask their Claude.ai chat for
  a deeper explanation separately — the two are used together deliberately.
