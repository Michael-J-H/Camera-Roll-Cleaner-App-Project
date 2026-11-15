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
  one per batch, not all 50. The photo shown for each set is its on-device *top pick* (see
  the "Top pick" status entry for how it's chosen), not earliest-taken or AI-selected —
  goal at this stage is confirming relevance/coverage, not picking a final "best" photo.
- **A full pop-out grid (sheet) is available**
  for deeper review — e.g. tapping into a specific cluster to see every photo in it. This is
  the "let me actually look closely" option, not the default view.
- **Singles (clusters of exactly 1 photo, i.e. no duplicates found) are excluded entirely from
  the whole review/deletion flow for v1** — never shown in previews, never flagged, never
  touched. This app's v1 scope is trimming duplicates only, not judging standalone photo
  quality (that's a possible future feature, out of scope now). Since clustering already
  distinguishes single-photo clusters, this exclusion requires no new logic, just a filter.

## AI architecture (two-stage photo judgment, plus the AI as the chat's voice)
1. **On-device clustering and ranking (free, offline):** Apple's Vision framework groups
   likely duplicates (feature prints plus time and location), then ranks every photo in a
   set — Apple's blink detector, face capture quality, aesthetics score, sharpness (see the
   "Top pick" status entry). No API calls, no cost, works offline.
2. **Cloud AI judgment (paid) — sets with people only:** the phone filters and ranks; the AI
   makes the final call among the phone's **top 10**, so it never weighs blurry or blinking
   shots. Landscapes, food and other sets keep the phone's pick. **Judged automatically,
   right after the scan, for every set with people** (decided Nov 2026) — see Decision Log
   → "Which sets the AI judges, and how many photos". It confirms the phone's ★
   unless it's clearly bad (backstop) or picks by a stated preference ("both of us
   laughing"). Model: Claude Haiku 5.5 or Sonnet 5.5 — choice deferred to testing with
   friends. Through OpenRouter while testing on the developer's phone; Anthropic directly,
   behind the relay, before TestFlight. **Checked Oct 2026:** Haiku 5.5 lists $0.10 per
   million input / $0.50 per million output tokens; Sonnet 5.5 $2 / $10. **Write the API
   code from the current docs, not from memory** — settings that worked on Haiku 4.5 now
   return errors (e.g. sampling settings and assistant "prefill").
3. **The AI as the chat's voice (decided Nov 2026):** the AI answers typed messages and acts
   through levers the app offers; fixed messages are written by us. See Decision Log → "The
   AI is the conversational face".
4. **Cost guardrails (revised Nov 2026 — see Decision Log → "The AI is the conversational
   face"):** the AI now also answers typed chat messages, so the guardrails are: fixed
   messages (greeting, "Scanning…", results) are written by us and cost nothing — the AI
   only runs when the user types or a set is judged; replies stay short and only recent
   messages are sent (costs don't grow over a long chat); gently on topic; a daily AI budget
   per user with a soft landing (the scripted buttons keep working); a tighter cap on
   re-picks, since those re-send photos. Still: send small images, not originals; don't
   re-send or re-judge a set already judged; consider a visible usage indicator. Text is
   cheap (~$0.0003–0.001 per message on Haiku, ~20× on Sonnet); photos are the main cost.
   *(Previously: AI only at decision points, never for general chat.)*
5. Open-source/offline-only models were considered as an alternative to cloud AI for the judgment
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
- **OpenRouter account** — one key for many AI companies' models, used only for testing on
  the developer's phone (the debug-only "Ask AI" tool, and next the AI chat). Set up Oct
  2026 with $10 credit; the key lives in the phone's Keychain. Not in the shipping app.
- **Anthropic API account** — needed when the app switches from OpenRouter to Anthropic
  directly (with the relay, before TestFlight); not yet set up. Set a monthly spending
  limit in the Anthropic Console.

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
- [x] Chat UI shell (basic text in/out) — `ChatShellView.swift`, iMessage-style bubbles.
      Started with placeholder replies; it now runs the scripted date → scan → results flow
      (entries below). Replies are still scripted — no AI in the chat yet.
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
- [x] Top pick — chosen on the phone, tested on device (`PhotoClusterEngine.rank(_:)`,
      `PhotoQualityScorer.swift`). The scan ranks *every* photo in each set, best first; the
      top one is the set's ★ top pick, and the rest let the next best take over if it's
      deleted. Ranking rules, in order:
      1. Photos where *anyone's* eyes are closed go below the rest — checked per person,
         since averaging everyone's eyes let one person's open eyes hide another's blink.
         **Blinks now come from Apple's own blink detector** (Core Image's face detector
         with its eye-blink option, run on the upright 2048px copy) — **tested on device
         (Oct 2026):** the lake set's ★ moved to a good shot of both looking at the camera,
         and its top 5 are the ones the developer would pick. Eyes looking down/away can
         read as a blink — harmless, since those shots aren't keepers either. It replaced a hand-made rule (height ÷ width of the eye outline, under
         0.2 = closed) which the AI test tool exposed in Oct 2026: on the lake set, both
         smiling at the camera scored 0.18 ("closed" — a smile squints the eyes) while
         looking at each other scored 0.34 ("open"), so the best shot sank to the bottom
         and the ★ went to a not-looking-at-camera shot. Apple's detector can miss
         side-on faces; those photos simply count as no blink.
      2. **Sets with people:** best combined *face capture quality* — Apple's on-device score
         for choosing the best of several shots of the same people (pose, expression, focus,
         lighting). A face missing from a photo counts as zero there. Near-equal face scores
         (within 0.05) are decided by the aesthetics score, then sharpness. Faces are judged
         on a 2048px copy of the photo (grouping uses 512px), since faces in wide shots were
         too small to read eyes reliably.
      3. **Sets without people:** best *aesthetics score* — Apple's built-in model judging
         composition, lighting and subject (-1 to 1; iOS 18+) — with sharpness
         (variance-of-Laplacian) breaking ties. Chosen over hand-coded composition rules like
         the golden ratio, which good photos often break on purpose and which barely vary
         within a burst. Horizon-tilt detection left out (the aesthetics score already
         weighs it).
      **Orientation:** iPhone photos are often stored sideways with a "rotate when
      displaying" tag; the quality checks above now get that tag (they'd been judging
      portrait photos lying on their side, which made the aesthetics score favour the
      landscape shot of the same scene). **Grouping (feature prints) still ignores the tag —
      left as-is by decision:** same-scene shots in different orientations grouped fine on
      the trip photos but not on quick indoor test shots (likely the 60-second window,
      close-up framing, or line-heavy indoor scenes — not measured); fine-tuning grouping
      risked an open-ended effort and could disturb results that work, so it's deferred to
      the AI step.
      **History:** (the eyes rule above was the "check Apple first" lesson again.) Sharpness alone picked a sharp but awkward mid-movement shot (a couple
      sliding off a rock) over ones of them sitting and smiling at the camera → face quality
      added; one person's blink was missed → per-person eye check and larger face images;
      aesthetics score added later. On-device check (Sep 26 – Oct 4, 2025): better but not
      perfect; the orientation fix's effect was hard to judge by eye — kept because it's
      correct regardless.
      **Deliberately paused here.** A "prefer everyone facing the camera" rule was rejected:
      the phone can't tell an intentional look (a couple looking at each other on purpose)
      from a glance away. **Known limit:** nothing on-device understands gestures or awkward
      poses (e.g. a hand pointed at the camera). Choosing between good shots is taste and
      intent, left to the AI step; until then the chat frames the pick as "my top pick …
      whether you agree". Not yet: a check across many sets that the pick matches what the
      user would keep.
- [x] Review/confirm/delete flow, tested on device (`ReviewView.swift`). No new permission
      was needed (read/write was already granted), and iOS confirms every deletion itself.
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
      days. Choices and deletions survive closing and reopening the review.
      **Chat row:** counts reflect deletions live; a set with every photo deleted drops out
      (of the row and the review); a set the user marks done shows a ✓ Done badge ("3
      duplicate sets · 1 done").
      **Done is only ever set by the user** ("Mark as done" in the review; tap again to undo)
      — inferring it was tried and wrongly marked a big set done partway through. The button
      is highlighted, as a hint only, once something's been deleted and nothing left is
      marked for deletion. The last set's button says "Finish" so "done" always means a
      finished set.
      **Next best:** if the top pick is deleted, the ★ moves to the next-ranked photo, which
      starts as Keep and becomes the set's cover in the chat. It moves only on an actual
      delete, not while photos are merely marked, and never overrides a choice the user made.
      **Deleting every photo in a set** shows a red "None of this moment will be kept" line
      and asks once more ("Delete every photo of this moment?") before iOS's own
      confirmation; sets with at least one photo kept go straight to iOS's confirmation.
      **Recovering deleted photos is left to iOS (decided).** Apps can't see or restore items
      in Recently Deleted, and the developer chose not to add an in-app hint pointing there —
      users can find Photos → Albums → Recently Deleted themselves.
- [ ] Cloud AI integration for judgment calls — test tool done; the in-app version is the "re-pick" lever of the conversational AI below. Decided so far:
      - **Scope:** the AI only handles **sets with people** (the phone already knows which
        sets have faces). Landscapes, food and other sets keep the phone's top pick.
      - **Teamwork:** the phone ranks every photo and filters; the AI makes the final call
        among the phone's top few, so it never weighs blurry or blinking shots and fewer
        photos are sent.
      - **One AI company, called directly when shipping** — no third-party router. **OpenRouter
        is used only for testing**: a debug-only "Ask AI" button in the review lets the
        developer try several models on their own phone. It must not be in the shipping app.
      - **Choosing the model — two tests,** on the developer's real photos (Sep 26 – Oct 4,
        2025), run in the app via OpenRouter and judged by the developer by eye. The AI's job
        in the backstop test is to *confirm* the phone's pick when it's acceptable and
        *override* only when it's clearly bad — many photos can be "best"; the ★ just must
        never be a bad one:
        1. **Backstop test:** can the AI stop a ★ landing on a clearly bad people photo
           (not looking at the camera, eyes closed, awkward faces) when better shots exist
           (e.g. the 22-photo lake set)?
        2. **Preference test — the core AI use case:** given a plain-words preference ("the
           mountain behind us looks best", "both of us laughing"), does the AI return the
           photo that best matches it? A few sets, judged by the developer by eye. This is a
           capability to choose a model for, not something to design.
      - **Test tool built and working on device** (branch `ai-test-openrouter`,
        `AskAIDebugView.swift`): "Ask AI" (✨) in the review's top bar. It sends photos of the
        set on screen, in the phone's ranking order (photo 1 = the ★), to any ticked models at
        once and shows each one's pick, reason, time and cost. Which photos: the phone's top
        N (2–30, default 10) or the whole set (capped at 30), optionally leaving out photos with
        closed eyes (same rule as the phone's ranking; nothing is left out if fewer than 2
        would remain). An empty
        preference runs the backstop test; a typed one runs the preference test. Photos go at
        1024px (512px option), turned upright, as JPEG. The answer is only shown — it never
        moves the ★ or changes Keep/Delete. Models offered (OpenRouter's list, Oct 18 2026,
        per million tokens in/out): Claude Haiku 5.5 ($0.10/$0.50), Claude Sonnet 5.5
        ($2/$10), GPT-6 Luna Pro ($0.10/$0.50), Gemini 3.8 Flash ($0.83/$4.12), Qwen 3.8
        Flash ($0.15/$0.47), plus any other model id typed in. The OpenRouter key is pasted
        in once and kept in the phone's Keychain — never in a project file. All of it is
        `#if DEBUG`, so Release (TestFlight/App Store) builds leave it out (checked: no
        OpenRouter text in the Release app).
      - **What the backstop looks for** (in the question sent to the AI): a ★ is overridden
        only for a clear flaw when another photo is clearly better — eyes closed, someone not
        looking at the camera while others are, awkward expression or pose, someone cut off by
        the frame edge, someone blocked, motion blur / out of focus. A clearly crooked
        horizon or frame only decides between otherwise-equal photos (it's easy to
        straighten); small composition differences are taste, not flaws — taste is what the
        preference test is for.
      - **Decided for now (Oct 2026): send the phone's top 10.** Now that the blink check
        works, the lake set's top photos match the developer's own picks, so the phone's
        ranking is a fair filter. Revisit if testers see the AI miss a better shot ranked
        below 10. Background on the question:
        The original plan sent only the
        phone's top few. The developer's concern: the phone ranks mainly by Apple's face
        quality score, so if that's wrong for a set, its whole top 8 may be wrong the same
        way. Counter-concern: AI accuracy drops with many near-identical photos, and bursts
        can be huge. Suggested middle ground: the phone only removes objective rejects
        (closed eyes, later maybe blur), everything else goes to the AI, with a cap. To be
        settled by testing the lake set (22 photos) with top 5 vs. whole set vs. whole set
        without closed eyes.
      - **The Ask AI screen shows the blink check under each photo** ("open 2/2", red
        "blink 1/2 ✕", or "no face") so it can be judged by eye.
      - **Whole sets failed on Claude at 1024px** ("Provider returned error"); 512px
        worked, and so did leaving out closed eyes (fewer photos). The error details showed
        why: OpenRouter had sent Claude to **Google's** cloud copy of it, which rejected the
        first photo's file type ("media_type: Input should be 'image/jpeg'…") — Anthropic's
        own limits allow these requests (100 images, 32 MB). Claude models are now sent to Anthropic only
        (OpenRouter's `only: ["anthropic"]`), which matches the shipping plan of calling
        Anthropic directly — **but the same error then came back from Anthropic itself**, so
        it depends on request size inside OpenRouter's conversion, not on who runs Claude.
        **Fix (tested on device):** a 4 MB budget for the photos in one request (a guess
        below what failed); over it, JPEG quality drops, then photo size, until it fits.
        Each run shows the size and quality actually sent. The lake set's whole set then
        went through as 20 photos at 768px, quality 0.60, 3.3 MB.
        Recheck when calling Anthropic directly — this looks like an OpenRouter quirk.
        **Side note for the real AI step:** in wide shots like the lake set, faces are only
        ~40px across even at 1024px; sending a crop around the people (the phone already
        knows where the faces are) may judge expressions better and cost less.
      - **First results (Oct 2026):** every model tried except Qwen 3.8 Flash handled the
        backstop test on the lake set. Qwen kept the phone's objectively bad ★, with a reason
        that echoed the phone's own logic.
      - **After the blink fix — lake set, whole set (20 photos, 768px):** the ★ is now a
        good shot, and both Claude Haiku 5.5 and Sonnet 5.5 confirmed it with sound reasons
        (both looking at the camera, smiling, nothing cut off). Haiku: 7.0s, 12,623 input
        tokens, $0.0014. Sonnet: 7.5s, same tokens, $0.026 — about 19× Haiku for the same
        answer here. One set only; the preference test and more sets are still to run.
      - **Model choice deferred to testing with friends (developer's call, Oct 2026):** on
        the developer's sets Haiku 5.5 and Sonnet 5.5 are evenly matched so far; Sonnet costs
        ~19× more. Estimated per people set at the top-10 default (1024px ≈ 1,040 tokens
        per photo by Anthropic's formula, checked against the measured runs): Haiku ≈
        $0.0012, Sonnet ≈ $0.023. **Note:** friends test through TestFlight, which can't
        include this OpenRouter tool (see checklist) — so the comparison there has to run
        through the real AI step. Both models are Anthropic's, so the relay can offer both
        (a hidden setting, or half the testers on each) without breaking "one AI company".
      - **The relay waits until it's needed** (decided Nov 2026) — built before TestFlight,
        not before; only the developer's phone uses the app until then.
- [ ] **Conversational AI — NEXT** (see Decision Log → "The AI is the conversational face"):
      - **First milestone:** the scripted flow stays exactly as it is; the AI answers typed
        chat messages, through OpenRouter (debug-only, on the developer's phone), so
        different models can be tried for how well they talk and follow the rules. Uses
        the OpenRouter key already saved in the Keychain.
      - **Comparing models: a fixed list of messages,** like the 197 date phrases — every
        model gets the same messages and the replies are judged side by side (otherwise
        each model gets a different conversation and the comparison isn't fair). **Claude
        Code drafts the list** (realistic requests, preferences, off-topic chat, attempts
        to make the AI do things it can't); the developer reviews it and adds their own.
        Asking friends was skipped (Nov 2026) — their effort is saved for testing the app.
      - **Over-promise check:** before any levers exist the AI can't actually do anything,
        so test whether it admits that or pretends — an early check of its instructions.
      - **Automatic judging of people sets — built and tested on device** (Nov 2026, Sep 26 –
        Oct 4, 2025: 28 sets, 11 with people). Haiku 5.5: $0.0058 for all 11. Sonnet 5.5:
        $0.0995 (~17×) — **same picks as Haiku in all 11 sets**, and **both kept the phone's
        ★ in every people set**, with sensible reasons. All sets in after ~30 seconds (5 at a
        time). The off switch, progressive showing, and the Developer-menu sheets all work.
        **Developer's read:** on this trip the AI acted as a failsafe, not a fixer — kept in
        the first pass for now, but its necessity there is an open question (one trip of
        mostly couple selfies after the blink fix may be an easy case; try trips with
        groups, kids, candid shots — **deferred**, the developer doesn't have such photos to
        hand yet). Its clearer value may be taste and preferences in the
        chat. Decision Log → "Which sets the AI judges"). Right after a scan,
        `ReviewSession` sends each set with people to the AI, 5 sets at a time: photos with
        nobody's eyes closed, at most the phone's top 10, at 1024px (shrunk to fit the
        request budget), with the backstop question. The AI's pick becomes the ★ (and the
        chat row's cover) — unless the user has already started on that set (a choice, a
        delete or "done"), so the ★ never moves under them. If the AI's pick is deleted,
        the ★ falls back to the phone's ranking. **Sets with people are shown only once
        judged** (developer's call, Nov 2026 — a user shouldn't see unjudged duplicates):
        other sets appear at once, and each people set joins the end of the row as its
        judgment comes back (added only at the end, so nothing on screen shifts). A failed
        judgment shows the set with the phone's pick. Fewer than 2 passing photos, a failed
        request or an unreadable answer → the phone's pick stands. All OpenRouter code now
        lives in `OpenRouterClient.swift` (the one file to swap for the relay). Testing
        aids (debug only): under the chat row, "Still choosing the best shots…" (the
        user-facing wording — no counts, which would raise "why only 11 of 28?") plus a
        testing-only "4 of 11 sets with people judged", then model and cost; the AI's verdict and reason at the top of each set in the review; "AI
        settings" in the chat's Developer menu (🔧, top right; its screens open as sheets
        with Done — pushing them froze the chat on device, as before) to switch judging off (stand-in for declining AI
        consent) and pick the model (default Claude Haiku 5.5).
      - **Then levers, one at a time,** starting with dates (handing phrases to the parser —
        Decision Log → "The date lever"), then re-pick with a preference, then explain a
        pick.
      - **Switching to Anthropic directly** comes with the relay, before TestFlight. Keep
        the network call in one small piece of code so that switch is contained. Write
        API code from current docs, not memory.

## Before TestFlight / App Store (checklist)
Items scattered through this brief that must be settled before anyone else uses the app.
Details live in the linked sections; this list is so none are missed.

**Must do:**
- [ ] **Paid Apple Developer Program** ($99/yr) — required for TestFlight and the App Store
      (see Toolchain). Until then the free account's 7-day app expiry applies.
- [ ] **Remove the OpenRouter test code** (`AskAIDebugView.swift`, the "Ask AI" button in
      `ReviewView.swift`, the "AI" link in `ChatShellView.swift`; it's debug-only, but delete
      it anyway) and **point `OpenRouterClient.swift`'s job at the relay** — automatic
      judging in `ReviewSession` calls it and remove the saved key
      from the phone ("Remove saved key" in that screen) or revoke it on openrouter.ai;
      the shipping app talks to one AI company directly.
- [ ] **Backend relay for the Claude API key**, with **App Attest** (requests must come from
      the real app) and **per-user rate limits** — the key must never ship inside the app
      (see Decision Log → relay). Remove any local development key first.
- [ ] **Photo file sizes:** the review's "about X MB" reads a value Photos keeps per file that
      Apple doesn't officially document. Decide: switch to the fallback (estimate from pixel
      dimensions) or accept the small App Store review risk (see `ReviewView.swift`).
- [ ] **Hide the developer screens** — the chat's Developer menu (🔧: Camera Roll, Debug:
      Clustering, AI settings), and the TEMPORARY diagnostic types in `PhotoClusterEngine.swift` — so users only
      see the chat.
- [ ] **Explicit permission before anything goes to the AI** — Apple's App Review Guideline
      5.1.2(i): apps must "clearly disclose where personal data will be shared with third
      parties, including with third-party AI, and obtain explicit permission before doing
      so." So a clear yes from the user (not just a notice) before the first photos **or
      chat text** are sent to Claude; without it, the app falls back to its no-AI version
      (Decision Log → "Without AI, the app still works"). Plus
      the App Store privacy labels. On-device features send nothing.
- [ ] **Apple's privacy manifest:** check whether the app uses any APIs that Apple requires a
      privacy-manifest reason for, and add one if so (not checked yet).

**Revisit if needed (decided, but worth a second look with real users):**
- [ ] **Grouping ignores photo orientation** — left as-is by decision (see the Top pick
      status entry); recheck if users report the same shot in two orientations not grouping.
- [ ] **Backwards dates** ("Oct 4 to Sep 26 2025") read as a year-long range — left as-is
      by decision (see Decision Log).

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
  come from the real app, plus per-user rate limits. Required before TestFlight/App
  Store — **built then, not before** (Nov 2026: originally planned as the first task of
  the cloud AI milestone; moved later since only the developer's phone uses the app). For development on the
  developer's own phone only, a local, never-committed key is acceptable.
- **The OpenRouter test key lives in the phone's Keychain, not in a project file (Nov 2026).**
  A git-ignored `Secrets.xcconfig` read at build time was suggested and declined: the
  test tool (`AskAIDebugView.swift`) already works with a key pasted into the app once
  and kept in iOS's encrypted Keychain. A build-time file would add a key file that
  could be committed by mistake, and would copy the key into the app itself (readable
  from the installed app), for no gain. The shipping app needs no key at all — the
  relay server holds it.
- **The AI is the conversational face (decided Nov 2026).** The original appeal — "chat with
  an AI that clears out duplicates and keeps the best" — is what users want, even though the
  work underneath is on rails. So the AI talks, and the app keeps the rails:
  - **Fixed moments are written by us** (greeting, "Scanning…", results, "No duplicates in
    that range") — same every time, free. The AI runs only when the user types or a set is
    judged; someone who only taps costs just the photo judgments.
  - **The AI acts through levers the app offers** (Anthropic calls this "tool use"): set a
    date range, start a scan, open a set, re-pick with a preference, explain a pick. It can
    only pull the levers it's given. **It never gets a delete lever** — iOS's own
    confirmation stays the only way to delete.
  - **It speaks after the lever's result comes back** — the app does the action and tells
    the AI what actually happened, and only then does the AI write its reply — so it
    describes what happened rather than predicting it.
  - **Facts come from the app's screen, not the AI's words** — counts, sizes, which photo,
    anything about deleting stay in the photo row, badges and review screen. The AI talks
    around them ("Here's what I found — what do you think?").
  - **Only talks about what it's doing or looking for;** brief off-topic banter, then
    steers back. Guardrails are under AI architecture → Cost guardrails.
  - **Downsides accepted:** every user who types costs something (shapes pricing before the
    App Store — free tier vs. subscription, not decided); less predictable than a script,
    so testing means reading conversations; model choice matters more for conversation than
    it did for photo picks (Apple's tools already narrow the photo judgment; nothing on the
    phone helps with the talking).
  - *Considered:* AI fully behind the scenes with a scripted chat (cheapest, but rigid when
    people type something unexpected), and the AI answering only with actions (predictable,
    but doesn't feel like talking to an AI — the thing users want).
- **Which sets the AI judges, and how many photos (decided Nov 2026).**
  - **Every set with people, automatically, right after the scan** (with AI consent given).
    The chat presents the picks with confidence — no "want me to double-check?" offer: a
    user expects the app to get it right from the start, and offering a double-check would
    make them doubt the first answer.
  - **Fewer photos when most are bad:** only photos that pass the phone's checks are sent
    (today: no closed eyes; a blur cutoff could be added once one is checked against real
    sets), at most 10. If only one passes, the phone's pick stands and no AI is called; if
    none pass ("every photo is bad"), there's nothing worth judging — the phone's pick
    stands, no AI call.
  - **Whole photos, not crops around the people** — in many people photos the background
    matters as much (the mountain behind the couple). Considered for cost (≈⅓ the tokens)
    and face detail, rejected for that reason.
  - **In reserve:** judge just ahead of the user (first few sets at once, the rest as they
    move through the review), so sets never opened are never paid for — if costs matter at
    scale. Catch: a later set's ★ could shift when the user reaches it.
  - **On hold:** skipping sets where the phone seems confident — its confidence isn't proven
    (it was confidently wrong on the lake set before the blink fix).
  - **Cost:** about $0.0012 per set on Haiku 5.5, $0.023 on Sonnet 5.5 — a trip with 20
    people sets ≈ 2.4¢ / 46¢.
- **The date lever hands phrases to the hand-written parser; the AI never calculates dates
  (decided Nov 2026).** The AI turns free-form wording into a phrase the parser already
  understands ("the fortnight before my Christmas break last year" → "two weeks before
  Christmas 2025"); the parser works out the dates; the confirmation step shows them; if the
  parser refuses, the AI asks the user. Date arithmetic is a known weak spot for AI models
  (Apple's on-device model got "two weeks before Christmas" wrong) — this keeps the 197
  tested phrases in charge of the actual dates.
- **Without AI, the app still works (decided Nov 2026).** Apple expects an app to stay
  usable when a user declines (Guideline 5.1.2(i) consent). Declining AI, no internet, or a
  used-up daily AI budget all fall back to today's app: typed dates through the hand-written
  parser plus the calendar, the scan, the duplicate sets, the phone's ★ pick, and the full
  review/delete flow. Lost: free-form chat beyond dates, the AI's judging, re-picks by
  preference. Typing something the parser can't read gets a scripted reply ("Without AI
  help I can only understand dates — you can turn it on in Settings any time"). AI help can
  be switched on or off later in Settings. Designed in from the start, not bolted on.
- **"Top pick": offline by default, Claude on request (direction agreed; details open).**
  Each duplicate set shows one *top pick* — today chosen on the phone (see the "Top pick"
  status entry). In the set's sheet it's first with a ★ "Top pick" badge; the chat says "Here's my
  top pick from each — … whether you agree." It's labelled "top pick", not "best",
  because the choice may later come from Claude and the user's stated taste.
  - **Offline pick = the free default and the gate.** It handles objective flaws (blur,
    blinks), costs nothing, works for everyone, and is enough for most bursts. The UI
    doesn't explain *why* a photo was picked; a short explanation can live in an in-app
    FAQ, and if a user asks in the chat "why this one?" the app must be able to answer
    (the scan already records sharpness and eyes-open data per photo).
  - **Claude = taste, only when asked** — e.g. "I want photos with better landscapes".
    Claude re-picks using the stated preference and the ★ moves to its choices. This is
    the "re-pick" lever of the conversational AI (see Decision Log → "The AI is the
    conversational face"); today's chat is scripted and only understands dates.
  - **Open questions:** (1) should Claude ever step in automatically on near-ties?
    (suggested: no for v1 — only on request, so cost stays zero unless asked);
    (2) when a preference is stated, which sets does it apply to — all, the open one, or
    ask? Telling "landscape" sets from "selfie with nature behind" sets needs judgment.
    Idea to evaluate: a free on-device first pass (Apple Vision's image classification
    labels like beach/mountain/sky, plus the face detection already run — a face filling
    the frame = selfie) narrows the sets, then Claude ranks only those; (3) should stated
    preferences be remembered across scans?
  - **Cost estimate (measured Oct 2026):** a photo at 1024px is about 1,040 input tokens
    (Anthropic's formula: width ÷ 28 × height ÷ 28, rounded up; 768px ≈ 590), which
    matched OpenRouter's charges exactly. One set at the top-10 default ≈ $0.0012 on
    Haiku 5.5, ≈ $0.023 on Sonnet 5.5. The "reasoning" isn't the expensive part — the
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
