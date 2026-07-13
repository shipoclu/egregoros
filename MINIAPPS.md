# Fediverse Mini Apps — V1 Design and Reference Implementation

New implementers should begin with the step-by-step
[`MINIAPP_IMPLEMENTER_GUIDE.md`](MINIAPP_IMPLEMENTER_GUIDE.md). This document
is the deeper protocol, security, and implementation reference.

> Status: v1 implementation candidate on the `miniapps` branch. The feature is
> disabled by default. Automated protocol, authorization, wallet, broker, and
> interoperability gates pass; production enablement still requires a
> deployment-specific browser/PWA matrix and adversarial review of the release
> build and egress controls.

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
exact HTTPS origin. Egregoros proxies them without persistent caching;
third-party CDN asset origins are not accepted in v1.

### 2. Discovery and launch

When a user puts a URL whose domain publishes a valid mini-app manifest in a
**fully public** note, Egregoros resolves it asynchronously and renders a rich
mini-app card in the note. The card uses the app's verified preview image/name
and has an explicit **Open** control. Selecting it launches the declared URL.
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

`openExternal` is allowed only after an app-originating user gesture. For a
cross-origin destination, Egregoros displays a host-owned confirmation naming
the destination domain before opening it. The iframe receives no device or
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

Cards never launch an app merely from an image/title click: the user must select
the explicit **Open** button. There is no v1 app directory, saved-app surface,
or other launcher. Direct, explicit app URLs remain valid entry points, while
`homeUrl` establishes the app's canonical base and supports future surfaces.

### 4. OAuth sign-in

The app uses OAuth 2.1 authorization code + PKCE against the **local calling
Egregoros instance**. Egregoros is the authorization server. Two explicit
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
non-OAuth capability such as the EVM wallet. It may also request disclosed
public-note launch context before OAuth. It must request OAuth before
`composeNote` or any future capability explicitly marked auth-gated. This lets
read-only public mini apps work without a consent prompt, while ensuring that
actions affecting the user's Egregoros account remain authenticated.

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

The once-per-app disclosure that public-note launch context is sent to the
app's domain is independent of OAuth. It appears before the app first receives
that context, including for apps that never declare OAuth; when both disclosures
are needed in the same launch, the host may present them together.

Egregoros settings provide a per-app revoke/disconnect control. Revocation
invalidates the app's access and refresh tokens plus its reusable grant, clears
the once-per-app launch-context approval, and closes any active iframe for that
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

Public app messages and consent-gated transactional mentions are specified as
a post-v1 extension in
[`MINIAPP_ACTIVITYPUB_MESSAGES.md`](MINIAPP_ACTIVITYPUB_MESSAGES.md). The app
operates one normal ActivityPub `Application` or `Service` actor. Public notes
are delivered to its followers; transactional notes are non-public, address
exactly one consenting actor, and contain one matching `Mention`.

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

The provenance marker is required for an object to claim mini-app production,
but is trusted only when its manifest, declared actor, activated signing-key
pin, and current domain policy all agree. Public app notes with no individual
recipient or mention carry the marker and omit purpose. Direct mentions must be
non-public, carry one purpose on both activity and object, and have an
independent user grant for that exact purpose. Missing, unknown, conflicting,
or array-valued purposes are suppressed; mixed operational and promotional
content is labeled promotional. Classification is sender-declared moderation
evidence rather than something Egregoros infers from prose. The complete wire
profile is normative in
[`MINIAPP_ACTIVITYPUB_MESSAGES.md`](MINIAPP_ACTIVITYPUB_MESSAGES.md#31-mini-app-provenance-and-message-purpose-wire-profile).

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
origin-checked `postMessage` handshake. Initial candidate methods:

- `ready()` — app declares that its first render is usable;
- `getContext()` — non-authoritative launch context, app/client protocol
  versions, locale/theme, the exact launch URL, and (when launched from a
  note) the author, note identifier, content, mentions, and link URL; and
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
syntactically exact public HTTPS domain under a fail-closed public-DNS policy.
This is not a static instance allowlist: the bootstrap still requires
`event.origin === hostOrigin === issuer`, and the SDK pins that one exact origin
for the channel lifetime. The app backend MUST independently reject private,
local, reserved, mixed public/private, redirected, or malformed issuer
destinations and connect to a DNS-pinned public address while preserving the
original hostname for Host, SNI, and TLS certificate verification. The
connected SDK exposes a frozen `bootstrap` containing
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
| Public base | `ready`, `bootstrap`, `getContext`, `close`, `openExternal` | Valid framed app; `getContext` needs context disclosure before note details are sent; `openExternal` needs user gesture. |
| OAuth initiation | `requestAuth` | Optional `oauth` manifest object and a public dynamic registration obtained by the backend or browser. |
| Wallet | `wallet.evm.getProvider` and its allowlisted EIP-1193 calls | Immutable wallet declaration, host wallet availability, and per-app wallet connection/confirmation. No OAuth required. |
| Transactional notifications | `notifications.getPermission`, `notifications.requestPermission` | Immutable ActivityPub declaration and OAuth; prompting additionally requires a user gesture and host confirmation. |
| OAuth-gated | `composeNote` | Immutable `compose_note` declaration plus an unexpired OAuth grant containing `identify` (or legacy `read`). |

#### Compose a note

`composeNote(draft)` is a required v1 host action. It hands a draft to the
Egregoros composer, which opens in its normal desktop panel or mobile sheet.
It never creates, queues, or submits a note: the user sees, may edit, and must
explicitly press Egregoros's normal submit button.

The initial draft schema is deliberately narrow and host-validated:

- `text` (string, optional), `spoilerText` (string, optional), and `language`
  (BCP 47 tag, optional);
- `visibility` (optional), always presented to the user as an editable
  selection and defaulting to Egregoros's normal composer default; and
- `inReplyTo` only when the target is the public note from which this app was
  launched, plus a bounded list of HTTPS links to include as ordinary text.

No media upload, poll creation, arbitrary reply target, silent publication, or
host API token is included in v1. These boundaries make the action useful for
sharing a result, challenge, or invite without letting a remote app post on a
user's behalf.

`compose_note` is an explicit immutable manifest capability. When an app
declares OAuth, its first approval screen shows every requested non-base host
capability; Egregoros enables only declared capabilities. Lifecycle/
authentication methods and `openExternal` are base SDK methods, not manifest
capabilities. `compose_note` is auth-gated and therefore unavailable until a
declared OAuth flow completes; wallet capabilities use their own per-app wallet
approval and do not require OAuth.

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
message. Context contains no access token or current-user identity. It is
available without OAuth after the separately consented launch-context
permission; note data is not implied by an OAuth API scope.

The handshake always exposes a `bootstrap` object with the exact Egregoros host
origin, SDK protocol version, and authorization-server issuer/metadata URL,
letting an OAuth-enabled app backend reuse or create its dynamic registration
and form a PKCE request. Bootstrap contains no
current-user identity. Apps may obtain locale/theme and public launch context
through `getContext()` after the separate context disclosure, whether or not
they authenticate with OAuth.

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
safe output with `Cache-Control: no-store`, no cookies, no referrer, and a fixed
image content type. It MUST re-run URL/DNS policy on every view because assets
are intentionally not persistently cached.

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

`ready`, `getContext`, wallet, compose, and OAuth messages all pass through the
same broker. The host MUST re-check the current manifest identity,
capabilities, user state, disclosure state, OAuth state, and domain policy at
the moment of each privileged operation; handshake success is not a durable
authorization grant.

### Data-release boundary

Before the once-per-app launch-context disclosure, `getContext` returns no note
details. After disclosure it returns only the documented fields from a fully
public note, normalized into a bounded DTO. It MUST NOT serialize database
structs, internal metadata, recipient lists beyond public fields, moderation
state, viewer identity, IP address, session IDs, or inferred relationships.
OAuth is the only path to Egregoros user identity/API data. Wallet account
addresses are exposed only by the separately approved wallet provider.

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

`composeNote` requires a currently authenticated OAuth grant, declared
`compose_note` capability, active exact-origin channel, current domain-policy
allowance, and a fresh broker request. All draft fields are untrusted and pass
through the same length, URL, visibility, reply-target, and content validation
as user-entered composer data. The app can only open and prefill the host-owned
composer; it cannot trigger its submit event, manufacture LiveView events,
select a hidden visibility, attach files, or bypass normal posting validation.

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

### Normative security references

- [OAuth 2.0 Security Best Current Practice (RFC 9700)](https://www.rfc-editor.org/info/rfc9700/)
- [OAuth Authorization Server Metadata (RFC 8414)](https://www.rfc-editor.org/info/rfc8414/)
- [OAuth Dynamic Client Registration (RFC 7591)](https://www.rfc-editor.org/info/rfc7591/)
- [WHATWG HTML iframe sandbox](https://html.spec.whatwg.org/multipage/iframe-embed-object.html)
- [W3C Content Security Policy Level 3](https://www.w3.org/TR/CSP/)
- [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [EIP-1193 Ethereum Provider API](https://eips.ethereum.org/EIPS/eip-1193)

## Launch-context disclosure

OAuth consent answers: “May this app access Egregoros APIs with these scopes?”
Launch-context disclosure answers a different question: “May Egregoros send
this public note's launch details directly to this external app?” An app can
use launch context without ever asking for OAuth, so the OAuth screen alone is
not a reliable disclosure point.

For a link opened from a public note, the context may include the exact linked
URL, the note's canonical URL/ID and public text, its author and public
mentions, plus the client theme/locale. It is untrusted application input, but
it is still data Egregoros is intentionally sending to the app's domain.

The choices are:

| Timing | User experience | Privacy trade-off |
| --- | --- | --- |
| Once per app | The first contextual launch says that this domain will receive public-note launch details; later launches proceed without repeating it. | Clear, low friction; recommended baseline. |
| Once per note | The user sees the same disclosure each time a different note launches the app. | Maximum reminder, but repetitive for normal use. |
| Only in OAuth consent | No separate message; data sharing is mentioned only if/when the app asks for OAuth. | Inadequate for apps that never request OAuth; not recommended. |

## Deferred from v1 unless explicitly selected

- app directory/search and user-installed/pinned apps;
- the ActivityPub messaging/notification-consent extension and any webhook or
  browser-push notification mechanism;
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
| App installation | Not in v1 | No saved/pinned-app launcher or app notifications. |
| Registration | Anonymous dynamic registration | One public registration per mini-app manifest and Egregoros issuer, cached by the app backend or browser. |
| Launch context | Available through SDK after once-per-app disclosure | It is untrusted; the user approves sending public-note details to the app domain. |
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
| Launcher | None in v1 | Apps open from an explicit card action or direct explicit URL. |
| Card activation | Explicit **Open** button only | Incidental image/title clicks do not launch remote code. |
| Mobile surface | Full-height safe-area-aware sheet | Provides clear close/back control rather than desktop floating UI. |
| External navigation | User gesture + host confirmation | Cross-origin destination domain is shown before opening. |
| Iframe permissions | Deny by default | Device/browser privileges require future capability-specific design. |
| Framing failure | Explicit error + external-open action | Never silently navigates the Egregoros surface away. |
| Federated cards | Supported for public incoming notes | Resolution failure leaves the source link intact. |
| Card assets | Proxied, not persistently cached | Protects viewer IP privacy without retaining remote assets. |
| Metadata refresh | One-hour default; shorter explicit TTL honored | User can manually refresh app details. |
| Pre-auth SDK data | Bootstrap issuer/origin only | Enables dynamic registration without exposing user or note context. |
| Authentication trigger | App calls `requestAuth` | No automatic prompt merely from card display or launch. |
| Authentication requirement | On demand | OAuth is required for compose/auth-gated capabilities, not for public/read-only apps. |
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
| Transactional messages | Proposed post-v1 direct-mention profile | One non-public recipient and matching mention; sender and receiver both enforce consent. |
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
untrusted app cannot obtain user identity or auth-gated actions without OAuth,
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
types, the documented ActivityPub messaging/notification-consent profile,
device permissions, an app directory, and non-public note launches as new
design efforts rather than implicit extensions.

The first-party SDK source and declarations live at
`assets/js/lib/fediverse_miniapp_sdk.{mjs,d.ts}`. Builds publish matching
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

The normative JSON Schema is
[`docs/schemas/fediverse-miniapp-manifest-v1.schema.json`](docs/schemas/fediverse-miniapp-manifest-v1.schema.json).
The schema cannot express equality with the origin from which it was fetched,
so hosts must still perform the exact-origin validation described here.

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
