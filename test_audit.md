# Test Suite Audit Plan

This document is a working plan + checklist for reviewing Egregoros’ test suite.

Goals:
- Ensure tests verify the **behaviors we actually care about** (security/privacy invariants, federation correctness, Mastodon/Pleroma API compatibility, UI correctness).
- Reduce **brittleness** (tests that fail for incidental HTML changes, timing, global config, or process ordering).
- Reduce **uneconomical tests** (slow integration tests where a smaller unit test would suffice).
- Identify and fill **coverage gaps** in critical areas (authz, privacy/DMs, signature verification, ingestion, delivery).

Non-goals:
- Chasing arbitrary “100% coverage”.
- Rewriting tests purely for style if they’re already stable and meaningful.

## Baseline (current state)

- `mix test --cover` (2026-01-12): `1308` tests, `0` failures, **84.50%** total coverage (threshold `85%`).
- “Smell” checks:
  - No `Process.sleep/1` / `:timer.sleep/1` occurrences in `test/`.
  - No `Application.put_env/delete_env` occurrences in `test/`.
- Lowest-coverage modules worth targeting early (high ROI for coverage gate):
  - `EgregorosWeb.WebSockAdapter` (0%)
  - `Egregoros.UserEvents` (~54%)
  - `Egregoros.InstanceSettings` (~60%)
  - `EgregorosWeb.Live.Uploads` (~50%)
  - `Egregoros.Workers.RefreshRemoteUserCounts` (~40%)
- Known test-suite noise:
  - Occasional `Postgrex.Protocol disconnected` log spam during suite/precommit runs (likely a process escaping the SQL sandbox owner lifetime).

## Review Criteria (per test / per file)

For each test file, answer:
1. **Intent:** What user-facing or security-critical behavior is this validating?
2. **Signal:** Does it fail for the right reasons? (Good assertions, not incidental output.)
3. **Determinism:** Does it avoid time dependence, global env changes, ordering dependence?
4. **Scope:** Is the level (unit vs integration vs LiveView) appropriate?
5. **Redundancy:** Is it duplicating coverage elsewhere? If yes, can we delete or merge?
6. **Cost:** Is it disproportionately slow? Can we use Mox / a unit boundary instead?

## Automated “Smell” Checks (always on)

These should converge to **zero occurrences**:
- `Process.sleep/1` or `:timer.sleep/1` in tests.
- Global config mutation in tests (`Application.put_env/delete_env`) where a process-local override would do.
- Tests with no meaningful assertions (`assert true`, “smoke tests” without verifying effects).
- Flaky waiting patterns (polling, sleeping) instead of deterministic synchronization.

## Workflow

1. **Inventory & metrics**
   - Count tests per file; locate the heaviest/slowest files.
   - Use `mix test --cover` to find low-coverage modules that matter.
2. **Mechanical cleanup**
   - Replace sleeps with deterministic state manipulation or process synchronization.
   - Introduce/configure a process-local runtime config override (so tests can stay async).
3. **Semantic review**
   - Go file-by-file, tagging each as:
     - ✅ keep
     - 🛠 refactor (brittle/slow)
     - 🧪 add coverage (missing cases)
     - 🗑 remove (redundant / nonsensical)
4. **Guardrails**
   - Prefer boundaries + Mox for “future” behaviors.
   - Keep commits small and semantically scoped (one refactor or one coverage area per commit).

## Checklist (test files)

Mark each file after review:
- [ ] test/egregoros/activities/accept_cast_and_validate_test.exs
- [ ] test/egregoros/activities/announce_cast_and_validate_test.exs
- [ ] test/egregoros/activities/builders_test.exs
- [ ] test/egregoros/activities/create_cast_and_validate_test.exs
- [ ] test/egregoros/activities/delete_cast_and_validate_test.exs
- [ ] test/egregoros/activities/delete_side_effects_test.exs
- [ ] test/egregoros/activities/emoji_react_cast_and_validate_test.exs
- [ ] test/egregoros/activities/follow_cast_and_validate_test.exs
- [ ] test/egregoros/activities/helpers_test.exs
- [ ] test/egregoros/activities/like_cast_and_validate_test.exs
- [ ] test/egregoros/activities/move_ingest_test.exs
- [ ] test/egregoros/activities/note_cast_and_validate_test.exs
- [ ] test/egregoros/activities/undo_authorization_test.exs
- [ ] test/egregoros/activities/undo_cast_and_validate_test.exs
- [ ] test/egregoros/activities/update_cast_and_validate_test.exs
- [ ] test/egregoros/activities/update_ingest_test.exs
- [ ] test/egregoros/activities/update_note_ingest_test.exs
- [ ] test/egregoros/activities/update_side_effects_test.exs
- [ ] test/egregoros/activity_pub/object_validators/types_test.exs
- [ ] test/egregoros/auth/bearer_token_test.exs
- [ ] test/egregoros/auth/default_test.exs
- [ ] test/egregoros/authz/oauth_scopes_test.exs
- [ ] test/egregoros/avatar_storage/local_test.exs
- [ ] test/egregoros/banner_storage/local_test.exs
- [ ] test/egregoros/bench/runner_test.exs
- [ ] test/egregoros/bench/seed_test.exs
- [ ] test/egregoros/bench/stats_test.exs
- [ ] test/egregoros/bench/suite_test.exs
- [ ] test/egregoros/cbor_test.exs
- [ ] test/egregoros/compat/upstream_fixtures_test.exs
- [ ] test/egregoros/custom_emojis_test.exs
- [ ] test/egregoros/deployment_test.exs
- [ ] test/egregoros/direct_messages_test.exs
- [ ] test/egregoros/discovery/implementations_test.exs
- [ ] test/egregoros/discovery_test.exs
- [ ] test/egregoros/dns/cached_test.exs
- [ ] test/egregoros/dns/inet_test.exs
- [ ] test/egregoros/e2ee_test.exs
- [ ] test/egregoros/federation/actor_discovery_test.exs
- [ ] test/egregoros/federation/actor_test.exs
- [ ] test/egregoros/federation/announce_object_fetch_test.exs
- [ ] test/egregoros/federation/delivery_test.exs
- [ ] test/egregoros/federation/fetch_thread_ancestors_test.exs
- [ ] test/egregoros/federation/follow_flow_test.exs
- [ ] test/egregoros/federation/follow_remote_async_test.exs
- [ ] test/egregoros/federation/incoming_follow_accept_test.exs
- [ ] test/egregoros/federation/incoming_follow_reject_test.exs
- [ ] test/egregoros/federation/incoming_undo_follow_test.exs
- [ ] test/egregoros/federation/like_object_fetch_test.exs
- [ ] test/egregoros/federation/outgoing_delivery_test.exs
- [ ] test/egregoros/federation/signed_fetch_test.exs
- [ ] test/egregoros/federation/thread_fetch_test.exs
- [ ] test/egregoros/federation/thread_replies_fetch_test.exs
- [ ] test/egregoros/federation/webfinger_test.exs
- [ ] test/egregoros/follow_requests_test.exs
- [ ] test/egregoros/html_test.exs
- [ ] test/egregoros/http/req_test.exs
- [ ] test/egregoros/http/stub_test.exs
- [ ] test/egregoros/http_date_test.exs
- [ ] test/egregoros/http_test.exs
- [ ] test/egregoros/instance_settings_test.exs
- [ ] test/egregoros/interactions_test.exs
- [ ] test/egregoros/keys_test.exs
- [ ] test/egregoros/maintenance/refetch_remote_actors_test.exs
- [ ] test/egregoros/media_storage/local_test.exs
- [ ] test/egregoros/mentions_test.exs
- [ ] test/egregoros/notifications_pubsub_test.exs
- [ ] test/egregoros/notifications_test.exs
- [ ] test/egregoros/oauth/scopes_authorization_test.exs
- [ ] test/egregoros/oauth/token_schema_test.exs
- [ ] test/egregoros/oauth_test.exs
- [ ] test/egregoros/objects_test.exs
- [ ] test/egregoros/passkeys/webauthn_test.exs
- [ ] test/egregoros/performance_regressions_test.exs
- [ ] test/egregoros/pipeline_cast_and_validate_test.exs
- [ ] test/egregoros/pipeline_test.exs
- [ ] test/egregoros/publish_test.exs
- [x] test/egregoros/rate_limiter/ets_test.exs
- [ ] test/egregoros/relationship_schema_test.exs
- [ ] test/egregoros/relationships_test.exs
- [ ] test/egregoros/relays_test.exs
- [ ] test/egregoros/release_healthcheck_test.exs
- [x] test/egregoros/runtime_config_test.exs
- [x] test/egregoros/safe_url_test.exs
- [ ] test/egregoros/security/html_scrubber_security_test.exs
- [x] test/egregoros/security/safe_url_no_dns_security_test.exs
- [ ] test/egregoros/security/uploads_security_headers_test.exs
- [ ] test/egregoros/signature/http_actor_fetch_test.exs
- [ ] test/egregoros/signature/http_test.exs
- [ ] test/egregoros/timeline_pubsub_scoping_test.exs
- [ ] test/egregoros/timeline_pubsub_test.exs
- [ ] test/egregoros/timeline_test.exs
- [ ] test/egregoros/uploads_config_test.exs
- [ ] test/egregoros/users_race_test.exs
- [ ] test/egregoros/users_test.exs
- [ ] test/egregoros/workers/deliver_activity_test.exs
- [ ] test/egregoros/workers/deliver_to_actor_test.exs
- [ ] test/egregoros/workers/fetch_actor_test.exs
- [x] test/egregoros/workers/follow_remote_test.exs
- [ ] test/egregoros/workers/ingest_activity_test.exs
- [x] test/egregoros/workers/resolve_mentions_test.exs
- [ ] test/egregoros_web/body_reader_test.exs
- [ ] test/egregoros_web/components/app_shell_test.exs
- [ ] test/egregoros_web/components/core_components_test.exs
- [ ] test/egregoros_web/components/layouts_test.exs
- [ ] test/egregoros_web/components/media_viewer_test.exs
- [ ] test/egregoros_web/components/status_card_test.exs
- [ ] test/egregoros_web/controllers/actor_controller_test.exs
- [ ] test/egregoros_web/controllers/admin/live_dashboard_test.exs
- [ ] test/egregoros_web/controllers/admin_controller_test.exs
- [ ] test/egregoros_web/controllers/e2ee_controller_test.exs
- [ ] test/egregoros_web/controllers/error_html_test.exs
- [ ] test/egregoros_web/controllers/error_json_test.exs
- [ ] test/egregoros_web/controllers/follow_collection_controller_test.exs
- [ ] test/egregoros_web/controllers/health_controller_test.exs
- [ ] test/egregoros_web/controllers/inbox_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/accounts_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/announcements_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/apps_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/blocks_mutes_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/conversations_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/custom_emojis_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/empty_list_endpoints_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/favourites_and_bookmarks_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/follow_requests_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/follows_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/instance_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/markers_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/media_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/notifications_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/preferences_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/push_subscription_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/search_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/statuses_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/streaming_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/tags_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/timelines_controller_test.exs
- [ ] test/egregoros_web/controllers/mastodon_api/trends_controller_test.exs
- [ ] test/egregoros_web/controllers/nodeinfo_controller_test.exs
- [ ] test/egregoros_web/controllers/oauth_controller_test.exs
- [ ] test/egregoros_web/controllers/oban_dashboard_test.exs
- [ ] test/egregoros_web/controllers/object_controller_test.exs
- [ ] test/egregoros_web/controllers/outbox_controller_test.exs
- [ ] test/egregoros_web/controllers/page_controller_test.exs
- [ ] test/egregoros_web/controllers/passkeys_controller_test.exs
- [ ] test/egregoros_web/controllers/pleroma_api/compat_endpoints_test.exs
- [ ] test/egregoros_web/controllers/pleroma_api/emoji_reaction_controller_test.exs
- [ ] test/egregoros_web/controllers/poco_controller_test.exs
- [ ] test/egregoros_web/controllers/registration_controller_test.exs
- [ ] test/egregoros_web/controllers/session_controller_test.exs
- [ ] test/egregoros_web/controllers/settings_controller_test.exs
- [ ] test/egregoros_web/controllers/webfinger_controller_test.exs
- [ ] test/egregoros_web/cors_test.exs
- [ ] test/egregoros_web/live/bookmarks_live_test.exs
- [ ] test/egregoros_web/live/favourites_live_test.exs
- [ ] test/egregoros_web/live/messages_live_test.exs
- [ ] test/egregoros_web/live/notifications_live_test.exs
- [ ] test/egregoros_web/live/privacy_live_test.exs
- [ ] test/egregoros_web/live/profile_live_test.exs
- [ ] test/egregoros_web/live/relationships_live_test.exs
- [ ] test/egregoros_web/live/search_live_test.exs
- [ ] test/egregoros_web/live/status_live_test.exs
- [ ] test/egregoros_web/live/tag_live_test.exs
- [ ] test/egregoros_web/live/timeline_live_test.exs
- [ ] test/egregoros_web/mastodon_api/account_renderer_test.exs
- [ ] test/egregoros_web/mastodon_api/notification_renderer_test.exs
- [ ] test/egregoros_web/mastodon_api/status_renderer_test.exs
- [ ] test/egregoros_web/mastodon_api/streaming_socket_test.exs
- [ ] test/egregoros_web/plugs/force_ssl_test.exs
- [ ] test/egregoros_web/plugs/rate_limit_inbox_test.exs
- [ ] test/egregoros_web/plugs/require_scopes_test.exs
- [ ] test/egregoros_web/plugs/session_cookie_domain_test.exs
- [ ] test/egregoros_web/plugs/static_assets_test.exs
- [ ] test/egregoros_web/plugs/uploads_access_test.exs
- [ ] test/egregoros_web/plugs/uploads_dynamic_root_test.exs
- [ ] test/egregoros_web/plugs/uploads_host_restriction_test.exs
- [ ] test/egregoros_web/plugs/verify_signature_test.exs
- [ ] test/egregoros_web/profile_paths_test.exs
- [ ] test/egregoros_web/safe_media_url_test.exs
- [ ] test/egregoros_web/time_test.exs
- [ ] test/egregoros_web/url_uploads_base_url_test.exs
- [ ] test/egregoros_web/view_models/actor_test.exs
- [ ] test/egregoros_web/view_models/status_test.exs
- [ ] test/mix/tasks/egregoros_tasks_test.exs
