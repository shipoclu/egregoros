# Fediverse mini-app reference

This is a deliberately small, static v1 mini app. It demonstrates that useful
apps can render and use public host actions before OAuth, while optional wallet
access remains host mediated.

The **Read public share info** action calls `getLaunchInfo()`. After the user
opens the clearly labelled rich card, it returns the exact app launch URL, the
exact link found in the public Note, and that original Note's ActivityPub ID.
It does not prompt, authenticate, or identify the viewer. **Request additional
note context** calls the separate `getContext()` method; the host obtains its
once-per-app permission before sharing public note text, author, and mentions.
If the card was encountered through a boost, v1 still identifies only the
original Note and does not attribute an Announce.

For a complete production walkthrough, including nginx, TLS, security headers,
caching, validation, and an optional OAuth-backend proxy, see
[DEPLOYMENT.md](./DEPLOYMENT.md).

Before deploying:

1. Replace every `https://miniapp.example` URL in `public/.well-known/fediverse-miniapp.json`.
2. Replace the trusted Egregoros origin in `public/app.mjs`; do not use an
   accept-any-origin callback.
3. Build and copy the pinned SDK artifact:

   ```sh
   MIX_ENV=prod mix assets.build
   cp priv/static/assets/js/fediverse-miniapp-sdk-v1.js \
     examples/fediverse-miniapp/public/fediverse-miniapp-sdk-v1.js
   cp priv/static/assets/js/fediverse-miniapp-sdk-v1.d.ts \
     examples/fediverse-miniapp/public/fediverse-miniapp-sdk-v1.d.ts
   ```

4. Serve `public/` from the exact HTTPS origin in the manifest, without
   redirects. The manifest must be available at
   `/.well-known/fediverse-miniapp.json` and the page must permit framing by the
   Egregoros instances you support through CSP `frame-ancestors`.

The reference intentionally has no backend and therefore does not demonstrate
dynamic OAuth registration or token exchange. Those operations belong on an
app backend; bearer and refresh tokens must never enter iframe JavaScript.
Mini apps use stable public client IDs and Egregoros never returns them a client
secret. The SDK's bootstrap gives that backend the exact issuer, OAuth
metadata URL, opener-free authorization-result relay URL, and launch ID needed
to validate and bind the flow to OAuth state.

When adding OAuth, always start retries with fresh state, PKCE, and handoff
values. The calling server must generate a consent-page `form-action` containing
the exact validated callback origin; this is dynamic server behavior, not a
domain that the app developer asks an nginx administrator to hardcode. See the
OAuth section of [DEPLOYMENT.md](./DEPLOYMENT.md) for the callback and CSP
checks.

Use the `identify` OAuth scope and `/api/v1/mini-apps/identity` when the app only
needs to link a Fediverse account. `identify` returns the account's ActivityPub
ID, username, fully qualified handle, display name, and profile URL; it does not
grant authenticated access to posts, timelines, notifications, or
conversations. Request broad `read` or `write` only for functionality that
actually needs those independent permissions.

The manifest may bound each declared scope with
`scopeAuthorizationMaxAgeSeconds`. At authorization time, request only the
subset needed for the current action and optionally pass
`authorizationLifetimeSeconds` to `sdk.requestAuth`. Every request retains
`identify`; a destructive step-up normally requests `identify write` with a
short deadline. The user and instance may shorten it further, and refresh
rotation cannot extend the resulting absolute expiration.
