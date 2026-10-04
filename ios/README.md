# Firas AI for iPhone and iPad

Native SwiftUI client for the Firas AI backend.

## Current local difficulty checkpoint — 2026-10-04

Agent is removed from both apps; Dark transparent glass is the default and themes stay
in Settings. The current local QA APK is
[FirasAI-difficulty-release-qa.apk](D:/tmp/firas-native-difficulty-2026-10-04/final-v4/FirasAI-difficulty-release-qa.apk),
SHA-256 `63281f3fedb592550cece9021ab33d1dec40c120bba13ac35f2aa0f4b7311583`. Exact installed API35 bytes verify; it is unpublished.
Android passes 376 JVM tests/38 suites and 150 actual chooser pointer/geometry cases in
five configurations, with synthetic UI callbacks. iOS difficulty is source implemented;
all 19 Swift suites and iPhone/Simulator execution remain 0 on Windows.

Seven levels now retain calibrated ordinary Chat instructions, including attached
context. Cancel keeps the draft; pre-POST retirement blocks stale dispatch and post-POST
cloud observation continues. Plan and remaining inline slash parity remain pending.
The Agent APNs source guards are tested locally but not deployed. See
[current behavior and proof limits](D:/Programming/Projects/FirasAI/docs/mobile-difficulty-parity.md).
Earlier sections below describe their recorded historical sources/APKs and are not
additional current execution claims.



## Requirements

- macOS with Xcode 26 or newer
- iOS / iPadOS 18 or newer
- The production API at `https://firasai.org` or a local Firas AI server

## Run

1. Open `FirasAI.xcodeproj` in Xcode.
2. Select the `FirasAI` scheme and an iPhone or iPad simulator.
3. Build and run.

The default API base URL is declared in `FirasAI/Resources/Info.plist` under
`FIRAS_API_BASE_URL`. Keep production on HTTPS. Local HTTP development is allowed only for
local networking by the app's ATS configuration.

## Architecture

- SwiftUI + Observation for UI state.
- An actor-isolated API client owns the shared `URLSession` and cookie session.
- Durable Chat, Code, media and Omnix work starts server-side and is polled without cancelling when a view
  disappears. Only the explicit Stop action calls the cancel endpoint.
- Image, cover, video, and music creation lives inside Firas Chat's `+` sheet and uses the
  production `/api/image/job`, `/api/video/job`, and `/api/music/job` durable-job routes.
- Terminal jobs route back into the correct Chat/Code/Brain surface through APNs, with the
  bundled `FirasComplete.wav` sound and a foreground completion haptic before the final reveal.
- Dark is the default, with transparent glass controls. The six web themes are mirrored as
  native design tokens and stored per device; theme controls appear only in Settings,
  matching the website's current local-only preference model.
- Native Liquid Glass is used on iOS 26+, with material fallbacks on iOS 18–25.

Agent has been removed from both mobile apps at the owner's request. It is not a pending port.
The iOS runtime has no Agent destination, store or submission operation. Agent is absent from
the product and job-submission enums, navigation labels and quota labels. Legacy history and
backup flags remain readable for filtering; old Agent notification payloads are ignored, and
foreground Agent banners are suppressed. Website/backend Agent, stored server records and
ongoing server jobs are unaffected. The former connected Android APK is superseded historical
evidence and is not a fallback for the current native client.

No web source file is changed by this project.

## Shared website service and intent

The iPhone app is a native cloud client of `firasai.org`; it does not host an Omnix worker.
`omnix 1` in Chat's model sheet and the Code home opens the same `/api/omnix/access` request
used by the website. One account has one approval record. When the server reports that the
account's isolated cloud workspace is ready, the client can submit a task, show observed
execution steps, request recovery of that same task, allow or deny a pending action once,
explicitly stop execution, and download the account's cloud files. Chat and Code recover
their corresponding server sessions through `latestJobs`; closing the sheet stops local
polling and does not cancel the task. Only account/product-bound identifiers are saved on
the device, without prompts, results or credentials.
Cloud memory, files, runs and Telegram connections are authorized by that same website
account and server ownership checks. No separate iPhone memory or worker is created.

Native Chat and Code call authenticated `POST /api/intent` with the complete request (up to
60,000 UTF-16 characters) and bounded recent context. A validated browser-build decision may
start Code generation. Questions, native source requests and uncertain classifications use a
normal answer instead; uncertainty never defaults to an HTML build or Code usage admission.
Unsupported document/media requests receive a truthful text response rather than a fabricated
artifact. This depends on deploying the website's `/api/intent` route; an unavailable route
falls back to normal answers and clarification.

Local Code editor projects are partitioned by account. Legacy projects in the old unscoped
directory are preserved on disk, but are not silently assigned to the next account that signs in.
They need an explicit account migration before appearing in the new library.
This local editor storage is separate from Omnix's shared server files.

Release configuration accepts only the website HTTPS origin; local HTTP overrides require a
Debug build. API redirects stay on their original origin. Generated Code previews use an
in-memory WebKit profile without the native account cookie jar, file navigation or native bridge.
No provider credentials or engine source belongs in the app bundle. These boundaries protect
server internals; a downloaded client binary and its displayed content can still be inspected.

## Validation

On Windows, `node ios/scripts/audit-products.mjs` performs structural and contract checks only.
The full website checkout also supports `node ios/scripts/audit-omnix-cloud.mjs`; it reads
server source contracts and therefore needs the repository's `tools/` directory.
`node --test tools/native-intent-router.test.mjs` checks the real native intent adapter/parser
and the shipping server completion helper against deterministic fake upstreams. It verifies
the shared router pin, disabled thinking, bounded fallback, unchanged vision/legacy calls,
abort handling and no upstream error-body logging. Passing it does not measure real model
latency or authenticated API behavior.

It does not compile Swift or run an iPhone simulator. On macOS with Xcode 26 or newer,
run the complete validation from the repository root:

```sh
bash ios/scripts/validate-xcode.sh
```

The runner is prepared to compile and execute nineteen suites: client policy, Omnix cloud policy,
account skills, difficulty policy, account-skill store ownership/cancellation races, chat text
rendering, chat view projection, chat image presentation, chat skill selection, ChatStore races,
difficulty selection, difficulty Store admission, prompt engineer,
model generation, CodeStore races, media wire encoding, source selection, MediaStudioStore races,
and real APIClient media transport against synthetic loopback files. Skill selection checks real
pin state, draft ownership and request encoding; owner races check successful empty refreshes,
stale results and cancellation. Production models, the backup sanitizer and five stores are
checked against limited device/transport fixtures. The transport suite uses a runner-owned
Python 3 child and checks streaming limits, MIME/container screening, cancellation, redirect
rejection, captured cookies, staging cleanup and the complete serialized Chat body limit.
It then builds the full app for Debug and Release Simulator destinations and retains compiler
logs, build logs and `.xcresult` bundles. These tests have not been run on the Windows host.

Then exercise Arabic explanation, French native-code, malformed-classifier,
account switch during an access or cloud task, same-origin login, and preview navigation cases on
Simulator. Swift compilation and Simulator checks remain required before shipping this change.
Cloud validation should additionally cover task recovery after closing/reopening, explicit stop,
once/deny action approval, own-file downloads, and denial of another account's identifiers.
Cloud results are currently displayed as selectable plain text rather than a full Markdown renderer.

## Mobile quality update (2026-10-03)

Account Settings now opens a native My Skills manager using the website's same account storage:
create, edit, enable/disable and delete. Full edits POST with the original id; toggles use a
minimal PATCH so they cannot overwrite an edit made on another device. Server content screening
remains authoritative, and native feedback is available in Arabic and English.

Chat now retains pending Stop intent, reserves Send before creating the first conversation,
rejects stale selection/account results, keeps earlier attachments in saved history, and avoids
publishing an unchanged transcript on every poll. Rich text parsing runs in a bounded actor cache;
camera images are downsampled during decode. Scrolling follows the response only while the reader
is near its bottom. Native glass controls share grouping/fallback behavior and real touch targets;
the fixed three-second completion hold has been removed.

Editable Chat text and attachment context now belong to the store in memory, so native navigation
does not discard them. Failed admission, Stop and navigation retire draft consumption while
keeping editable input. Only the matching accepted CID can clear unchanged submitted portions;
later text or context edits survive older receipts. Same-account authentication epochs preserve
unsent input and fence old bindings; changing accounts clears private drafts and context. Pure
policy and production-store tests cover these cases in the Mac runner, but have not been compiled
or executed on Windows. Process-termination draft persistence is not implemented by this policy.

Chat and Settings expose generation 1 and 1.1. New Chat and Code requests default to
the shipping website's 1.1, while an explicitly saved generation 1 choice stays selected.
Legacy requests omit `mgen`; 1.1 requests send exactly `"1.1"`. Saved replies, answer alternatives,
retry references, imported backups and resumed old job pointers preserve their original
generation. Model names reflect the selection used by each request. The separate Omnix path
continues to display generation 1.

Run `node ios/scripts/audit-performance.mjs` and `node tools/mobile-contract-audit.mjs` in addition
to the source audits above. For compilation, pure behavior tests, and Debug/Release Simulator
builds on macOS, use `bash ios/scripts/validate-xcode.sh`. Source checks are not device validation.
See `../docs/mobile-feature-parity.md` for remaining website features to port and
`../docs/native-mobile-performance.md` for device acceptance criteria.

Media creation now saves one bound user/assistant turn in the current ordinary Chat before
submitting `cid`/`chatId` to the shipping image, video or music job route. A durable dispatch
fence permits one POST; a lost response, app relaunch or unknown receipt uses GET by the same CID.
Opening Studio never submits a render, and dismissing it does not stop an accepted cloud job.
`node --test tools/native-media-binding.test.mjs` runs the actual durable server modules against
the same wire fixture used by the Swift encoding suite. `node ios/scripts/audit-media.mjs`
checks source wiring. Both run on Windows; Swift compilation and authenticated media creation,
download, Share and Photos validation remain required on a Mac/iPhone.

The 2026-10-04 account-skills reliability update shares one app-owned store between
Settings and the Chat picker. User actions capture account/epoch/lifetime tickets
before queuing work; reads and mutations use frozen credentials across transport
waits. Lost, cancelled or retired write responses block another mutation until a
later owned list review and explicit acknowledgement. Closing the manager retains
this uncertainty in the current app process. A successful new-skill response retains
its canonical ID in a newer edited draft, so its next Save updates that accepted row.
No mutation is replayed. Process-restart recovery is not implemented for this guard.

The account-skills production-store fixture has 70 authored assertion sites and is included
in the current 16-suite Mac validation runner. Source audits and bilingual catalogue checks pass;
Swift compilation, fixture execution and actual account/editor behavior remain unrun
on Windows. Frozen source evidence is under
`D:/tmp/firas-keyboard-2026-10-04/ios-skills/`.

## Ordinary Chat and Photos reliability update (2026-10-04)

Ordinary Chat dispatches one job-admission POST. A lost acknowledgement, HTTP 408/409 or
server failure is reconciled with GETs for the original CID and its actual job ID; the client
does not replay the POST. The pre-admission record also permits GET-only recovery when a
store is reconstructed from an available receipt. Stop captures the owner, authentication
epoch and CID at the tap, so a queued control cannot target a replacement job or retire its
draft. Stop intent is reread after restoration waits and before the observer starts. Control
recovery is bounded, and an authoritative completed answer wins a Stop race.

After an owned CID lookup reports an unavailable receipt, the user can check the original
answer again or explicitly remove its reference from this app. Local removal keeps editable
text and attachments, sends no cancel or admission request, and does not remove server history.
The cloud answer may still finish; a later explicit Send creates a new CID.

The existing ordinary Chat v1 UserDefaults record contains full messages and attachment
context, rather than identifiers alone. Writing and reading it back confirms in-process
acceptance, not atomic disk durability or fsync. The synthetic reconstruction fixture reuses
the same defaults suite; it does not prove recovery after OS termination. Unsent drafts remain
memory-only. Initial history updates read canonical history before PUT, but a concurrent writer
can still race the GET-to-PUT interval; a backend atomic append is outside this slice.

User image rows fall back to stored full sources when thumbnails are absent, and retain the
original image index for preview even when another image fails to decode. Grid images are
downsampled to 360 pixels and deliberate previews to 1,600 pixels. Recent Photos thumbnails
are requested asynchronously with exact request leases, stale/degraded callback checks and
cancellation when the tile disappears. These are source-backed changes; frame time, memory
and real Photos authorization behavior have not been measured on an iPhone here.

Long-chat request preparation now calculates each message's existing grapheme cost once,
preserving the 320,000-character threshold, oldest-first removal and final two complete
messages. Thumbnail strings are still joined before counting, including graphemes that cross
their boundaries. Only the inference suffix is trimmed; saved history remains unchanged.
The text renderer checks cancellation after synchronous Markdown parsing and before cache
accounting, eviction or insertion. This fence does not interrupt Foundation parsing already
in progress, and neither change has been timed or profiled on an iPhone here.

The production ChatStore suite now contains 77 scenario blocks and 171 authored `expect`
sites: the earlier admission/recovery/control slice added 22 blocks and 38 sites, and the
request-budget slice adds seven blocks and 18 sites using actual Store requests and saved
history. The Foundation-only image presentation suite retains 36 authored assertion sites.
All 16 Swift suites, including all 171 ChatStore assertion sites, have **0 executions** on
this Windows host. Source checks pass; no Swift compiler, Xcode build, Simulator/device
behavior or performance/profile proof is available here. These Mac and physical-device
checks remain required; no full iOS build or runtime/profile pass is claimed.

The native `/prompteng` helper remains an app-owned durable operation, with its language choice
shown only when the command token matches. It uses a stable CID without creating a Chat turn;
uncertain admission is recovered by reads rather than replay. Applying a result checks the
captured composer revision, and leaving the panel does not stop its cloud task. This interface
does not reintroduce Agent or theme controls outside Settings.
