# Fediverse Mini Apps — Normative V1 Host and App Protocol

> **Mastodon API compatibility required.** This protocol relies on the
> Mastodon-compatible API and OAuth surface throughout. It is for Egregoros and
> servers that implement that surface; it is **not** a generic ActivityPub
> feature. Servers such as Misskey that do not implement the Mastodon API are
> unsupported and miniapps will not work on them.

This document is the self-contained interoperability specification. It is
intended to be sufficient input for a person or coding agent implementing a
compatible host in different ActivityPub server software, or implementing a
mini app without access to Egregoros source code. The optional
[`MINIAPP_IMPLEMENTER_GUIDE.md`](MINIAPP_IMPLEMENTER_GUIDE.md) is a tutorial;
it is not required to discover any wire rule.

> Status: **V1 implementation candidate.** Egregoros implements this candidate
> on the `miniapps` branch, disabled by default. “V1” below means this exact
> candidate, not a claim that an external standards body has frozen it.
> Implementations advertise it as `version: "1"` and
> `fediverse_miniapp_profile: "1"`. Incompatible changes require a new version.

### How to read this specification

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHOULD**, **SHOULD NOT**,
and **MAY** are to be interpreted as described by RFC 2119 and RFC 8174 when
they appear in uppercase. Closed JSON objects reject unknown members. Unless a
field explicitly says otherwise, JSON member names and string values are
case-sensitive, arrays retain order, and repeated array values are invalid.

The final “Clean-room V1 implementation contract” consolidates every custom
data shape and browser message. It is normative and takes precedence if older
design rationale elsewhere in this document is less precise. Referenced RFCs,
HTML, CSP, ActivityPub, EIP-1193, and OAuth specifications remain normative for
their standard protocols; no Egregoros source file, JSON Schema file, SDK
implementation, example app, or other Markdown document is needed to fill in a
Fediverse-mini-app-specific rule.

V1 conformance has two levels:

- A **core host** implements discovery, cards, the isolated iframe host,
  `ready`, launch information, permissioned context, OAuth, identity,
  `compose_note`, and external navigation.
- A host MAY additionally advertise `wallet.evm` and/or
  `notifications.activitypub`. Apps MUST feature-detect them. The current
  ActivityPub notification declaration is an optional V1 extension, not a core
  requirement. The richer provenance/purpose vocabulary and delegated
  `app_activities` publishing are V2 and MUST NOT be inferred from V1 fields.

An implementation is compatible only if it implements every REQUIRED rule for
the surfaces it advertises. UI layout and persistence technology may differ;
security boundaries, exact-origin decisions, data-release rules, and wire
messages may not.

## Goal

Let an external developer publish a small web application on their own HTTPS
domain. When a user opens a supported link in Egregoros, Egregoros presents the
app in a user-controllable, lower-right floating iframe. An app can authenticate
the current Egregoros user through the calling instance's OAuth provider when it
needs authenticated capabilities; it otherwise uses only non-authenticated
capabilities the user has authorized.

This is inspired by Farcaster Mini Apps, but is a Fediverse-native protocol,
not a wire-compatible implementation.

## Lessons adopted from Farcaster Mini Apps

Farcaster separates four concerns:

1. A domain-scoped manifest identifies the app and declares host-facing
   capabilities.
2. Page-level embed metadata makes individual app URLs discoverable in social
   content.
3. A versioned iframe/WebView SDK provides host-to-app context and app-to-host
   actions.
4. Authentication uses a public OAuth client with PKCE; an app may keep tokens
   on a backend or, for a static browser app, exchange and hold them in the
   iframe.

Egregoros should keep this separation. It should *not* trust iframe-provided
identity/context, put a bearer token in the host relay, or treat a manifest as
a blanket permission grant.

## Existing Egregoros foundation

Egregoros already operates an OAuth authorization-code provider with PKCE,
registered applications, explicit redirect-URI validation, token revocation,
and scoped bearer-token authorization. The mini-app protocol can build on that
provider rather than introduce a second identity system.

## Interoperability profile for Fediverse-server implementers

This document is also the reference profile for another Fediverse server that
wants to host compatible mini apps. A compatible host implements the security
and wire behaviour below; it does not need to share Egregoros's language,
database schema, UI, or ActivityPub implementation. The Egregoros paths in
this section describe the current **v1 compatibility surface**, not an
endorsement of a particular internal architecture.

An implementer MUST preserve these externally observable rules:

| Surface | v1 compatibility requirement |
| --- | --- |
| App identity | Fetch the manifest only from `https://<app-origin>/.well-known/fediverse-miniapp.json`; validate and pin its exact HTTPS origin before registering or launching the app. |
| Iframe transport | Give each launch a fresh, origin-pinned `MessagePort`/nonce channel. Never expose host DOM, cookies, CSRF values, host storage, bearer tokens, or a general `postMessage` authority to the iframe. |
| SDK startup | Bootstrap is a one-time message sent when the iframe loads. The app must create its SDK listener synchronously before framework rendering or lazy imports; a host must not treat a missed bootstrap as an authorization success. |
| Authorization metadata | Serve RFC 8414 metadata at `https://<issuer>/.well-known/oauth-authorization-server`, including `fediverse_miniapp_profile: "1"`, S256 PKCE support, and the advertised registration, authorization, token, and revocation endpoints. The current SDK validates this exact metadata location. |
| Authorization relay | Provide the host-owned, fragment-only relay at `https://<issuer>/mini-apps/oauth/relay`. The current v1 SDK/bootstrap binds this exact URL. It accepts no token, does not use `window.opener`, broadcasts only the correlated result, and uses `no-store`, no-referrer, and `frame-ancestors 'none'`. |
| Browser OAuth | Support public clients with `token_endpoint_auth_method: "none"`, authorization-code + required S256 PKCE, exact redirect-URI matching, single-use short-lived codes, and no implicit, password, or client-credentials grant. |
| Dynamic registration | Deduplicate public registrations by `(issuer, canonical manifest URL)` and return the same public `client_id` for an equivalent registration. No client secret may be issued or required. |
| Narrow identity | Expose `GET /api/v1/mini-apps/identity` for an `identify` bearer grant, returning only the documented narrow identity representation and `Cache-Control: no-store`. This is a current v1 profile endpoint; a future version can advertise an alternative explicitly. |

The metadata-advertised registration, authorization, token, and revocation URLs
may have different paths on another server. The fixed metadata, relay, and
identity paths above are part of compatibility with the current v1 SDK and
implementer examples. A server that changes one needs a versioned SDK/profile
extension rather than silently changing it.

Open-host interoperability is a v1 deployment requirement, not an
Egregoros-specific convenience. A generally published miniapp is built and
deployed once and MUST be capable of launching from different canonical HTTPS
origins running Egregoros or another compatible ActivityPub server. Required
and recommended app settings therefore MUST NOT assume one calling instance
domain. Each individual launch remains bound to one exact origin; accepting a
canonical HTTPS origin says only which issuer controls that namespace, not
which software it runs or whether it is honest. A deliberately private app MAY
use a fixed host list, but it must describe itself as instance-restricted and
will not be generally interoperable.

### Browser CORS interoperability

`browser_code` is deliberately usable by a static app: it has no backend and
no client secret. Therefore every issuer endpoint used directly by that
cross-origin iframe MUST implement non-credentialed CORS. This is a protocol
requirement, not merely an nginx convenience:

- `GET /.well-known/oauth-authorization-server` MUST include
  `Access-Control-Allow-Origin` for the calling app origin (or `*`). Although a
  simple `GET` normally has no preflight, the browser still rejects its response
  without this header.
- Dynamic registration and token/revocation `POST`s MUST answer preflight and
  allow the requested method and `content-type`; bearer-protected identity/API
  requests MUST also allow `authorization` when that header is used.
- Responses must not depend on an issuer session cookie and must not use
  `Access-Control-Allow-Credentials`. Authorization itself remains a
  top-level, host-controlled navigation where the user can authenticate and
  consent; it is not a credentialed XHR from the iframe.
- Hosts should return CORS headers on error responses too. Otherwise an
  ordinary OAuth error becomes an opaque browser network error that an app
  cannot safely diagnose.

For the Egregoros v1 reference endpoints, that means CORS is required for
metadata, `POST /oauth/mini-app/register`, `POST /oauth/token`,
`POST /oauth/revoke`, and `GET /api/v1/mini-apps/identity`. A host may use a
strict allowlist of validated mini-app origins instead of `*`; it must make the
same decision on the preflight and actual response.

## V1 architecture

### 1. Manifest

An app domain publishes a versioned JSON manifest at this stable well-known
URL:

`https://app.example/.well-known/fediverse-miniapp.json`

The initial manifest would declare:

- stable protocol version and app name;
- optional publisher display name and website, which are informational only;
- start URL and allowed launch URL/origin boundary;
- icon, preview image, and optional theme/splash metadata;
- OAuth client metadata (or an indirection to standard OAuth client
  registration);
- requested capabilities/scopes; and
- an immutable ActivityPub actor declaration for public publishing and
  consent-gated transactional mentions.

The manifest is intentionally domain-scoped: one app identity owns the domain,
while individual paths identify launch destinations/shareable views within that
app. See “Domain paths and cards” below.

Egregoros always displays the manifest domain as the primary trust signal.
Publisher metadata does not prove an affiliation, identity, or safety claim;
users should treat it as untrusted unless it is independently established by
the same domain.

All manifest icon/splash URLs and page-card image URLs must use the manifest's
exact HTTPS origin. Egregoros proxies and sanitizes them, then caches only the
safe re-encoded raster for a bounded lifetime; third-party CDN asset origins
are not accepted in v1.

### 2. Discovery and launch

When a user puts a URL whose domain publishes a valid mini-app manifest in a
**fully public** note, Egregoros resolves it asynchronously and renders a rich
mini-app card in the note. The card uses the app's verified preview image/name
and has an explicit **Open** control. The card states that opening it shares the
public Note's canonical ActivityPub ID and the exact linked mini-app URL with
the displayed app origin, but does not share the viewer's identity. Selecting
it launches the declared URL and makes that narrow public launch information
available to the app without another prompt or OAuth.
Links in followers-only, direct, private, or otherwise non-public notes remain
ordinary links in v1 and do not provide mini-app launch context. URLs outside
the app's verified origin must open externally or require an explicit new
launch, never silently replace the iframe.

This applies to public local notes and public notes received through federation.
Remote-link preview failure is isolated from ActivityPub ingest and timeline
rendering; it leaves the ordinary link intact. Derived mini-app/card state is
stored outside canonical `Object.data` so it is never accidentally federated.
At most one card is rendered per note: the first valid mini-app URL in source
order. Later URLs remain ordinary links, limiting visual clutter and remote
fetch work.

This mirrors Farcaster's separation of page-level share metadata from the
domain-level manifest, while retaining a normal link if fetching or validation
fails. If page-specific metadata is absent, the generic card launches the exact
linked URL rather than assuming the manifest's home URL; this preserves deep
links and makes missing metadata visible during development.

### 3. Host surface

On desktop, Egregoros renders a fixed, lower-right panel with a visible app
identity header and controls to collapse, close, expand, and open externally.
Following Farcaster's documented web surface, the expanded desktop panel starts
at 424×695px and may adapt down for smaller viewports. The panel's
open/collapsed state is server-authoritative per user and app, so it survives
LiveView re-renders.

On mobile/PWA, the same app is presented in a vertical, full-screen modal/sheet
with safe-area-aware layout, a branded loading screen, and a visible close/back
route. This follows Farcaster's modal model rather than attempting to squeeze a
desktop floating panel into a phone viewport. The iframe is sandboxed,
constrained to a validated origin, and given a restrictive permissions
policy/CSP on both surfaces. It needs `allow-scripts`, `allow-forms`, and
`allow-same-origin` so a real external web app can preserve its own cookies and
session. Because the iframe is cross-origin from Egregoros, this does not let it
read or modify Egregoros. It must not receive top-navigation, downloads,
pointer-lock, or unmediated popup permissions; OAuth is opened by a
host-controlled top-level surface instead.

`openExternal` is accepted by the SDK only after an app-originating user
gesture assertion, then requires a real click on host-owned UI naming the exact
destination origin before any new top-level context opens. The iframe receives no device or
browser permissions in v1: camera, microphone, geolocation, clipboard read,
downloads, and notifications are denied until each has a dedicated capability,
consent, and threat-model design.

If the app blocks framing with `X-Frame-Options` or CSP `frame-ancestors`, the
host displays a clear framed-app error with an **Open externally** action. It
does not silently replace the Egregoros surface with a browser navigation.
A generally published app may use `frame-ancestors https:` so compatible
Fediverse instances can embed it without advance registration. That directive
controls framing only; it grants no host capability. Exact browser-origin
matching, bootstrap issuer equality, message-port pinning, backend public-DNS
validation, OAuth, and per-capability consent remain the authorization
boundaries. A private or instance-specific app may use a narrower
`frame-ancestors` policy.

Consequently, conformance guidance MUST present `frame-ancestors https:` as the
normal static policy for a generally published app. A copied example that
names one Egregoros domain without labelling the app private is
non-interoperable. The directive must be an HTTP response header; a CSP `<meta>`
element cannot set `frame-ancestors`.

Only one mini app may be active at a time. Launching another app explicitly
closes/replaces the active panel or sheet; v1 has no background/minimized app
strip or app launcher. Collapsing the active app retains its live iframe and
session while the user navigates Egregoros; closing or replacing it tears down
the iframe.

In a server-rendered or morphing frontend such as LiveView, the active frame is
a persistent client-owned island. Trusted JavaScript creates and navigates the
broker iframe; server patches may update bounded host metadata but MUST NOT
render, replace, move, or re-parent that iframe. The ignored island must keep a
stable DOM identity and sibling position across every loading, consent,
compose, notification, external-navigation, wallet, collapse, and expansion
patch. In particular, conditionally inserting a dialog before the ignored node
can cause a DOM reconciler to treat the iframe as a different child and reload
it. Place the island at a fixed structural position (Egregoros uses the first
direct child), render overlays after it, and use CSS ordering for visual layout.
Requesting context or any other SDK operation is a message exchange, never a
frame navigation or launch restart.

Opening a card for a Note that was displayed because another actor announced
or boosted it still attributes the original Note. Announce discovery and
attribution are not part of v1: the host neither claims which viewer announced
the Note nor supplies an Announce ID. An app may independently fetch the public
`sourceNoteId` and apply whatever reward or abuse policy fits its own threat
model.

Cards never launch an app merely from an image/title click: the user must select
the explicit **Open** button. There is no v1 app directory, saved-app surface,
or other launcher. V1 ordinary launches come from explicit cards on fully
public Notes. The developer workbench may create a clearly labeled synthetic
diagnostic launch; `homeUrl` establishes the app's canonical base and supports
future launchers.

### 4. OAuth sign-in

The app uses OAuth 2.1 authorization code + PKCE against the **local calling
Fediverse instance**. That instance is the authorization server. Two explicit
completion modes are supported:

- `backend_handoff` is the default. The app backend exchanges the code, keeps
  the Egregoros tokens, and gives the iframe a verifier-bound app-session
  handoff code.
- `browser_code` is for static browser applications. The callback relays only
  the short-lived authorization code to the initiating iframe, which exchanges
  it through the non-credentialed CORS token endpoint using its PKCE verifier.
  Bearer and refresh tokens never enter the host relay.

Apps may request the normal Egregoros/Mastodon-compatible scopes (including
read, write, and follow), subject to the user's explicit consent and the
instance's existing scope policy.

The host SDK may provide a `requestAuth` action that begins this flow in a
top-level, host-controlled authorization window/sheet. It must not use a
third-party iframe for consent or rely on third-party cookies.

The authorization page's ordinary CSP may retain `form-action 'self'` globally,
but the concrete consent response MUST add the origin of the exact registered
and validated callback URI to `form-action`. Browsers can enforce
`form-action` across the POST's redirect chain, so a self-only policy can block
the otherwise valid redirect to the app callback. This exception is generated
per authorization request after client, redirect URI, manifest, scope, and PKCE
validation. It contains only the normalized HTTPS origin (including a
non-default port), never a wildcard, path, query, fragment, credential, or
unvalidated request value. Reverse proxies must preserve this response-specific
policy rather than replacing it with a static CSP.

When a mini app requests a consequential OAuth scope such as `write`, the
consent UI must make any additional acknowledgement a browser-required control
and must also enforce it server-side. An incomplete form must remain visibly
incomplete instead of collapsing to an undifferentiated OAuth error. Failed,
cancelled, stale, or interrupted attempts are transaction-bound; the app starts
a fresh authorization request with new state and PKCE values, plus a fresh
handoff binding in backend mode, rather than replaying an old authorization
URL.

Authentication is optional and app-initiated. A newly launched iframe may call
`ready`, receive the non-user `bootstrap` object, use `openExternal` after a
user gesture, discover host capabilities, and use any separately authorized
non-OAuth capability such as the EVM wallet. It can read the narrow public
launch information and may request separately disclosed enriched public-note
context before OAuth. It may also call `composeNote` without OAuth: the current
host session identifies the posting user, and the trusted host composer requires
that user to review and explicitly submit the draft. Future capabilities marked
auth-gated still require OAuth.

The default backend authorization handoff is as follows:

1. The app backend obtains/reuses its dynamic registration for the calling
   Egregoros issuer and creates an authorization request with PKCE.
2. The iframe calls `requestAuth` with the client ID, exact registered callback
   URL, a non-empty subset of manifest-declared scopes, an optional requested
   authorization lifetime, PKCE challenge, opaque state, and a host-generated
   request correlation ID. Every subset retains `identify` (or legacy `read`)
   as its identity baseline.
3. Egregoros validates that those values match its registered client and the
   app's current manifest, then opens its own authorization/consent surface.
4. The authorization response goes only to the app's exact-origin callback,
   where the backend exchanges the code and establishes the app's own session.
   The authorization popup is opened with `noopener,noreferrer`, so the app
   callback never receives a reference capable of navigating the Egregoros
   window. After the exchange, the callback redirects the popup to the exact
   host-owned `authorizationResultRelay` URL from bootstrap, with only the
   launch ID, validated OAuth state, status, and opaque app-session handoff code
   in the URL fragment.
   The fragment is not sent in the HTTP request. The minimal host page validates
   it and broadcasts the result over a same-origin `BroadcastChannel` whose
   name contains the unguessable launch ID. The main host accepts it only for
   its active authorization request, rechecks the live OAuth grant server-side,
   and relays the result to the original iframe. The OAuth code, Egregoros
   tokens, and app session data never enter this channel.

The iframe sends its backend the exact `authorizationResultRelay` and
`launchId` from the already origin-pinned bootstrap while preparing its OAuth
state. The backend MUST require the relay URL to equal
`<trusted issuer>/mini-apps/oauth/relay`, bind both bootstrap values to the
OAuth state, and use them only once. A successful callback redirects to:

```text
https://social.example/mini-apps/oauth/relay#version=1&launch_id=LAUNCH_ID&state=OAUTH_STATE&status=success&handoff_code=HANDOFF_CODE
```

Cancellation uses `status=cancelled` with no `handoff_code`; other failures use
`status=error`. Duplicate fragment keys, extra fields, invalid identifiers, and
fragments over 1024 characters are rejected. The relay response uses
`Cross-Origin-Opener-Policy: same-origin`, `frame-ancestors 'none'`, no-store,
and a no-referrer policy. It contains no user/session data and never reads
`window.opener`.

The app may call `ready` before or after authentication. Failed, cancelled, or
expired authorization leaves the app able to use only non-authenticated SDK
features; auth-gated features remain unavailable.

If `ready()` does not arrive by the host deadline, Egregoros keeps the branded
loading screen and offers **Retry** and **Open externally**. It does not close
the app automatically.

The host sends bootstrap only once when the iframe load completes. An app MUST
create the SDK synchronously during initial module startup, before framework
rendering or lazy-loaded code can run after that event. The SDK installs its
bootstrap listener when it is created. A deferred `import()`/code-split SDK can
miss the one-time message permanently, leaving `connect()` pending and producing
the host's “miniapp did not become ready” state. Framework apps should create one
SDK instance before rendering and pass that instance into their component tree;
they must not recreate it during component renders or retries.

After a user has approved the immutable client and one requested scope subset,
the app may reuse that grant until its absolute deadline. The authorization surface
still identifies the current Egregoros account and provides a visible
cancel/account-switch route. Revocation, expiry, changed login, or an invalid
app session returns the flow to normal authorization. Egregoros issues a
short-lived access token and rotating refresh token. Rotation preserves the
grant family's original absolute deadline and can never turn a one-day grant
into a persistent grant.

#### Backend iframe-session handoff

Cross-origin iframe cookies cannot be relied on: browser/user privacy controls
may block them and the Egregoros instance cannot override those controls. A
backend-mode app therefore implements this one-time handoff after its backend
exchanges the OAuth code:

1. The iframe generates a cryptographically random `handoff_verifier`; it
   sends only its SHA-256 `handoff_challenge` to the app backend while preparing
   `requestAuth`.
2. The backend records that challenge against the app's authorization state.
   After a successful OAuth code exchange, it creates a random,
   single-use `handoff_code`, bound to that challenge, with a short TTL (at
   most 60 seconds).
3. The callback redirects its opener-free popup to the host relay fragment
   shown above with `{launchId, state, status: "success", handoffCode}`. The host
   correlates that launch to the one pending request, forwards the result to
   the original exact-origin iframe, and does not persist the fragment or code
   in HTTP logs or app state.
4. The iframe sends `handoff_code` and `handoff_verifier` directly to its app
   backend over HTTPS. Only the iframe knows the verifier, so an Egregoros host
   that can see the code and challenge cannot redeem it. The backend establishes
   the app's own iframe session by its chosen same-origin mechanism.

Apps may use cookies or the Storage Access API as an optimization, but they
cannot require them for a functional mini-app session. The handoff carries no
Egregoros bearer token and is never available to a different app origin.

#### Static browser authorization-code completion

A static app passes `completionMode: "browser_code"` to `requestAuth` and
omits `handoffChallenge`. Before starting this flow, its issuer must satisfy
the non-credentialed CORS requirements above: metadata is a cross-origin `GET`
and registration/token requests are cross-origin `POST`s. It uses this flow:

1. The iframe obtains or reuses its public dynamic `client_id`, creates a fresh
   high-entropy state value and PKCE verifier/challenge, and retains the
   verifier only in its current iframe session.
2. The static callback needs the exact bootstrap relay URL and launch ID after
   the opener-free navigation. The app may encode those non-secret routing
   values with a random nonce inside its opaque, base64url state. The iframe
   still stores and later compares the complete exact state value.
3. The iframe calls `requestAuth` with `completionMode: "browser_code"`, the
   public client data, exact callback, requested scope subset, state, and S256
   challenge. Egregoros binds those values to the active launch.
4. The callback does not exchange or store the code. After validating its
   state structure and requiring the relay to equal
   `<issuer>/mini-apps/oauth/relay`, it redirects to:

   ```text
   https://social.example/mini-apps/oauth/relay#version=1&launch_id=LAUNCH_ID&state=OAUTH_STATE&status=success&authorization_code=AUTHORIZATION_CODE
   ```

5. The host accepts only the exact unexpired, unconsumed code whose app, user,
   redirect URI, scopes, and S256 challenge match the pending launch request.
   It relays that code over the pinned SDK channel and never relays a bearer or
   refresh token.
6. The iframe compares the returned transaction state through the SDK's
   correlated request, then posts the code, public client ID, exact redirect
   URI, and retained PKCE verifier to the metadata-advertised token endpoint.
   Only after that exchange succeeds may it use an authenticated host action.

For the open-host static profile, the callback automatically performs the
redirect in step 4 without another user confirmation. This is a deliberate
interoperability and usability decision. The callback MUST still require a
strictly decoded state structure, a canonical exact HTTPS issuer accepted by
its host policy, the fixed `/mini-apps/oauth/relay` path, bounded fields, and a
valid success-or-error result shape. It MUST use `location.replace` or
equivalent replacement navigation and MUST NOT accept an arbitrary relay URL,
path, query, credentials, HTTP origin, or code format.

A purely static, generally published app has no independent server-held record
with which to authenticate an issuer supplied through OAuth state. Its callback
is therefore intentionally usable as a constrained open redirect to an
arbitrary canonical HTTPS origin at exactly `/mini-apps/oauth/relay`. This does
not authorize the attacker or make a forged/stolen code redeemable: the host
still requires its pending app, user, launch, state, exact redirect URI, scopes,
single-use code, and S256 challenge, while the iframe retains the verifier. It
does leave redirect and phishing-reputation risk. This v1 profile accepts that
residual risk instead of requiring an unfamiliar post-OAuth confirmation. An
app that cannot accept it MUST use a backend-held transaction binding or an
equivalent issuer record established independently before authorization.

The registered callback may be a query-driven route at the static app root,
such as `https://app.example/?oauth=callback`; it need not require a server
callback handler. It still MUST be the exact HTTPS URI in both the manifest,
registration, authorization request, and token exchange. Static-site rewrite
rules must serve the SPA entry document for that callback without replacing or
dropping its query string. The callback may briefly load after the popup
navigation, but it must neither render a token nor exchange the code itself.

The browser app is a public client and has no secret. It SHOULD keep tokens in
`sessionStorage`, clear them on logout or session teardown, use no third-party
runtime scripts, and deploy a strict CSP. Persistent IndexedDB or
`localStorage` increases the lifetime of a token theft. Frontend token storage
has the normal browser-SPA XSS risk, but PKCE prevents a host, extension, or
other observer that sees only the authorization code from redeeming it. Iframe
storage can be partitioned, cleared, or denied by browser privacy settings, so
an app MUST NOT depend on persistent storage to complete registration or OAuth;
it must work with only its current in-memory/session state.

### Optional EVM wallet capability

Wallet support is an opt-in host capability, independent of OAuth. It follows
the Farcaster model: the app receives a host-mediated
[EIP-1193](https://eips.ethereum.org/EIPS/eip-1193) Ethereum Provider through
the SDK, rather than a private key, seed phrase, wallet cookie, or Egregoros
OAuth token. The app uses the provider's standard `request()` calls (directly
or through libraries such as viem, ethers, or wagmi); the host routes them to
the user's Egregoros wallet UI. The wallet UI, not the iframe, owns account
connection, chain switching, simulation/preview, warnings, and the final user
confirmation for every signature or transaction.

The manifest gains an immutable wallet declaration:

```json
"wallet": {
  "evm": {
    "enabled": true,
    "required": false,
    "requiredChains": ["eip155:8453"]
  }
}
```

`requiredChains` uses CAIP-2 identifiers and is optional. An app with
`wallet.evm.enabled: true` receives the `wallet.evm.getProvider` capability
only when the instance supports a wallet and the user has enabled one. The
`required` field defaults to `false`: a wallet-enabled app can launch with a
no-wallet fallback unless it explicitly declares the capability required.
If `required` is true and no compatible wallet/chain is available, the host
shows an incompatibility error rather than launching a broken app.

The wallet-connection sheet states that the app may request wallet connection
and transaction/signature prompts; it does *not* authorize any transaction.
Every signing, transaction, account exposure, or chain change remains
individually user-confirmed and requires an iframe user gesture. The SDK exposes
supported chains/capabilities at runtime so apps can show a compatible fallback.

The v1 bridge supports only account discovery/connection, chain discovery,
`personal_sign`, `eth_signTypedData_v4`, and one `eth_sendTransaction` per
user gesture. EIP-5792-style `wallet_sendCalls` batches are deferred: they can
group requests for one wallet confirmation, but add important simulation,
partial-failure, and anti-scam requirements. No wallet access is available
unless the app declared the capability in its immutable manifest.

#### Wallet adapter boundary

The mini-app protocol talks only to an Egregoros `EvmWalletAdapter` behind the
host's `wallet.evm.getProvider` bridge. The adapter returns supported CAIP-2
chains and processes the allowlisted EIP-1193 requests; the host binds every
request to the authenticated user, exact mini-app origin, and user gesture,
rate-limits it, and renders the confirmation UI. The iframe never reaches
`window.ethereum` or another wallet SDK directly.

Wallet account exposure is per-app. Until a mini app calls
`eth_requestAccounts` from a user gesture, its provider returns no accounts.
The resulting app-origin/account connection is remembered until the user
revokes it. Egregoros settings include a separate **Disconnect wallet from this
app** control that clears this wallet permission and leaves the app's OAuth
grant unchanged.

The wallet UX is seamless without becoming delegated authority: the first
per-app connection uses one native host sheet, and later calls skip repeated
wallet/account-picker steps. Every signature or transaction still uses one
compact host confirmation that identifies the exact app domain and a
human-readable action/transaction summary. It is not preceded by a redundant
connection confirmation.

The initial `InjectedWalletAdapter` bridges the user's browser-injected
Ethereum wallet (for example, an extension) through this host boundary. It is
available only where an injected provider exists; it does not make a desktop
extension magically available to a mobile PWA.

A future `JawWalletAdapter` can be selected only by an Egregoros administrator
in server configuration. JAW publishes an EIP-1193-compatible provider and
passkey smart-account flow, so it maps to the same adapter methods. Its API
key, account mode, paymaster/sponsorship policy, and passkey/popup UI belong to
the Egregoros deployment configuration and host wallet surface—never to a
mini-app manifest or iframe. JAW's more advanced delegated permissions,
headless accounts, and batched calls are explicitly outside this protocol until
separately threat-modeled.

### Consent and controls

For an OAuth-enabled app, the OAuth approval screen presents the app name,
hosting/manifest domain, optional publisher metadata, and the scopes requested
by this transaction from the immutable manifest maximum. The user also chooses
an authorization duration no longer than the app, manifest, or instance
maximum. Normal OAuth consent is sufficient for requested non-write scopes. If
the request includes `write`, the user must
complete a separate, plain-language second confirmation explaining that the app
can perform write actions through the Egregoros API. Neither confirmation lets
the app silently publish through the host compose action.

The once-per-app disclosure for enriched public-note context is independent of
OAuth. It appears before the app first receives note text, author, mentions, or
other enriched context, including for apps that never declare OAuth. The narrow
public launch information described on the rich card is available on open
without this prompt. When OAuth and enriched-context disclosures are needed in
the same launch, the host may present them together.

Egregoros settings provide a per-app revoke/disconnect control. Revocation
invalidates the app's access and refresh tokens plus its reusable grant, clears
the once-per-app enriched-context approval, and closes any active iframe for that
app. A future launch starts the approval process again.

Instance operators can configure mini-app domain allow/deny patterns. Policy is
enforced before manifest/page metadata or asset fetching, card display, iframe
launch, dynamic registration, and OAuth authorization. A blocked app appears
as an ordinary link and cannot use a previously issued registration or token.
Patterns are exact hosts or DNS-suffix wildcards only—for example,
`example.com` and `*.example.com`; arbitrary regular expressions are not part
of v1. Deny rules always win. If an allowlist is non-empty, only matching
domains may operate as mini apps. Rule changes take effect immediately: a newly
blocked app's iframe closes, future host calls and token use are denied, and its
links revert to ordinary links.

#### ActivityPub messaging and notification consent

Public app messages need no host extension. Consent-gated transactional
mentions are the optional `notifications.activitypub` V1 extension whose
complete receiver contract is consolidated below; the longer
[`MINIAPP_ACTIVITYPUB_MESSAGES.md`](MINIAPP_ACTIVITYPUB_MESSAGES.md) adds app-
developer guidance and future vocabulary rationale. The app
operates one normal ActivityPub `Application` or `Service` actor. Public notes
use ordinary federation and may include normal public `Mention` tags without
invoking the mini-app notification extension. Transactional notes are
non-public, address exactly one consenting actor, and contain one matching
`Mention`.

Notification permission is deliberately separate from launch context. The
SDK `notifications.getPermission()`/`requestPermission()` surface reports and
requests user-specific permission only after OAuth and a host-owned gesture
confirmation. An OAuth-authenticated backend endpoint provides the
authoritative recipient/app-actor binding. Egregoros rechecks current consent
when the signed direct mention arrives, so revocation suppresses user-visible
delivery even when the sender has stale state.

The current v1 manifest strictly parses and immutably persists the actor
declaration, Egregoros has actor-bound consent storage, and the SDK/broker have
a typed, capability-gated permission transport. The host advertises the
capability, requires active OAuth, answers non-prompting state reads, owns the
grant/deny dialog, and provides independent Privacy-settings revocation.
The OAuth-authenticated backend endpoint derives the app solely from the bearer
token's registered client and returns the canonical recipient actor only for a
current grant. Inbound enforcement requires one exact local recipient and
matching mention plus current notification and OAuth grants; invalid or revoked
deliveries are acknowledged without persistence. Actor-document activation
uses a unique background job and keeps the capability disabled until the exact
actor identity, same-origin endpoints, key ownership, and RSA key fingerprint
are validated and pinned. Public ActivityPub publishing requires no mini-app
host extension and can be implemented independently.

The next protocol revision adds a self-contained inline `fma` namespace and
three distinct vocabulary properties:

- `fma:miniApp` links both the activity and object to the exact canonical
  well-known manifest URL; and
- optional `fma:notificationPurpose` is the closed scalar enum
  `transactional` or `promotional`; and
- optional `fma:miniAppLink` is an ActivityStreams `Link` on an ordinary public
  `Note` that identifies one exact, visible candidate launch URL.

In that future revision, the provenance marker is required for an object to claim mini-app production,
but is trusted only when its manifest, declared actor, activated signing-key
pin, and current domain policy all agree. Public app notes with no individual
recipient or mention carry the marker and omit purpose. Direct mentions must be
non-public, carry one purpose on both activity and object, and have an
independent user grant for that exact purpose. Missing, unknown, conflicting,
or array-valued purposes are suppressed; mixed operational and promotional
content is labeled promotional. Classification is sender-declared moderation
evidence rather than something Egregoros infers from prose. This future wire
profile is developed in
[`MINIAPP_ACTIVITYPUB_MESSAGES.md`](MINIAPP_ACTIVITYPUB_MESSAGES.md#31-mini-app-provenance-and-message-purpose-wire-profile),
but it is not part of `fediverse_miniapp_profile: "1"` and is not needed to
implement this document's transactional-Boolean V1 extension.

`fma:miniAppLink` is discovery metadata, not mini-app provenance or trust. Its
`href` must exactly match a URL parsed from sanitized note content, and its
closed `Link` shape carries `type: Link`, the full mini-app vocabulary IRI as
`rel`, `mediaType: text/html`, and an optional bounded display name. The full
IRI is required because ActivityStreams does not JSON-LD-coerce `rel` values to
identifiers. The receiver still applies
URL safety and domain policy, derives the origin's fixed well-known manifest
location, and independently validates the app. Explicit and implicit URLs share
one candidate/fetch budget and can produce at most one mini-app card. Invalid
hints degrade to ordinary links and never invalidate the containing note.

#### Dynamic registration

Any OAuth-enabled developer may anonymously register their app with a calling
instance before asking a user to authorize it. Use OAuth Dynamic Client
Registration (RFC 7591) advertised from the instance's OAuth Authorization
Server Metadata (RFC 8414), with a mini-app profile that makes the following
normative:

1. Registration may occur from the mini-app backend or, for a static browser
   app, directly from the iframe through non-credentialed CORS. The response is
   a public OAuth client: it returns a stable `client_id`, declares
   `token_endpoint_auth_method: "none"`, and never returns a client secret.
2. The registration cache key is `(authorization_server_issuer,
   canonical_manifest_url)`. A conforming app MUST reuse a valid known client
   registration for every user of that app on that issuer and MUST NOT register
   again merely because a new user opens it. Persistent browser storage is an
   optimization, not a prerequisite: privacy controls may partition or deny
   `localStorage`/IndexedDB in an iframe. If the cache is unavailable or empty,
   the app may register again and relies on the host's idempotent result.
3. The instance validates that every HTTPS redirect URI is on the manifest's
   canonical app origin—exact scheme, host, and port—and it stores the
   canonical manifest URL with the client record. Redirects cannot be widened
   through a later authorization request.
4. A registration contains fixed app metadata—canonical manifest URL, name,
   website, redirect URIs, maximum scopes, optional per-scope authorization
   ages, and OAuth grant/response types. The registration response returns the
   ages as `scope_authorization_max_age_seconds`.
   It has no user identity, note context, or per-user fields.
5. A compatible host permanently deduplicates an equivalent registration while
   that app identity exists, idempotently returns the same public `client_id`,
   rate-limits/abuse-monitors anonymous registration, and allows instance
   operators to disable it. It rejects registrations whose manifest cannot be
   securely fetched and validated. A conflicting immutable manifest returns
   an error rather than a second client.

The registration endpoint is `POST /oauth/mini-app/register` with the single
`manifest_url` field. The first equivalent request returns `201`; later
equivalent requests return `200` with the same public metadata. This removes
the first-caller secret-capture race inherent in anonymous confidential-client
registration. Mini-app public clients MUST omit `client_secret` during code
exchange, refresh, and revocation. The instance requires S256 PKCE for every
authorization code and explicitly rejects `client_credentials` for these
clients.

This prevents an ordinary app launch from producing a client per user. It does
not make an anonymous registration endpoint cost-free: instances still need
rate limits and abuse controls, because any public API can be used to create
junk registrations.

#### Immutable scope declaration

If an app declares OAuth, its maximum OAuth scope set is fixed when first
observed/registered on an instance. Changing that declared maximum (adding,
removing, or renaming scopes) invalidates the manifest for that app identity
and is rejected. Each authorization request may select a non-empty subset of
that maximum, but it cannot introduce a new scope and must include `identify`
(or legacy `read`). An OAuth-enabled manifest scope set MUST include `identify`,
which links the grant to the user's minimal Fediverse identity without granting
authenticated access to timelines, posts, notifications, or conversations.
The broad `read` scope is optional and implies `identify` for compatibility,
but new mini apps MUST declare `identify` explicitly.
Apps that do not declare OAuth need no dynamic registration and can operate
solely through non-authenticated capabilities. An OAuth-enabled app that needs
a different permission set must use a new app identity/domain until a future
version defines a safe migration and re-consent flow.

`oauth.scopeAuthorizationMaxAgeSeconds` is an optional immutable object whose
keys must also occur in `oauth.scopes`. Values are integer seconds from 300
through 31,536,000. A missing key requests the instance maximum. Launch context
cannot set or extend OAuth lifetime; it is untrusted presentation input.

For each transaction, the effective maximum is the minimum of the app's
`authorizationLifetimeSeconds` request, every requested scope's manifest
maximum, and the instance maximum. The user may shorten it again on the
host-owned consent screen. The access token expires after at most one hour and
never after the authorization deadline. The refresh-token family has that same
absolute authorization deadline, which rotation MUST preserve. The token
response reports the remaining deadline as `authorization_expires_in`.

Different lifetimes require separate grants. For example, an app may keep an
`identify` grant for a year, then request `identify write` for one day when the
user invokes a destructive operation. The shorter request does not replace the
long identity grant. Literal non-expiring credentials are not supported;
“until revoked” user experience still requires periodic finite reauthorization.

#### Mini-app OAuth scope meanings

The authorization screen MUST list each requested permission separately and
must not describe `identify`, `read`, and `write` as one combined account-access
grant:

| Scope | Authority granted | Typical use |
| --- | --- | --- |
| `identify` | Call `GET /api/v1/mini-apps/identity`, which returns only the user's ActivityPub ID, local username, fully qualified account name, display name, and profile URL. | Link a Fediverse account to an app. This is the normal and least-privilege choice. |
| `read` | Use authenticated read APIs, including data such as timelines, posts, notifications, conversations, and visibility-limited resources where the endpoint permits it. It also implies `identify`. | Apps whose actual feature requires account data, not merely the user's identity. |
| `write` | Use write APIs permitted by Egregoros, including creating, editing, or deleting content. It does not imply `read` or `identify`, and mini apps receive the additional write confirmation required by this profile. | Apps that perform API writes as the user. Host-mediated `composeNote` remains a separate prefill-only capability. |

The identity response is intentionally a new narrow endpoint rather than
`/api/v1/accounts/verify_credentials`: the Mastodon-compatible endpoint
requires `read` and exposes a substantially broader account representation.
The response to `/api/v1/mini-apps/identity` MUST be marked `no-store`. Backend
mode keeps bearer and refresh tokens on the app backend; browser-code mode
holds them in the iframe's JavaScript session.

### 5. Host SDK

Publish a small versioned JavaScript SDK. Its transport uses a nonce-bound,
origin-checked bootstrap followed by the transferred-port protocol specified
in the clean-room contract. The V1 methods are:

- `ready()` — app declares that its first render is usable;
- `getLaunchInfo()` — immediately available, non-authoritative public
  attribution containing only protocol version, exact launch URL, exact linked
  URL, and the original public Note's canonical ActivityPub ID;
- `getContext()` — separately permissioned enriched public-note context,
  containing the exact launch/link URLs and (when launched from a note) its
  identifier, text, author, and public mentions; and
- `requestAuth(authorization)`, `close()`, and
  `openExternal(url)` — host-mediated actions; and
- `notifications.getPermission()` and
  `notifications.requestPermission()` — capability-gated ActivityPub
  transactional-message permission state and host-owned prompting.

The v1 reference module is built as
`/assets/js/fediverse-miniapp-sdk-v1.js`. A mini app should vendor and serve a
pinned copy from its own origin rather than hot-linking an arbitrary user's
instance. Construction requires an `allowedHostOrigin(origin)` callback; there
is deliberately no accept-any-host default. The app can allow a known instance
exactly, but a generally published Fediverse mini app SHOULD instead accept any
syntactically exact canonical HTTPS origin. This is not `() => true`: the
browser callback rejects HTTP, credentials, paths, queries, fragments,
non-canonical ports, trailing slashes, and malformed values.
This is not a static instance allowlist: the bootstrap still requires
`event.origin === hostOrigin === issuer`, and the SDK pins that one exact origin
for the channel lifetime. Browser JavaScript cannot securely perform or pin DNS
resolution. When an app has a backend that dereferences issuer-controlled URLs,
that backend MUST independently reject private, local, reserved, mixed
public/private, redirected, or malformed destinations and connect to a
DNS-pinned public address while preserving the original hostname for Host,
SNI, and TLS certificate verification. A fully static app instead treats the
accepted host as an open-world issuer authoritative only for its own namespace;
claims about an actor outside that namespace require independent verification.
The connected SDK exposes a frozen `bootstrap` containing
`hostOrigin`, OAuth `issuer`, `authorizationServerMetadata`, the exact
`authorizationResultRelay`, protocol version, launch ID, and the currently
available capability names.

Every published SDK build MUST ship matching TypeScript declarations even when
its runtime is authored in JavaScript. Egregoros builds
`fediverse-miniapp-sdk-v1.d.ts` beside the ESM file and type-checks the public
surface in CI. The declarations cover bootstrap/context DTOs, OAuth and compose
inputs/results, publication receipts, stable SDK errors, wallet capabilities,
and overloads for every allowlisted EIP-1193 method. A runtime/declaration
change is one versioned SDK change; publishing JavaScript with missing or stale
types is a release failure.

The reference API is promise-based:

```js
import {createFediverseMiniAppSDK} from "./fediverse-miniapp-sdk-v1.js"

const sdk = createFediverseMiniAppSDK({
  allowedHostOrigin: origin => publicHttpsFediverseOrigin(origin),
})

const bootstrap = await sdk.connect()
await sdk.ready()
const launchInfo = await sdk.getLaunchInfo()

// This separately asks the host for the user's once-per-app approval.
const context = await sdk.getContext()

button.addEventListener("click", async () => {
  await sdk.openExternal("https://docs.example/chapter/1")
})

const ethereum = sdk.wallet.getProvider()
const accounts = await ethereum.request({method: "eth_requestAccounts", params: []})

const permission = await sdk.notifications.getPermission()
notificationButton.addEventListener("click", async () => {
  await sdk.notifications.requestPermission()
})
```

`requestAuth` accepts the public dynamic client ID, exact redirect URI, a
manifest-allowed scope subset, optional `authorizationLifetimeSeconds`, and
PKCE state/challenge. The default `backend_handoff` mode also requires a
one-time handoff challenge. The explicit `browser_code` mode forbids that
challenge and returns `authorizationCode` instead of `handoffCode`; the SDK
fixes PKCE to `S256`. `composeNote(draft)` resolves when the host
accepts or rejects the draft and `on("composeNotePublished", callback)` emits
the later publication receipt. `wallet.getProvider()` returns a narrow
EIP-1193-compatible provider only when `wallet.evm` appears in bootstrap
capabilities. Notification methods similarly require
`notifications.activitypub`; prompting also requires current browser user
activation. Calls time out, are correlated by random IDs, and reject with a
stable `error.code`. Destroying the SDK closes the private port and rejects all
pending calls.

| Access class | V1 methods | Prerequisite |
| --- | --- | --- |
| Public base | `ready`, `bootstrap`, `getLaunchInfo`, `getContext`, `close`, `openExternal` | Valid framed app; `getLaunchInfo` needs no OAuth or prompt, `getContext` needs enriched-context disclosure, and `openExternal` needs the SDK gesture assertion plus a trusted host click. |
| OAuth initiation | `requestAuth` | Optional `oauth` manifest object and a public dynamic registration obtained by the backend or browser. |
| Wallet | `wallet.evm.getProvider` and its allowlisted EIP-1193 calls | Immutable wallet declaration, host wallet availability, and per-app wallet connection/confirmation. No OAuth required. |
| Transactional notifications | `notifications.getPermission`, `notifications.requestPermission` | Immutable ActivityPub declaration and OAuth; prompting additionally requires a user gesture and host confirmation. |
| Host-confirmed compose | `composeNote` | Immutable `compose_note` declaration, active channel, signed-in host user, current domain allowance, and explicit submission in trusted host UI. No OAuth grant is required. |

#### Compose a note

`composeNote(draft)` is a required v1 host action. It hands a draft to the
Egregoros composer, which opens in its normal desktop panel or mobile sheet.
It never creates, queues, or submits a note: the user sees, may edit, and must
explicitly press Egregoros's normal submit button.

The initial draft schema is deliberately narrow and host-validated:

- `text` (string, optional), `spoilerText` (string, optional), and `language`
  (BCP 47 tag, optional);
- `visibility` (optional), always presented to the user as an editable
  selection and defaulting to `public` in the V1 wire contract; and
- `inReplyTo` only when the target is the public note from which this app was
  launched, plus a bounded list of HTTPS links to include as ordinary text.

No media upload, poll creation, arbitrary reply target, silent publication, or
host API token is included in v1. These boundaries make the action useful for
sharing a result, challenge, or invite without letting a remote app post on a
user's behalf.

`compose_note` is an explicit immutable manifest capability. Egregoros enables
only declared capabilities, but compose permission is not part of OAuth consent:
each invocation opens trusted host UI and only the host user can submit it.
Lifecycle/authentication methods and `openExternal` are base SDK methods, not
manifest capabilities. Wallet capabilities use their own per-app wallet
approval and likewise do not require OAuth.

Each successful `composeNote` call is assigned a host-generated `requestId`.
After—and only after—the user submits successfully, the SDK emits a
`composeNotePublished` event to the initiating iframe containing that
`requestId`, the canonical ActivityPub object ID/URL of the new note, and its
visibility scope (`public`, `unlisted`, `followers`, or `direct`). No content,
author, mentions, attachments, OAuth token, or delivery state is included. An
app can fetch a public or unlisted note at that URL to independently verify its
existence and contents; a private note may not be fetchable, but the receipt
does not disclose anything beyond its identifier and visibility. This is a
receipt, not authority: it does not claim that federation delivery succeeded
and is never emitted before local publication succeeds. Cancellation and failed
submission produce no event in v1.

The app must validate the host origin and handshake nonce; Egregoros must
validate the iframe origin against the installed manifest before accepting every
message. Neither public launch information nor enriched context contains an
access token or current-user identity. Public launch information is available
without OAuth or a second prompt after the disclosed **Open** action. Enriched
context is available without OAuth only after the separate once-per-app
permission; neither kind of note data is implied by an OAuth API scope.

The handshake always exposes a `bootstrap` object with the exact Egregoros host
origin, SDK protocol version, and authorization-server issuer/metadata URL,
letting an OAuth-enabled app backend reuse or create its dynamic registration
and form a PKCE request. Bootstrap contains no
current-user identity. Apps obtain the narrow public attribution through
`getLaunchInfo()` and may obtain enriched note context through `getContext()`
after the separate disclosure, whether or not they authenticate with OAuth.

Launch context is useful but is untrusted input—it can be malformed, stale, or
controlled by the note author. More importantly, opening an app shares it with
the app's external domain. In v1, mini apps are launched only from fully public
notes, which removes the limited-audience-note case. The host must still make
that disclosure clear before the first contextual launch and treat it as a
separately consented `miniapp:launch_context` permission.

## Hostile mini-app security boundary

### Threat model and protected assets

A mini app is arbitrary hostile Internet code. Its operator controls its DNS,
TLS endpoint, redirects, HTTP headers, manifest, page metadata, HTML,
JavaScript, iframe navigations, `postMessage` payloads, OAuth parameters,
external URLs, and wallet RPC requests. The app may attempt phishing, UI
redressing, data exfiltration, CSRF, SSRF, DNS rebinding, OAuth mix-up/code
injection, capability escalation, wallet theft, denial of service, and browser
sandbox escape. Publisher labels and a valid HTTPS certificate prove control of
the domain only; they do not make the app trustworthy.

The boundary MUST protect:

- Egregoros's process, filesystem, database, internal network, cloud metadata,
  secrets, and availability;
- host DOM, LiveView socket, session/CSRF cookies, local storage, OAuth codes and
  tokens, and other apps' state;
- user identity and note context until the applicable disclosure/authorization;
- wallet accounts, signing keys, signatures, transactions, chain state, and
  provider configuration; and
- canonical ActivityPub data. Derived mini-app state MUST remain in
  `Egregoros.Object.internal` or dedicated tables and MUST NOT enter
  `Egregoros.Object.data`.

The trusted computing base is limited to Egregoros server code, the small host
SDK/broker, browser same-origin/sandbox enforcement, and the selected wallet
adapter. The mini app, its backend, all remote bytes, and every value received
from them are untrusted.

### Non-negotiable invariants

1. App JavaScript MUST never execute in the Egregoros origin or receive direct
   references to host DOM, LiveView, cookies, storage, CSRF values, OAuth
   tokens, wallet implementations, or server internals.
2. Every privilege crosses a typed, versioned host broker. The server or wallet
   adapter MUST independently authorize each privileged request; a manifest,
   disabled button, prior UI check, or well-formed SDK message is never proof of
   authority.
3. An app receives only the minimum data required for the specific operation.
   Data from one app session, user, note, iframe, origin, or OAuth client MUST
   never be reusable in another.
4. Exact origin means normalized scheme, ASCII/Punycode host, and effective
   port. Production origins MUST be HTTPS. Userinfo, fragments, IP-literal
   hosts, opaque origins, `localhost`, non-HTTPS schemes, and parser-ambiguous
   URLs MUST be rejected.
5. Egregoros MUST NOT frame an app at its own origin. Host authentication
   cookies MUST be host-only (`__Host-` prefix where supported), `Secure`,
   `HttpOnly`, `Path=/`, have no `Domain` attribute, and use an appropriate
   `SameSite` policy. State-changing host endpoints MUST additionally enforce
   CSRF tokens and exact `Origin` checks; cookie policy alone is not CSRF
   protection.
6. Failure is closed: invalid, stale, oversized, unsupported, blocked, or
   ambiguous input loses the requested capability. Discovery failure falls back
   to an ordinary link; it never weakens sandbox, origin, consent, OAuth, or
   wallet checks.

### Server-side remote fetching and SSRF containment

Manifest, page, and image fetching MUST use a dedicated outbound client with no
Egregoros cookies, authorization headers, client certificates, proxy
credentials, ambient cloud credentials, or shared cookie jar. Remote bytes are
parsed as data only; Egregoros MUST NOT execute remote JavaScript, CSS, SVG,
templates, or use a general headless browser for discovery.

For every outbound request Egregoros MUST:

- canonicalize the URL once with one strict parser, require HTTPS, and validate
  the exact origin before resolving DNS;
- resolve all A and AAAA answers and reject the request if any answer is
  loopback, private, link-local, multicast, documentation/reserved,
  carrier-grade NAT, or otherwise non-global;
- pin the validated address for the connection while still validating the TLS
  certificate and SNI against the original hostname, preventing a DNS
  rebinding/TOCTOU change between validation and connection;
- follow at most two redirects for manifests, actors, pages, and images; every
  hop MUST remain on the exact original origin and repeat URL-shape, domain
  policy, DNS, public-IP, and pinned-connection validation before connecting;
- apply an egress firewall that independently blocks internal networks, Unix
  sockets, and cloud metadata endpoints even if application validation fails;
- enforce connection, first-byte, and total timeouts; decompressed response-size
  limits; per-origin concurrency/rate limits; and a global worker queue so an
  attacker cannot exhaust schedulers, sockets, memory, or database connections;
  and
- require the expected MIME type with `X-Content-Type-Options: nosniff`
  semantics. Suggested hard limits are 64 KiB manifest JSON, 1 MiB page HTML,
  5 MiB compressed image input, and 10 megapixels after decode.

JSON parsing MUST reject duplicate keys, invalid Unicode, excessive nesting,
non-integer/out-of-range numbers, unknown security-sensitive fields, and values
outside explicit length/count bounds. HTML parsing extracts only the one
declared meta element; it never evaluates markup. The image proxy MUST accept a
small raster allowlist (for example PNG, JPEG, WebP, and AVIF), decode in a
resource-limited worker, reject SVG and animated/decompression bombs, and serve
safe output with no cookies, no referrer, and a fixed image content type. A
successful sanitized image response MUST permit bounded private user-agent
caching; five minutes is the v1 recommended maximum age. Error responses MUST
use `Cache-Control: no-store`, and shared intermediary caches MUST NOT retain
the response.

The host MUST also keep a bounded cache of successfully sanitized rich-card
images so repeated cards do not repeat remote fetch and decoder work. It MUST
cache only the safe re-encoded raster, never the untrusted source response or a
failure. The key MUST bind the exact image URL and current card resolution
token, and that token MUST change when the resolved image URL changes. Cache
storage MUST have finite entry, byte, and time limits. Concurrent misses for an
identical key SHOULD be coalesced into one fetch and decode. Before returning a
host-cache hit, the host MUST still verify that the exact card resolution is
active and that current app/domain policy permits it. URL, DNS, redirect, and
egress policy MUST run again whenever a cache miss causes a remote fetch.

### Iframe and browser containment

The remote app MUST NOT be framed directly by the privileged LiveView document.
The panel/sheet frames a small trusted same-origin broker document created for
one launch session; that broker alone frames the external app. The main
Egregoros CSP can therefore use `frame-src 'self'`. The broker response is
generated server-side with a per-launch CSP whose `frame-src` contains exactly
the validated app origin and whose remaining policy is approximately
`default-src 'none'; script-src <trusted hashed/nonced broker>; connect-src
'none'; img-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';
frame-ancestors 'self'`. The broker contains no timeline/user HTML, no OAuth or
wallet secrets, and no general application code; it only enforces the channel
and forwards typed requests to the privileged host.

The external app iframe MUST be created by that broker only after the manifest,
page launch URL, operator policy, and user action have passed server-side
validation. Its security attributes are fixed by trusted broker code and cannot
be relaxed by manifest or SDK input:

```html
<iframe
  sandbox="allow-scripts allow-forms allow-same-origin"
  referrerpolicy="no-referrer"
  allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'; payment 'none'; usb 'none'; serial 'none'; bluetooth 'none'; hid 'none'; midi 'none'; display-capture 'none'; fullscreen 'none'"
>
```

`allow-same-origin` is necessary for a normal external web app to use its own
origin and session, but it is safe only while the app is never same-origin with
the Egregoros parent. The host MUST NOT add `allow-top-navigation`,
`allow-top-navigation-by-user-activation`, `allow-popups`,
`allow-popups-to-escape-sandbox`, `allow-downloads`, `allow-modals`,
`allow-pointer-lock`, `allow-presentation`, or
`allow-storage-access-by-user-activation` in v1.

Neither the main document nor broker CSP may broadly allow `https:` frames.
The broker MUST retain sole control of the external iframe `src`; same-origin
path navigation is permitted, but an observed cross-origin navigation
invalidates the channel and tears down the iframe.

Deployment proxies MUST preserve these route-specific CSP headers rather than
installing a single static CSP for the whole origin. The normative operator
configuration, including Caddy and nginx examples, HSTS, Permissions Policy,
forwarded-header trust, and verification commands, is documented in
[`deploy/SECURITY_HEADERS.md`](deploy/SECURITY_HEADERS.md).
External navigation goes only through the host's gesture-bound confirmation.
The app cannot hide or draw over the host-owned header, domain label, close,
collapse, permission, OAuth, compose, external-navigation, or wallet surfaces.
All host text derived from the app is inserted as text, never raw HTML.

Egregoros API routes MUST NOT enable credentialed CORS for mini-app origins.
Ambient Egregoros browser sessions are not an app API: authenticated API access
requires the app's explicit OAuth bearer token, and state-changing browser
routes retain normal CSRF/Origin protection.

### Message-channel authentication and validation

The host generates at least 256 bits of randomness for a new channel/session ID
on every iframe creation. The trusted parent↔broker channel and broker↔app
channel are distinct; a request is never forwarded by copying arbitrary
messages between windows. The initial broker↔app window message MUST use the
exact `targetOrigin`; the broker accepts it only when `event.origin` is the exact
app origin and `event.source === iframe.contentWindow`. `"*"` MUST never be used
as a target origin. After this check, the broker SHOULD transfer a dedicated
`MessageChannel` port and close both ports on iframe navigation, replacement,
policy change, logout, revocation, timeout, or origin mismatch.

Every message envelope MUST include protocol version, channel ID, unique
request ID, method/event name, and bounded payload. The broker MUST apply a
closed method allowlist; strict per-method schemas; string, array, nesting, and
total-message limits; duplicate/replay detection; request deadlines; and
per-channel/user/origin rate limits. Unknown methods, extra security-sensitive
fields, malformed structured-clone values, prototype-pollution keys, unsolicited
responses, and IDs from another channel are rejected without side effects.
Errors returned to the app are stable codes without stack traces, database
identifiers, network topology, or secret-bearing details.

The v1 concrete per-launch ceilings are 384 KiB for one structured message,
2 MiB total channel payload, 512 received browser envelopes, 128 accepted
request IDs, and eight correlated requests awaiting responses. The app-to-host
side uses a token bucket with a burst of 40 messages and a refill of 20 per
second. The server independently accepts at most 256 broker events, 128
requests, the same byte ceilings and rate, and only one host-owned prompt or
operation at a time. Traffic before the one valid `ready` message, exceeding
any ceiling, or attempting to overwrite a pending prompt is rejected; a budget
violation closes the private port and launch. A new iframe load does not reset
these per-launch counters; only a new random launch ID does.

Because the UI can present only one host-owned prompt or privileged operation
at a time, an additional valid request received while one is pending MUST get
an immediate, exactly correlated protocol response using that operation's
documented failure shape. It MUST NOT replace the visible request and MUST NOT
be silently dropped: a dropped response leaves the SDK promise pending and
leaks a broker outstanding-request slot until timeout. For EIP-1193 requests,
use the standard `-32002` request-already-pending error. The response must
preserve the original prompt, launch ID, message channel, iframe identity, and
per-launch budgets.

`ready`, `getLaunchInfo`, `getContext`, wallet, compose, and OAuth messages all pass through the
same broker. The host MUST re-check the current manifest identity,
capabilities, user state, disclosure state, OAuth state, and domain policy at
the moment of each privileged operation; handshake success is not a durable
authorization grant.

### Data-release boundary

After the app has sent valid `ready`, `getLaunchInfo` is answered entirely
inside the origin-pinned broker channel and never opens a host prompt. The
immutable, exactly shaped, bounded DTO contains only `version`, `launchUrl`,
`linkedUrl`, and `sourceNoteId`. The launch and linked URLs MUST be bounded
HTTPS URLs. `sourceNoteId` MUST be a bounded absolute HTTP(S) canonical ID of
the fully public original Note and MUST NOT contain credentials or a fragment.
The response contains no viewer, author, content,
mention, OAuth, wallet, session, or Announce data. It is not placed in the app
URL or query string.

Before the once-per-app enriched-context disclosure, `getContext` returns no
enriched note details. After disclosure it returns only the documented fields
from a fully public note, normalized into a bounded DTO. It MUST NOT serialize
database structs, internal metadata, recipient lists beyond public fields,
moderation state, viewer identity, IP address, session IDs, or inferred
relationships. OAuth is the only path to Egregoros user identity/API data.
Wallet account addresses are exposed only by the separately approved wallet
provider.

Closing an iframe clears ephemeral channel state. Revoking context permission,
OAuth, wallet permission, or operator policy takes effect immediately and
invalidates relevant server-side state; a stale iframe cannot continue using a
previous channel.

### OAuth and app-session security

OAuth-enabled apps MUST follow the authorization-code flow with transaction-
specific S256 PKCE, high-entropy `state`, exact registered HTTPS redirect URI,
authorization-server issuer validation, single-use short-lived codes, and no
implicit/password grants. Authorization and callback responses MUST use
`Cache-Control: no-store` and a restrictive `Referrer-Policy`; codes, state,
handoff values, access tokens, and refresh tokens MUST be redacted from logs,
error reporting, analytics, URLs shown to other origins, and browser history
where possible.

Dynamic registration may occur from a backend or static browser app. Egregoros
registers a mini app as a public client and never issues it a client secret.
Refresh/access tokens MUST never enter the host relay or host message channel.
They remain backend-only in `backend_handoff` mode and iframe-only after the
token response in `browser_code` mode.
Registration, authorization, token exchange, refresh, revocation, and every
bearer-token API request MUST re-check the current exact app origin, immutable
maximum scope set, requested subset, absolute authorization deadline, and
operator domain policy. Refresh tokens require rotation/replay detection or
equivalent family invalidation and MUST retain the original family deadline.
Revocation and a newly matching
deny rule invalidate the whole token family immediately.

The callback completion message uses the same exact-origin/source/channel
rules. A backend-mode handoff code is bound to the iframe's secret verifier,
single-use, non-loggable, and expires within 60 seconds. A browser-mode
authorization code is short-lived, single-use, and bound to the iframe's PKCE
verifier; Egregoros verifies its exact pending record before relaying it. OAuth consent is
not permission to compose through the host; conversely, a granted `write`
scope allows the app backend to use the documented API and must be presented to
the user as such.

### Compose boundary

`composeNote` requires a declared `compose_note` capability, active exact-origin
channel, signed-in host user, current domain-policy allowance, and a fresh
broker request. It does not require an OAuth grant. All draft fields are
untrusted and pass through the same length, URL, visibility, reply-target, and
content validation as user-entered composer data. The app can only open and
prefill the host-owned composer; it cannot trigger its submit event, manufacture
LiveView events, select a hidden visibility, attach files, or bypass normal
posting validation.

The final submit is a direct user action on Egregoros UI. The publication
receipt is generated only after the database transaction succeeds and contains
only the request ID, canonical ActivityPub ID/URL, and final visibility. The
app never receives draft edits, cancellation reason, failure internals, or a
promise of federation delivery.

### Wallet boundary

The iframe receives an EIP-1193 proxy object, never `window.ethereum`, a JAW
instance, private key, seed, passkey material, wallet cookie, API key, paymaster
credential, or unrestricted JSON-RPC transport. The host wallet adapter accepts
only the v1 RPC allowlist and applies strict method-specific schemas, supported-
chain checks, connected-account checks, payload/value/gas bounds, rate limits,
and user-gesture requirements. At minimum v1 MUST reject raw-key/export methods,
`eth_sign`, raw transaction submission, arbitrary chain addition, batch calls,
delegated/session permissions, and unknown RPC methods.

`eth_accounts` returns `[]` until that exact app origin has a remembered wallet
connection. Each signature or transaction is presented in host-owned UI with
the exact app domain, account, chain, destination, value, fees, and decoded
action when available. Simulation/scam screening is advisory defense-in-depth,
not a substitute for confirmation. The exact request bytes/semantic hash shown
to the user MUST be the request sent; any account, chain, payload, or policy
change between review and send cancels and requires a new confirmation.

The injected-wallet and future JAW implementations remain behind the same
adapter. JAW configuration and API keys are administrator-owned and never
accepted from a manifest. Wallet disconnect, OAuth revoke, app close, logout,
and domain deny rules cancel pending prompts and invalidate the applicable
connection state.

### Operator policy, availability, and observability

One central policy service MUST decide domain allow/deny status. Every fetch,
card render, iframe creation, broker message, OAuth registration/authorization/
token use, compose request, wallet request, and asset proxy request calls that
service. Deny wins, changes are immediate, and Egregoros also provides a global
mini-app kill switch that closes active frames and disables all mini-app
network, broker, OAuth-profile, compose, and wallet entry points.

Apply quotas per source IP, app origin, OAuth client, user, and instance, with
bounded queues and circuit breakers. Mini-app failures MUST never block
ActivityPub ingest, timeline rendering, login, normal OAuth clients, or the
composer. Background workers handling remote input are supervised and run with
the least filesystem/network privileges available.

Audit security decisions—registration, consent, revoke, policy changes,
blocked fetches, channel violations, compose receipts, and wallet approvals or
rejections—with app origin, user/account identifier as appropriate, action,
result, and correlation ID. Logs MUST exclude note content unless explicitly
needed, URL query secrets, OAuth credentials, handoff codes/verifiers, wallet
payload secrets, cookies, and private keys. Repeated origin/schema/rate
violations should terminate the channel and feed operator abuse controls.

The ActivityPub notification extension persists a narrower dedicated audit:
permission grant/deny/revoke and delivery accepted/suppressed, with only local
user ID, exact app origin, exact app actor, bounded reason code, and timestamp.
It deliberately has no columns for content, activity/note IDs, recipient actor
URLs, OAuth credentials, or key material. Activation validates and pins the
actor's exact RSA public-key PEM, key ID, and fingerprint; accepted modulus
sizes are 2048 through 8192 bits. Signature verification for a declared actor
uses only that pinned key and MUST NOT trigger an actor/key network fetch. A
different, missing, malformed, or not-yet-pinned key fails closed before
ordinary signature verification can authorize delivery.

For delivery replay suppression, the server stores only a secret-keyed HMAC of
the local user ID, exact app actor, and ActivityPub activity ID. The raw
activity ID is never retained in the mini-app audit. The fingerprint is unique
per user, so a replay is ignored before persistence or side effects. Consent,
OAuth revocation, authorization, persistence, and the accepted/suppressed audit
decision are serialized on the same per-user/app lock. Audit history is pruned
transactionally to at most 500 rows per user; an operator may configure a lower
limit but may not raise this security ceiling.

The purpose-label revision adds declared and effective purpose to that audit;
it does not add message content or identifiers.

### Required adversarial tests

Before release, automated tests MUST cover at least:

- private/loopback/link-local/IPv6/encoded-IP SSRF, DNS rebinding, redirect,
  cloud-metadata, decompression bomb, oversized HTML/JSON, duplicate JSON key,
  malformed Unicode, hostile SVG, slow-response, and fetch-flood cases;
- same-origin iframe rejection, top-navigation/popup/download attempts,
  framing-header failure, CSP and Permissions-Policy enforcement, host-overlay
  attempts, cross-origin iframe navigation, and browser cookie-blocking modes;
- spoofed `postMessage` origin/source, wildcard-origin regression, stale or
  replayed channel/request IDs, cross-app messages, unknown methods, oversized
  and prototype-polluting payloads, navigation during a request, logout/revoke/
  deny during a request, and message floods;
- OAuth redirect confusion, state/PKCE/issuer mismatch, code reuse, mix-up,
  scope/capability mutation, refresh replay, callback spoofing, handoff theft,
  registration floods, token use after revoke/deny, callback redirects blocked
  by self-only `form-action`, hostile callback values attempting to widen CSP,
  and secret-redaction tests;
- context access before disclosure, non-public-note context, viewer/internal
  field leakage, compose without OAuth/capability, synthetic submit attempts,
  invalid reply/visibility/URL, and receipt-before-commit cases; and
- wallet account access before connection, RPC allowlist bypass, chain/account
  substitution, transaction mutation after preview, signing without gesture,
  concurrent prompt races including a correlated busy response without iframe
  replacement, disconnect/deny during confirmation, provider object escape,
  and attempts to obtain injected/JAW secrets.

Security controls are release gates. Tests MUST assert outcomes and absence of
side effects, not merely that an error was rendered.

### Opt-in developer conformance workbench

Egregoros provides an authenticated, user-opt-in conformance workbench at
`/developer/mini-apps`. A user enables **Show developer tools in the sidebar**
under Settings → Account; only then is the **Developer** sidebar item shown.
The route rechecks the persisted preference on mount and before starting a
probe. Turning the preference off invalidates that user's existing diagnostic
launch immediately.

The user enters the exact shareable miniapp URL, not merely its origin or home
page. A server-side diagnostic then uses the production policy, fetcher,
parsers, and image sanitizer to check, as applicable:

1. canonical public HTTPS input and current instance allow/deny policy;
2. `/.well-known/fediverse-miniapp.json` retrieval, MIME type, strict manifest
   schema, immutable declarations, and exact-origin URLs;
3. the linked page, manifest home page, and resolved launch page, deduplicating
   identical `(resource kind, URL)` pairs;
4. optional manifest icon, splash image, and card image retrieval plus actual
   raster decode and normalization through the production sanitizer;
5. an optional declared ActivityPub actor response and actor/key document
   validation without activating or persisting the declaration; and
6. relevant HTTP hardening headers on every fetched resource.

For pages, the required header checks are an unambiguous
`X-Content-Type-Options: nosniff`, an enforced CSP `frame-ancestors` policy that
permits the exact calling Egregoros origin, and the absence of a conflicting
`X-Frame-Options`. `Referrer-Policy: no-referrer`, an explicit
`Permissions-Policy` denial of host-denied device capabilities, and a positive
HSTS `max-age` are reported as recommended hardening. Non-page resources are
required to use `nosniff`; HSTS is recommended. HTTP status, direct/safe
redirect behavior, TLS, DNS/IP safety, response size, content encoding,
header ambiguity, MIME type, and body bounds remain enforced by the production
fetcher rather than reimplemented by the workbench.

For a generally published app, `frame-ancestors https:` satisfies the framing
check for every canonical HTTPS compatible host; the workbench does not require
the current Egregoros domain to be compiled into the app. The current v1
server-side probe follows manifest and card declarations, not arbitrary HTML
dependency graphs. It therefore does not enumerate every `<script src>` or
stylesheet link. The real `ready()` handshake proves that the startup
JavaScript executed, while implementers must separately verify correct MIME,
`nosniff`, HSTS, CSP, and caching headers for scripts, styles, and other runtime
subresources. A future bounded exact-origin dependency probe may make those
checks explicit without weakening fetch limits.

Every attempted check is displayed as required or recommended and as passed or
failed. A failed prerequisite stops dependent requests, and the checklist says
so; the tool MUST NOT make speculative requests after it can no longer derive
their URLs safely. Recommended failures do not fail conformance. Full
conformance requires both all attempted required server checks and a browser
`ready()` check.

When a valid manifest and structurally safe card can be derived, the workbench
shows the shared rich-card component even if a later framing or hardening check
failed. Opening it uses the production sanitized image proxy, same-origin
broker, sandboxed remote iframe, exact-origin channel, launch ID, message
budgets, and readiness timeout. The result becomes conformant only after that
particular iframe calls SDK `ready()` for its current launch. Loading,
navigation, timeout, and retry reset or fail the readiness result rather than
reusing a stale success.

A diagnostic preview is deliberately not backed by a fabricated ActivityPub
Note. It receives this launch information:

```json
{
  "version": "1",
  "launchUrl": "https://miniapp.example/exact/path",
  "linkedUrl": "https://miniapp.example/exact/path",
  "sourceNoteId": "https://social.example/developer/mini-apps"
}
```

The `sourceNoteId` is a protocol-valid synthetic developer-page URL, not an
ActivityPub object ID and not evidence that a public Note exists. The card
disclosure says this explicitly. A miniapp MUST NOT award or verify sharing
from diagnostic launch information; reward logic must fetch and validate a
real public Note ID supplied by an ordinary public-note launch.

Diagnostic cards are non-persistent, kept in bounded server memory for at most
15 minutes, and limited to one current card per developer user. Broker and
asset routes require the exact authenticated owner and immutable resolution
token, recheck the current developer preference and domain policy, and recheck
authorization after an image fetch before returning bytes. A new probe replaces
the user's previous diagnostic card. The workbench permits at most five probe
starts per user per minute in addition to global fetch concurrency, size,
timeout, and network limits.

The server sends no user cookies, OAuth tokens, authorization headers, client
certificates, identity, or private note context to probed resources. Requests
are bounded credential-free `GET`s. Remote strings are rendered only through
normal HTML escaping, and images are never reflected without sanitization.
Because any server-side probe reveals the instance's network address and
request timing to the remote host, the feature remains explicitly opt-in. It is
a development aid, not a third-party trust certification or a substitute for
the adversarial tests above.

### Normative security references

- [OAuth 2.0 Security Best Current Practice (RFC 9700)](https://www.rfc-editor.org/info/rfc9700/)
- [OAuth Authorization Server Metadata (RFC 8414)](https://www.rfc-editor.org/info/rfc8414/)
- [OAuth Dynamic Client Registration (RFC 7591)](https://www.rfc-editor.org/info/rfc7591/)
- [WHATWG HTML iframe sandbox](https://html.spec.whatwg.org/multipage/iframe-embed-object.html)
- [W3C Content Security Policy Level 3](https://www.w3.org/TR/CSP/)
- [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [EIP-1193 Ethereum Provider API](https://eips.ethereum.org/EIPS/eip-1193)

## Public launch information and enriched-context disclosure

OAuth consent answers: “May this app access Egregoros APIs with these scopes?”
The mini-app card separately tells the user: “Opening shares this public post's
Fediverse ID and exact app link with this app domain; it does not share your
identity.” That explicit launch action releases the narrow `getLaunchInfo()`
DTO without a second dialog. An app can use this data without ever asking for
OAuth.

The separate enriched-context disclosure asks whether the app may additionally
receive the public Note's text, author, and public mentions through
`getContext()`. Both DTOs are untrusted application input. The public ID and
link let an app independently fetch a Note and decide whether it qualifies for
a share reward, but the protocol makes no anti-abuse or reward-validity claim.

The enriched-context consent choices are:

| Timing | User experience | Privacy trade-off |
| --- | --- | --- |
| Once per app | The first `getContext()` request says that this domain will receive public-note text, author, and mentions; later requests proceed without repeating it. | Clear, low friction; selected baseline. |
| Once per note | The user sees the same disclosure each time a different note launches the app. | Maximum reminder, but repetitive for normal use. |
| Only in OAuth consent | No separate message; data sharing is mentioned only if/when the app asks for OAuth. | Inadequate for apps that never request OAuth; not recommended. |

## Deferred from v1 unless explicitly selected

- app directory/search and user-installed/pinned apps;
- promotional-purpose ActivityPub messages, webhooks, and browser-push
  notification mechanisms (the transactional-mention extension is optional V1);
- payments, non-EVM wallets, EIP-5792 batching, and device permissions;
- host-side profile-navigation actions beyond `openExternal`;
- cross-instance app reputation/discovery federation; and
- mobile-native presentation.

## Decisions log

| Topic | Decision | Rationale |
| --- | --- | --- |
| Protocol relationship | Fediverse-native; inspired by Farcaster, not compatible | OAuth and ActivityPub provide different primitives. |
| Identity transport | OAuth authorization code + PKCE | Backend mode keeps bearer tokens server-side; browser mode delivers only the PKCE-bound code before the iframe exchanges it. |
| Initial presentation | Desktop lower-right collapsible iframe | Required target behavior. |
| Discovery | Rich card when a note includes a valid mini-app URL | The app must still be explicitly opened by the viewer. |
| OAuth scopes | Existing scopes may be requested | Supports applications beyond Farcaster's identity-only model. |
| Publishing | Anybody may publish a manifest-bearing HTTPS mini app | No directory/admin approval is required to publish. |
| Platforms | Desktop and mobile/PWA | Desktop floating panel; mobile full-screen sheet. |
| App installation | Not in v1 | No saved/pinned-app launcher; optional ActivityPub transactional mentions do not install an app. |
| Registration | Anonymous dynamic registration | One public registration per mini-app manifest and calling issuer, cached by the app backend or browser. |
| Public launch information | `getLaunchInfo()` after explicit card open, without a second prompt | Exact launch URL, linked URL, and original public Note ID only; no viewer identity or Announce attribution. |
| Enriched context | `getContext()` after once-per-app disclosure | Untrusted public-note text, author, and mentions are shared with the app domain. |
| Context source visibility | Fully public notes only | Non-public notes retain ordinary links in v1. |
| OAuth callback origin | Exact manifest origin | Prevents callback widening to sibling/subdomains. |
| Card model | Required domain manifest + optional page metadata | Exact-page cards when available; generic app card otherwise. |
| Scope changes | Forbidden in v1 | A changed permission set requires a new app identity/domain. |
| Compose action | Required, prefill-only | The app opens an editable host draft; only the user can submit it. |
| Compose receipt | Public post URL after successful submission | Correlated to the request; lets the app independently verify public publication. |
| Protocol names | `fediverse-miniapp` | Uses `/.well-known/fediverse-miniapp.json` and `fediverse:miniapp` metadata. |
| Concurrent apps | One active app | A new launch replaces the existing panel/sheet. |
| Generic-card launch URL | Exact linked URL | Preserves deep links; missing page metadata does not silently fall back home. |
| In-app navigation | Any exact-origin path | Cross-origin destinations are opened externally only after a user gesture. |
| Collapse behavior | Retain live iframe | Navigation around Egregoros does not reset the active app session. |
| Launcher | None in v1 | Apps open from an explicit card action on a fully public Note; the opt-in developer workbench is diagnostic only. |
| Card activation | Explicit **Open** button only | Incidental image/title clicks do not launch remote code. |
| Mobile surface | Full-height safe-area-aware sheet | Provides clear close/back control rather than desktop floating UI. |
| External navigation | SDK gesture assertion + host confirmation | The exact destination origin is shown before any top-level context opens. |
| Iframe permissions | Deny by default | Device/browser privileges require future capability-specific design. |
| Framing failure | Explicit error + external-open action | Never silently navigates the Egregoros surface away. |
| Federated cards | Supported for public incoming notes | Resolution failure leaves the source link intact. |
| Card assets | Proxied, sanitized, and boundedly cached | Protects viewer IP privacy while preventing repeated cards from multiplying remote fetch and decoder work. |
| Metadata refresh | One-hour default; shorter explicit TTL honored | User can manually refresh app details. |
| Pre-auth SDK data | Bootstrap plus public `getLaunchInfo()` attribution | Enables dynamic registration and organic-share discovery without exposing viewer identity; enriched context remains permissioned. |
| Authentication trigger | App calls `requestAuth` | No automatic prompt merely from card display or launch. |
| Authentication requirement | On demand | OAuth is required only for OAuth-gated capabilities, not for public/read-only apps or host-confirmed compose. |
| OAuth callback completion | Opener-free popup redirects to a host-owned fragment relay and launch-secret `BroadcastChannel` | Backend mode relays a verifier-bound app handoff; browser mode relays only the exact PKCE-bound authorization code. Bearer tokens never traverse the relay. |
| Repeat consent | Reuse valid immutable grant | Authorization UI still provides account identity, switch, and cancel. |
| Token renewal | Short-lived access + rotating refresh token | Backend or browser refreshes without extending the absolute grant deadline. |
| Iframe session establishment | Backend handoff or browser code exchange | Both work when third-party cookies/storage are unavailable. |
| `ready()` timeout | Keep branded loading UI | Retry and external-open are offered; app is not auto-closed. |
| EVM wallet declaration | Immutable `wallet.evm.enabled` manifest capability | Provider is available only when host/user support it. |
| EVM app interface | Host-mediated EIP-1193 provider | Private keys never enter the iframe and wallet access stays separate from OAuth tokens. |
| Wallet availability | Optional by default | `required: true` fails with a compatible-wallet error; otherwise app falls back. |
| Initial wallet methods | Discovery/connect, message/typed signing, one transaction | Batch/delegation/headless wallet operations wait. |
| Wallet implementation seam | Host `EvmWalletAdapter` | Injected wallet now; admin-configured JAW adapter later. |
| Wallet account exposure | Per app after gesture-based connection | `eth_accounts` is empty before approval. |
| Wallet revocation | Separate from OAuth disconnect | User can remove account access without removing API authorization. |
| Wallet UX | One connection sheet, one compact approval per sign/transaction | No repeated picker or redundant connection confirmation. |
| Cards per note | One, first valid URL in source order | Limits remote fetches and visual clutter. |
| Publisher metadata | Optional, informational | Hosting domain remains the only built-in trust signal. |
| Page metadata authority | Presentation/launch only | It cannot change app identity, OAuth, scopes, or capabilities. |
| Visual asset origins | Exact app origin | Prevents third-party CDN identity ambiguity; assets are proxied. |
| Baseline OAuth scope | `identify` required when OAuth is declared | Links the app to a minimal five-field Fediverse identity without authenticated post/timeline access. Legacy broad `read` grants imply `identify`. |
| Scope request | Non-empty subset of an immutable manifest maximum | Every request retains `identify`; step-up grants cannot introduce undeclared scopes. |
| Authorization lifetime | Per-scope immutable manifest maximum, then app/server/user minimum | Access tokens last at most one hour; refresh rotation never extends the absolute grant deadline. |
| Host capabilities | Immutable manifest declaration | Consent visibly covers non-base actions such as `compose_note`. |
| Context disclosure | Once per app, independent of OAuth | Required before public note context is sent; may be combined with OAuth consent. |
| App public messages | Ordinary app-owned ActivityPub actor | Followers receive standard public `Create(Note)` activities. |
| Transactional messages | Optional V1 `notifications.activitypub` extension | One non-public recipient and matching mention; sender and receiver both enforce consent. |
| Notification permission | Separate from launch context and OAuth | Dedicated host UI/API avoids leaking user authority through public launch context. |
| `write` scope | Separate second confirmation | Makes high-impact API authority unmistakable. |
| User revocation | Settings disconnect revokes grants/tokens/context approval | A later launch must gain fresh approval. |
| Instance domain policy | Operator allow/deny patterns | Gate applies to every mini-app lifecycle stage. |
| Domain-policy syntax | Exact host + `*.` DNS suffix wildcard | Predictable matching; no arbitrary regex. |
| Domain-policy precedence | Deny wins; non-empty allowlist is restrictive | Operators can enforce a trusted-domain set. |
| Policy updates | Immediate | Existing iframe/token access is blocked and iframe closed. |

## Delivery plan and acceptance criteria

1. **Protocol and data model.** Define manifest/card schemas, validation,
   stable app identity, app-policy records, user context-consent records, and
   derived card/manifest cache records outside `Object.data`.
2. **Safe discovery.** Implement asynchronous public-note URL extraction,
   operator policy checks, SSRF-safe well-known/page fetches, exact-origin
   validation, one-card selection, proxied non-persistent assets, and graceful
   ordinary-link fallback.
3. **OAuth profile.** Publish authorization-server metadata plus the
   mini-app dynamic-registration profile; enforce one app–issuer registration
   for OAuth-enabled apps, immutable `identify`-inclusive scopes/capabilities,
   exact callbacks, grants, write confirmation, token refresh/revocation, and
   instance policy on token use.
4. **Host UI and SDK.** Deliver desktop floating panel and mobile full-height
   sheet, splash/`ready`, nonce/origin handshake, bootstrap/auth/session-handoff
   flow, context disclosure, same-origin navigation, and capability-gated host
   actions.
5. **Composition, wallet, and controls.** Implement prefill-only `composeNote`,
   correlated minimal receipts, the injected-wallet adapter/EIP-1193 bridge,
   per-app wallet confirmations, user disconnect controls, operator policy
   configuration,
   explicit external-navigation confirmation, and framing-error UX. Keep the
   JAW adapter behind the same interface and out of this implementation phase.
6. **Hardening and interoperability.** Automate the complete trusted
   broker↔SDK channel against the deployable reference mini app. Before each
   production release, run the documented desktop and installed PWA/mobile
   browser matrix, including cookie-blocking modes, OAuth and `postMessage`
   failure paths, public federation cards, scope revocation, domain-policy
   changes, and checks that derived state never enters ActivityPub objects.

The feature is ready for release only when tests demonstrate that an
untrusted app cannot obtain user identity or OAuth-gated actions without OAuth,
cannot obtain note context before the separate context disclosure, cannot
increase scopes or capabilities, redeem a host-visible handoff code without the
iframe verifier, navigate Egregoros, escape exact-origin restrictions, bypass
instance policy, or cause a note to be submitted without the user's normal
composer action.
Wallet tests must additionally prove that an iframe cannot obtain an account
without per-app connection approval, sign/send without a fresh user gesture and
host confirmation, access a non-allowlisted RPC method, or receive a private
key or host OAuth token.

## V1 design status

All currently identified v1 product and protocol decisions have been resolved.
Future work should treat wallet delegation, transaction batching, other wallet
types, promotional-purpose/provenance ActivityPub vocabulary, device
permissions, an app directory, and non-public note launches as new design
efforts rather than implicit extensions. The narrowly specified transactional-
mention receiver remains an optional V1 extension.

The first-party SDK source and declarations live in the standalone
[`fediverse-miniapp-sdk`](https://github.com/shipoclu/fediverse-miniapp-sdk)
repository as raw ES modules with no runtime dependencies or build step.
Egregoros pins an exact Git commit through `assets/package-lock.json`; its thin
asset entrypoint bundles that package and publishes matching
`fediverse-miniapp-sdk-v1.{js,d.ts}` artifacts. A deployable public/read-only
example with optional wallet support lives at `examples/fediverse-miniapp/`;
its manifest is parsed by the Elixir suite and its SDK transport is exercised
through the same-origin broker, nested sandbox, and transferred ports by the
asset interoperability suite. A separate static React example exercises the
`browser_code` OAuth completion profile without an app backend.

## Domain paths and cards

## V1 wire format

The following is the strict JSON shape. V1 rejects unknown fields,
duplicate keys, and ambiguous encodings rather than allowing different host
implementations to interpret the same manifest differently. Additions require a
documented protocol revision. Fields that influence identity, OAuth, scopes,
wallet declarations, or capabilities remain immutable for a registered app
identity.

### Domain manifest

Published as `https://{app-origin}/.well-known/fediverse-miniapp.json`:

```json
{
  "version": "1",
  "name": "Budget Polls",
  "publisher": {"name": "Example Studio", "url": "https://app.example/about"},
  "homeUrl": "https://app.example/",
  "iconUrl": "https://app.example/icon.png",
  "splash": {
    "imageUrl": "https://app.example/splash.png",
    "backgroundColor": "#152238"
  },
  "oauth": {
    "redirectUris": ["https://app.example/oauth/callback"],
    "scopes": ["identify", "write"],
    "scopeAuthorizationMaxAgeSeconds": {
      "identify": 31536000,
      "write": 86400
    }
  },
  "wallet": {
    "evm": {
      "enabled": true,
      "required": false,
      "requiredChains": ["eip155:8453"]
    }
  },
  "activityPub": {
    "actorUrl": "https://app.example/ap/actor",
    "publicNotes": true,
    "transactionalMentions": true
  },
  "capabilities": ["compose_note"],
  "cacheTtlSeconds": 3600
}
```

This example is the currently implemented manifest shape. The next
provenance/purpose revision replaces `transactionalMentions` with immutable
`mentionPurposes`; `transactionalMentions: true` maps only to
`["transactional"]` and never grants promotional messaging.

Required fields are `version`, `name`, `homeUrl`, and `capabilities`. The
`oauth` object is optional; when present, `oauth.redirectUris` and
`oauth.scopes` are required. `homeUrl` and every OAuth redirect URI must use
the manifest's exact HTTPS origin. An OAuth-enabled manifest's `oauth.scopes`
must include `identify`. Broad `read` is separate, optional authority and is
not needed merely to link a Fediverse account. Its `scopes` and all manifests'
`capabilities` arrays are
de-duplicated, bounded, and immutable after first registration/observation. The
optional `scopeAuthorizationMaxAgeSeconds` object is also immutable; every key
must name a declared scope and every value must be 300 through 31,536,000
seconds. Authorization requests may choose subsets and shorter durations but
cannot exceed those declarations. The
`wallet` and `activityPub` objects are optional and immutable when present. An
ActivityPub actor URL must use the exact origin, have a non-root path, and have
no query or fragment. At least one publishing mode must be enabled;
`transactionalMentions` additionally requires OAuth. The current one-hour cache
default applies when `cacheTtlSeconds` is absent; an explicit shorter TTL is
honored.

The machine-readable JSON Schema mirror is
[`docs/schemas/fediverse-miniapp-manifest-v1.schema.json`](docs/schemas/fediverse-miniapp-manifest-v1.schema.json).
It is useful for tooling but is not an additional source of normative rules.
It cannot express equality with the origin from which it was fetched, duplicate
key rejection, or the complete origin policy, so implementations use the
clean-room contract below as the authority.

### Page card metadata

A shareable app page may include one HTML element:

```html
<meta name="fediverse:miniapp" content='{
  "version":"1",
  "title":"Vote: 2026 budget",
  "imageUrl":"https://app.example/cards/budget-2026.png",
  "buttonTitle":"Vote",
  "launchUrl":"https://app.example/polls/2026-budget"
}'>
```

The host validates the JSON and all URLs, proxies images, and treats invalid
metadata as absent. `launchUrl` must be on the exact app origin. Without this
tag, a valid linked URL on the app origin gets the generic manifest card and
launches the exact linked URL.

There are two useful levels of mini-app metadata:

| Level | Example | Purpose | Trade-off |
| --- | --- | --- | --- |
| Domain manifest | `https://polls.example/.well-known/fediverse-miniapp.json` | Establishes that `polls.example` is an app; declares stable name/icon, canonical start URL, OAuth/SDK configuration, and origin boundary. | One generic card for every URL if used alone. |
| Page/card metadata | `https://polls.example/polls/2026-budget` | Makes this particular URL launch a particular in-app view and gives it a title, image, and button label. | The app developer must emit metadata for each shareable page. |

For example, a domain may host both `/new` and `/polls/2026-budget`:

- With only a domain manifest, links to both render as “Polls — Open app” and
  open their exact linked paths. This preserves deep links and makes missing
  page metadata visible instead of silently redirecting to `homeUrl`.
- With page/card metadata, `/polls/2026-budget` can render “Vote: 2026 budget”
  with its own preview image, and **Open** starts the iframe at that exact URL.
  This is the Farcaster-style rich-link experience and enables individual
  polls, games, auctions, documents, and profiles to spread through notes.

Recommended v1: require the domain manifest, allow an optional
mini-app-specific JSON `<meta>` tag on any linked page, and fall back to the
generic manifest card when page metadata is absent. The card payload must be
strictly schema-validated and its launch URL must remain inside the manifest's
permitted origin/path boundary. Page metadata may override only card title,
image, button label, and launch URL; it cannot override the domain app name,
icon, publisher metadata, OAuth client registration, scopes, or host
capabilities.

## Clean-room V1 implementation contract

This section turns the design above into a finite implementation target. A
coding agent should implement this section first, then use the earlier sections
for rationale and UI guidance. “Character” means a Unicode scalar value;
“byte” means a UTF-8 byte. All size limits apply before interpretation.

### 1. Common parsers and origin model

Every security-sensitive JSON parser MUST reject invalid UTF-8, duplicate
member names at any nesting level, a nesting depth greater than 16, and input
that is not one complete JSON value. Objects in this protocol are closed:
members not listed in the applicable table are invalid. A host MUST NOT use a
parser mode in which the last duplicate member silently wins.

Every protocol URL is at most 2,048 UTF-8 bytes. Parse URLs with one consistent
standards-conforming URL implementation, then apply all of these rules:

1. Require `https`, except that a public ActivityPub Note ID supplied as
   `sourceNoteId` may use `http` for federation compatibility.
2. Require a hostname and reject user names, passwords, malformed ports, and
   IP literals. The effective port is the explicit port or 443 for HTTPS.
3. Convert an international hostname to its ASCII/Punycode form, lowercase it,
   and remove exactly one terminal dot before policy comparison. Reject a DNS
   name longer than 253 bytes, fewer than two labels, an empty label, or a
   label that is longer than 63 bytes or does not match
   `[a-z0-9](?:[a-z0-9-]*[a-z0-9])?`.
4. Reject WHATWG IPv4-number candidates, including a final decimal-only label
   or a `0x` hexadecimal form, even if the URL library would reinterpret it.
5. Reject raw C0 controls, space, backslash, DEL, invalid percent escapes, and
   any percent escape that decodes to a control, backslash, or DEL.
6. Require an empty path or a path beginning `/`. A manifest-declared URL MUST
   have no fragment. Rules below say explicitly when a query is forbidden.

An **origin** is the tuple `(scheme, normalized ASCII hostname, effective
port)`. “Exact origin” always means equality of all three values; it never
means a suffix, registrable-domain, textual-prefix, wildcard, or redirect
match. Serialize default HTTPS port 443 without `:443`.

Before any outbound connection, resolve the hostname and require **every** A
and AAAA answer to be globally routable. Reject loopback, private, link-local,
multicast, unspecified, documentation, benchmark, carrier-grade NAT, reserved,
and IPv4-mapped non-global IPv6 addresses. Pin the accepted address set to the
connection while retaining the original hostname for TLS SNI and certificate
verification. Re-resolve and repeat the complete check for every later fetch;
never trust a prior browser fetch or cache entry as an SSRF decision.

### 2. Domain manifest

For any candidate app URL, derive its origin and fetch exactly:

`https://<candidate-origin>/.well-known/fediverse-miniapp.json`

The well-known URL has no query or fragment. The response body is at most
65,536 bytes and is strict JSON as defined above. The top-level object permits
only these members:

| Member | Required | Exact V1 rule |
| --- | --- | --- |
| `version` | yes | String exactly `"1"`. |
| `name` | yes | 1–64 characters, valid UTF-8, no leading or trailing whitespace. |
| `publisher` | no | Closed object described below. Informational only. |
| `homeUrl` | yes | URL on the exact manifest origin. |
| `iconUrl` | no | URL on the exact manifest origin. |
| `splash` | no | Closed object described below. |
| `oauth` | no | Closed object described below. |
| `wallet` | no | Closed object described below. |
| `activityPub` | no | Optional V1 notification extension described below. |
| `capabilities` | yes | Unique array of 0–16 core capability strings. V1 permits only `compose_note`. |
| `cacheTtlSeconds` | no | Integer 60–3,600; default 3,600. |

`publisher` has exactly required `name` and `url` members. Its name is 1–100
trimmed characters and its URL is exact-origin. It is never an identity proof.

`splash` has exactly required `imageUrl` and `backgroundColor` members. The
image is exact-origin. The color matches `^#[0-9A-Fa-f]{6}$`; hosts may
normalize it to lowercase after validation.

`oauth` has these members and no others:

| Member | Required | Exact V1 rule |
| --- | --- | --- |
| `redirectUris` | yes | 1–8 unique exact-origin HTTPS URLs. |
| `scopes` | yes | 1–32 unique strings, each 1–64 UTF-8 bytes and matching `^[a-z][a-z0-9:_-]*$`. New manifests include `identify`. |
| `scopeAuthorizationMaxAgeSeconds` | no | Closed object whose keys are declared scopes and values are integers 300–31,536,000. It contains no more entries than `scopes`. |

`identify` is the V1 narrow identity baseline. It is independently requestable
and does not grant a broad read API. For compatibility with older
Mastodon/Pleroma-style scope hierarchies, a token containing `read` also
satisfies the narrow identity check; `write` does not. A host MAY continue to
register a legacy manifest whose scope list contains `read` but not `identify`,
but every conforming new app declares and normally requests `identify`
explicitly.
`compose_note` does not require an `oauth` object or any OAuth scope. Compose
opens host UI and the signed-in host user submits; it is not delegated API
publishing. An app declares OAuth only when it separately needs identity,
transactional mentions, or Mastodon-compatible API access.

`wallet` contains exactly required member `evm`. `evm` contains required
boolean `enabled`, optional boolean `required` (default `false`), and optional
`requiredChains` (default `[]`). Chains are a unique array of at most 16
strings, each at most 64 bytes and matching `^eip155:[1-9][0-9]*$`. If
`enabled` is false, `required` MUST be false and `requiredChains` MUST be empty.
A host that does not advertise `wallet.evm` may still show and launch an app
whose wallet is optional; it MUST refuse an app whose wallet is required or
whose required chain cannot be satisfied.

`activityPub` is the optional, current V1 notification extension. It contains
exactly required `actorUrl`, `publicNotes`, and `transactionalMentions` members.
The latter two are booleans and at least one is true. `actorUrl` is an
exact-origin HTTPS URL with a non-root path and no query or fragment.
`transactionalMentions: true` requires `oauth`. It does not authorize
promotional messages, delegated posting as the user, `mentionPurposes`, or
`app_activities`; those are outside core V1. A core host MAY reject this object
as an unsupported optional extension while continuing to support apps that do
not declare it.

The app origin is the app identity. On first successful registration or
observation the host stores a cryptographic fingerprint over the canonical
manifest identity declarations: origin, OAuth redirect URIs/scopes/scope age
ceilings, capabilities, wallet declaration, and ActivityPub declaration.
Changing any of those fields is an identity change and MUST fail closed until
the prior registration is administratively removed or a future migration
protocol authorizes the change. Display `name`, `publisher`, `homeUrl`, icon,
splash, and cache TTL may refresh after validation but never widen authority.

The JSON Schema in this repository is a convenience and test artifact. The
rules in this section are the complete normative schema, including constraints
that ordinary JSON Schema cannot express, such as equality with the fetched
origin and duplicate-key rejection.

### 3. Public-note discovery and page cards

V1 discovery runs only for an ActivityStreams `Note` that is fully public: its
`to` array contains `https://www.w3.org/ns/activitystreams#Public`. Do not
discover from followers-only, direct, local-only, or merely unlisted notes.
The discovery result is derived local state and MUST NOT be inserted into the
canonical ActivityPub object.

Accept at most 100,000 UTF-8 bytes of Note HTML. Parse it as HTML, not with a
single regular expression. In source order, collect at most ten URL candidates:

1. Take `href` values from anchors except anchors whose class-token list
   contains `mention`, `mention-link`, or `hashtag`.
2. Ignore text inside `script`, `style`, `template`, `noscript`, `iframe`,
   `object`, and `embed`.
3. From text not already inside an anchor, recognize strings beginning
   `https://` through the first whitespace or `<`, `>`, `"`, or `'` character.
   Repeatedly trim terminal `. , ! ? ; : ) ] }` characters.
4. Preserve the exact candidate string, reject it if it fails the common URL
   rules, and de-duplicate exact strings while preserving first occurrence.

Try candidates in that order. For each candidate, fetch and validate its
origin manifest and linked HTML page. The first valid app produces exactly one
card; later candidates remain ordinary links. Failure is isolated: retain the
ordinary link and do not fail ActivityPub ingestion or timeline rendering.

The linked page body is at most 1,000,000 UTF-8 bytes. Parse HTML and inspect
`meta` elements whose `name` value is `fediverse:miniapp` under normal HTML DOM
attribute matching. More than one matching element is invalid. Zero means use
the generic card. Exactly one requires a non-empty `content` value of at most
32,768 UTF-8 bytes containing a strict closed JSON object with exactly:

| Member | Rule |
| --- | --- |
| `version` | String exactly `"1"`. |
| `title` | 1–80 trimmed characters. |
| `imageUrl` | Exact-app-origin HTTPS URL. |
| `buttonTitle` | 1–32 trimmed characters. |
| `launchUrl` | Exact-app-origin HTTPS URL. |

Invalid or duplicate page metadata has no authority and MUST be treated as
absent for presentation: the host uses a generic manifest card and launches
the **exact linked URL**, including its path and query, rather than `homeUrl`.
Valid page metadata may change only the title, preview image, button label, and
launch URL. It cannot change app identity, OAuth, scopes, or capabilities.

Every card visibly shows the verified app hostname and uses an explicit Open
button. It states that opening discloses the public Note ID and exact linked
URL to that app origin, but not the viewer's identity. Opening records:

- `launchUrl`: valid metadata `launchUrl`, otherwise the exact linked URL;
- `linkedUrl`: always the exact link found in the Note; and
- `sourceNoteId`: the original public Note's canonical ActivityPub `id`, not an
  Announce/boost ID.

The card image and manifest image assets are fetched through a host image
proxy. Accept at most 5,000,000 bytes, permit only AVIF, WebP, PNG, and JPEG,
decode as a raster image, enforce dimension/pixel ceilings, and re-encode to a
safe raster response. Never reflect SVG, HTML, remote headers, cookies, or
active content. Cache only successfully sanitized output under bounded entry,
byte, and time limits; never cache the untrusted source response or failures.
The cache key binds the image URL and card resolution token, identical
concurrent misses are coalesced, and authorization plus current domain policy
are checked before each host-cache response. Successful responses use bounded
private browser caching; failures remain `no-store`.

### 4. Bounded outbound HTTP contract

Manifest, page, actor, and image requests are credential-free `GET` requests.
Send no user cookies, authorization header, client certificate, referrer,
OAuth value, or private Note data. Send `Accept-Encoding: identity`; reject a
response whose `Content-Encoding` is present and not `identity`.

Use these `Accept` values:

| Resource | `Accept` | Maximum body |
| --- | --- | --- |
| manifest | `application/json` | 65,536 bytes |
| page | `text/html` | 1,000,000 bytes |
| image | `image/avif,image/webp,image/png,image/jpeg` | 5,000,000 bytes |
| optional ActivityPub actor | `application/activity+json,application/ld+json,application/json` | 65,536 bytes |

Allow at most two redirects. Resolve a relative `Location` against the current
URL, then require the result to retain the exact original origin and pass all
URL, DNS, policy, and TLS checks again. A redirect has exactly one `Location`
of at most 2,048 bytes and a body no larger than 8,192 bytes. Only status 200 is
a final success.

Bound a response to 64 header fields, 32,768 aggregate header bytes, and 8,192
bytes per field line. A final response has exactly one parseable
`Content-Type`; parameters are allowed but the normalized media type must match
the table. If `Content-Length` exists, require exactly one non-negative decimal
value no larger than the resource maximum and require the received byte count
to equal it. Reject a response containing both `Content-Length` and
`Transfer-Encoding`. Abort while streaming as soon as the maximum is crossed.
Use ceilings of 2 seconds to connect, 3 seconds without receive progress, and
8 seconds total per fetch.

Required app responses include exactly one effective
`X-Content-Type-Options: nosniff`. HTML pages need an enforced CSP
`frame-ancestors` policy that permits the exact calling host and no conflicting
`X-Frame-Options`. A generally published app SHOULD send
`Content-Security-Policy: frame-ancestors https:` so it works from arbitrary
compatible HTTPS hosts. It SHOULD also send `Referrer-Policy: no-referrer`, a
positive HSTS `max-age`, and a `Permissions-Policy` denying camera, microphone,
geolocation, payment, USB, serial, Bluetooth, HID, MIDI, and display capture.
These headers belong on the app's responses and may be emitted by the app
server; a reverse proxy MUST NOT duplicate or weaken them.

### 5. OAuth issuer profile and HTTP APIs

The host's issuer is its canonical HTTPS origin. It serves RFC 8414 JSON at the
fixed URL `<issuer>/.well-known/oauth-authorization-server`. In addition to
standard validation, a V1 app requires these values:

```json
{
  "issuer": "https://social.example",
  "authorization_endpoint": "https://social.example/oauth/authorize",
  "token_endpoint": "https://social.example/oauth/token",
  "revocation_endpoint": "https://social.example/oauth/revoke",
  "registration_endpoint": "https://social.example/oauth/mini-app/register",
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"],
  "token_endpoint_auth_methods_supported": ["none"],
  "scopes_supported": ["identify"],
  "fediverse_miniapp_profile": "1"
}
```

Endpoint paths other than the fixed metadata, relay, and identity paths may
differ when advertised. Every advertised endpoint is an absolute HTTPS URL on
the exact issuer origin. Arrays may include additional supported standard
values, but they MUST include the values shown; only `identify` is a mandatory
portable scope, and `none` is required for public mini-app clients. Metadata
and all custom OAuth responses use
`Cache-Control: no-store`, `Pragma: no-cache`, and
`Referrer-Policy: no-referrer`.

Dynamic registration sends `POST` with `Content-Type: application/json` to the
advertised registration endpoint and the closed body:

```json
{"manifest_url":"https://app.example/.well-known/fediverse-miniapp.json"}
```

The URL must be that app origin's canonical well-known URL. The host fetches it
itself and creates a public client once per `(issuer, canonical manifest URL)`.
An identical retry returns the same `client_id`; it MUST NOT create one client
per user or browser. First creation returns 201 and reuse returns 200 with:

```json
{
  "client_id": "opaque-public-client-id",
  "client_name": "Budget Polls",
  "client_uri": "https://app.example/",
  "redirect_uris": ["https://app.example/oauth/callback"],
  "scope": "identify write",
  "scope_authorization_max_age_seconds": {"identify":31536000,"write":86400},
  "grant_types": ["authorization_code", "refresh_token"],
  "response_types": ["code"],
  "token_endpoint_auth_method": "none"
}
```

No response contains `client_secret`. Closed error bodies have
`{"error":"code","error_description":"human-readable text"}`. Use 422
`invalid_request`, `invalid_manifest_url`, `oauth_not_declared`, or
`invalid_manifest`; 409 `manifest_changed`; 403 `disabled` or
`domain_denied`; and 429 for a registration-rate limit. An implementation may
vary descriptions but not codes or their meaning.

Authorization uses code + mandatory S256 PKCE, exact redirect matching,
single-use short-lived codes, and public-client token exchange. Do not support
implicit, resource-owner-password, or client-credentials grants for a mini-app
registration. An authorization request contains standard `response_type=code`,
`client_id`, `redirect_uri`, space-separated `scope`, `state`,
`code_challenge`, and `code_challenge_method=S256`, plus optional
`authorization_lifetime_seconds`. State is 43–256 base64url characters without
padding. The challenge is exactly 43 such characters. Requested scopes are a
non-empty subset of the immutable registered scopes and include `identify`.
The optional lifetime is an integer from 300 to 31,536,000 seconds and cannot
exceed any declared per-scope maximum. Omitting it uses the shortest applicable
server/manifest ceiling.

The token and revocation endpoints MUST accept
`application/x-www-form-urlencoded` requests from a public client. A code
exchange contains exactly the standard security fields shown (in either form
order) and no client secret:

```text
grant_type=authorization_code
code=<single-use-code>
client_id=<profile-public-client-id>
redirect_uri=<exact-registered-uri>
code_verifier=<43..128-RFC7636-verifier>
```

A refresh request contains `grant_type=refresh_token`, the rotating
`refresh_token`, and `client_id`; an optional `scope` may only narrow the
existing grant and MUST include `identify`. It cannot add authority or extend
the deadline. Revocation contains `token`, `client_id`, and optional standard
`token_type_hint`; it returns 200 for a syntactically valid request whether the
token was current or already unknown, and revokes the whole mini-app grant
family when either of its tokens is identified. Mini-app requests omit
`client_secret` in all three operations. OAuth failures use the standard JSON
`error` and optional `error_description` values and the status behavior of RFC
6749/7009 without host stack traces.

Issue access tokens for no more than one hour. A refresh token belongs to one
grant family, rotates on use with replay detection (or equivalent family
invalidation), and never moves the family's absolute authorization deadline.
Token success responses include standard `access_token`, `token_type`,
`expires_in`, `refresh_token`, and `scope`, plus
`authorization_expires_in`, the remaining absolute grant lifetime in seconds.
Revocation, logout, app-origin denial, immutable-manifest mismatch, or deadline
expiry invalidates the applicable family immediately.

The fixed narrow identity API is `GET <issuer>/api/v1/mini-apps/identity` with
`Authorization: Bearer <access-token>`. It requires an allowed mini-app client
and the `identify` scope. Its closed success object is:

```json
{
  "id": "https://social.example/users/alice",
  "username": "alice",
  "acct": "alice@social.example",
  "display_name": "Alice",
  "url": "https://social.example/@alice"
}
```

`id` is the user's actual ActivityPub actor ID; `url` is the public profile
page and may differ. All five values are strings. Failure is 401
`{"error":"unauthorized"}`, 403 `{"error":"insufficient_scope"}`, or 403
`{"error":"not_mini_app"}`. The response is never cacheable.

Metadata, registration, token, revocation, identity, and any browser-used
extension API support non-credentialed CORS. Return an allowed exact app origin
or `*`, never require cookies, never set `Access-Control-Allow-Credentials`,
and answer preflight for the actual method and `content-type` and/or
`authorization` headers. Apply CORS to error responses too.

#### Native OAuth compatibility adapters

`identify` is the only portable OAuth permission every V1 host MUST implement.
It is a mini-app-profile scope even when the underlying server calls the nearest
native permission `profile`, `read`, `read:accounts`, `read:account`, or
something else. The host maps that native account proof to a profile-scoped
grant and the exact five-field identity API above. The mapping MUST NOT make an
`identify` token valid on broader native read endpoints. Thus the mini app does
not need to know which server software issued the token.

The profile is an adapter boundary, not a claim that an unmodified ActivityPub
server already conforms:

| Native family | Typical native difference | Required V1 adapter behavior |
| --- | --- | --- |
| Mastodon | Proprietary `POST /api/v1/apps`; current releases issue confidential clients and a secret, and scope granularity varies by version. | Add the manifest-driven public-client registration endpoint. Never expose or require a native client secret in a mini app. Map `identify` to the least identity authority and issue a profile-conforming public-client grant. |
| Pleroma/Akkoma-style | Mastodon-compatible app registration commonly returns a client secret and uses its own scope/application records. | Add the same public-client facade, immutable manifest binding, PKCE enforcement, and narrow identity API while reusing native user consent internally. |
| Misskey | Modern releases use OAuth/IndieAuth client URLs and permissions such as `read:account`; older deployments may use MiAuth or legacy app secrets. | Present the V1 RFC 8414/public-registration facade and an opaque profile `client_id`; map `identify` to account identity only. MiAuth or a URL client ID may be an internal adapter detail but MUST NOT change the app-facing V1 messages. |

The mini-app-facing authorization, token, and registration endpoints may be a
thin layer over the server's native implementation or a separate restricted
OAuth client type. Either way, their observable behavior remains this profile:
public client, mandatory S256, exact redirects, profile scope records, bounded
grant lifetime, fixed identity DTO, and no client secret. A native provider
that has non-expiring tokens, no refresh rotation, confidential clients only,
or no PKCE cannot be exposed directly; the adapter must supply the stricter V1
behavior.

`oauth.scopes` is the app's immutable maximum set, not a claim that every host
supports every name. A host MUST advertise `identify` in `scopes_supported`.
It MAY advertise `read`, `write`, `follow`, `push`, granular native scopes, or
future portable scopes. Registration records and echoes the manifest maximum,
including names this issuer does not support, so a single manifest can target
several server families. At authorization time the requested subset must be
both manifest-declared and issuer-supported; otherwise return standard
`invalid_scope`. Apps inspect metadata and request only a supported subset,
always including `identify`.

Only `identify` and its fixed endpoint are cross-server API semantics in core
V1. `read` means access to the issuer's documented authenticated read APIs;
`write` means access to its documented write APIs and may include deletion;
their exact endpoint sets differ across software. Consent MUST describe the
actual local authority. A host MUST NOT guess mappings from similar names or
silently broaden an unknown scope. Portable delegated publishing with the
narrower `app_activities` authority is V2; V1 apps use `compose_note` when they
need portable user-reviewed posting.

The profile-facing `client_id` returned by registration is an opaque string of
10–200 base64url characters. A server whose native layer uses a URL client ID
or confidential-client row stores an internal alias from this public ID; it
does not put the native URL or secret on the browser MessagePort. This keeps the
V1 SDK identical across native OAuth families.

### 6. Host data transfer objects

Opening the explicit card makes this immutable, prompt-free object available
after `ready` through `getLaunchInfo`:

```json
{
  "version": "1",
  "launchUrl": "https://app.example/polls/2026-budget?view=full",
  "linkedUrl": "https://app.example/polls/2026-budget?ref=post",
  "sourceNoteId": "https://social.example/objects/123"
}
```

The object has exactly those four members. Both app URLs pass the common HTTPS
rules and may retain a fragment because they record exact browser launch/link
values. `sourceNoteId` is an absolute HTTP(S) URL without credentials or
fragment. This object contains no viewer identity, Note content, author,
mentions, recipients, moderation state, OAuth state, or Announce attribution.

`getContext` is a distinct, once-per-user-per-exact-app-origin permission. On
approval, and only for the same still-public source Note, return this closed
object:

```json
{
  "version": "1",
  "launchUrl": "https://app.example/polls/2026-budget?view=full",
  "sourceUrl": "https://app.example/polls/2026-budget?ref=post",
  "note": {
    "id": "https://social.example/objects/123",
    "url": "https://social.example/objects/123",
    "content": "Plain text, tags removed",
    "author": "https://remote.example/users/bob",
    "mentions": ["https://social.example/users/alice"]
  }
}
```

The outer and `note` objects are closed. `content` is HTML-stripped, trimmed,
and at most 5,000 characters. `mentions` contains at most 32 unique non-empty
ActivityStreams Mention `href`/`id` strings, each at most 2,048 bytes. `id` is
the original Note's canonical ActivityPub ID; V1 sets `url` to that same value.
`sourceUrl` is the exact `linkedUrl`. OAuth is not required for either public
DTO. Context denial never changes the prompt-free launch object.

### 7. Compose draft and receipt

`composeNote` requires the immutable `compose_note` capability, a public-note
launch, a signed-in host user, current domain allowance, and the active channel.
It does not require OAuth authorization. The draft is a closed object with
optional:

| Member | Rule and default |
| --- | --- |
| `text` | String up to 5,000 characters; default empty. |
| `spoilerText` | String up to 500 characters; default empty. |
| `language` | Empty or up to 35 characters matching `^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$`; default empty. |
| `visibility` | `public`, `unlisted`, `followers`, or `direct`; default `public`. |
| `inReplyTo` | Empty/absent or an HTTPS URL exactly equal to this launch's `note.id`. |
| `links` | At most eight valid HTTPS URLs. Exact duplicates are removed in first-seen order. Default empty. |

The host appends unique links to trimmed-right text after one blank line, one
URL per line, and rejects the draft if the result exceeds 5,000 characters.
Acceptance opens a host-owned, editable composer; it never publishes. The user
may edit every normal field and must submit using trusted host UI. The app
receives no edit stream.

The initial result status is one of `accepted`, `unavailable`, or
`invalid_draft`. Only `accepted` also contains a fresh `requestId`. After a
successful database commit, the host emits a receipt for that request with
only the canonical ActivityPub Note `id`/URL and final `scope` (`public`,
`unlisted`, `followers`, or `direct`). It emits no receipt on cancel or failed
submission and makes no claim that federation delivery has completed.

### 8. Browser isolation and bootstrap

The authenticated host page MUST NOT frame the remote app directly. It frames
a minimal same-origin broker document, and that document creates the remote
iframe. This yields three principals:

```text
authenticated host UI (issuer origin; cookies and trusted prompts)
  └─ same-origin broker document (no secrets; exact frame-src app origin)
       └─ remote app iframe (app origin; sandboxed)
```

The broker response is private/no-store HTML with
`X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`, and a unique
nonce policy equivalent to:

```text
default-src 'none'; script-src 'self'; style-src 'nonce-<random>';
frame-src <exact-app-origin>; frame-ancestors 'self'; base-uri 'none';
form-action 'none'; object-src 'none'; connect-src 'none'; img-src 'none';
```

It contains only bounded, HTML-escaped app origin, launch URL, and display
title values plus first-party relay code. It has no user data or OAuth value.
The remote iframe has `sandbox="allow-scripts allow-forms allow-same-origin"`,
`referrerpolicy="no-referrer"`, and a Permissions Policy that denies all
undeclared browser/device capabilities. It has no `allow-popups`, downloads,
top navigation, storage-access escape, pointer lock, or presentation authority.
The app's exact origin MUST differ from every cookie-bearing hostname of the
host installation, including media or alternate frontend hosts.

Create a cryptographically random 32-byte launch nonce and encode it as exactly
43 unpadded base64url characters. This `launchId` identifies one active launch,
not an app or user. Reload/navigation closes old ports but does not reset
per-launch budgets. Replacement, logout, policy denial, or close destroys the
broker and all ports. A new app launch gets a new `launchId`.

The authenticated host creates a `MessageChannel`. After the broker iframe
loads, it sends one closed three-member window message to that iframe with
`targetOrigin` equal to the exact issuer origin, `event.source` equal to the
broker iframe window, and one transferred port:

```js
{
  type: "fediverse-miniapp:host-bootstrap",
  appOrigin: "https://app.example",
  bootstrap: { /* object below */ }
}
```

The broker validates the exact host origin/source, exact app origin, and one
port. On each remote iframe load it creates another `MessageChannel`, forwards
structured messages between the two ports, and sends the following object to
the remote iframe with `targetOrigin` equal to the exact app origin,
`event.source` equal to the remote iframe's immediate parent, and exactly one
transferred port:

```json
{
  "type": "fediverse-miniapp:bootstrap",
  "version": "1",
  "launchId": "43-character-base64url-launch-id",
  "hostOrigin": "https://social.example",
  "issuer": "https://social.example",
  "authorizationServerMetadata": "https://social.example/.well-known/oauth-authorization-server",
  "authorizationResultRelay": "https://social.example/mini-apps/oauth/relay",
  "capabilities": ["wallet.evm", "notifications.activitypub"]
}
```

That object has exactly eight members. `hostOrigin` and `issuer` are identical
canonical origins. The metadata and relay values are exactly those fixed paths
on that origin. `capabilities` is a unique array of host capabilities usable in
this launch; V1 permits `wallet.evm` and `notifications.activitypub`. Core
methods, OAuth, and `compose_note` are not advertised in this array: their
availability follows the manifest and live authorization checks.

An app installs its bootstrap listener synchronously, before deferred imports
or framework rendering. It accepts at most one bootstrap, only from its
immediate `parent`, only with one transferred port, only when
`event.origin === bootstrap.hostOrigin`, and only after its app-defined
`allowedHostOrigin` function accepts that canonical HTTPS origin. It validates
all eight fields before starting the port. It never replies with window
`postMessage`; all later traffic uses the transferred port.

The first app-to-host port message MUST be exactly:

```json
{"type":"ready","version":"1","launchId":"43-character-base64url-launch-id"}
```

Traffic before it is a protocol violation and closes the port. A repeated
identical `ready` after readiness is ignored. `ready` means the first usable
app render exists; it is not authentication, consent, or proof of safety. If it
does not arrive by the host's UI deadline, show Retry and Open externally while
keeping the host usable. Retry reloads the broker/app and requires a new
`ready`; it never fabricates success.

### 9. Port value grammar, budgets, and correlation

Although examples use JSON, the transport is HTML structured clone. Accept
only values representable as null, a string, a boolean, a finite number, a
dense ordinary array, or an ordinary/null-prototype object with enumerable
data properties. Reject `undefined`, bigint, symbol, function, accessor,
Date, RegExp, Map, Set, Blob, typed array, DOM object, custom prototype, sparse
array, cycle, repeated object reference, and prototype-pollution structure.
Security-sensitive envelopes are closed and reject extra members. Optional
members are either present with a valid value or entirely absent; sending an
own property whose value is JavaScript `undefined` is invalid.

Measure a deterministic JSON-like encoding before processing. Per launch,
enforce all of these ceilings on the browser broker:

| Limit | Value |
| --- | ---: |
| nesting depth | 16 |
| nodes in one message | 4,096 |
| one message | 393,216 bytes (384 KiB) |
| total bytes, both directions | 2,097,152 bytes (2 MiB) |
| inbound app messages | 512 |
| unique accepted request/call IDs | 128 |
| requests awaiting response | 8 |
| app-message token bucket | burst 40; refill 20/second |

The server-side host bridge independently enforces at most 256 accepted broker
events, 128 requests, the same byte ceilings, and the same token bucket. It
does not trust the browser limiter. Any budget, readiness, launch-ID, or value-
grammar violation closes the channel and cancels pending operations.

`requestId` and `callId` match `^[A-Za-z0-9_-]{1,64}$`, are unique for the
launch, and are unpredictable for honest clients; the SDK uses 16 random bytes
encoded as 22 unpadded base64url characters. A response must match the pending
request type and ID. Ignore unsolicited, duplicate, wrong-type, stale-launch,
or malformed responses. The SDK default request timeout is 30 seconds and its
`destroy()` rejects all pending calls and closes the port.

Only one host-owned prompt or privileged operation may be active. A second
well-formed request gets an immediate correlated response without replacing
the first: context `unavailable`, notification `unavailable`, auth `error`,
compose `unavailable`, external navigation `denied`, or wallet error `-32002`.
It MUST NOT be silently dropped, because that strands the SDK promise and an
outstanding slot.

### 10. Exact app-to-host requests

All objects below are closed. Every message contains the shown `version: "1"`
and current `launchId`. The host revalidates app origin, manifest fingerprint,
domain policy, user/login state, capability, permission, and OAuth grant at the
moment it handles each request.

Prompt-free launch information:

```json
{"type":"getLaunchInfo","version":"1","launchId":"…","requestId":"…"}
```

Permissioned enriched context:

```json
{"type":"getContext","version":"1","launchId":"…","requestId":"…"}
```

OAuth, in default backend-handoff mode:

```json
{
  "type": "requestAuth",
  "version": "1",
  "launchId": "…",
  "requestId": "…",
  "clientId": "opaque-public-client-id",
  "redirectUri": "https://app.example/oauth/callback",
  "scopes": ["identify"],
  "state": "43-to-256-base64url-characters",
  "codeChallenge": "43-character-S256-challenge",
  "codeChallengeMethod": "S256",
  "handoffChallenge": "43-character-SHA256-challenge"
}
```

It may additionally contain integer `authorizationLifetimeSeconds` from 300 to
31,536,000. `clientId` matches `^[A-Za-z0-9_-]{10,200}$`; `redirectUri` is at
most 2,048 bytes and is later required to equal a registered URI; scopes are a
unique array of 1–32 values matching
`^[A-Za-z][A-Za-z0-9:_-]{0,63}$`. State is unpadded base64url, 43–256
characters. Challenges are exactly 43 unpadded base64url characters.

Static browser-code mode omits `handoffChallenge` and adds
`"completionMode":"browser_code"`. Backend mode omits `completionMode`; the
default is `backend_handoff`. No other mode or combination is valid.

Compose uses exactly the draft defined in section 7:

```json
{"type":"composeNote","version":"1","launchId":"…","callId":"…","draft":{}}
```

Close is fire-and-forget and has no response:

```json
{"type":"close","version":"1","launchId":"…","requestId":"…"}
```

External navigation is:

```json
{
  "type":"openExternal","version":"1","launchId":"…","requestId":"…",
  "url":"https://outside.example/path","userActivation":true
}
```

The URL is valid HTTPS, at most 2,048 bytes, and may include a fragment. The
boolean is an app assertion, not trusted proof of a browser gesture; section 14
defines the required host-owned interaction.

The optional notification extension uses:

```json
{"type":"getNotificationPermission","version":"1","launchId":"…","requestId":"…"}
```

or:

```json
{
  "type":"requestNotificationPermission","version":"1","launchId":"…",
  "requestId":"…","userActivation":true
}
```

Both require advertised `notifications.activitypub`, the matching immutable
ActivityPub declaration, and a current OAuth grant satisfying `identify`.
Prompting additionally requires trusted host confirmation.

Wallet uses the seven-member envelope in section 13.

### 11. Exact host-to-app responses and events

Launch information always uses:

```json
{
  "type":"launchInfoResult","version":"1","launchId":"…","requestId":"…",
  "launchInfo":{"version":"1","launchUrl":"https://app.example/…","linkedUrl":"https://app.example/…","sourceNoteId":"https://social.example/objects/123"}
}
```

Context always includes a `context` member. On success it is the section 6 DTO;
otherwise it is JSON null:

```json
{
  "type":"contextResult","version":"1","launchId":"…","requestId":"…",
  "status":"ok","context":{"version":"1","launchUrl":"…","sourceUrl":"…","note":{}}
}
```

Allowed statuses are `ok`, `denied`, and `unavailable`. `denied` means the user
declined/revoked disclosure; `unavailable` covers ineligible source data,
logout, policy, or another active prompt. Apps MUST NOT infer a private detail
from the distinction.

OAuth failure has exactly five members and status `cancelled`, `error`, or
`invalid_request`:

```json
{"type":"authResult","version":"1","launchId":"…","requestId":"…","status":"cancelled"}
```

Success has exactly one completion value. Backend mode adds `handoffCode`
matching `^[A-Za-z0-9_-]{16,512}$`; browser mode instead adds
`authorizationCode`, exactly 43 unpadded base64url characters:

```json
{
  "type":"authResult","version":"1","launchId":"…","requestId":"…",
  "status":"success","handoffCode":"single-use-app-session-code"
}
```

Compose result has exactly the five base members below. Only `accepted` adds a
sixth `requestId` matching the ID grammar:

```json
{
  "type":"composeNoteResult","version":"1","launchId":"…","callId":"…",
  "status":"accepted","requestId":"host-compose-request-id"
}
```

Statuses are `accepted`, `unavailable`, or `invalid_draft`.
The later event is closed and independent of the original `callId`:

```json
{
  "type":"composeNotePublished","version":"1","launchId":"…",
  "requestId":"host-compose-request-id",
  "id":"https://social.example/objects/new-note","scope":"public"
}
```

The ID is an absolute canonical ActivityPub object URL at most 2,048 bytes and
scope is `public`, `unlisted`, `followers`, or `direct`.

External navigation returns exactly:

```json
{
  "type":"openExternalResult","version":"1","launchId":"…","requestId":"…",
  "status":"approved"
}
```

Status is `approved` or `denied`.

Notification success contains exactly:

```json
{
  "type":"notificationPermissionResult","version":"1","launchId":"…",
  "requestId":"…","status":"ok","state":"granted",
  "actorUrl":"https://app.example/ap/actor"
}
```

State is `prompt`, `granted`, or `denied`; actor URL is the validated declared
HTTPS actor. Failure omits both fields and uses `auth_required` or
`unavailable`. The bearer API counterpart, if this extension is implemented,
is `GET <issuer>/api/v1/mini-apps/notification-permission`: a granted response
is `{"state":"granted","recipientActor":"<user AP ID>","appActor":"<app actor ID>"}`
and a denied response is `{"state":"denied"}`. It uses the same no-store,
identify, app-registration, and CORS requirements as the identity endpoint.

Wallet responses use the envelope in section 13. Malformed or unknown
app messages have no side effect. Do not invent a catch-all successful
response, leak stack traces, or reflect hostile values into trusted UI.

### 12. OAuth popup completion relay

The host opens authorization only after a real click on a host-owned control,
using an opener-free top-level popup/sheet. The registered app callback handles
the OAuth response, validates exact state, and navigates with replacement to
the bootstrap `authorizationResultRelay`. The URL has no query; its fragment is
at most 1,024 characters and has no duplicate or extra key.

Backend success:

```text
#version=1&launch_id=<43-base64url>&state=<43..256-base64url>&status=success&handoff_code=<16..512-base64url>
```

Browser-code success replaces the last key with
`authorization_code=<43-base64url>`. Cancellation/error has only `version`,
`launch_id`, `state`, and `status=cancelled` or `status=error`. The two success
code keys are mutually exclusive.

The relay response is private/no-store HTML with `Pragma: no-cache`,
`Referrer-Policy: no-referrer`, `X-Content-Type-Options: nosniff`,
`Cross-Origin-Opener-Policy: same-origin`,
`Cross-Origin-Resource-Policy: same-origin`, and CSP:

```text
default-src 'none'; script-src 'self'; frame-ancestors 'none';
base-uri 'none'; form-action 'none'; object-src 'none'; connect-src 'none';
img-src 'none'; style-src 'none';
```

It never reads `window.opener`. After strict parsing it opens the same-origin
`BroadcastChannel` named exactly
`fediverse-miniapp-auth:<launchId>:<state>` and posts one closed camel-case
object:

```json
{
  "type":"fediverse-miniapp:auth-completion","version":"1",
  "launchId":"…","state":"…","status":"success","handoffCode":"…"
}
```

Browser mode uses `authorizationCode`; failure has only the five base members.
The active host listener accepts a message only for its one pending launch,
request, exact state, completion mode, redirect, scopes, client, user, and
unexpired server-side OAuth transaction. It then closes the BroadcastChannel,
marks the transaction consumed, and sends the corresponding `authResult` on
the pinned app port. The relay never receives, stores, or forwards an access
token, refresh token, PKCE verifier, handoff verifier, app session, or cookie.

Backend handoff codes are app-generated, single-use, expire within 60 seconds,
and are bound to a SHA-256 `handoffChallenge`. The app iframe alone retains the
verifier and redeems code + verifier directly with its backend. Browser-mode
authorization codes remain issuer-generated, single-use, short-lived, and
bound to the iframe's PKCE verifier; the iframe exchanges one at the advertised
token endpoint. A host-visible code is never sufficient without its verifier.

### 13. Optional EIP-1193 wallet wire

Advertise `wallet.evm` only when the manifest enables it, host policy permits
it, an injected/future embedded adapter is available, and all required chains
can be handled. The SDK exposes a frozen provider with one
`request({method, params})` function. It never exposes `window.ethereum`, a
private key, wallet object, RPC URL, seed, or administrator credential.

The app request is exactly:

```json
{
  "type":"walletRequest","version":"1","launchId":"…","requestId":"…",
  "method":"personal_sign","params":["0x6869","0x1111111111111111111111111111111111111111"],
  "userActivation":true
}
```

`userActivation` is boolean. It must be true for `eth_requestAccounts`,
`personal_sign`, `eth_signTypedData_v4`, and `eth_sendTransaction`; it may be
false for `eth_accounts` and `eth_chainId`. It remains untrusted advisory input
and never replaces host confirmation.

Only these methods and parameter orders exist:

| Method | Exact `params` | Result |
| --- | --- | --- |
| `eth_accounts` | `[]` | 0–16 unique lowercase 20-byte hex addresses; `[]` before per-origin connection. |
| `eth_chainId` | `[]` | Canonical EVM quantity string. |
| `eth_requestAccounts` | `[]` | 1–16 unique lowercase addresses after host connection approval. |
| `personal_sign` | `[data, address]` | 65-byte hex signature. Data is even-length hex, at most 65,536 bytes. |
| `eth_signTypedData_v4` | `[address, typedDataJsonString]` | 65-byte hex signature. |
| `eth_sendTransaction` | `[transaction]` | 32-byte transaction-hash hex. |

An address matches `^0x[0-9a-fA-F]{40}$` and is normalized lowercase. Hex data
is `0x` plus an even count of digits and is normalized lowercase. A quantity
is `0x0` or `0x` followed by a non-zero hex digit and further hex digits; no
leading zeroes. Quantities are bounded to the field width below.

A transaction is a closed object. `from` is required and must be one of the
exact app's connected accounts. Optional fields are `to`, `data`, `value`,
`gas`, `gasPrice`, `maxFeePerGas`, `maxPriorityFeePerGas`, `nonce`, `chainId`,
`type`, and `accessList`. `to` is an address. `data` is at most 65,536 bytes.
Widths are value/gas-price/fee/chainId 256 bits, gas/nonce 64 bits, and type 8
bits. Contract creation requires non-empty data when `to` is absent. Legacy
`gasPrice` is mutually exclusive with EIP-1559 fee fields, and
`maxPriorityFeePerGas <= maxFeePerGas`. An access list has at most 128 closed
`{address, storageKeys}` objects; each has at most 256 32-byte hex keys.

Typed data is a strict JSON string at most 65,536 UTF-8 bytes. Reject duplicate
keys, floats/exponents, integers outside JavaScript's safe range when encoded
as numbers, `-0`, dangerous names `__proto__`, `constructor`, or `prototype`,
depth over 12, more than 4,096 nodes, more than 128 entries in a container,
more than 32 types or 32 fields per type, and a string over 8,192 bytes. The
top object has exactly `types`, `primaryType`, `domain`, and `message`.
Identifiers match `^[A-Za-z_][A-Za-z0-9_]{0,63}$`. Require an
`EIP712Domain` definition and a declared non-domain primary type. Types may be
declared structs, `address`, `bool`, `string`, dynamic/fixed `bytes1`–`bytes32`,
or `int`/`uint` with omitted width or a multiple-of-eight width 8–256, with at
most four array dimensions and a fixed dimension no greater than 128. Domain
fields are limited to the correctly typed `name`, `version`, `chainId`,
`verifyingContract`, and `salt`. Dynamic `bytes` values are at most 32,768
bytes. Validate every value recursively and
canonicalize the resulting object before showing or sending it.

Wallet success is the closed result envelope:

```json
{
  "type":"walletResult","version":"1","launchId":"…","requestId":"…",
  "result":"0x…"
}
```

`result` has the method-specific shape above. Failure replaces `result` with
closed `error: {"code": <integer>, "message": "<at most 256 chars>"}`. Codes
are integers from -32,768 through 49,999; invalid adapter codes normalize to
4001. Use standard EIP-1193/JSON-RPC codes where applicable: 4001 user rejected,
4100 unauthorized/unavailable, 4200 unsupported, 4900 disconnected, 4901 wrong
chain, -32602 invalid parameters, -32603 invalid response, and -32002 another
request pending. Error messages contain no wallet/provider internals.

`eth_accounts` returns only the intersection of the current wallet accounts
and the remembered exact-app-origin connection. `eth_requestAccounts` creates
that connection only after host approval. Each signature and transaction gets
a fresh host-owned review and confirmation; section 14 makes the confirmation
and execution binding mandatory. Disconnect, logout, app close, OAuth revoke,
domain denial, account/chain change, or wallet adapter loss cancels pending work
and immediately removes authority as applicable.

### 14. Mandatory hostile-app security boundary

Treat the remote iframe, every app response, every manifest/card/ActivityPub
document, every URL, and every MessagePort value as malicious. Treat the
browser, host server, OAuth issuer, and wallet adapter as separate components
that must each enforce their own boundary. No check performed in one component
is proof to another.

#### Trusted user actions

`userActivation: true` is an assertion made by attacker-controlled app code.
The SDK uses `navigator.userActivation.isActive` to reject accidental calls by
honest apps, but an attacker can bypass the SDK and write any value to its port.
A host MUST NOT use this boolean as authorization or as proof of a click.

Every consequential operation therefore ends at trusted host UI:

| Request | Required trusted interaction |
| --- | --- |
| `requestAuth` | Show the exact app origin, issuer, scopes, and duration in host UI. A real click there opens the opener-free authorization surface. `write` receives a second explicit acknowledgement. |
| `getContext` first use | Host-owned once-per-app disclosure naming the exact app origin and fields. Denial releases nothing. |
| `composeNote` | Host-owned editable composer; a real click on its ordinary submit control is the only publication path. |
| `openExternal` | Host-owned control naming the exact destination origin. Its click opens a new top-level context with `noopener,noreferrer`. A port message alone never calls `window.open`. |
| `requestNotificationPermission` | Host-owned confirmation naming exact app origin and activated actor. |
| `eth_requestAccounts` | Host-owned connection confirmation naming exact origin, account(s), chain, and wallet source. |
| signature or transaction | A fresh host-owned confirmation showing exact account, chain, method, payload/destination, value, and fees. |

Trusted prompts render outside the broker subtree, cannot be covered by app
content, retain a visible issuer/app-origin header, trap focus appropriately,
and remain operable with keyboard and assistive technology. The app cannot set
their HTML, labels, hidden inputs, action URL, z-index, submit event, or default
choice. Only bounded escaped text values are interpolated.

#### Origin, frame, cookie, and CORS invariants

- Validate both `event.origin` and `event.source` for the two bootstrap window
  messages, use exact non-wildcard `targetOrigin`, then abandon window
  messaging for the transferred port. A correct origin with a wrong window, or
  a correct window after navigation, fails.
- A port is only a transport binding. Every operation still checks current
  launch, origin, user, policy, declaration, permission, and grant. Never turn
  readiness or port possession into a durable authorization flag.
- The main authenticated page frames only its same-origin broker. Its CSP needs
  `frame-src 'self'` (or the exact broker origin); the broker alone names the
  exact app origin in `frame-src`. Preserve route-specific CSP headers.
- Use host-only `Secure`, `HttpOnly`, and appropriate `SameSite` cookies, with
  `__Host-` names when possible. Never configure a parent-domain cookie that
  an app or media sibling can receive. Enforce CSRF on cookie-authenticated
  mutations even though the iframe lacks cookies.
- Mini-app CORS endpoints are bearer/public-client APIs only. They never read a
  browser session cookie, allow credentials, or reflect an unvalidated Origin.
  The authorization page remains top-level and cookie-authenticated.
- The concrete authorization consent response adds only the already validated
  callback **origin** to `form-action`, because browsers may enforce that
  directive across a form redirect. Never use `*` or copy an unparsed callback
  string into CSP. Other host pages retain the ordinary stricter policy.
- Reject an app origin equal to any host cookie domain. `allow-same-origin` in
  the remote sandbox is safe only because the app is cross-origin from every
  host principal.

#### Payload-smuggling invariants

Parse each untrusted representation once into a closed typed value. Do not
validate one representation and execute another. In particular:

1. JSON uses duplicate-rejecting parsing before object construction. HTML is
   parsed as inert data. ActivityPub extension fields are read from the parsed
   JSON object, not from JSON-LD remote-context expansion.
2. Structured-clone envelopes are copied member-by-member from an allowlist.
   Never spread the original object into a server event, merge unknown maps,
   trust getters/prototypes, or stringify and reparse after validation.
3. Browser camel-case to server snake-case conversion is an explicit mapping.
   The server validates the mapped object again and ignores any client-supplied
   user ID, app origin, manifest URL, actor URL, OAuth application ID, policy
   decision, or permission bit.
4. Preserve exact `linkedUrl` and `launchUrl` as separately validated values.
   Do not decode twice, normalize a hostile URL into equality, reorder/drop a
   query, replace it with `homeUrl`, or compare only hosts. Use the canonical
   origin tuple only for origin decisions.
5. Reconstruct authorization URLs from typed fields with a URL builder. Never
   concatenate state, redirect, scope, or challenge into HTML. Form actions and
   redirects come from persisted registration/transaction data, not request
   echoing.
6. Wallet review and execution use one immutable normalized request or a
   cryptographic semantic hash bound to launch ID, request ID, execution nonce,
   origin, account, and chain. Any change between display and adapter execution
   cancels and requires a new confirmation.
7. Host-rendered remote names, titles, errors, URLs, and ActivityPub content are
   escaped/sanitized in the final output context. Remote images are decoded and
   re-encoded; they are never served as supplied bytes with supplied headers.

Malformed messages, unknown fields, wrong types, overlong values, replayed
identifiers, and wrong-launch values have zero side effects. A failure response
uses the fixed status/error shape, never a reflected payload. Repeated schema or
budget violations terminate the launch.

#### Authorization and lifecycle invariants

- Registration, authorization, token exchange/refresh, identity, compose,
  wallet, notification permission, and every authenticated native API request
  recheck current immutable registration and domain policy. Deny wins
  immediately over caches and existing tokens.
- Bind authorization state to exact issuer, user, client, app origin, redirect,
  scope set, duration, PKCE challenge, completion mode, launch, and one request.
  Codes and relay results are short-lived, single-use, and accepted once.
- Access/refresh tokens, client/native secrets, cookies, PKCE/handoff verifiers,
  private keys, wallet objects, and CSRF tokens never enter bootstrap, launch
  context, MessagePort, card HTML, URLs visible to another origin, analytics,
  or logs.
- Serialize consent/revocation and privileged effects on a per-user/app lock.
  Logout, revoke, app close/replacement, source Note becoming non-public,
  manifest/policy change, and account deletion cancel pending prompts and cause
  stale callbacks/responses to fail.
- One app may be active. Collapse retains the exact iframe and port; close or
  replacement destroys them. In a morphing/SPA frontend, keep the broker frame
  in a stable client-owned DOM island so ordinary state patches cannot reload,
  re-parent, or duplicate it.
- A global kill switch disables discovery fetches, cards, broker creation,
  registration/authorization, identity, compose, wallet, notifications, and
  active frames without impairing ordinary ActivityPub or OAuth clients.

Log bounded security decisions with time, action, outcome, app origin, and a
local correlation identifier. Redact URL queries where they may contain
secrets, Note/context content, OAuth material, handoff data, wallet payloads,
cookies, key material, and remote network topology. Apply quotas/circuit
breakers per IP, origin, user, client, and instance so a mini app cannot block
federation ingest, timelines, login, or the ordinary composer.

### 15. Optional V1 ActivityPub transactional-mention extension

This section is required only when a host advertises
`notifications.activitypub`. The current V1 extension supports one permission
class: transactional mentions. It does **not** support promotional consent,
`mentionPurposes`, `fma:miniApp`, `fma:notificationPurpose`, a custom JSON-LD
namespace, or user-attributed delegated publishing. Those require a later
version. Do not infer them from `transactionalMentions: true`.

An app operates one stable backend-controlled `Application` or `Service` actor
for all users. The manifest declaration is stored inactive. A unique bounded
background activation fetches `actorUrl` with no redirect, the common DNS/TLS
boundary, a 65,536-byte limit, and an ActivityStreams JSON media type. The
closed security projection must satisfy:

- actor `id` exactly equals declared `actorUrl` and `type` is `Application` or
  `Service`;
- `inbox`, `outbox`, `followers`, and `publicKey.id` are HTTPS URLs on the
  actor/manifest exact origin; inbox/outbox/followers paths are non-root;
- `publicKey.owner` exactly equals actor ID;
- `publicKeyPem` decodes to one RSA public key with modulus 2,048–8,192 bits;
  and
- app origin, manifest fingerprint, actor, endpoints, key ID, key PEM, and
  SHA-256 key fingerprint are atomically pinned.

Activation never silently follows a moved actor, fetches a later key from a
signature `keyId`, or repins a changed document. A changed security projection
disables the extension until explicit operator/user recovery. Advertise the
capability only after successful activation and current policy approval.

Permission is keyed by `(local user, exact app origin, exact activated actor)`
and is independent of context, wallet, and generic OAuth consent. The SDK grant
requires an active mini-app OAuth grant satisfying `identify` plus the
host-owned confirmation. OAuth revoke/expiry, app/actor invalidation, domain
denial, permission revoke, or account deletion disables it immediately. The
backend permission endpoint derives app/actor from the bearer token and never
accepts either as caller input. It returns the user actor ID only while granted,
using the response specified in section 11.

An inbound transactional delivery is accepted for user-visible processing only
if all of these hold in one locked transaction:

1. It is a normal signed ActivityPub `Create` with one embedded `Note`.
2. Activity `actor` and Note `attributedTo` exactly equal the activated actor.
   The HTTP signature verifies using only the pinned key ID and key; no network
   key fetch occurs.
3. Neither activity nor Note has ActivityStreams Public in `to`, `cc`, `bto`,
   or `bcc`. Each addresses exactly one actor: the same local recipient.
4. The Note has exactly one `Mention` whose `href`/`id` exactly equals that
   recipient. It has no other mentioned or addressed actor.
5. The recipient is local, the app registration/identify grant and
   transactional permission are current, the actor/origin is allowed, and
   normal federation signature, block, moderation, content, and size policies
   also pass.
6. A secret-keyed HMAC over local user ID, app actor, and stable activity ID has
   not already been consumed. Store the HMAC, never the raw activity ID, in the
   notification-specific replay/audit table.

On success, persist the ordinary private Note/activity and create normal local
notification/direct-message effects. On any extension failure, create no
object, notification, or side effect, but return the same non-oracular
successful inbox status used for an accepted duplicate so the sender cannot
probe permission/account state. Ordinary invalid ActivityPub may still receive
the host's normal generic rejection before this check.

The notification audit stores only local user ID, exact app origin, exact app
actor, grant/deny/revoke or accepted/suppressed reason, and timestamp. It has no
content, raw activity/note ID, recipient URL, OAuth value, or key. Keep at most
500 rows per user. Consent authorization, replay consumption, persistence, and
the audit decision are serialized to prevent revoke/delivery races.

Public notes authored by the app actor use ordinary ActivityPub and require no
mini-app host feature. A useful producer supplies WebFinger, actor, inbox,
outbox, followers, public activity/note dereferencing, signed `Follow`/`Undo`
handling and `Accept`, and durable signed delivery. Public app notes must not
mention an individual merely to trigger this extension.

### 16. Deterministic conformance vectors

Use `https://app.example` as app origin, `https://social.example` as issuer,
`A` repeated 43 times as a syntactically valid launch/challenge value, and
`req_1` as a valid request ID. These are parser vectors, not entropy examples;
production IDs are random.

| ID | Input or condition | Required outcome |
| --- | --- | --- |
| URL-01 | `https://App.Example:443/a?x=1` | Accept; origin is `https://app.example`; preserve exact path/query value for launch/link attribution. |
| URL-02 | `https://app.example.evil.test/` compared with app origin | Reject exact-origin equality. |
| URL-03 | `https://app.example@evil.test/`, `https://127.0.0.1/`, `https://0x7f000001/`, or a percent-encoded backslash | Reject before DNS/connect. |
| URL-04 | DNS returns one public and one private address | Reject the entire fetch; do not choose the public answer. |
| FETCH-01 | 302 from app origin to another path on same origin, then 200 | Accept if both hops independently pass and redirect budget remains. |
| FETCH-02 | Redirect to another origin or encoded body with `gzip` | Reject without parsing body. |
| FETCH-03 | Both `Content-Length` and `Transfer-Encoding`, duplicate content type, or body length mismatch | Reject as ambiguous/smuggled. |
| MAN-01 | Minimal `{"version":"1","name":"A","homeUrl":"https://app.example/","capabilities":[]}` | Accept as unauthenticated core app. |
| MAN-02 | The same JSON with a second `name` key or unknown top-level key | Reject manifest. |
| MAN-03 | OAuth scopes `["identify"]`, exact redirect, empty capabilities | Accept; registration is public and identity-only. |
| MAN-04 | `compose_note` without OAuth/identify | Accept; compose authorization comes from the declaration, active host session, and explicit host UI submission. |
| MAN-05 | Cross-origin icon/redirect or mutable OAuth scope maximum after registration | Reject/fail closed. |
| MAN-06 | Optional wallet enabled false with required true or a required chain `eip155:0` | Reject manifest. |
| CARD-01 | No mini-app meta on valid linked page | Generic card; launch exact linked URL, not home URL. |
| CARD-02 | Two matching meta tags, duplicate JSON key, cross-origin launch/image, or overlong title | Treat metadata as absent; never apply its authority. |
| DISC-01 | Public Note has mention anchor first and ordinary app anchor second | Skip mention link; test the ordinary link. |
| DISC-02 | Followers-only Note contains a valid app link | Do not fetch manifest/page or create a card. |
| BOOT-01 | Eight-field bootstrap from immediate parent, exact allowed host origin, one port | Accept once; first port message must be exact `ready`. |
| BOOT-02 | Correct object from wrong `event.source`, correct source with `targetOrigin=*`, extra bootstrap key, or two ports | Reject and release no data. |
| PORT-01 | Valid `getLaunchInfo` after ready | Return exactly the four-field launch DTO without prompt/OAuth/viewer. |
| PORT-02 | Any request before ready, `undefined` optional property, accessor/custom prototype, duplicate ID, stale launch, ninth outstanding request, or oversized message | No side effect; apply specified violation/close behavior. |
| CTX-01 | First `getContext`, user denies | Correlated `denied` with `context:null`; launch info remains available. |
| CTX-02 | Approved context after source Note becomes non-public | `unavailable` with null; do not use cached public state. |
| OAUTH-01 | New app requests only `identify` on Egregoros, Mastodon-adapter, Pleroma-adapter, or Misskey-adapter host | Same profile flow and same five-field identity DTO; native mapping is not visible. |
| OAUTH-02 | App asks for undeclared/unsupported scope, wrong redirect, wrong state/PKCE/mode, expired code, or second code use | Reject without token or grant mutation. |
| OAUTH-03 | Repeat registration for same issuer + canonical manifest | Same client ID; no new row per user. |
| RELAY-01 | Exact one-time browser-code fragment for active request | Relay only authorization code to matching port; iframe must still present verifier at token endpoint. |
| RELAY-02 | Duplicate/extra fragment key, wrong state/launch/mode, both code fields, or fragment over 1,024 chars | Ignore/close; no app response containing a code. |
| COMP-01 | Valid compose after identify, then user edits and submits | `accepted` first; receipt only after commit with final ID/scope. |
| COMP-02 | App sends a submit-like field/event, arbitrary reply target, ninth link, or total text over 5,000 chars | Reject/ignore; no post. |
| EXT-01 | App sends `userActivation:true` without any real gesture | Do not open; require host-owned click. |
| WAL-01 | `eth_accounts` before exact-origin connection | Return `[]`. |
| WAL-02 | Signature/transaction boolean says true but host confirmation absent | Do not call adapter; return rejection/cancel result. |
| WAL-03 | Reviewed request's account, chain, data, value, or execution nonce changes | Cancel; require a new review. |
| AP-01 | Signed exact-actor direct Note to one consenting local mention with pinned key | Optional extension may persist once and notify. |
| AP-02 | Public audience hidden in `bcc`, second recipient/mention, stale consent/OAuth, wrong/rotated key, or replay | Acknowledge non-oracularly; persist nothing and create no notification. |

Tests MUST assert both the response and absence/presence of durable side
effects. Run the browser vectors in at least current Chromium, Firefox, and
WebKit desktop plus installed mobile/PWA modes supported by the product. Test
third-party-cookie/storage blocking even though the protocol does not rely on
cross-origin cookies.

### 17. Clean-room implementation order and acceptance checklist

Use this order so untrusted network/browser surfaces never precede their
validators:

1. **Feature and policy core.** Add disabled-by-default global enablement,
   exact/suffix host allow and deny rules (deny wins), cookie-host rejection,
   quotas, and immediate invalidation hooks.
2. **Pure parsers.** Implement strict duplicate-rejecting JSON, URL/origin/DNS
   policy, manifest, card, launch/context, compose, message, and wallet schemas
   as side-effect-free functions with the vectors above.
3. **Bounded egress.** Implement the credential-free DNS-pinned streaming HTTP
   client, content/header/redirect limits, and raster image sanitizer. Do not
   reuse a generic federation client unless it meets every bound.
4. **Local data model.** Store immutable app declaration/fingerprint, derived
   card records, public OAuth registration, grants/token-family deadline,
   context consent, wallet connection, and active launch separately. Never add
   derived card/permission data to canonical ActivityPub JSON.
5. **Asynchronous discovery.** Queue public Notes, extract bounded candidates,
   stop at first valid app, persist one derived card, and isolate failures from
   federation/timelines.
6. **Host UI and broker.** Build the desktop floating/collapsible and mobile
   full-height surfaces, stable client-owned iframe island, same-origin broker,
   nested sandbox, CSP, loading/error/retry state, and trusted prompt layer.
7. **Port protocol.** Implement exact bootstrap, ready state machine, schemas,
   budgets, replay/correlation, one-prompt behavior, live rechecks, teardown,
   and every core response. Verify with an app written independently from the
   host.
8. **OAuth adapter.** Add RFC 8414 profile metadata, idempotent manifest-based
   public registration, exact consent, S256 authorization code flow, duration
   and rotating refresh family, relay, CORS, revocation, and native-provider
   mapping. Implement literal portable `identify` and the fixed identity DTO
   before any broader local scope.
9. **Core actions.** Add prompt-free launch info, once-per-app context,
   host-owned compose and post-commit receipt, close, and confirmed external
   navigation. Test revoke/policy/logout races at every commit boundary.
10. **Optional capabilities.** Add wallet only behind the adapter and full
    method/confirmation suite. Advertise ActivityPub notifications only after
    actor activation, permission API, pinned-key receiver checks, replay/audit,
    and revocation all pass. Partial optional work remains unadvertised.
11. **Operator/developer surfaces.** Add per-app revoke/disconnect, wallet
    disconnect, context/notification controls, domain policy, kill switch,
    redacted audit, and the conformance workbench with a real `ready` test.
12. **Release gate.** Run deterministic, adversarial, SDK interoperability,
    CSP/header, OAuth-family, browser/PWA, accessibility, load, and rollback
    tests against the production build and production egress configuration.

A core host is ready to claim `fediverse_miniapp_profile: "1"` only when every
item below is true:

- [ ] A valid app hosted once can launch from arbitrary compatible canonical
      HTTPS instance origins; no example or header assumes one Egregoros host.
- [ ] The fixed well-known manifest and RFC 8414 metadata paths, relay path,
      identity path, exact schemas, CORS, and HTTP security headers match this
      document.
- [ ] Public-note discovery produces at most one derived card and never mutates
      or delays the canonical ActivityPub object.
- [ ] The remote app is nested behind the same-origin broker with the exact
      sandbox, CSP, origin/source validation, and transferred-port state
      machine.
- [ ] The reference V1 SDK can connect, call `ready`, receive launch info,
      request/deny/approve context, authorize with both completion modes,
      obtain the exact identity DTO, compose and receive a receipt, and close.
- [ ] No app-controlled value can directly open a window, approve a grant,
      submit a post, expose an account, sign data, send a transaction, or grant
      transactional mentions.
- [ ] Anonymous registration is idempotent per issuer+manifest, never returns a
      secret, and cannot create one client per user.
- [ ] `identify` works identically over the host's native auth model without
      granting native read/write access; additional scopes are advertised and
      consented according to actual local semantics.
- [ ] Policy/revoke/logout/manifest change invalidates frames, tokens, prompts,
      and operations immediately, including races at commit/execution time.
- [ ] Payload, header, URL, origin, redirect, structured-clone, OAuth, wallet,
      and ActivityPub smuggling vectors fail without side effects or secret
      disclosure.
- [ ] The runtime SDK and its TypeScript declarations describe the same API and
      protocol version. Apps can vendor the raw module without a build step.
- [ ] Logs, audits, metrics, error pages, HTML, URLs, relay messages, and launch
      DTOs contain none of the prohibited secrets or private user data.
- [ ] Optional capability names appear in bootstrap only when their complete
      declaration, UI, server enforcement, revocation, and tests are live.

Internal language, framework, database schema, job runner, OAuth library, and
ActivityPub storage model are implementation choices. Passing this checklist
requires matching externally observable values and security outcomes, not
copying Egregoros internals.

### 18. App SDK compatibility surface

A host implementation does not have to publish its own app SDK, but it MUST
interoperate with the V1 SDK surface below. An independently written SDK uses
the same method behavior and exact port messages. The reference package is a
raw ECMAScript module with no runtime dependency or build step; apps vendor a
pinned copy on their own exact origin rather than hot-linking an arbitrary
calling instance.

Construction is synchronous so the bootstrap listener exists immediately:

```js
const sdk = createFediverseMiniAppSDK({
  allowedHostOrigin(origin) {
    return acceptsCanonicalPublicHttpsOrigin(origin)
  },
  timeoutMs: 30_000,
})
```

`allowedHostOrigin` is required and returns exactly boolean true to accept. A
generally published app validates a canonical public HTTPS origin rather than
hard-coding one instance; a private app may use an exact list. The SDK still
requires the event/source/issuer equality in section 8. Browser test injection
may additionally supply window, parent, navigator, and crypto objects; apps do
not use those options in production.

The frozen public API is:

```ts
interface FediverseMiniAppSDK {
  readonly bootstrap: MiniAppBootstrap | null
  connect(): Promise<MiniAppBootstrap>
  ready(): Promise<void>
  getLaunchInfo(): Promise<MiniAppLaunchInfo>
  getContext(): Promise<MiniAppLaunchContext>
  requestAuth(request: MiniAppBackendAuthorizationRequest): Promise<{status: "success", handoffCode: string}>
  requestAuth(request: MiniAppBrowserAuthorizationRequest): Promise<{status: "success", authorizationCode: string}>
  composeNote(draft: MiniAppComposeDraft): Promise<MiniAppComposeResult>
  close(): Promise<void>
  openExternal(url: string): Promise<{status: "approved" | "denied"}>
  on(event: "composeNotePublished", callback: (receipt: MiniAppComposePublishedReceipt) => void): () => void
  readonly wallet: {getProvider(): MiniAppEvmProvider}
  readonly notifications: {
    getPermission(): Promise<MiniAppNotificationPermission>
    requestPermission(): Promise<MiniAppNotificationPermission>
  }
  destroy(): void
}
```

The types are exactly the DTO, authorization, draft, receipt, notification,
and wallet shapes in sections 6–13. `connect()` resolves to the frozen bootstrap
after strict validation. `ready()` sends the ready message. Correlated calls
after connection use a fresh request ID and time out after the configured
interval. `composeNote` and
`openExternal` return their status objects; the later compose receipt is an
event and unsubscribe is the function returned by `on`. `destroy()` is
idempotent, removes the bootstrap listener, closes the port, rejects pending
calls, and clears event listeners.

SDK exceptions are `Error` objects named `MiniAppError` with a string or
numeric `code`. The stable string codes are:

| Code | Meaning |
| --- | --- |
| `HOST_VALIDATOR_REQUIRED` | Construction omitted the exact host-origin policy. |
| `DESTROYED` | The SDK/port was destroyed before completion. |
| `TIMEOUT` | No valid correlated result arrived within the call timeout. |
| `CONTEXT_UNAVAILABLE` | Context status was denied or unavailable. |
| `AUTH_FAILED` | OAuth status was cancelled, invalid, or unsuccessful. |
| `CAPABILITY_UNAVAILABLE` | An optional capability is absent/unavailable. |
| `AUTH_REQUIRED` | The requested extension requires a current OAuth grant. |
| `USER_ACTIVATION_REQUIRED` | Honest-SDK preflight did not observe current browser activation. This is not host proof. |

Wallet failures use the numeric codes in section 13. Before port traffic, the
provider throws 4200 when `wallet.evm` is not advertised and -32602 for invalid
method parameters; a malformed correlated provider result becomes -32603.
Notification methods check `notifications.activitypub` before sending.

Every JavaScript SDK release MUST ship a matching `index.d.ts`, even when the
runtime is JavaScript. The declarations include readonly DTOs, the two mutually
exclusive OAuth overloads, compose/event types, optional capabilities, and
method-specific EIP-1193 overloads. Runtime and declarations are one atomic
versioned change. The wire version remains string `"1"` even if the package's
own semantic version changes.

The reference package is
[`@fediverse-miniapps/sdk`](https://github.com/shipoclu/fediverse-miniapp-sdk).
When installed from Git, pin a full commit or tag and commit the consuming
lockfile. When served without bundling, copy `index.js`, `index.d.ts`, and the
complete imported `wallet/` directory; copying only the entry module breaks its
relative imports. Serve JavaScript with a JavaScript MIME type and `nosniff`.

### Informative native-provider references

These links explain why the adapter boundary is necessary; the mini-app
profile above remains the normative app-facing contract:

- [Mastodon OAuth and proprietary application registration](https://docs.joinmastodon.org/spec/oauth/)
- [Mastodon application registration API](https://docs.joinmastodon.org/methods/apps/)
- [Mastodon OAuth scopes](https://docs.joinmastodon.org/api/oauth-scopes/)
- [Pleroma OAuth application administration](https://docs.pleroma.social/backend/development/API/admin_api/)
- [Misskey OAuth/IndieAuth authorization](https://misskey-hub.net/en/docs/for-developers/api/token/oauth/)
- [Misskey API permissions](https://misskey-hub.net/en/docs/for-developers/api/permission/)
