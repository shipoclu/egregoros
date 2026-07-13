# Fediverse mini-app reference

This is a deliberately small, static v1 mini app. It demonstrates that useful
apps can render and use public host actions before OAuth, while optional wallet
access remains host mediated.

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
