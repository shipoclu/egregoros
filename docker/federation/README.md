# Federation-in-a-box

This is a repo-local Docker Compose setup that runs **Egregoros + Pleroma + Mastodon** in a private container network and executes a small **federation smoke test** (outgoing follow from Egregoros to both remotes, waiting for Accept).

This environment is intentionally **not production-like**:

- Everything is **HTTP-only** behind an internal Caddy reverse proxy (`gateway`)
- Egregoros runs with:
  - `EGREGOROS_ALLOW_PRIVATE_FEDERATION=true` (bypasses DNS/private-IP SSRF checks for federation URLs)
  - `EGREGOROS_FEDERATION_WEBFINGER_SCHEME=http` (WebFinger uses http inside the compose network)

## Usage

From the Egregoros repo root:

```bash
docker compose -f docker/federation/compose.yml up -d --build
docker compose -f docker/federation/compose.yml --profile fedtest run --rm fedtest
```

Cleanup:

```bash
docker compose -f docker/federation/compose.yml down -v
```

## Notes

- Pleroma is built from `${PLEROMA_CONTEXT}` (defaults to `../../../pleroma`).
- Mastodon uses `${MASTODON_IMAGE}` (defaults to `ghcr.io/mastodon/mastodon:v4.5.3`).
- If you want to poke around manually, run curls from inside containers (e.g. `docker compose -f docker/federation/compose.yml exec fedtest sh`).
