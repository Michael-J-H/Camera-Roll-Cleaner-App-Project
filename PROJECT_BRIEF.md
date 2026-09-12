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
- [ ] On-device duplicate clustering (NEXT UP — see below for why this comes before chat UI)
- [ ] Chat UI shell (basic text in/out)
- [ ] Wire clustering + metadata search into chat (inline preview row, pop-out grid)
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

## Notes for Claude Code
The developer (project owner) is not a coder. Prioritize:
- **Always explain what code does and why, in plain language** — not just what it does, but
  why it's done that way, especially when there were alternative approaches.
- **Clearly flag what's required vs. what's a suggestion/preference** whenever presenting a
  choice or writing code a particular way — don't let optional stylistic choices read as if
  they were mandatory, and vice versa.
- Small, testable milestones over large batches of untested code.
- If an explanation would benefit from a slower, teaching-style walkthrough, it's fine to keep
  the in-tool explanation brief and note that the developer will ask their Claude.ai chat for
  a deeper explanation separately — the two are used together deliberately.
