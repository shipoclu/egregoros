# Fediverse miniapp implementer's guide

This guide builds the smallest useful Egregoros miniapp first, then adds
optional features one at a time. It is intended for someone implementing their
first miniapp.

[`MINIAPPS.md`](MINIAPPS.md) is the normative protocol and security reference.
If this guide and that document ever differ, follow `MINIAPPS.md`.

## What a miniapp is

A basic miniapp is an ordinary HTTPS web application that:

1. publishes a JSON manifest at a fixed well-known URL;
2. allows an Egregoros instance to frame its pages;
3. loads a pinned copy of the Egregoros miniapp SDK; and
4. connects to the host and calls `ready()`.

The app can be a vanilla single-page application. It does not need a special
framework.

There are three possible parts:

- **The Egregoros host** discovers the app, displays its card, frames it, and
  mediates SDK actions.
- **The miniapp page** is the HTML, CSS, and JavaScript running in the
  cross-origin iframe.
- **The miniapp backend** is optional. It is needed for OAuth and any private
  application data, but not for a basic public app.

The miniapp itself does **not** need an ActivityPub actor, WebFinger, inbox,
outbox, or ActivityPub note-creation endpoint. ActivityPub publishing and
transactional messages are a separate optional extension. A miniapp that only
uses the SDK, including the host-owned composer, should omit `activityPub` from
its manifest.

## First milestone: launch a static app

Start with these five files:

```text
public/
├── .well-known/
│   └── fediverse-miniapp.json
├── app.js
├── fediverse-miniapp-sdk-v1.d.ts
├── fediverse-miniapp-sdk-v1.js
└── index.html
```

Publish the matching `fediverse-miniapp-sdk-v1.d.ts` beside the JavaScript file,
even if the app itself uses plain JavaScript. The runtime and its public types
are one versioned SDK release.

### Step 1: choose one HTTPS origin

Give the app a dedicated public origin such as `https://miniapp.example`.
During initial development, use that exact origin everywhere. Scheme, hostname,
and non-default port are all part of the origin.

Egregoros fetches remote app resources defensively. The hostname must resolve
to public addresses, TLS must be valid for the hostname, and the manifest and
linked page must return directly without relying on redirects.

### Step 2: publish the minimal manifest

Serve this as JSON from
`https://miniapp.example/.well-known/fediverse-miniapp.json`:

```json
{
  "version": "1",
  "name": "My First Miniapp",
  "homeUrl": "https://miniapp.example/",
  "capabilities": [],
  "cacheTtlSeconds": 300
}
```

The required fields are `version`, `name`, `homeUrl`, and `capabilities`.
`cacheTtlSeconds` is optional and defaults to 3600 seconds; 300 is convenient
while deploying. Its allowed range is 60 through 3600 seconds.

Keep the manifest strict:

- Use only documented fields. Version 1 rejects unknown and duplicate fields.
- Keep `homeUrl` and every other manifest URL on the manifest's exact origin.
- Start with an empty `capabilities` array.
- On a disposable development origin, omit `oauth`, `wallet`, and `activityPub`
  until the app implements them.
- Treat declarations as permanent for this app origin. In particular, OAuth
  scopes and host capabilities cannot be silently changed after registration.

Egregoros records identity-affecting declarations when it first observes the
manifest. If the production app will need OAuth, wallet, ActivityPub, or a host
capability, finalize those declarations before the production origin is first
discovered. Use a disposable development origin for the minimal milestone, or
use a new app origin when changing an immutable declaration.

The complete shape and JSON Schema are in the
[wire-format section of `MINIAPPS.md`](MINIAPPS.md#v1-wire-format) and
[`docs/schemas/fediverse-miniapp-manifest-v1.schema.json`](docs/schemas/fediverse-miniapp-manifest-v1.schema.json).

### Step 3: vendor the SDK

Copy the version 1 SDK into the app instead of importing it from a particular
Egregoros instance. From an Egregoros source checkout:

```sh
MIX_ENV=prod mix assets.build
cp priv/static/assets/js/fediverse-miniapp-sdk-v1.js \
  /path/to/miniapp/public/fediverse-miniapp-sdk-v1.js
cp priv/static/assets/js/fediverse-miniapp-sdk-v1.d.ts \
  /path/to/miniapp/public/fediverse-miniapp-sdk-v1.d.ts
```

Copy the `.js` and `.d.ts` files from the same build. Pin the resulting files
with the rest of the app so an instance upgrade cannot unexpectedly change the
app's runtime.

### Step 4: connect and become ready

Create `index.html` with a visible initial state and ordinary buttons. Always
use `type="button"`; otherwise a button inside a form may submit and reload the
iframe.

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>My First Miniapp</title>
  </head>
  <body>
    <main>
      <h1>My First Miniapp</h1>
      <p id="status">Connecting to Egregoros…</p>
      <button id="context" type="button">Get launch context</button>
      <button id="close" type="button">Close</button>
      <pre id="output"></pre>
    </main>
    <script type="module" src="/app.js"></script>
  </body>
</html>
```

Create `app.js`. For the first deployment, trust the exact Egregoros origin
where the app will be tested:

```js
import {createFediverseMiniAppSDK} from "./fediverse-miniapp-sdk-v1.js"

const trustedHosts = new Set(["https://social.example"])
const status = document.querySelector("#status")
const output = document.querySelector("#output")

/**
 * Returns whether an origin may host this miniapp.
 *
 * @param {string} origin - The exact origin offered by the SDK bootstrap.
 * @returns {boolean} Whether the host is trusted.
 */
const isAllowedHostOrigin = origin => trustedHosts.has(origin)

const sdk = createFediverseMiniAppSDK({
  allowedHostOrigin: isAllowedHostOrigin,
})

try {
  const bootstrap = await sdk.connect()
  output.textContent = JSON.stringify({bootstrap}, null, 2)
  status.textContent = "Connected"
  await sdk.ready()
} catch (error) {
  status.textContent = `Connection failed: ${error?.code || error?.message || "unknown error"}`
}

/** Requests and displays the public launch context. */
const showContext = async () => {
  try {
    const context = await sdk.getContext()
    output.textContent = JSON.stringify({context}, null, 2)
  } catch (error) {
    output.textContent = JSON.stringify({
      error: error?.message || "Unknown error",
      code: error?.code,
    })
  }
}

/** Asks the host to close the miniapp surface. */
const closeMiniapp = () => sdk.close()

document.querySelector("#context").addEventListener("click", showContext)
document.querySelector("#close").addEventListener("click", closeMiniapp)
```

Call `connect()` as soon as the page loads. Call `ready()` as soon as the first
usable view is rendered; do not wait for authentication or optional data. Until
then, the host intentionally keeps its loading state visible.

`allowedHostOrigin` must fail closed. A private app can use an exact set as
above. A generally published app may accept public HTTPS Fediverse origins,
but both its browser code and backend must implement the public-DNS and exact
origin rules from [`MINIAPPS.md`](MINIAPPS.md#hostile-mini-app-security-boundary).
Do not replace the callback with `() => true`.

### Step 5: permit framing

The app's HTTP response must allow the intended Egregoros origin to frame it.
For an app tested only on `https://social.example`, a suitable response header
starts with:

```text
Content-Security-Policy: default-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors https://social.example
```

Set `frame-ancestors` as an HTTP response header; browsers ignore it in an HTML
`<meta>` element. Do not also send `X-Frame-Options: DENY` or `SAMEORIGIN`,
because either can block the cross-origin host.

Add only the network, image, or style sources the application actually uses.
The production nginx example and the rest of the recommended headers are in
[`examples/fediverse-miniapp/DEPLOYMENT.md`](examples/fediverse-miniapp/DEPLOYMENT.md).

### Step 6: verify discovery and launch

First verify the resources directly:

```sh
curl --fail --silent --show-error \
  https://miniapp.example/.well-known/fediverse-miniapp.json | jq .
curl --fail --silent --show-error --head https://miniapp.example/
curl --fail --silent --show-error --head \
  https://miniapp.example/fediverse-miniapp-sdk-v1.js
```

Check the status, `Content-Type`, CSP, hostname, and every URL in the returned
manifest. Do not use `curl -L`: a successful check should not need redirects.

Then publish the exact app URL in a **fully public** note on an Egregoros
instance whose miniapp policy permits the domain. Discovery is asynchronous,
so the ordinary link can briefly appear before its card. The card must require
an explicit **Open** action. Open it and confirm that:

1. the host's loading view disappears after `ready()`;
2. the bootstrap displays the expected host origin and launch ID;
3. **Get launch context** produces a host-owned permission flow and result; and
4. **Close** closes the host surface.

Private, followers-only, and direct notes intentionally remain ordinary links.

## Optional: customize cards for individual pages

The manifest identifies the domain. A shareable page can additionally put one
strict metadata element in its HTML `<head>`:

```html
<meta name="fediverse:miniapp" content='{
  "version":"1",
  "title":"Open puzzle 42",
  "imageUrl":"https://miniapp.example/cards/puzzle-42.png",
  "buttonTitle":"Play",
  "launchUrl":"https://miniapp.example/puzzles/42"
}'>
```

All URLs must stay on the app's exact origin. Without this element, Egregoros
uses the generic manifest card and still launches the exact linked URL, so SPA
deep links and hash routes work without page metadata.

## Optional: add OAuth and authenticated actions

Add OAuth only after the static milestone works. OAuth requires an app backend;
never register a client, exchange a code, store an Egregoros token, or make a
bearer-token request in iframe JavaScript.

Because the declaration is immutable after first observation, develop this on
a disposable origin or publish the final OAuth declaration before testing the
production origin. Adding `oauth` or `compose_note` to an already observed
manifest requires a new app identity/origin.

### Step 1: declare the smallest authority

For account linking, add only `identify`. The host-owned composer also needs
the `compose_note` capability, but it does not need the broad `write` API scope:

```json
{
  "version": "1",
  "name": "My First Miniapp",
  "homeUrl": "https://miniapp.example/",
  "oauth": {
    "redirectUris": ["https://miniapp.example/oauth/callback"],
    "scopes": ["identify"],
    "scopeAuthorizationMaxAgeSeconds": {
      "identify": 31536000
    }
  },
  "capabilities": ["compose_note"],
  "cacheTtlSeconds": 300
}
```

Use `identify` instead of broad `read` when the app only needs the user's ID,
handle, display name, and profile URL. Call `/api/v1/mini-apps/identity` with
that token. Request `write` only when the app independently calls APIs that can
create, edit, or delete content as the user. The host composer never silently
publishes and does not require that API authority.

Manifest OAuth declarations are an immutable maximum. Each authorization
request should ask for only the subset and lifetime needed at that moment.

### Step 2: register from the backend

The SDK bootstrap supplies the exact `issuer`,
`authorizationServerMetadata`, `authorizationResultRelay`, and `launchId`.
Treat them as untrusted until the backend verifies the issuer and public DNS.

The backend fetches `authorizationServerMetadata`, reads its advertised
`registration_endpoint`, and posts JSON containing only the canonical manifest
URL:

```json
{"manifest_url":"https://miniapp.example/.well-known/fediverse-miniapp.json"}
```

Store and reuse the returned public `client_id` for that app manifest and
issuer. A miniapp registration has no client secret.

### Step 3: prepare one bound authorization transaction

For every attempt, the backend must store a short-lived record containing:

- fresh high-entropy OAuth `state`;
- a fresh PKCE verifier and its S256 challenge;
- the exact redirect URI and requested scope subset;
- the exact issuer, relay URL, and `launchId` from bootstrap; and
- the SHA-256 challenge of a fresh handoff verifier generated by the iframe.

The iframe passes the prepared `clientId`, redirect URI, scopes, state, PKCE
challenge, and handoff challenge to `sdk.requestAuth()`. The host fixes PKCE to
S256 and opens its own opener-free authorization surface. Do not open a second
popup from the iframe.

### Step 4: complete the callback and relay

The backend callback validates state, exchanges the code server to server, and
keeps all access and refresh tokens on the backend. It creates a random,
single-use handoff code with a maximum 60-second lifetime, then redirects to
the exact relay URL bound to state with exactly this fragment shape:

```text
#version=1&launch_id=LAUNCH_ID&state=OAUTH_STATE&status=success&handoff_code=HANDOFF_CODE
```

Do not omit `version`, `launch_id`, or `state`; the host needs all three to
correlate the result to the live iframe request. Put the fields in the fragment,
not the query string. Cancellation uses `status=cancelled` with no handoff
code, and failure uses `status=error` with no handoff code.

After `requestAuth()` returns the handoff code, the iframe sends that code and
its original handoff verifier directly to the app backend. The backend verifies
the binding, consumes the code once, and returns an opaque app session token.
Keeping that app token in `sessionStorage` is a simple baseline. Egregoros
tokens must never reach the iframe, URL, host message channel, or browser log.

Start a failed, cancelled, expired, or retried flow from scratch with new
state, PKCE, and handoff values.

### Step 5: use the host-owned composer

Once the OAuth grant includes the required authority and the manifest declares
`compose_note`, the iframe can call:

```js
const result = await sdk.composeNote({
  text: "A result prepared by my miniapp",
  links: ["https://miniapp.example/results/42"],
})
```

This opens and pre-fills Egregoros's normal composer. It does not publish a
note. The user can edit the draft and must explicitly submit it. This feature
does not require the miniapp to implement any ActivityPub endpoint.

## Other optional SDK features

- `openExternal(url)` asks the host to open a URL. Call it directly from a
  user gesture; cross-origin destinations receive host confirmation.
- `wallet.getProvider()` exposes a narrow host-mediated EIP-1193 provider only
  when `wallet.evm` is declared and available. The miniapp never receives a
  private key.
- ActivityPub transactional notifications require the separate immutable
  `activityPub` declaration, OAuth, actor verification, and user consent. Do
  not add them to a first app. See
  [`MINIAPP_ACTIVITYPUB_MESSAGES.md`](MINIAPP_ACTIVITYPUB_MESSAGES.md) only if
  the application actually needs this extension.
- `sdk.destroy()` permanently closes the SDK message channel for the current
  page. Use `sdk.close()` when the intention is to close the visible app.

## Troubleshooting

| Symptom | First things to check |
| --- | --- |
| The URL stays an ordinary link | The note is fully public; miniapps are enabled; domain policy allows the hostname; the well-known manifest returns `200` JSON without a redirect; all DNS addresses are public. |
| A card appears but the app does not open | The launch URL uses the manifest's exact origin and its TLS certificate is valid. |
| The frame is blank or reports framing failure | The page response's CSP `frame-ancestors` includes the exact Egregoros origin and `X-Frame-Options` is absent. |
| The host loading screen never clears | The SDK file loads with a JavaScript MIME type; `allowedHostOrigin` accepts the exact host; `connect()` succeeds; `ready()` is called after the initial render. |
| SDK methods time out | The page did not navigate or submit, the SDK was not recreated or destroyed, and only one pending host confirmation is active. Log the stable SDK error code. |
| OAuth preparation fails | The backend can fetch the exact bootstrap metadata URL, uses its advertised registration endpoint, registers the canonical manifest URL, and reuses the returned client ID. |
| Authorization succeeds but the iframe is not notified | The callback redirects to the exact bootstrap relay and the fragment has exactly `version`, `launch_id`, `state`, `status`, and `handoff_code`, all bound to the current attempt. |
| Auth works but the iframe session does not | The handoff code is unexpired and unused, and the iframe redeems it with the verifier whose SHA-256 challenge was stored with OAuth state. Do not depend on third-party iframe cookies. |
| A changed manifest stops resolving | Identity, OAuth, capability, wallet, and ActivityPub declarations are immutable after observation or registration. Restore the declaration or deploy a new app identity/origin. |

When diagnosing discovery on Egregoros, inspect logs for `miniapp lookup` and
the `mini_apps` Oban queue. Browser console and network errors are usually more
useful for framing, SDK, and OAuth callback problems.

## Implementer checklist

### Minimal launch

- [ ] The app has one stable public HTTPS origin.
- [ ] `/.well-known/fediverse-miniapp.json` returns `200` JSON directly.
- [ ] The manifest contains `version`, `name`, `homeUrl`, and `capabilities`.
- [ ] All manifest, card, callback, image, and launch URLs use the exact app
      origin.
- [ ] Undeveloped optional sections are omitted, not filled with placeholders.
- [ ] The SDK JavaScript and TypeScript declarations come from the same pinned
      build and are served by the app.
- [ ] `allowedHostOrigin` fails closed and accepts the intended exact host.
- [ ] The page calls `connect()` on load and `ready()` after its first usable
      render.
- [ ] Every action button has `type="button"`, awaits its SDK call, and shows a
      useful stable error code.
- [ ] The response CSP permits only intended framing hosts.
- [ ] `X-Frame-Options` does not block cross-origin framing.
- [ ] A fully public note produces a card and the explicit **Open** action
      launches the exact linked route.
- [ ] Context, external navigation, and close are tested inside Egregoros, not
      only in a top-level browser tab.

### OAuth, if used

- [ ] OAuth operations and Egregoros tokens exist only on the app backend.
- [ ] The manifest declares exact callback URIs, the minimum scopes, and useful
      maximum authorization ages.
- [ ] The backend validates bootstrap issuer/metadata/relay values and public
      DNS before making requests.
- [ ] Registration uses the metadata-advertised endpoint and canonical
      `manifest_url`; the public client ID is cached per issuer.
- [ ] Each attempt has fresh state, S256 PKCE, handoff verifier/challenge, and a
      short expiry.
- [ ] State binds the issuer, exact relay, launch ID, redirect URI, scopes, PKCE,
      and handoff challenge.
- [ ] The callback validates state, exchanges the code server to server, and
      redirects to the exact five-field relay fragment.
- [ ] The handoff code is random, single-use, verifier-bound, and expires within
      60 seconds.
- [ ] The iframe stores only an opaque app session token and does not require
      third-party cookies.
- [ ] Cancellation and retry create an entirely new transaction.

### Before production

- [ ] Manifest and page-card JSON pass the version 1 schemas and contain no
      unknown or duplicate fields.
- [ ] Production CSP, MIME types, caching, TLS, and direct non-redirecting
      responses have been checked with `curl`.
- [ ] App pages expose no unnecessary camera, microphone, geolocation, popup,
      download, or top-navigation permissions.
- [ ] Launch context is treated as untrusted input even though it describes a
      public note.
- [ ] OAuth and app-session endpoints validate method, content type, request
      size, origin/CSRF rules, expiry, and single-use transitions.
- [ ] Secrets, authorization codes, tokens, handoff values, and private context
      are excluded from logs and analytics.
- [ ] The app has been tested at the host's desktop and mobile iframe sizes.
- [ ] The Egregoros operator has enabled miniapps and its allow/deny policy
      permits the app domain.

## Reference implementations

- [`examples/fediverse-miniapp`](examples/fediverse-miniapp) is the smallest
  static reference app.
- [`examples/fediverse-miniapp/DEPLOYMENT.md`](examples/fediverse-miniapp/DEPLOYMENT.md)
  covers nginx, security headers, caching, validation, and backend proxying.
- [`MINIAPPS.md`](MINIAPPS.md) defines the complete protocol and security
  invariants.
