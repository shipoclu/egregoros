# Native frontend design and performance audit

**Reviewed:** 2026-07-12  
**Scope:** Phoenix LiveView UI, the browser bundle and hooks, CSS/media delivery, and the LiveView list/update boundaries that most affect perceived responsiveness. This is a static code audit, supplemented with the checked-in built asset sizes; it is not a substitute for device/network profiling.

## Executive assessment

The native frontend has a solid LiveView foundation. The main timelines, bookmarks, profile, notifications, messages, privacy lists, and badges use streams; pagination is cursor-based; status decoration is batched; and most media uses lazy image loading or metadata-only media preload. Those are the right primitives for a responsive feed.

The largest risks are concentrated rather than systemic:

1. Every page downloads, parses, and initializes code for expensive, infrequent features (E2EE recovery, BIP-39, custom media players, cropper, and mini-app/wallet support).
2. Video and cropper lifecycle code can multiply global event work during normal browsing and does not fully clean up.
3. Tag and relationship pagination retain and re-render growing ordinary lists instead of using streams.

Addressing those three areas first should make the application materially faster on modest mobile hardware and in media-heavy feeds, without changing the LiveView product model.

## Evidence and baseline

- The checked-in generated `priv/static/assets/js/app.js` is **516 KiB uncompressed / 112 KiB gzip**. Its CSS peer is **166 KiB uncompressed / 23 KiB gzip**. These are checked-in, non-digested build artifacts; production minification will reduce transfer size, but it will not remove the architectural issue that all code is in the initial execution graph.
- `assets/js/app.js` imports every hook plus E2EE/BIP-39 code at startup (lines 21-45), and registers all of them in the initial `LiveSocket` (lines 1448-1473).
- The mini-app host is rendered for all LiveViews when the mount hook assigns its closed state (`lib/egregoros_web/components/layouts.ex:190`), and its closed `<aside>` still mounts `MiniAppHost` (`lib/egregoros_web/mini_app_host.ex:123-142`). Its hook constructs wallet, readiness, authentication, and broker support immediately.
- `StatusVM.decorate_many/2` currently builds a bulk rendering context (actors, counts, viewer relationships, emoji counts, reblogs, mini-app cards) before mapping entries. This supersedes the N+1 concern in the older `perfomance_audit.md` for the normal LiveView feed path.
- The project already has useful backend query telemetry and benchmark baselines under `perf/`. Equivalent browser-level budgets are absent.

## Findings

| Priority | Finding | User impact | Recommended outcome |
| --- | --- | --- | --- |
| P0 | One eager application bundle includes all features | Slower first interaction and more main-thread parse/compile work on every page | Load feature code only when the matching UI is present or requested |
| P0 | Media player global event handling scales with the number of videos | Pointer movement and timers can become expensive on media-heavy timelines | Scope events to the active player and use explicit teardown |
| P1 | Cropper initialization has no lifecycle owner and can duplicate listeners | Navigation/profile edits can leave handlers retained; dragging can run more than once | Convert it to a LiveView hook with `destroyed`, stable listener references, and idempotent open/close |
| P1 | Tag and relationship lists are paginated as ordinary assigns | Diff, render, and socket memory grow with every loaded page | Use LiveView streams and incremental insertion/deletion |
| P1 | Remote Google Fonts is on the critical CSS path | Extra third-party request/stylesheet dependency before stable text rendering | Self-host subset WOFF2 fonts or use system fonts first with `font-display: swap` |
| P1 | Audio metadata work starts for every mounted audio card | Extra range requests and parsing even if an audio post is never played | Start ID3 parsing on intent/visibility; cancel it when removed |
| P2 | Large LiveViews duplicate feed, reply, and interaction orchestration | Behavior drift and a high cost to change or test common paths | Extract narrow shared server-side feature modules, not a large generic LiveView macro |
| P2 | No client-side performance budgets | Regressions in bundle size, interaction delay, and LiveView patch cost are invisible in CI | Add a small, reproducible browser-performance gate and telemetry dashboard |

### P0 — eager bundle and hidden mini-app initialization

`app.js` is both the LiveView bootstrap and a 1,668-line feature implementation. Static imports make E2EE recovery/messaging, the 2,048-word BIP-39 list, cropper, custom audio/video players, and mini-app wallet/broker code part of the initial download and parse cost. The mini-app host goes further: it is mounted while closed, so ordinary feed visitors initialize the hook's wallet adapter, readiness state, auth relay, and event registrations even when they never use a mini-app.

This is the clearest first-load modularity boundary: **bootstrap code must not own feature implementations**.

Recommended design:

1. Keep a small `app.js` containing Phoenix/LiveSocket setup, theme initialization, topbar, and a small set of universally needed hooks.
2. Make media, E2EE/passkeys, cropper, and mini-app support independent feature entry points. Load them with `import()` only when their server-rendered feature marker is present; use esbuild ESM splitting/chunks for production.
3. Do not render the mini-app hook while closed. Render an inert launcher/placeholder and mount the full host only after a mini-app card is opened. The mini-app feature chunk should load at that point.
4. Keep a tiny synchronous proxy hook only where LiveView requires a registered hook name before the dynamic module loads. The proxy should queue lifecycle work and delegate once the import resolves; it should not import unrelated features.

Success criteria: measure the initial, public-timeline JS separately from mini-app/E2EE/media chunks. Set an explicit gzip and parse-time budget for the first route. Do not treat minification alone as a fix.

### P0 — custom video players broadcast work globally

Each video player installs `document` `mousemove`, `mouseup`, and `fullscreenchange` listeners. The `mousemove` callback calls `resetControlsTimeout()` even when the pointer is not dragging that video (`assets/js/hooks/video_player_util.js:383-397`). Therefore, a feed with several video cards schedules/clears a controls timer for every player on every pointer movement anywhere in the document. The anonymous `fullscreenchange` listener cannot be removed by the cleanup function (`353-357`, compared with cleanup at `433-438`), retaining player closures after stream removal/navigation.

Recommended design:

- Use Pointer Events plus `setPointerCapture` on the progress control. Attach movement handling only for the active drag; do not keep a document `mousemove` handler per player.
- Keep controls visibility handling on the player element only, throttle it to one `requestAnimationFrame`, and do not schedule timers for paused/offscreen players.
- Store every document-level handler in a named reference and remove it in cleanup. Pause media, cancel timers/animation frames, and release any Web Audio resources on teardown.
- Apply the same pointer-capture pattern to audio seeking. Audio does not currently reset timers globally, but it still adds two document listeners per card.

This is a responsiveness issue rather than a cosmetic cleanup: a media-heavy timeline can degrade ordinary scrolling, hovering, and clicking.

### P1 — cropper lifecycle is not LiveView-safe

`initImageCropper` runs on DOM content loaded and after every LiveView page-loading stop (`assets/js/app.js:1475-1480`). It creates an `ImageCropper` outside the hook lifecycle (`assets/js/hooks/image_cropper.js:384-389`). The instance installs anonymous input/click/key listeners, including a window `keydown` listener that has no removable reference (`25-53`), but exposes no `destroy` method.

There is also an immediate interaction problem: every `open()` can call `setupDragListeners`; it does not first tear them down (`156-166`). Cached image loading can execute both the `onload` path and the `complete` path, making duplicated drag listeners plausible.

Recommended design:

- Replace the global initializer with `phx-hook="ImageCropper"` on the cropper section.
- Bind named handlers once in `mounted`; make `open` idempotent; use Pointer Events/pointer capture for movement.
- In `destroyed`, abort active `FileReader`/image work where possible, remove every local/window listener, revoke object URLs if used, and call `unlockScroll` if the modal is open.
- Test a live navigation away from settings and repeated open/close cycles by asserting listener-independent outcomes (one crop movement, Escape closes only the current dialog).

### P1 — two paginated views bypass streams

`TagLive` keeps all decorated posts in `@posts`, concatenates the next page, de-duplicates the entire list, and reassigns it (`lib/egregoros_web/live/tag_live.ex:387-414`). Its template then loops over all cards (`465-470`). `RelationshipsLive` follows the same pattern for `@items` (`102-136`, `188-192`). Each additional page increases:

- server-side socket memory;
- BEAM work to concatenate/de-duplicate;
- rendered/diffed list size; and
- browser DOM and patch application work.

Use the same stream shape already proven in `TimelineLive`, `ProfileLive`, `BookmarksLive`, and `NotificationsLive`: `stream/4` at mount, `stream_insert/4` for each page item, and `stream_delete/3` for unfollow/removal. Keep only cursor/end/count state as assigns. Where a map such as `follow_map` is required, bound it to the streamed window or recompute only the affected entry.

This matters most when users load dozens of tag/relationship pages, but it is cheap to prevent now and preserves the frontend's otherwise consistent list architecture.

### P1 — fonts and media create avoidable critical-path work

`assets/css/app.css` imports Google Fonts with `@import`. That introduces a remote stylesheet dependency and a second font request chain before text settles. The interface already declares suitable system fallbacks.

Prefer either:

- a system-font-first design (best initial render); or
- locally hosted, subset WOFF2 files with `@font-face`, `font-display: swap`, and only the weights actually used.

For audio, every `AudioPlayer` calls `parseID3` on mount, which issues a `Range: bytes=0-131072` request (`assets/js/hooks/audio_player_util.js` and `id3_parser.js`). The attachment component mounts an audio hook for every audio card, including cards never played. Defer this request until the user presses play or an `IntersectionObserver` determines the item is near the viewport; use an `AbortController` and discard results if the hook is destroyed.

Images are generally handled well: attachment and avatar images use `loading="lazy"`, and media uses `preload="metadata"`. Improve the remaining largest image opportunities by declaring `width`/`height` or `aspect-ratio` to reserve layout space, and use `decoding="async"` consistently for non-hero feed images.

### P2 — server-side modularity should follow feature seams

The component layer is already sensibly split (`StatusCard`, attachment grid, composer, notification items), and `StatusVM` is a useful batching boundary. The live modules still combine several responsibilities: data-source selection, cursor pagination, PubSub subscription tracking, compose/reply form state, mention search, uploads, interactions, and rendering. `TimelineLive` is 1,809 lines; similar interaction/reply flows are repeated in tag, profile, search, bookmarks, and status views.

Do not extract a universal "feed LiveView" abstraction: timeline membership, subscription semantics, and page controls differ enough that it would become opaque. Instead extract small, testable service boundaries:

- `FeedPagination`: accepts a fetch function and owns cursor/end/stream insertion rules.
- `FeedInteractions`: validates an action and returns the authoritative status entry to stream back.
- `ReplyComposer`: owns reply form defaults, normalization, uploads, mention suggestions, and publish outcome.
- `NotificationBadge`: provides a deliberately cheap count/cache API rather than calling `Notifications.list_for_user(...) |> length()` on every LiveView mount.

Use behaviours/Mox at any future remote/federated boundary, but keep these local UI-service modules as plain functions first. Add focused LiveView tests around streams, pagination, and server-authoritative modal state before moving handlers.

### P2 — make responsiveness measurable

Backend query telemetry and benchmark fixtures are a strong start, but they do not reveal a 200 ms long task in the browser or a 100 KiB bundle regression. Add:

1. A production-build asset budget test for initial JS/CSS and feature chunks (gzip and Brotli sizes).
2. A small Playwright/Lighthouse mobile-profile journey: cold public timeline, load two pages, open/close compose, and open one media item. Record LCP, INP proxy/long tasks, cumulative layout shift, and transferred bytes.
3. `PerformanceObserver` instrumentation for long tasks and navigation timings, sampled to application telemetry with route and device-class tags.
4. Phoenix telemetry around LiveView mount/event/render durations and diff byte size, correlated with timeline size. Alert on p95 rather than optimizing one local average.

Suggested initial guardrails (to calibrate against real users before enforcing strictly): no long task above 100 ms during first timeline interaction on a mid-tier mobile profile; no per-video document-level pointer work; and no growth in initial bundle bytes when an isolated feature is added.

## What should remain

- LiveView streams and cursor pagination on the main feed paths.
- Server-authoritative composer/modal state with client hooks used for immediate UX only.
- `StatusVM.decorate_many/2` as the batch rendering context; avoid reverting to per-card query helpers.
- `IntersectionObserver` timeline sentinels and their cleanup pattern.
- Lazy images, metadata-only audio/video preload, and production digested static assets.

## Recommended execution order

1. Add a browser measurement baseline and production bundle report, then split/defer mini-app, E2EE, cropper, and media code.
2. Fix video/audio listener ownership and cropper lifecycle, with regression tests for removal and repeated open/close.
3. Stream `TagLive` and `RelationshipsLive` and add pagination tests that verify old entries remain without re-rendering the collection.
4. Remove the remote font dependency and reserve media layout dimensions.
5. Refactor repeated LiveView handlers only behind behavior-preserving tests and metrics.

## Validation notes

- No application behavior was changed for this audit, so no test suite was run.
- The upstream Pleroma checkout referenced by the repository instructions was not present at `../pleroma`; this audit therefore relies on the current codebase and its existing performance baselines rather than a direct upstream comparison.
