# Egregoros

Egregoros is a **PostgreSQL + Elixir/OTP + Phoenix (LiveView)** ActivityPub server with:

- a Mastodon-compatible API (including streaming),
- a first-class LiveView UI (Tailwind v4),
- a reduced, opinionated architecture designed to stay maintainable.

## Design goals

- **Single ActivityPub storage model:** everything ActivityPub (objects *and* activities) is stored in one Postgres table (`objects`) using a JSONB payload plus a few denormalized query columns.
- **One module per ActivityPub type:** activity handling lives in `lib/egregoros/activities/*` (Ecto embedded schema + ingestion + side effects) so adding new types doesn’t require editing many files.
- **Unified ingestion:** local authoring, inbound federation, and on-demand fetches all go through a single ingestion pipeline (`Egregoros.Pipeline`).
- **Swapability:** caching, discovery, HTTP, signatures, media storage, authz, and rate limiting sit behind behaviour boundaries so they can be replaced later without rewrites.

## Feature highlights

### Federation (ActivityPub)

- WebFinger + NodeInfo 2.0
- Actor endpoints, inbox/outbox, object fetch (`/objects/:uuid`)
- HTTP Signatures for deliveries
- Signed fetch (for servers that require signed GETs for public objects)
- Async ingestion/delivery via Oban (burst-resistant federation)
- Thread completion (best-effort, bounded, async):
  - fetch missing ancestors via `inReplyTo`
  - fetch replies via ActivityPub `replies` collections when available

### Social features

- Posts (Notes)
- Attachments (images/video/audio) with alt text
- Likes, reposts (Announce), emoji reactions (including custom emoji reactions)
- Follows + unfollows, follow requests (locked accounts)
- Bookmarks, favourites

### Mastodon API

Implements a Mastodon-compatible API sufficient for real clients (including WebSocket streaming). Exact surface area is still evolving; keep an eye on `tasks.md` for compatibility work.

### LiveView UI

- Public + home timelines with live updates
- Status/thread view (`/@:nickname/:uuid`) with reply modal
- Composer with visibility, language, content warnings, sensitive toggle, attachments, emoji picker, mention autocomplete
- Profiles, notifications, settings, light/dark/system theme

## Architecture (quick tour)

- **Core ingestion:** `lib/egregoros/pipeline.ex` → activity module (`lib/egregoros/activities/*`) → `objects` + `relationships` + side effects (broadcast, notifications, delivery).
- **Storage model:**
  - `objects` (`lib/egregoros/object.ex`): ActivityPub objects/activities (JSON payload + columns: `ap_id`, `type`, `actor`, `object`, `published`, `local`)
  - `relationships` (`lib/egregoros/relationship.ex`): unique actor↔object state (Follow/Like/Announce/Bookmark/EmojiReact:* etc)
  - `users` (`lib/egregoros/user.ex`): local + remote actors
- **Federation:** inbox/outbox/object controllers, `Egregoros.Federation.Delivery` (outbound), `Egregoros.Federation.SignedFetch` (signed GET).
- **Background work:** Oban workers under `lib/egregoros/workers/*` for ingestion, delivery, and thread completion.
- **Rendering safety:** `lib/egregoros/html.ex` is the single HTML safety boundary (sanitize remote HTML; escape+linkify local text).

For the full overview, read `architecture.md`.

## Development

### Prerequisites

- Elixir + Erlang/OTP
- PostgreSQL

### Setup

```sh
mix setup
mix phx.server
```

Visit `http://localhost:4000`.

## Docker / Coolify

For a self-contained stack (app + Postgres), use `docker-compose.yml`.

```sh
cp .env.example .env
# Set SECRET_KEY_BASE (generate one with: mix phx.gen.secret)
docker compose -f docker-compose.yml -f docker-compose.local.yml up --build
```

The local override also publishes two optional web front-ends:

- Pleroma-FE: `http://localhost:4001`
- pl-fe: `http://localhost:4002`

For production, change `POSTGRES_PASSWORD` (and use URL-safe characters or URL-encode it in `DATABASE_URL`).

The container runs migrations automatically on startup via `Egregoros.Release.migrate/0`.
For multi-node deployments, run migrations as a one-off task instead of on every boot.

### Coolify notes

- Use the **Docker Compose** deployment type and point it at this repo.
- Do not publish the app port with `ports:`; let Coolify/Traefik route to the container port instead.
- Because the app listens on port `4000`, add the port in Coolify’s domain mapping (e.g. `https://example.com:4000`).
- Set `PHX_HOST` / `PHX_SCHEME` / `PHX_PORT` to the public URL of your instance (important for federation).
- Persist volumes `egregoros_db` and `egregoros_uploads` (Coolify will create named volumes automatically).

### Serving uploads from a separate subdomain

To isolate user uploads on a separate origin (recommended defense-in-depth), you can serve them from a dedicated
subdomain like `i.example.com`:

- Point `i.example.com` at the same Coolify app/service as the main domain.
- Set `EGREGOROS_UPLOADS_BASE_URL=https://i.example.com` so URLs for `/uploads/*` are generated on that host.
- Set `EGREGOROS_SESSION_COOKIE_DOMAIN=example.com` (or `.example.com`) so the browser can send the session cookie
  to the uploads host (required for followers-only/direct media visibility checks).

When `EGREGOROS_UPLOADS_BASE_URL` is set, Egregoros will only serve `/uploads/*` when the request `Host` matches that
uploads host, so uploads aren’t accessible on the main app origin.

### External host (ngrok / reverse proxies)

ActivityPub IDs and API URLs are generated from the configured endpoint URL. To run behind ngrok, set:

- `PHX_HOST` (or `EGREGOROS_EXTERNAL_HOST`) to your ngrok hostname
- `PHX_SCHEME` (or `EGREGOROS_EXTERNAL_SCHEME`) to `https`
- `PHX_PORT` (or `EGREGOROS_EXTERNAL_PORT`) to `443`

These are read in `config/runtime.exs`.

### Tests

```sh
mix test
mix test --cover
```

When you’re done with a batch of changes, run:

```sh
mix precommit
```

### Benchmarks

See `BENCHMARKS.md` for seeding and running the built-in benchmark harness.

## Docs / checklists

- `architecture.md` — moving parts and data flow
- `security.md` — security & privacy checklist
- `tasks.md` — current backlog and priorities
- `frontend_checklist.md` — UI parity checklist
- `BENCHMARKS.md` — benchmark harness
- `e2ee_dm.md` — notes on end-to-end encrypted DMs (frontend crypto)

## Troubleshooting

### `:emfile` / "too many open files" crash under load

If you see errors like `Unexpected error in accept: :emfile` (Bandit/ThousandIsland) or
`File operation error: emfile`, your OS file descriptor limit is too low (often `ulimit -n 256`).

Increase it before starting the server:

```sh
ulimit -n 8192
mix phx.server
```
