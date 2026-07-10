# Egregoros Security and Correctness Audit

**Audit date:** 2026-07-10  
**Scope:** the Egregoros Phoenix application, its ActivityPub ingestion/fetch/delivery paths, HTTP signatures, OAuth/session handling, media handling, deployment defaults, and the security-relevant parts of the test suite.  
**Reference baseline:** the W3C ActivityPub Recommendation, historic Pleroma fixes in the locally available `../spc-pleroma` checkout, and published Mastodon security advisories.

## Executive summary

Egregoros already has several valuable controls: outbound redirects are disabled, fetched actor IDs are checked against the requested URL, remote activities cannot claim local IDs, HTTP-signature keys are bound to the outer ActivityPub actor, `Undo` and `Delete` compare the acting actor with the stored target actor, outbound responses are size/time bounded, common private and IPv4-mapped IPv6 destinations are blocked, and rendered remote HTML is sanitized.

Those controls are not yet sufficient for hostile federation. The central problem is that identity and authorization checks are spread across individual activity modules rather than enforced at a single trust boundary. In particular, a remote actor can submit an object whose ID belongs to another remote authority, and an `Update` can replace an existing note after changing its stored owner to another actor on the same remote instance. Embedded `Follow` objects in `Accept` and `Reject` are also acted upon without exact correlation to a previously sent follow and the accepting/rejecting actor.

The audit found **8 high**, **7 medium**, and **1 low** issue. No issue was classified critical because the reviewed paths do not directly permit takeover of a local account or execution on the server; several high-severity issues do permit remote impersonation, relationship manipulation, SSRF, or forged credentials.

**Release recommendation:** do not describe the federation boundary as hardened until remediation phases 0 through 4 below are complete. In particular, complete F-01 through F-06 before exposing an instance to untrusted federation.

## Severity model

- **Critical:** unauthenticated local account takeover, arbitrary server code execution/file write, or equivalent instance-wide compromise.
- **High:** remote identity/authorization bypass, stored-object impersonation, meaningful SSRF, forged security assertions, or broadly exploitable authentication/availability failure.
- **Medium:** confidentiality weakness requiring URL disclosure, meaningful hardening gap, cross-node/concurrency weakness, or correctness failure that can cause data loss/replay.
- **Low:** defense in depth with limited direct exploitability.

## Findings summary

| ID | Severity | Finding | Historic analogue |
| --- | --- | --- | --- |
| F-01 | High | No central authority containment for remote activity/object IDs | Pleroma 2018/2019 containment fixes; W3C object-origin guidance |
| F-02 | High | `Update` does not authorize against the stored owner or enforce freshness | Pleroma Update authorization fixes; Mastodon remote-identity takeover class |
| F-03 | High | Embedded `Follow` in `Accept`/`Reject` is not exactly authorized or correlated | W3C Accept/Reject requirements |
| F-04 | High | Inbox HTTP signatures do not require the body, target, or host to be signed | HTTP-signature replay/body substitution class |
| F-05 | High | ActivityStreams fetches do not enforce response media type | Pleroma object-spoofing fix; Mastodon CVE-2024-25623 |
| F-06 | High | SSRF validation is subject to DNS rebinding and uses an incomplete denylist | Mastodon 2026 SSRF advisories |
| F-07 | High | Remote Verifiable Credential proofs are explicitly not verified | Forged issuer/credential assertions |
| F-08 | High | Rate limiting is non-atomic, proxy-unaware, per-node, and absent on auth endpoints | Mastodon CVE-2023-49952/proxy trust class |
| F-09 | Medium | WebFinger results are not bound to the requested subject or media type | Pleroma 2024 WebFinger spoofing fix |
| F-10 | Medium | Federation persistence, side effects, retries, update ordering, and deletes are not safely atomic/idempotent | Replay/resurrection and partial-ingestion correctness |
| F-11 | Medium | Private/direct media is served as unauthenticated bearer URLs | Attachment confidentiality after URL disclosure |
| F-12 | Medium | Standalone deployment sends the session cookie to all subdomains | Subdomain isolation/cookie tossing |
| F-13 | Medium | Upload type and image resource validation is incomplete | Mastodon media-processing advisory class |
| F-14 | Medium | OAuth redirect/token lifecycle validation has gaps | Redirect URI and refresh-token replay hardening |
| F-15 | Medium | Unbounded federation discovery can amplify one inbox request into many jobs | Federation denial of service |
| F-16 | Low | No explicit Content Security Policy is configured | Browser defense in depth |

## Detailed findings

### F-01 — Remote IDs are not contained to the authority allowed to create them

**Severity:** High  
**Impact:** remote object namespace poisoning, cross-domain impersonation, and persistent cache poisoning.

`Egregoros.Pipeline.validate_namespace/2` in `lib/egregoros/pipeline.ex:62-73` rejects a remote top-level ID only when it uses the local instance's host. It does not require a remote activity or embedded object's ID authority to match the actor/author authority. `Note.cast_and_validate/2` in `lib/egregoros/activities/note.ex:55-84` requires `id`, `type`, and `actor`, but has no host/authority check. A `validate_host_match/2` helper exists in `lib/egregoros/activities/validations.ex:39-55`, but it is not a universal ingestion boundary and is not used for notes. Embedded objects reached through `Create` or `Announce` therefore inherit the same gap.

An actor at `evil.example` can send a signed `Create` whose author is also the evil actor but whose note ID is `https://victim.example/objects/123`. Egregoros can persist the note under the victim's namespace. First-write conflict behavior can then prevent the legitimate victim object from being stored, and UI/API consumers can attribute data to an authority that never served it.

The [ActivityPub object guidance](https://www.w3.org/TR/activitypub/#obj) says received content should be validated against its origin, and [object identifiers](https://www.w3.org/TR/activitypub/#obj-id) must have authority belonging to the originating server. This is the same class addressed by Pleroma's [2018 same-domain containment fix](https://git.pleroma.social/pleroma/pleroma/-/commit/0b2c051a04b3eeb7292f2b847c98fcbafbb20ed2) and [2019 IR-level containment check](https://git.pleroma.social/pleroma/pleroma/-/commit/739bbe0d3bbe06ca9d634498ea5909f35fc5ad84).

**Remediation:** create one fail-closed `ObjectAuthority`/policy boundary invoked before actor discovery or persistence. Normalize and compare scheme, IDNA host, and effective port. Define a per-type authorization matrix for the activity ID, actor, embedded object's ID and author/issuer, and any child object that makes an identity claim. Do not require arbitrary attachment/CDN URLs to share an origin; the policy must distinguish claimed object identity from referenced resources. Same-origin is the provenance floor, not permission for every actor on a multi-user origin to mutate every object.

**Test-first acceptance criteria:**

1. A signed remote `Create` with an object ID on a different remote authority is rejected and stores neither the activity nor object.
2. The same check applies to standalone objects and embedded objects reached through `Announce`, `Update`, `Offer`, and collection/thread fetches.
3. Local-namespace rejection remains intact.
4. Valid fixtures with cross-origin attachment/CDN URLs continue to work.
5. URI tests cover case normalization, IDNA, default/non-default ports, userinfo, fragments, malformed URLs, and mixed HTTP/HTTPS policy.

### F-02 — `Update` can replace another actor's stored note and replay stale state

**Severity:** High  
**Impact:** one remote user can impersonate another user on the same remote instance in Egregoros; old updates can roll newer state back.

`Update.validate_object/1` in `lib/egregoros/activities/update.ex:523-568` checks that the replacement payload names the `Update.actor`. It does not compare the actor with the owner of the already stored object. `maybe_apply_note_update/3` loads the existing note at `lib/egregoros/activities/update.ex:127-154`, validates only the replacement note's actor, and calls `Objects.upsert_object(..., conflict: :replace)`. The replace path in `lib/egregoros/objects.ex:1358-1377` protects `ap_id` and `type`, but permits `actor` and data to be replaced.

Consequently Alice at `remote.example` can send an `Update` for Bob's existing note ID, put Alice in the replacement `attributedTo`, and cause the stored note owner to become Alice. This passes even under a same-origin-only policy because Alice and Bob share an origin. The path also does not enforce a monotonic `updated` timestamp or equivalent version, allowing an authorized old update to overwrite newer content.

Pleroma historically tightened updates so [only the actor themselves could update](https://git.pleroma.social/pleroma/pleroma/-/commit/75670a99e46a09f9bddc0959c680c2cb173e1f3b), then broadened the rule to [actors on the same origin](https://git.pleroma.social/pleroma/pleroma/-/commit/547def67a76854aa4c9c8438eb1ee4dfa36fd8ac). For a multi-user origin, exact stored ownership remains the safer mutation rule. Mastodon's [GHSA-3fjr-858r-92rw / CVE-2024-23832](https://github.com/mastodon/mastodon/security/advisories/GHSA-3fjr-858r-92rw) demonstrates the impact of getting queried-versus-returned identity comparisons wrong.

**Remediation:** lock/load the stored object, require exact equality between `Update.actor` and the stored canonical owner (or an explicit delegated-controller relation), and never derive mutation authority from the replacement payload. Preserve immutable identity fields. Require a valid, strictly newer `updated`/version value when replacing data and make exact replays idempotent. Apply equivalent checks to actors, credentials, and every future mutable type.

**Test-first acceptance criteria:**

1. Alice cannot update Bob's stored note when both are on the same origin.
2. A replacement payload cannot change the stored owner.
3. An older update cannot overwrite a newer update; an exact replay is a no-op.
4. Concurrent updates serialize deterministically under a database lock/constraint.
5. Authorized actor and explicit delegated-controller cases remain supported.

### F-03 — `Accept` and `Reject` trust uncorrelated embedded follows

**Severity:** High  
**Impact:** a remote actor can create or remove follow relationships involving a local user without being the followed target.

`apply_follow_accept/1` in `lib/egregoros/activities/accept.ex:76-130` falls back to an embedded `Follow` map when no stored follow exists and then upserts a real `Follow` relationship. It never requires `Accept.actor == Follow.object`, and it does not require the exact follow to have been sent/stored previously. Inbox targeting at `lib/egregoros/activities/accept.ex:324-354` checks the embedded follower as a recipient but not the acceptor's authority. `apply_follow_reject/1` in `lib/egregoros/activities/reject.ex:90-130` has the corresponding issue and can delete a relationship from an embedded follow.

The [ActivityPub Accept section](https://www.w3.org/TR/activitypub/#accept-activity-inbox) requires the follow being accepted to have been previously sent by the receiver. A valid accept/reject must therefore correlate the exact stored activity, follower, target, and accepting/rejecting actor.

**Remediation:** require an existing pending `FollowRequest`/stored `Follow` with the same activity ID and tuple. Require the outer actor to equal the follow target and the inbox user/follower to equal the follow actor. Treat an embedded object only as a representation of the already stored request, not as authorization to create one. Apply the same correlation pattern to `Offer` accept/reject transitions.

**Test-first acceptance criteria:** test forged embedded follows, wrong accepting target, wrong follower inbox, mismatched stored ID, duplicate accept/reject, out-of-order delivery, and a valid pending-follow transition.

### F-04 — HTTP signatures may omit body, request target, and host

**Severity:** High  
**Impact:** a party that receives a weakly signed request can replay its signature within the date window while changing the body, destination host, or request target.

`lib/egregoros/signature/http.ex:325-343` enforces `(request-target)`, host, date, digest, and content length only when `:signature_strict` is true. No runtime/production configuration enables it, so the default is false. `validate_digest/3` at `lib/egregoros/signature/http.ex:269-290` validates the body only when `digest` was listed as signed. A signature covering only `date` can therefore pass. `EgregorosWeb.Plugs.VerifySignature` correctly binds the parsed outer actor to the key owner, but that actor field is not trustworthy when the body itself was not signed.

**Remediation:** for inbox POSTs, require at least `(request-target)` (or the modern equivalent), `host`, `date`, and a supported digest covering the exact raw body. Do not make `content-length` mandatory where HTTP/2 interoperability makes it unavailable. Parse duplicate/combined headers defensively, use constant-time digest comparison, and make trusted-proxy reconstruction explicit rather than trusting forwarded headers from arbitrary peers. Consider a staged telemetry-only compatibility window, but fail closed after it.

**Test-first acceptance criteria:** reject date-only signatures, unsigned/missing/mismatched digest, replay to a different path or host, duplicated headers, and a changed body. Retain tests for valid legacy Cavage signatures and add a separately specified path for modern HTTP Message Signatures if supported.

### F-05 — Fetched ActivityStreams JSON is accepted without media-type verification

**Severity:** High  
**Impact:** arbitrary JSON hosted on an actor's web origin can be interpreted as authoritative ActivityPub content, enabling same-domain content/account impersonation.

`Egregoros.Federation.ObjectFetcher.fetch_and_ingest/1` in `lib/egregoros/federation/object_fetcher.ex:10-32` accepts any 2xx response and decodes JSON without examining response headers. Actor fetching in `lib/egregoros/federation/actor.ex:62-98` behaves the same way. `ObjectFetcher.validate_id/2` does compare a present ID exactly, which is a good control, but its fallback at line 52 accepts a missing ID. WebFinger fetches likewise ignore media type.

This is the class fixed by Pleroma's [2020 ActivityStreams content-type validation](https://git.pleroma.social/pleroma/pleroma/-/commit/6ca709816f74f1171423c7bc040619fca57a2087) and Mastodon's [GHSA-jhrq-qvrm-qr36 / CVE-2024-25623](https://github.com/mastodon/mastodon/security/advisories/GHSA-jhrq-qvrm-qr36). The W3C [retrieving objects](https://www.w3.org/TR/activitypub/#retrieving-objects) section defines the ActivityStreams representations used for dereferencing.

**Remediation:** centralize remote-response validation. Require `application/activity+json` or `application/ld+json` with the ActivityStreams profile, parsing parameters and header casing correctly. Require a nonempty exact `id` matching the final requested URL. Define any compatibility exceptions explicitly and narrowly. Apply the validator to actors, objects, thread/collection pages, following graphs, and signed-fetch fallbacks.

**Test-first acceptance criteria:** reject `text/html`, generic uploaded `application/json`, missing/invalid content type, missing ID, and mismatched ID; accept the two standard media types with valid parameters.

### F-06 — SSRF checks are not bound to the connection and do not cover all non-global ranges

**Severity:** High  
**Impact:** access to loopback, private services, or cloud metadata through DNS rebinding or overlooked special-use addresses.

`SafeURL.validate_host/1` resolves and validates DNS at `lib/egregoros/safe_url.ex:60-77`, and `Egregoros.DNS.Cached` caches that result for 60 seconds by default (`lib/egregoros/dns/cached.ex:38-93`). Req/Finch then resolves the hostname independently when opening the connection. The validated address is not pinned to the transport, leaving a DNS time-of-check/time-of-use gap. The address classifier at `lib/egregoros/safe_url.ex:107-129` is also a private-range denylist rather than a global-unicast allowlist; multicast, documentation, benchmarking, reserved, and other special-use ranges are not comprehensively excluded.

The implementation does correctly reject IPv4-mapped/compatible IPv6 private addresses and IPv6 `::`, directly covering the defects described by Mastodon's [GHSA-xx55-4rrg-8xg6 / CVE-2026-47389](https://github.com/mastodon/mastodon/security/advisories/GHSA-xx55-4rrg-8xg6) and [GHSA-crr4-7rm4-8gpw / CVE-2026-46348](https://github.com/mastodon/mastodon/security/advisories/GHSA-crr4-7rm4-8gpw). The broader missing-range risk is illustrated by [GHSA-xfrj-c749-jxxq / CVE-2026-22245](https://github.com/mastodon/mastodon/security/advisories/GHSA-xfrj-c749-jxxq).

**Remediation:** resolve once, reject the request unless every candidate address is allowed, choose an allowed address, and connect to that exact IP while preserving the original hostname for TLS SNI and certificate verification. Treat only explicitly global addresses as allowed. Reject URL userinfo and ambiguous/noncanonical numeric host forms. Keep `EGREGOROS_ALLOW_PRIVATE_FEDERATION` off in production and document that enabling it deliberately removes DNS-based SSRF protection.

Redirects are currently disabled globally by `lib/egregoros/http/req.ex:4`, which is the correct default and matches Pleroma's [2025 cross-site redirect fix](https://git.pleroma.social/pleroma/pleroma/-/commit/adb5cb96d38d24d0756fd42e6ae84c4c95c6f758). If redirects are ever enabled, each hop must be same-origin under the chosen policy, re-resolved and pinned, bounded in count, and stripped of credentials/signatures when policy requires. Signed POSTs should not be automatically redirected.

**Test-first acceptance criteria:** use Mox boundaries for DNS and transport to demonstrate an alternating public/private DNS answer cannot change the connected IP. Cover all IANA special-use IPv4/IPv6 classes, mapped addresses, noncanonical numerics, userinfo, and redirect chains. Add an explicit regression test proving 30x responses are not followed today.

### F-07 — Verifiable Credential proofs are not verified

**Severity:** High  
**Impact:** forged badge/credential issuer claims can be persisted and displayed as trusted assertions.

`lib/egregoros/activities/verifiable_credential.ex:34-52` contains an explicit TODO and skips proof verification. `Offer` only requires the offer and credential IDs to share a domain (`lib/egregoros/activities/offer.ex:268-294`); it does not make that equivalently prove the embedded credential issuer controls the outer signed actor.

**Remediation:** introduce a `CredentialProofVerifier` behaviour boundary and require verified proof purpose, verification method/controller, issuer, canonicalized payload, supported suite, temporal validity, and recipient. Bind the issuer/controller to the outer ActivityPub actor or an explicit delegation chain. Unsupported suites must fail closed, not be treated as unsigned credentials.

**Test-first acceptance criteria:** use Mox to assert the verifier contract is called. Reject absent, altered, unsupported, expired, wrong-purpose, wrong-controller, and wrong-recipient proofs; accept only a fixture with a verified supported proof.

### F-08 — Rate limiting is bypassable and deployment proxy identity is ambiguous

**Severity:** High  
**Impact:** concurrency bypass, instance-wide accidental throttling, authentication brute force, and inconsistent limits across a cluster.

`Egregoros.RateLimiter.ETS.bump_counter/3` in `lib/egregoros/rate_limiter/ets.ex:62-77` performs lookup plus insert rather than an atomic counter update, so concurrent requests can lose increments. State is node-local. `RateLimitInbox` keys on `conn.remote_ip` (`lib/egregoros_web/plugs/rate_limit_inbox.ex:45-55`), but no trusted-proxy IP normalization is configured. In the standalone Caddy topology (`docker-compose.standalone.yml:13-28`), the transport peer seen by Bandit appears to be Caddy; absent trusted proxy handling, unrelated federation traffic can share one bucket. Blindly trusting incoming `X-Forwarded-For` would create the opposite bypass. No comparable limiter was found on login, registration, OAuth application registration, authorization, or token endpoints.

This is the same deployment-sensitive trust class highlighted by Mastodon's [GHSA-c2r5-cfqr-c553 / CVE-2023-49952](https://github.com/mastodon/mastodon/security/advisories/GHSA-c2r5-cfqr-c553).

**Remediation:** use an atomic fixed/sliding-window implementation (`:ets.update_counter` with safe window rollover, or a reviewed library) and define cluster semantics. Derive client IP only through an explicit trusted-proxy list and reject/ignore spoofed forwarding headers from untrusted peers. Add separate buckets for IP, verified actor, and remote domain where appropriate. Rate-limit login, registration, OAuth client creation, authorization failures, token issuance/refresh, password reset, and expensive fetch/discovery operations.

**Test-first acceptance criteria:** concurrent tests must never admit more than the configured limit. Cover direct clients, trusted one/multiple-hop proxies, untrusted spoofed headers, Caddy deployment behavior, window rollover, multiple nodes or documented per-node multiplication, and auth endpoint limits.

### F-09 — WebFinger is not bound to the requested account

**Severity:** Medium  
**Impact:** discovery confusion and actor substitution.

`lib/egregoros/federation/webfinger.ex:6-21` decodes any 2xx JSON response and selects any `rel=self` URL. It does not require the returned `subject` to equal the requested normalized `acct:user@domain`, validate the JRD media type, or require an ActivityPub-compatible self-link type. Pleroma addressed this class with its [2024 WebFinger spoofing fix](https://git.pleroma.social/pleroma/pleroma/-/commit/b15f8b06425edbfc3a7cef2a55c609b12ee14377).

**Remediation and tests:** require an exact normalized subject, JRD/JSON content type, one safe self link with an ActivityStreams media type, and then retain the actor fetch's exact-ID check. Test subject, host, Unicode/IDNA, duplicate self links, unsafe URLs, and media-type mismatches.

### F-10 — Federation changes are not durably atomic, ordered, or retry-safe

**Severity:** Medium  
**Impact:** partial ingestion, lost side effects, stale overwrites, resurrection after delete, and difficult incident recovery.

`Pipeline.ingest_with/3` persists through `module.ingest/2` before running side effects (`lib/egregoros/pipeline.ex:20-30`). If a side effect fails, durable state may already exist. `Egregoros.Workers.IngestActivity.perform/1` discards every pipeline error at `lib/egregoros/workers/ingest_activity.ex:14-17`, including potentially transient database/network errors despite `max_attempts: 5`. `Delete` physically removes the target at `lib/egregoros/activities/delete.ex:101-104` rather than leaving a tombstone, so a replay/fetch can resurrect it. F-02 additionally describes missing update ordering.

**Remediation:** make validation and durable state transition one transaction with row locks/constraints. Write an idempotent outbox of post-commit side effects rather than holding a DB transaction open across network delivery. Give errors a permanent-versus-transient taxonomy so Oban retries only transient failures. Store tombstones and return 410/appropriate federation representations; prevent a normal create/fetch from replacing a tombstone without an explicit protocol rule. Record applied activity IDs/version metadata in `Object.internal`, never in canonical external `Object.data`.

**Test-first acceptance criteria:** inject failures before/after persistence, retry jobs, race duplicate deliveries, deliver old/new updates out of order, and attempt resurrection after delete. Assert exactly-once state transitions and at-least-once idempotent side effects.

### F-11 — Private/direct attachments are unauthenticated bearer URLs

**Severity:** Medium  
**Impact:** anyone who obtains a private attachment URL through logs, referrers, browser history, forwarding, or recipient leakage can fetch it without authorization.

`EgregorosWeb.Plugs.Uploads` serves every `/uploads/media/*` path through `Plug.Static` (`lib/egregoros_web/plugs/uploads.ex:28-53`). `Egregoros.MediaStorage.Local` stores all media in the same public tree (`lib/egregoros/media_storage/local.ex:67-79`) without visibility metadata. UUID filenames reduce guessing but do not provide revocation or authorization. This contradicts the completed “Private upload access control” item in `security.md`; that tracking file should not be treated as evidence of the current implementation.

**Remediation:** explicitly choose and document a bearer-URL threat model or implement separate public/private storage with short-lived signed URLs or an authenticated media gateway. Federation complicates recipient authorization; do not place reusable local credentials in federated JSON. For end-to-end encrypted messages, encrypt attachment content client-side and make server URLs ciphertext-only. Add orphan cleanup and revocation.

**Test-first acceptance criteria:** an anonymous client cannot fetch local private/direct plaintext media under the selected model; authorized recipients can; public media remains cacheable; revocation and federation behavior are specified.

### F-12 — Session cookie scope defeats subdomain isolation

**Severity:** Medium  
**Impact:** the session cookie is sent to media and frontend subdomains, increasing exposure and enabling parent-domain cookie tossing after a subdomain compromise.

Runtime session options support a `Domain` attribute (`lib/egregoros_web/plugs/session.ex:24-35`), and `docker-compose.standalone.yml:9-12` sets it to the parent instance domain while deliberately serving media and alternate frontends from subdomains. `HttpOnly` limits JavaScript reads but does not stop those hosts from receiving the cookie or setting a conflicting parent-domain cookie.

**Remediation and tests:** use a host-only cookie, preferably a `__Host-` name with `Secure`, `HttpOnly`, `Path=/`, and an intentional SameSite policy. Remove `EGREGOROS_SESSION_COOKIE_DOMAIN` from the standalone default. Test that requests to `i.`, `fe.`, and `pl-fe.` do not carry the main session cookie and that session renewal/logout still work.

### F-13 — Upload validation trusts client metadata and processes untrusted images in-process

**Severity:** Medium  
**Impact:** decompression/pixel bombs, malformed native-library inputs, incorrect content serving, and resource exhaustion.

`lib/egregoros/media_storage/local.ex:51-64` accepts the client-provided `Plug.Upload.content_type` and maps it to an extension without checking file magic. Images are opened and thumbnailed in the web application process at lines 82-97 without explicit dimensions/pixel-count, decode-time, memory, or concurrency limits. Generated UUID paths avoid the arbitrary output-path problem behind Mastodon's [GHSA-9928-3cp5-93fm / CVE-2023-36460](https://github.com/mastodon/mastodon/security/advisories/GHSA-9928-3cp5-93fm), and `nosniff` headers are a positive control, but decoder attack surface remains.

**Remediation and tests:** detect type from bytes, validate container structure, set decoded pixel/dimension/frame/duration limits, isolate processing in a resource-limited worker, fail closed when thumbnail processing fails for an alleged image, and keep libvips/Vix patched. Test truncated files, type/extension disagreement, high dimensions with tiny compressed size, animation/frame limits, and worker timeout/crash cleanup.

### F-14 — OAuth redirect and token lifecycle validation is incomplete

**Severity:** Medium  
**Impact:** nonstandard/unsafe redirect registrations, indefinitely useful stolen access tokens, and concurrent refresh replay.

Redirect matching is exact, which is good, but `Egregoros.OAuth.Application.validate_redirect_uris/1` (`lib/egregoros/oauth/application.ex:34-49`) only validates list/nonempty shape, not URI scheme, authority, fragment, control characters, or a deliberate native-app policy. Access tokens have no expiry by default (`lib/egregoros/oauth.ex:11-14,410-415`). Refresh rotation creates the new token before revoking the old token at `lib/egregoros/oauth.ex:129-137` without a lock/transaction, allowing concurrent refreshes to mint multiple successors.

**Remediation and tests:** validate absolute HTTPS redirect URIs, with explicit localhost/custom-scheme rules only for public native clients; disallow fragments/userinfo/control characters and require PKCE for public clients. Set finite access-token TTLs. Rotate refresh tokens under a row lock/atomic consumed-at update and revoke the token family on reuse. Test parallel refresh with supervised tasks and SQL-sandbox ownership.

### F-15 — Actor discovery has no per-activity fan-out bound

**Severity:** Medium  
**Impact:** one accepted inbox body can enqueue a large number of actor fetch jobs and outbound requests.

`Egregoros.Federation.ActorDiscovery.actor_ids/1` collects all actor, recipient, and mention entries and `enqueue/2` inserts one job per unique unknown HTTP URL (`lib/egregoros/federation/actor_discovery.ex:10-30,84-115`). No maximum recipient/tag/nested collection count is applied before job creation. Body byte limits alone do not prevent substantial database and network amplification.

**Remediation and tests:** define structural limits for recipients, tags, attachments, nesting depth, collection pages/items, and actor-discovery jobs. Reject or truncate before side effects according to a documented policy. Add per-domain fetch budgets and job uniqueness. Test a maximum-valid activity and one-over-limit activity without creating jobs for rejected input.

### F-16 — No explicit Content Security Policy

**Severity:** Low  
**Impact:** a future sanitizer/template mistake has fewer browser-side containment layers.

Browser pipelines call `put_secure_browser_headers`, but no explicit CSP was found. Add a nonce/hash-based CSP compatible with LiveView and the locally bundled assets, with `object-src 'none'`, constrained `frame-ancestors`, and narrow media/connect sources. Deploy in report-only mode first and test response headers and core LiveView flows.

## Historic advisory comparison

### Pleroma

| Upstream change | Egregoros status |
| --- | --- |
| [Contain remote objects to actor domain (2018)](https://git.pleroma.social/pleroma/pleroma/-/commit/0b2c051a04b3eeb7292f2b847c98fcbafbb20ed2) and [IR-level containment (2019)](https://git.pleroma.social/pleroma/pleroma/-/commit/739bbe0d3bbe06ca9d634498ea5909f35fc5ad84) | **Missing as a global invariant**; see F-01. |
| [Only the actor may update (2020)](https://git.pleroma.social/pleroma/pleroma/-/commit/75670a99e46a09f9bddc0959c680c2cb173e1f3b), later [same-origin update allowance (2022)](https://git.pleroma.social/pleroma/pleroma/-/commit/547def67a76854aa4c9c8438eb1ee4dfa36fd8ac) | Replacement payload is bound to the updater, but stored owner is not checked; same-origin peer takeover remains. See F-02. |
| [Validate ActivityStreams response content type (2020)](https://git.pleroma.social/pleroma/pleroma/-/commit/6ca709816f74f1171423c7bc040619fca57a2087) | **Missing**; see F-05. |
| [Prevent WebFinger spoofing (2024)](https://git.pleroma.social/pleroma/pleroma/-/commit/b15f8b06425edbfc3a7cef2a55c609b12ee14377) | **Missing subject binding**; see F-09. |
| [Do not follow cross-site object redirects (2025)](https://git.pleroma.social/pleroma/pleroma/-/commit/adb5cb96d38d24d0756fd42e6ae84c4c95c6f758) | **Pass:** all Req redirects are disabled. Add a regression test and preserve the invariant. |

### Mastodon

| Advisory | Egregoros status |
| --- | --- |
| [GHSA-3fjr-858r-92rw / CVE-2024-23832](https://github.com/mastodon/mastodon/security/advisories/GHSA-3fjr-858r-92rw), remote impersonation through an ID comparison error | Exact fetched actor/object ID checks are present, but inbox namespace poisoning and stored-owner update authorization remain (F-01/F-02). |
| [GHSA-jhrq-qvrm-qr36 / CVE-2024-25623](https://github.com/mastodon/mastodon/security/advisories/GHSA-jhrq-qvrm-qr36), missing ActivityStreams media-type validation | **Affected by the same class**; see F-05. |
| [GHSA-xfrj-c749-jxxq / CVE-2026-22245](https://github.com/mastodon/mastodon/security/advisories/GHSA-xfrj-c749-jxxq), incomplete disallowed address ranges | Current denylist is incomplete and should become a global-address allowlist; see F-06. |
| [GHSA-xx55-4rrg-8xg6 / CVE-2026-47389](https://github.com/mastodon/mastodon/security/advisories/GHSA-xx55-4rrg-8xg6), IPv4-mapped IPv6 SSRF | **Pass for known mapped private forms** in `SafeURL`; retain regression coverage. DNS pinning remains missing. |
| [GHSA-crr4-7rm4-8gpw / CVE-2026-46348](https://github.com/mastodon/mastodon/security/advisories/GHSA-crr4-7rm4-8gpw), IPv6 unspecified-address SSRF | **Pass for `::`**; retain regression coverage. |
| [GHSA-9928-3cp5-93fm / CVE-2023-36460](https://github.com/mastodon/mastodon/security/advisories/GHSA-9928-3cp5-93fm), arbitrary file creation through media | No attacker-chosen destination path was found. Media validation/resource isolation still needs F-13. |
| [GHSA-ccm4-vgcc-73hp / CVE-2023-36459](https://github.com/mastodon/mastodon/security/advisories/GHSA-ccm4-vgcc-73hp), oEmbed XSS | No oEmbed/unfurl fetch path was found; remote HTML is sanitized before `raw`. Add CSP as F-16. |
| [GHSA-c2r5-cfqr-c553 / CVE-2023-49952](https://github.com/mastodon/mastodon/security/advisories/GHSA-c2r5-cfqr-c553), proxy-header rate-limit bypass/misconfiguration | Proxy-aware client identity is not configured; see F-08. |

## Verified positive controls

These controls should be locked in with regression tests while remediation proceeds:

- `Egregoros.HTTP.Req` sets `redirect: false`, a 5-second receive timeout, and a 1 MB response cap; all direct `Req` use found in the application flows through this module.
- Remote top-level activities cannot use the local instance namespace (`Pipeline.validate_namespace/2`).
- Fetched actor JSON must exactly match the requested actor URL (`Federation.Actor.to_user_attrs/2`).
- The verified HTTP-signature key owner is compared with the outer `actor`/`attributedTo` (`EgregorosWeb.Plugs.VerifySignature`).
- `Undo` and `Delete` side effects require exact stored actor equality.
- Common loopback, RFC1918, link-local, carrier-grade NAT, IPv4-mapped/compatible IPv6 private addresses, IPv6 unique-local/link-local, `::`, and `::1` are rejected by default.
- Remote rendered HTML flows reviewed before `Phoenix.HTML.raw/1` pass through the sanitizer; no oEmbed fetch/render path was found.
- Upload destinations use server-generated UUID names rather than client-controlled paths, and upload responses carry `nosniff`/frame-denial headers.
- OAuth bearer and refresh tokens are stored as digests, redirect URI use is exact-match, sessions are renewed on authentication, and production cookies are configured secure.
- `mix hex.audit` reported **“No retired packages found”** on 2026-07-10. This is not a complete vulnerability scan and should not be interpreted as one.

## Remediation plan

All implementation work should follow the repository's TDD rule: add the smallest failing exploit/regression test first, confirm the failure, implement the invariant, then run the focused tests plus `mix format` and `mix precommit`. Prefer upstream Pleroma fixtures from `test/fixtures`. Introduce behaviour boundaries and Mox where the eventual implementation depends on DNS/transport, credential proof verification, or other future/external behavior.

### Phase 0 — Freeze invariants and add exploit tests

1. Add failing tests for F-01 through F-06 before changing behavior.
2. Add passing lock-in tests for redirects disabled, fetched ID equality, local namespace rejection, Undo/Delete actor equality, IPv4-mapped IPv6 blocking, `::` blocking, and response size limits.
3. Create an authorization matrix document/test table for each supported ActivityPub type: creator, ID authority, object owner, target, required prior state, permitted transition, and inbox target.

### Phase 1 — Central ActivityPub authority and transition authorization

1. Implement the central authority policy from F-01.
2. Fix stored-owner authorization and version ordering for every `Update` path (F-02).
3. Require exact stored prior-state correlation for Follow/Offer Accept/Reject (F-03).
4. Audit every side-effecting type (`Create`, `Update`, `Delete`, `Undo`, `Accept`, `Reject`, `Add`, `Remove`, `Like`, `Announce`, `EmojiReact`, `Offer`, credential types) against the matrix.

**Exit gate:** no remote activity can create an identity claim outside its permitted authority or mutate/transition an object it does not exactly control.

### Phase 2 — Signed request integrity

1. Make body digest, request target, host, and date mandatory for inbox POST signatures (F-04).
2. Define trusted proxy handling once and share it between signature reconstruction, HTTPS enforcement, logs, and rate limiting.
3. Add replay/body/path/host substitution tests and compatibility telemetry.

**Exit gate:** changing any authorization-relevant request byte or destination invalidates the signature.

### Phase 3 — Fetch provenance and SSRF transport

1. Add the central ActivityStreams response validator and strict ID requirement (F-05).
2. Fix WebFinger subject/type binding (F-09).
3. Introduce a DNS-resolve/connect transport boundary, pin the validated IP, and use a global-address allowlist (F-06).
4. Preserve redirects-off and test it. If a later interoperability decision enables redirects, implement the per-hop policy before changing the default.

**Exit gate:** the bytes accepted as an ActivityPub object came from the exact validated authority over a connection to the validated public IP and with an ActivityStreams media type.

### Phase 4 — Credential and abuse boundaries

1. Introduce and enforce the Mox-backed credential proof verifier (F-07).
2. Replace non-atomic counters, configure trusted proxies, define cluster semantics, and protect auth endpoints (F-08).
3. Bound actor discovery and all collection/recipient fan-out (F-15).

**Exit gate:** unsigned/forged credentials fail closed, and a single unauthenticated source cannot create unbounded work or bypass configured limits through concurrency/proxy headers.

### Phase 5 — Durable federation correctness

1. Separate transactional state transitions from idempotent post-commit jobs (F-10).
2. Add permanent/transient error types and allow Oban to retry transient ingestion failures.
3. Add tombstones and monotonic update/version handling.

**Exit gate:** duplicate, concurrent, out-of-order, failed, and retried delivery produces one deterministic state and retry-safe side effects.

### Phase 6 — Session, media, and OAuth hardening

1. Decide and implement the private-media confidentiality model (F-11).
2. Move to a host-only `__Host-` session cookie and remove the parent-domain default (F-12).
3. Isolate and bound media processing (F-13).
4. Validate OAuth redirect URI classes, require PKCE where appropriate, set token TTLs, and make refresh rotation atomic (F-14).
5. Deploy an explicit CSP in report-only mode, then enforce it after resolving violations (F-16).

### Phase 7 — Regression and operational verification

1. Run focused tests after each finding, then the full `mix precommit` coverage gate.
2. Add federation-box adversarial cases for cross-origin IDs, redirect responses, wrong media types, DNS rebinding, and out-of-order transitions.
3. Add structured security telemetry for rejected authority, signature, content-type, SSRF, and rate-limit decisions without logging secrets or private object bodies.
4. Reconcile or replace `security.md` so completed checkboxes correspond to executable regression tests.
5. Repeat the advisory comparison and dependency audit before the next public release.

## Verification performed

- Focused HTTP, URL-safety, signature, update, accept, delete, and undo regression suite: **61 tests, 0 failures**.
- Repository-required `mix format`: passed.
- Repository-required `mix precommit`: **3 JavaScript tests and 2,047 ExUnit tests passed with 0 failures**; total Elixir coverage was **85.03%**, above the 85% gate.
- `mix hex.audit`: **No retired packages found**.

## Audit limitations

- This was a source and test audit, not a production penetration test. No live deployment, cloud metadata endpoint, reverse-proxy chain, or multi-node cluster was attacked.
- The upstream `../pleroma` path named by the repository instructions was not present. Historic Pleroma references were verified against the available `../spc-pleroma` checkout and its `upstream` history.
- `mix hex.audit` checks retired Hex packages; it does not cover every CVE in Erlang/OTP, native libraries such as libvips, container images, Caddy, PostgreSQL, operating-system packages, or JavaScript transitive dependencies.
- Cryptographic implementations were reviewed for call-site authorization and configuration, not formally verified.
- The focused existing security/federation suite passed: **61 tests, 0 failures**. Those tests do not currently encode the exploit cases in F-01 through F-06, which is why Phase 0 begins there.
