# Deploying the reference Fediverse mini app

This guide deploys the static reference app behind nginx at the exact origin
`https://miniapp.example`. Substitute your real hostname and the exact
Egregoros origins you trust everywhere they appear.

The reference app works without OAuth. It can request public launch context,
open a confirmed external URL, and use an optional host-mediated EVM wallet.
The final section explains the additional boundary needed when adding an OAuth
backend.

## 1. Prerequisites

- A DNS `A` and/or `AAAA` record for the mini-app hostname.
- A publicly trusted TLS certificate for that exact hostname.
- nginx with access to the certificate files.
- A checkout of Egregoros to build a pinned copy of the SDK.
- One or more exact Egregoros origins that are allowed to frame the app, such
  as `https://social.example`. Include a non-default port when applicable.

Use a dedicated origin for the mini app. Do not deploy it beneath the Egregoros
origin, and do not broaden trust to `https:` or `*`.

## 2. Configure the app identity

Edit `public/.well-known/fediverse-miniapp.json` and replace every occurrence
of `https://miniapp.example`. All manifest URLs must remain on the exact same
scheme, host, and effective port as the manifest itself.

Edit `public/app.mjs` and replace the example host allowlist:

```js
const trustedHosts = new Set([
  "https://social.example",
  "https://community.example",
])
```

Do not implement this callback as `() => true`. The SDK deliberately requires
the app to make an exact host-origin trust decision.

If the app does not need an EVM wallet, remove the `wallet` object from the
manifest and remove the wallet controls from the page. If wallet support is
optional, retain `"required": false`.

## 3. Build and pin the SDK

From the Egregoros repository root:

```sh
MIX_ENV=prod mix assets.build

cp priv/static/assets/js/fediverse-miniapp-sdk-v1.js \
  examples/fediverse-miniapp/public/fediverse-miniapp-sdk-v1.js

cp priv/static/assets/js/fediverse-miniapp-sdk-v1.d.ts \
  examples/fediverse-miniapp/public/fediverse-miniapp-sdk-v1.d.ts
```

Deploy the JavaScript and TypeScript declaration from the same build. Do not
mix SDK versions, and do not hot-link the SDK from an arbitrary user's
Egregoros instance.

## 4. Install the static files

One possible filesystem layout is:

```text
/srv/fediverse-miniapp/public/
├── .well-known/
│   └── fediverse-miniapp.json
├── app.mjs
├── fediverse-miniapp-sdk-v1.d.ts
├── fediverse-miniapp-sdk-v1.js
└── index.html
```

Install it without granting the nginx worker write access:

```sh
sudo install -d -o root -g www-data -m 0755 /srv/fediverse-miniapp/public
sudo cp -a examples/fediverse-miniapp/public/. /srv/fediverse-miniapp/public/
sudo chown -R root:www-data /srv/fediverse-miniapp/public
sudo find /srv/fediverse-miniapp/public -type d -exec chmod 0755 {} \;
sudo find /srv/fediverse-miniapp/public -type f -exec chmod 0644 {} \;
```

Adapt the group name on systems where nginx uses a group other than
`www-data`.

## 5. nginx configuration

The configuration below is self-contained. Replace the hostname, certificate
paths, and `frame-ancestors` origins. The reference HTML currently contains an
inline style block, so `style-src` includes `'unsafe-inline'`. A production app
can move that CSS into a same-origin file and then remove `'unsafe-inline'`.

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name miniapp.example;

    return 308 https://miniapp.example$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name miniapp.example;

    root /srv/fediverse-miniapp/public;
    index index.html;

    ssl_certificate     /etc/letsencrypt/live/miniapp.example/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/miniapp.example/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Replace these exact origins with the Egregoros instances you trust.
    # Never use "frame-ancestors *" or a bare "https:" source here.
    add_header Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; font-src 'self'; media-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'; frame-ancestors https://social.example https://community.example" always;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=(), hid=(), midi=(), display-capture=()" always;

    # Do not set X-Frame-Options. SAMEORIGIN or DENY would prevent the trusted
    # cross-origin Egregoros broker from framing this app. frame-ancestors is
    # the authoritative framing policy.

    location = /.well-known/fediverse-miniapp.json {
        default_type application/json;
        try_files $uri =404;
        expires 5m;
        # Allowing GET also permits HEAD in nginx.
        limit_except GET { deny all; }
    }

    location = /fediverse-miniapp-sdk-v1.js {
        default_type application/javascript;
        try_files $uri =404;
        expires -1;
        limit_except GET { deny all; }
    }

    location = /fediverse-miniapp-sdk-v1.d.ts {
        default_type text/plain;
        try_files $uri =404;
        expires -1;
        limit_except GET { deny all; }
    }

    location = /app.mjs {
        default_type application/javascript;
        try_files $uri =404;
        expires -1;
        limit_except GET { deny all; }
    }

    location / {
        try_files $uri $uri/ /index.html;
        expires -1;
        limit_except GET { deny all; }
    }

    # Deny other hidden files while leaving the exact well-known route above.
    location ~ /\. {
        deny all;
    }
}
```

Notes:

- The manifest and every launch URL must respond directly over HTTPS. Egregoros
  does not follow discovery redirects.
- The example revalidates SDK files so security fixes are not hidden behind a
  long-lived cache. A content-hashed production filename may instead use an
  immutable long-lived cache.
- nginx `add_header` inheritance changes when a child `location` contains its
  own `add_header`. If you add location-specific headers, repeat the security
  headers or place them in an included snippet used by every location.
- If the hostname is not dedicated to the mini app, do not add
  `includeSubDomains` to HSTS until every subdomain is HTTPS-ready.

Validate and reload nginx:

```sh
sudo nginx -t
sudo systemctl reload nginx
```

## 6. Verify the deployment

Check the manifest without following redirects:

```sh
curl --fail --silent --show-error \
  https://miniapp.example/.well-known/fediverse-miniapp.json | jq .
```

Check response headers:

```sh
curl --fail --silent --show-error --head https://miniapp.example/
curl --fail --silent --show-error --head \
  https://miniapp.example/fediverse-miniapp-sdk-v1.js
```

Confirm all of the following:

- The page and manifest return `200` directly over HTTPS.
- The manifest has `Content-Type: application/json`.
- `.js` and `.mjs` files have a JavaScript MIME type.
- CSP `frame-ancestors` contains only the intended exact Egregoros origins.
- No `X-Frame-Options: DENY` or `SAMEORIGIN` header is present.
- The SDK JavaScript and `.d.ts` came from the same Egregoros build.

Finally, place an exact mini-app URL in a fully public note on an allowed
Egregoros instance. Verify that it becomes a rich card, opens only after the
explicit **Open** action, reaches `ready()`, and shows the host-owned context
and wallet confirmations when requested.

## 7. Operator policy on Egregoros

The calling Egregoros instance must enable mini apps and allow the app domain:

```sh
EGREGOROS_MINI_APPS_ENABLED=true
EGREGOROS_MINI_APPS_DOMAIN_ALLOWLIST=miniapp.example
```

An operator can instead leave the allowlist empty and use a denylist, but an
explicit production allowlist is the safer starting point. Exact deny rules and
matching wildcard deny rules take precedence.

## 8. Adding an OAuth backend later

The static reference app has no OAuth backend. Do not perform dynamic client
registration, exchange authorization codes, store access/refresh tokens, or
call bearer-token APIs in iframe JavaScript. Mini apps are public OAuth clients;
Egregoros does not return a client secret for them.

A backend deployment should:

1. Read the exact issuer, metadata URL, `authorizationResultRelay`, and
   `launchId` from the SDK bootstrap and send them to the app backend as
   untrusted input.
2. Validate the issuer against the same trusted-host policy used by the app.
3. Register one public client per app manifest and issuer, cache its stable
   `client_id`, and reuse it. Equivalent registration returns that same ID and
   no secret.
4. Keep access/refresh tokens only on the backend. Omit `client_secret` from
   token and revocation requests; `client_credentials` is unavailable.
5. Use transaction-specific S256 PKCE, high-entropy state, the exact registered
   callback, and the verifier-bound one-time iframe handoff. Bind the exact
   relay URL and launch ID to the OAuth state.
6. Store no OAuth token in a URL, browser log, analytics event, or host message.
7. After exchanging the callback code, redirect the opener-free popup to
   `<authorizationResultRelay>#version=1&launch_id=...&state=...&status=success&handoff_code=...`.
   The handoff code belongs in the fragment, never a query parameter. For
   cancellation or error, omit it and use `status=cancelled` or `status=error`.
8. Begin every retry as a new OAuth transaction. Generate new state, PKCE, and
   handoff verifier/challenge values; do not bookmark or replay a previously
   displayed authorization URL after a deployment, cancellation, timeout, or
   failed callback.

The backend must accept the relay URL only when it is exactly
`<trusted issuer>/mini-apps/oauth/relay`. It must never derive or accept an
arbitrary relay domain from request input. The callback must not use
`window.opener` or send its result directly to the Egregoros page.

The Egregoros authorization server is responsible for generating a consent-page
CSP whose `form-action` contains only `'self'` and this app's validated callback
origin. The app developer does not configure their domain in the Egregoros
proxy and must not ask an operator to add a wildcard CSP. If authorization is
blocked with a `form-action 'self'` console error, verify that the server is
running a version with callback-aware OAuth CSP and that no proxy/CDN replaces
or appends CSP. On a correct response for
`https://miniapp.example/oauth/callback`, the directive is:

```text
form-action 'self' https://miniapp.example
```

The callback endpoint itself should be a no-store server route. It exchanges
the code and redirects to the exact host relay bound into OAuth state; it does
not need to relax the miniapp page's ordinary `form-action 'none'` policy.

If the backend listens locally on port `4100`, narrowly proxy only its required
paths instead of proxying the whole site:

```nginx
location = /oauth/callback {
    proxy_pass http://127.0.0.1:4100;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}

location /api/ {
    proxy_pass http://127.0.0.1:4100;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
}
```

Because nginx header inheritance is easy to weaken accidentally, repeat or
include the same CSP and security-header snippet inside proxied locations. The
backend must also validate method, content type, request size, CSRF/origin where
cookies are involved, and every OAuth state transition independently.

## 9. Browser action lifecycle

SDK calls such as `getContext`, notification permission, OAuth, compose,
external navigation, and wallet requests are asynchronous message exchanges.
They must not assign `window.location`, submit the miniapp page, or reload the
iframe. If an action control is inside a form, use `type="button"` or prevent
the form's default submission before calling the SDK.

Disable the initiating control while its promise is pending, restore it after
success or failure, and display stable SDK error codes. A host may allow only
one host-owned confirmation at a time; a concurrent request should fail
promptly (wallets use EIP-1193 `-32002`) and the app should let the user retry
after the visible prompt is resolved. Do not interpret that failure as a reason
to call `location.reload()` or recreate the SDK. `sdk.destroy()` intentionally
makes the current app channel inert, while `sdk.close()` intentionally asks the
host to tear down the whole miniapp surface.

OAuth authorization windows are opened by the trusted host after its own
confirmation. The iframe should call `requestAuth` from its user gesture and
await the correlated result; it must not open a competing popup, retain an
opener reference, or poll the authorization window.

## Deployment checklist

- [ ] Manifest and application URLs use one exact HTTPS origin.
- [ ] SDK `.js` and `.d.ts` are copied from the same pinned build.
- [ ] `allowedHostOrigin` contains exact trusted Egregoros origins.
- [ ] nginx serves JSON and JavaScript with correct MIME types.
- [ ] CSP `frame-ancestors` names only trusted Egregoros origins.
- [ ] `X-Frame-Options` does not block the trusted broker.
- [ ] Device permissions, top navigation, popups, and downloads are not added.
- [ ] Egregoros operator allow/deny policy permits the app domain.
- [ ] Manifest, page, SDK, context, external action, and optional wallet flows
      are tested from a fully public note.
- [ ] Any OAuth secrets and bearer tokens remain backend-only.
- [ ] OAuth retries create fresh state, PKCE, and handoff values.
- [ ] The server's OAuth consent CSP dynamically names the exact registered
      callback origin, and no proxy replaces or appends that CSP.
- [ ] SDK action buttons do not submit or reload the iframe and handle a
      correlated host-busy failure without recreating the SDK.
