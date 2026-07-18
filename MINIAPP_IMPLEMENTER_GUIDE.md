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

A generally published miniapp must be deployable once and work when launched
from different canonical HTTPS domains running Egregoros or another compatible
ActivityPub server. Do not compile one instance hostname into public app
settings. Every launch is still pinned to one exact host origin; open-host
interoperability does not mean accepting malformed origins or trusting origin
strings carried only inside messages. A deliberately private app may use a
fixed host list, but is not generally interoperable.

There are three possible parts:

- **The Egregoros host** discovers the app, displays its card, frames it, and
  mediates SDK actions.
- **The miniapp page** is the HTML, CSS, and JavaScript running in the
  cross-origin iframe.
- **The miniapp backend** is optional. It is recommended when tokens or private
  application data should stay outside browser JavaScript, but a static app can
  use the browser-code OAuth profile without one.

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
├── index.html
└── vendor/
    └── fediverse-miniapp-sdk/
        ├── index.d.ts
        ├── index.js
        └── wallet/
            └── evm_wallet_schema.js
```

Keep the matching `index.d.ts` beside the JavaScript package, even if the app
itself uses plain JavaScript. The runtime, wallet schema, and public types are
one versioned SDK release.

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

### Step 3: install and pin the SDK

Install an exact tag or full commit of the standalone package over Git SSH
instead of importing code from a particular Egregoros instance:

```sh
npm install \
  'git+ssh://git@github.com/shipoclu/fediverse-miniapp-sdk.git#COMMIT_OR_TAG'
```

Commit the resulting lockfile. A bundled app imports
`@fediverse-miniapps/sdk` directly. A no-build static app copies the complete
installed package—`index.js`, `index.d.ts`, and `wallet/`—beneath its own
public vendor directory without rewriting the files. Do not copy `index.js`
alone: it intentionally imports its adjacent wallet schema.

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

Create `app.js`. For a generally published app, accept any syntactically exact
canonical HTTPS host origin:

```js
import {createFediverseMiniAppSDK} from "/vendor/fediverse-miniapp-sdk/index.js"

const status = document.querySelector("#status")
const output = document.querySelector("#output")

/**
 * Returns whether a value is one exact canonical HTTPS host origin.
 *
 * @param {string} origin - The exact origin offered by the SDK bootstrap.
 * @returns {boolean} Whether the host origin is syntactically allowed.
 */
const isAllowedHostOrigin = origin => {
  if (typeof origin !== "string") return false

  try {
    const parsed = new URL(origin)
    return parsed.protocol === "https:" &&
      parsed.origin === origin &&
      !parsed.username &&
      !parsed.password
  } catch {
    return false
  }
}

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

#### Framework startup timing: create the SDK before rendering

The host sends its one-time bootstrap message when the iframe finishes loading.
Create the SDK synchronously during initial module startup, before React, Vue,
Svelte, or another framework starts rendering. The SDK installs the bootstrap
message listener when it is created.

Do **not** lazy-load the SDK with `import()` and create it later. Code splitting,
hydration, deferred initialization, or an asynchronous import can let the iframe
`load` event win the race. The host then sends the bootstrap before the listener
exists; the message cannot be replayed and the host reports that the miniapp did
not become ready.

For example, create one SDK instance before React renders and pass that instance
into the app:

```js
import {createRoot} from "react-dom/client"
import {createFediverseMiniAppSDK} from "/vendor/fediverse-miniapp-sdk/index.js"
import App from "./App.jsx"

const sdk = createFediverseMiniAppSDK({
  allowedHostOrigin: isAllowedHostOrigin,
})

createRoot(document.querySelector("#root")).render(<App sdk={sdk} />)
```

The instance should live for the iframe's entire lifetime. Do not recreate it on
component renders, route changes, retries, or ordinary errors.

`allowedHostOrigin` must fail closed. A generally published app applies the
canonical HTTPS syntax check above, while a private app can replace it with an
exact set. The SDK additionally requires the browser event origin, bootstrap
host origin, and OAuth issuer to be equal and pins that one origin for the
channel lifetime. Browser JavaScript cannot perform DNS pinning. A backend that
fetches issuer URLs must independently apply the public-DNS, redirect, TLS,
timeout, and DNS-pinning rules from
[`MINIAPPS.md`](MINIAPPS.md#hostile-mini-app-security-boundary). Do not replace
the callback with `() => true`.

### Step 5: permit framing

The app's HTTP response must allow compatible hosts to frame it. A generally
published static app uses:

```text
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src https:; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'; frame-src 'none'; frame-ancestors https:
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=(), bluetooth=(), hid=(), midi=(), display-capture=()
Strict-Transport-Security: max-age=31536000; includeSubDomains
```

Set `frame-ancestors` as an HTTP response header; browsers ignore it in an HTML
`<meta>` element. Do not also send `X-Frame-Options: DENY` or `SAMEORIGIN`,
because either can block the cross-origin host.

`frame-ancestors https:` permits arbitrary HTTPS frame ancestors, including a
compatible host and its same-origin broker. It does not authenticate the host;
the exact SDK handshake does that binding for each launch. A private app may
replace `https:` with fixed exact origins, but a generally published app must
not require developers to rebuild it for every Egregoros domain.

Add only the network, image, or style sources the application actually uses.
The production nginx example and the rest of the recommended headers are in
[`examples/fediverse-miniapp/DEPLOYMENT.md`](examples/fediverse-miniapp/DEPLOYMENT.md).

### Step 6: verify discovery and launch

On an Egregoros development account, open Settings → Account, enable **Show
developer tools in the sidebar**, save, and select **Developer**. Enter the
exact URL that users will share. The conformance workbench checks the manifest,
strict schemas, the linked/home/launch pages, declared images and actor when
present, production-safe fetching, and the relevant headers for the exact
Egregoros origin.

If Egregoros detects a structurally valid card, it displays the same rich-card
component used on public notes. Open that preview to run the browser-only test.
The workbench is not complete until the real broker iframe receives `ready()`
from the SDK. A diagnostic preview uses a synthetic developer-page source URL,
not a fabricated public Note, so do not use it to test share rewards or public
Note verification.

The checklist distinguishes required failures from recommended hardening. A
failed prerequisite can prevent later resources from being requested. Fix each
required failure and run the exact URL again; a new run replaces the prior
short-lived preview.

The current workbench follows manifest/card declarations and does not crawl
every HTML script or stylesheet dependency. Its real `ready()` test proves that
startup JavaScript executed, but you must also inspect every runtime
subresource's direct response, MIME type, `nosniff`, HSTS, CSP, and caching
policy. Apply the security headers at the server level so page, manifest,
script, stylesheet, and later asset locations inherit them consistently.

First verify the resources directly:

```sh
curl --fail --silent --show-error \
  https://miniapp.example/.well-known/fediverse-miniapp.json | jq .
curl --fail --silent --show-error --head https://miniapp.example/
curl --fail --silent --show-error --head \
  https://miniapp.example/vendor/fediverse-miniapp-sdk/index.js
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

Hosts cache the safe raster produced from a rich-card image for a short,
bounded period and may let the user's browser cache it privately. Publish image
changes at a new URL when they must appear immediately. Hosts must rotate the
card resolution token when `imageUrl` changes, coalesce repeated requests for
the same resolution, and never cache unsanitized source bytes or failed image
processing results.

## Optional: add OAuth for identity or API access

Add OAuth only after the static milestone works. Choose one completion profile:

- `browser_code` keeps the deployment completely static. The iframe exchanges
  a PKCE-bound authorization code and holds tokens in its JavaScript session.
- `backend_handoff` exchanges and holds Egregoros tokens on an app backend, then
  gives the iframe a short-lived verifier-bound app-session handoff.

Never put an access or refresh token in the host relay. A browser-only app has
the normal SPA risk that an XSS vulnerability can read its tokens; a backend
profile provides stronger token isolation.

Because the declaration is immutable after first observation, develop this on
a disposable origin or publish the final OAuth and capability declarations
before testing the production origin. Adding `oauth` or `compose_note` to an
already observed manifest requires a new app identity/origin.

### Step 1: declare the smallest authority

For account linking, add only `identify`. Independently, the host-owned composer
needs the `compose_note` capability, but it does not require OAuth or the broad
`write` API scope. This combined example declares both features:

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

### Static browser profile

Use this profile when the entire application will be deployed as static files.

#### Step 1: register the public client

The SDK bootstrap supplies the exact `issuer`,
`authorizationServerMetadata`, `authorizationResultRelay`, and `launchId`.
Require the bootstrap issuer and host origin to match the exact host accepted by
`allowedHostOrigin`.

Fetch `authorizationServerMetadata`, read its advertised
`registration_endpoint`, and post JSON containing only the canonical manifest
URL:

```json
{"manifest_url":"https://miniapp.example/.well-known/fediverse-miniapp.json"}
```

The endpoint supports non-credentialed CORS. Store and reuse the returned
public `client_id` for that app manifest and issuer. It has no client secret.

#### Step 2: create state and PKCE values

For every attempt, generate a fresh random PKCE verifier and calculate its S256
challenge. Also generate a fresh state value. The static callback needs the
issuer and launch ID after its opener-free navigation, so the app can encode
these non-secret routing values plus a random nonce into a compact base64url
state value. The complete state must be 43 through 256 base64url characters.

Keep the exact state, PKCE verifier, client ID, callback URI, and metadata token
endpoint in the iframe's `sessionStorage`. Do not place the verifier in state or
in any URL.

#### Step 3: request browser-code authorization

Call the SDK directly from the user's action:

```js
const result = await sdk.requestAuth({
  completionMode: "browser_code",
  clientId,
  redirectUri: "https://miniapp.example/oauth/callback",
  scopes: ["identify"],
  state,
  codeChallenge,
  authorizationLifetimeSeconds: 86400,
})
```

`handoffChallenge` is deliberately absent in this mode. Egregoros opens its own
opener-free OAuth window and binds the app, user, exact callback, scopes, state,
and S256 challenge to the pending launch.

#### Step 4: relay only the authorization code

The static callback reads `code` and `state` from its own URL. Decode only the
app's strict state structure, require the issuer to be the expected public HTTPS
origin, and construct the relay as exactly
`<issuer>/mini-apps/oauth/relay`. Automatically replace the callback window
with:

```text
#version=1&launch_id=LAUNCH_ID&state=OAUTH_STATE&status=success&authorization_code=AUTHORIZATION_CODE
```

For an OAuth error, redirect with `status=cancelled` or `status=error` and omit
both code fields. Do not exchange the code in the callback and do not store it
there. Egregoros accepts only the exact unexpired code matching the pending
application, user, callback, scopes, and PKCE challenge.

Do not add a second confirmation solely for this return navigation. The open
static profile deliberately optimizes for the familiar OAuth flow in which the
callback returns immediately. Use `location.replace`, validate a canonical
exact HTTPS issuer, force the fixed relay path, reject duplicate or malformed
callback fields, and never accept a complete relay URL from state or a query
parameter.

This choice has a documented residual cost: because a purely static callback
has no independent server-held transaction record, an attacker can construct
state that turns the callback into a constrained open redirect to an arbitrary
canonical HTTPS origin's `/mini-apps/oauth/relay` path. PKCE and Egregoros's
pending-request checks still prevent a forged or stolen code from granting
access, but redirect/phishing-reputation abuse remains possible. If that is not
acceptable for an app's threat model, use the backend profile or another
independently authenticated pre-authorization issuer binding.

#### Step 5: exchange and store the tokens

When `requestAuth()` resolves, compare the still-current transaction state and
post the returned `authorizationCode` to the metadata-advertised token endpoint
as `application/x-www-form-urlencoded` with:

```text
grant_type=authorization_code
client_id=PUBLIC_CLIENT_ID
redirect_uri=https://miniapp.example/oauth/callback
code=AUTHORIZATION_CODE
code_verifier=PKCE_VERIFIER
```

The token endpoint supports non-credentialed CORS. Store the token response in
the iframe's `sessionStorage`, then delete the PKCE transaction. Use the access
token in an `Authorization: Bearer ...` header. Rotate refresh tokens and retain
the original absolute `authorization_expires_in` deadline.

A static app should use a strict CSP, avoid third-party runtime scripts, clear
tokens on logout, and prefer `sessionStorage` over persistent `localStorage` or
IndexedDB. Browser storage is partitioned under the Egregoros top-level site;
the authorization-code relay avoids depending on storage shared with the
top-level callback window.

### Backend handoff profile

Use this profile when Egregoros tokens should never enter iframe JavaScript.

#### Step 1: register from the backend

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

#### Step 2: prepare one bound authorization transaction

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

#### Step 3: complete the callback and relay

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

### Use the host-owned composer

Once the manifest declares `compose_note`, the iframe can call this before or
without any OAuth flow:

```js
const result = await sdk.composeNote({
  text: "A result prepared by my miniapp",
  links: ["https://miniapp.example/results/42"],
})
```

This opens and pre-fills Egregoros's normal composer. It does not publish a
note. The user can edit the draft and must explicitly submit it. This feature
uses the signed-in host session rather than an app-held token and does not
require the miniapp to implement OAuth or any ActivityPub endpoint.

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
| The host loading screen never clears | The SDK file loads with a JavaScript MIME type; the SDK was created synchronously before framework rendering; `allowedHostOrigin` accepts the exact host; `connect()` succeeds; `ready()` is called after the initial render. |
| SDK methods time out | The page did not navigate or submit, the SDK was not recreated or destroyed, and only one pending host confirmation is active. Log the stable SDK error code. |
| OAuth preparation fails | The browser or backend can fetch the exact bootstrap metadata URL, uses its advertised registration endpoint, registers the canonical manifest URL, and reuses the returned client ID. |
| Authorization succeeds but the iframe is not notified | The callback redirects to the exact bootstrap relay. Backend mode uses the exact `handoff_code` fragment; browser mode uses the exact `authorization_code` fragment. Never include both. |
| Auth works but the iframe session does not | The handoff code is unexpired and unused, and the iframe redeems it with the verifier whose SHA-256 challenge was stored with OAuth state. Do not depend on third-party iframe cookies. |
| Browser-code OAuth returns an error | The relayed code is the exact still-pending code, state and launch ID match the active SDK request, and token exchange has not already consumed the code. |
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
- [ ] A generally published build accepts different exact canonical HTTPS host
      origins without a compiled instance list; a private build clearly
      documents its fixed list.
- [ ] `allowedHostOrigin` rejects HTTP, credentials, paths, queries, fragments,
      trailing slashes, non-canonical ports, and malformed values.
- [ ] The SDK is created synchronously before framework rendering or lazy-loaded
      code can miss the one-time iframe bootstrap message.
- [ ] The page calls `connect()` on load and `ready()` after its first usable
      render.
- [ ] Every action button has `type="button"`, awaits its SDK call, and shows a
      useful stable error code.
- [ ] A public app sends HTTP `frame-ancestors https:`; a private app sends its
      documented exact origins. The policy is not supplied only through meta.
- [ ] `X-Frame-Options` does not block cross-origin framing.
- [ ] A fully public note produces a card and the explicit **Open** action
      launches the exact linked route.
- [ ] The Egregoros developer workbench passes every required server check and
      the real iframe `ready()` handshake for the exact shareable URL.
- [ ] The app treats the workbench's synthetic developer-page source as a
      diagnostic only, never as proof of a public ActivityPub Note or share.
- [ ] Context, external navigation, and close are tested inside Egregoros, not
      only in a top-level browser tab.

### OAuth, if used

- [ ] The app explicitly uses either `browser_code` or the default
      `backend_handoff` completion profile.
- [ ] The manifest declares exact callback URIs, the minimum scopes, and useful
      maximum authorization ages.
- [ ] The browser and any backend validate bootstrap issuer/metadata/relay
      values before making requests.
- [ ] Registration uses the metadata-advertised endpoint and canonical
      `manifest_url`; the public client ID is cached per issuer.
- [ ] Each attempt has fresh state and S256 PKCE; backend mode also has a fresh
      handoff verifier/challenge.
- [ ] State binds the issuer, exact relay, launch ID, redirect URI, scopes, and
      PKCE; backend mode also binds the handoff challenge.
- [ ] Browser mode relays only `authorization_code`, exchanges it from the
      iframe with the retained verifier, and stores tokens in `sessionStorage`.
- [ ] Backend mode exchanges the code server-side and relays only a random,
      verifier-bound, single-use handoff code that expires within 60 seconds.
- [ ] Neither mode depends on cookies or storage shared between the top-level
      callback and cross-site iframe.
- [ ] Cancellation and retry create an entirely new transaction.

### Before production

- [ ] Manifest and page-card JSON pass the version 1 schemas and contain no
      unknown or duplicate fields.
- [ ] Production CSP, MIME types, caching, TLS, and direct non-redirecting
      responses have been checked with `curl`.
- [ ] Page, manifest, JavaScript, stylesheet, and declared asset responses all
      receive the intended security headers and correct MIME types.
- [ ] `Permissions-Policy` denies camera, microphone, geolocation, payment,
      USB, serial, Bluetooth, HID, MIDI, and display capture; production HTTPS
      responses carry a positive HSTS `max-age`.
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
- [ ] Each distinct public deep link that the app expects users to share has
      been run through the workbench; testing only the origin home page is not
      sufficient.

## Reference implementations

- [`examples/fediverse-miniapp`](examples/fediverse-miniapp) is the smallest
  static reference app.
- [`examples/fediverse-miniapp/DEPLOYMENT.md`](examples/fediverse-miniapp/DEPLOYMENT.md)
  covers nginx, security headers, caching, validation, and backend proxying.
- [`MINIAPPS.md`](MINIAPPS.md) defines the complete protocol and security
  invariants.
