# Tasks / Backlog

This is a living checklist for **Egregoros** (Postgres + Elixir/OTP + Phoenix/LiveView).

Notes:
- Keep tasks **small** and **TDD-first** (failing test → implementation → refactor).
- Prefer fixtures in `test/fixtures/` for federation compatibility tests.
- When behavior is missing (authz rules, remote lookups, caches), introduce a behaviour boundary and use **Mox** in tests.

## Next priorities (recommended)

- [x] **Mastodon `Status` entity completeness** (reduce client quirks)
  - [x] Add contract-style tests for required keys/types from `docs.joinmastodon.org/entities/Status/`.
  - [x] Ensure optional-but-expected keys are present (`application`, `edited_at`, `filtered`, etc.).
  - [x] Ensure reblogs (`Announce`) map cleanly to Mastodon “reblog” shape (bookmark/like/reblog flags reflect the original status).
  - [x] Ensure reply metadata is complete (`in_reply_to_id` + `in_reply_to_account_id`) when parent + actor are known.
- [x] **Status/thread view polish** (`/@:nickname/:uuid`)
  - [x] Make reply UI consistent with the main composer (same component, same options).
  - [x] Reply in-place/modal from timeline (no navigation required).
  - [x] Improve thread rendering UX (ancestors/descendants layout, navigation, empty/loading states).
- [x] **Thread completion expansion**
  - [x] Fetch missing ancestors/OPs best-effort when ingesting replies and when fetches are triggered by likes/announces (bounded + async).
- [x] **Finish `Update`/`Delete` impersonation constraints**
  - [x] Add/verify tests so cross-actor edits/deletes are impossible.

## Federation core (ActivityPub)

- [x] **Ingest `Update` activities**
  - [x] Apply **actor profile updates** (`Person`) safely (no cross-actor updates).
  - [x] Apply **object edits** (`Note`) where compatible (edit history + visibility rules).
  - [x] Decide/implement **object upsert semantics** for Updates (currently “insert-or-return existing”).
- [x] Ingest `Move` activities (account migration).
- [x] Implement/verify `Update`/`Delete` constraints for **impersonation safety** (e.g. Update actor must match updated actor id).
- [x] Improve “fetch-on-demand” ingestion contexts so internally-fetched activities aren’t rejected as “not targeted”.
- [x] Keep/expand thread completion: fetch missing replies/ancestors/descendants when receiving partial threads.

## Mastodon API compatibility

- [ ] Fill out remaining Mastodon API gaps that clients expect:
  - [x] `GET /api/v1/conversations` (currently returns `[]`)
  - [x] `GET /api/v1/favourites` (was stubbed)
  - [x] `GET /api/v1/bookmarks` (was stubbed)
  - [x] Status edit/Update flows end-to-end (API + AP Update).
  - [x] Ensure Status entity fields match `docs.joinmastodon.org/entities/Status/` where feasible.

## Performance / scalability

- [ ] Make federation ingress/egress consistently **async** (Oban) with back-pressure, retries, and rate limits.
- [x] Benchmark suite: realistic seed + perf probes for timelines, thread views, search, ingestion bursts (see `BENCHMARKS.md`).
- [ ] Keep caching behind behaviours so backends can be swapped (ETS → Redis, etc.).
- [ ] **Timeline read-path performance follow-ups** (from `perfomance_audit.md` + `perfomance_addendum_by_claude.md`)
  - [ ] Define budgets (p95, query count) and collect baselines (`EXPLAIN (ANALYZE, BUFFERS)`) for:
    - [ ] `Objects.list_home_statuses/2` for (a) no follows, (b) dormant follows.
    - [ ] Tag timeline + `only_media=true`.
    - [ ] `Objects.count_note_replies_by_parent_ap_ids/1` on a page-sized parent set.
  - [ ] Bench suite: add cases that reproduce the edge scenarios above (especially sparse home timelines).
  - [x] LiveView timelines: remove N+1 patterns in `EgregorosWeb.ViewModels.Status.decorate_many/2` + `EgregorosWeb.ViewModels.Actor.card/1` (batch context like `MastodonAPI.StatusRenderer.rendering_context/2`).
  - [x] Mastodon notifications: batch `NotificationRenderer` (accounts + statuses) and avoid per-item `StatusRenderer.render_status/2`.
  - [x] Add missing DB index support for notification patterns: index `objects.object` (and a composite such as `(type, object, id)` if plans need it).
  - [x] Rewrite hashtag predicate to hit the existing `objects_status_data_path_ops_index` (prefer `data @> %{"tag" => [...]}` over `data->'tag'` expressions).
  - [x] Home timeline query: split into actor-driven + addressed-to-me branches and merge (e.g. `UNION ALL` + outer `ORDER BY id DESC LIMIT ?`), with a fast-path for “no follows”.
  - [x] Media-only filter: make it index-friendly (denormalized `has_media`/`attachment_count` column + index, or a validated functional index).
  - [x] Threads/replies: add a normalized `in_reply_to_ap_id` field + index, then rework replies count + context queries to avoid per-node DB traversal (recursive CTE and/or `conversation_id` strategy).
  - [x] Observability: add telemetry spans + query tagging for timeline reads; optionally add lightweight ETS caches for hot `Users.get_by_ap_id/1`/counts behind behaviours.
  - [ ] (Longer-term) Evaluate a materialized `timeline_entries` derived cache (feature-flagged, async fan-out/backfill, correctness filters for blocks/mutes/deletes).

## Security / privacy

- [x] Work through remaining open items in `security.md` and mark them as addressed.
- [x] Signature strictness tightening (keep **off by default**; enable via `config :egregoros, :signature_strict, true`).
- [ ] Continuous audit for privacy leaks (public timelines, streaming, media access, DM visibility).

## UX / UI (LiveView)

- [ ] Work through `frontend_checklist.md` (prioritized UX parity with Mastodon/Pleroma clients).
- [ ] Composer polish: unify controls, fix edge cases, add missing attachments flows, improve keyboard UX.
- [ ] Thread/status view polish (navigation, scroll restoration, reply modal UX).
