# Mini-app ActivityPub messages: implementer's guide

> Status: public ActivityPub publishing can be implemented independently today.
> Egregoros parses and immutably persists the mini-app actor declaration and
> notification-consent decisions. The SDK and broker implement the typed
> permission transport, and the host implements OAuth-gated state reads,
> confirmation, persistence, and revocation UI. The OAuth-authenticated backend
> permission endpoint, actor-document activation, and inbound
> transactional-message consent enforcement are available.

This guide defines the smallest useful ActivityPub service a mini-app developer
can operate for two distinct purposes:

1. **Public messages** published by an app-owned actor for followers and the
   public Fediverse.
2. **Transactional messages** delivered as non-public notes that mention one
   user who explicitly consented to messages from that exact mini app and
   actor.

These are ActivityPub messages, not browser push notifications. Delivery may be
delayed, duplicated, rejected, or filtered like any other federated activity.
An accepted inbox response is not proof that a person saw a notification.

## 1. One actor per mini app

Operate one stable `Application` or `Service` actor for the app, not one actor
per customer. For example:

```text
Actor:  https://weather.example/ap/actor
Handle: @weather@weather.example
```

Using a normal actor lets users inspect, follow, mute, or block the application
with existing Fediverse controls. Keep its private signing key and all OAuth
tokens on the app backend; neither belongs in iframe JavaScript.

The smallest interoperable actor service exposes:

| Route | Minimum behavior |
| --- | --- |
| `GET /.well-known/webfinger?resource=acct:weather@weather.example` | Returns the actor URL. |
| `GET /ap/actor` | Returns the actor document and public key. |
| `POST /ap/inbox` | Accepts only the small inbound control-plane allowlist described below. |
| `GET /ap/outbox` | Returns an `OrderedCollection`; pagination is strongly recommended. |
| `GET /ap/followers` | Returns or identifies the actor's follower collection. |
| `GET /ap/activities/{id}` | Dereferences public activities. |
| `GET /ap/notes/{id}` | Dereferences public notes. Private transactional notes must not be exposed publicly. |

The actor document is approximately:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://w3id.org/security/v1"
  ],
  "id": "https://weather.example/ap/actor",
  "type": "Application",
  "preferredUsername": "weather",
  "name": "Weather Alerts",
  "inbox": "https://weather.example/ap/inbox",
  "outbox": "https://weather.example/ap/outbox",
  "followers": "https://weather.example/ap/followers",
  "publicKey": {
    "id": "https://weather.example/ap/actor#main-key",
    "owner": "https://weather.example/ap/actor",
    "publicKeyPem": "-----BEGIN PUBLIC KEY-----..."
  }
}
```

For meaningful public distribution the service is not literally write-only.
It must accept `Follow` and matching `Undo` activities, verify their HTTP
signatures, maintain a follower list, and send a signed `Accept` for each valid
follow. It may reject every other inbound activity. Without this small inbound
control plane, public notes can be dereferenced but do not have an audience to
which the app can deliver them.

## 2. Public messages

A public message is an ordinary `Create` containing a public `Note`. Address it
to both the ActivityStreams Public collection and the actor's followers:

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://weather.example/ap/activities/01JXYZ",
  "type": "Create",
  "actor": "https://weather.example/ap/actor",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://weather.example/ap/followers"],
  "published": "2026-07-11T12:00:00Z",
  "object": {
    "id": "https://weather.example/ap/notes/01JXYZ",
    "type": "Note",
    "attributedTo": "https://weather.example/ap/actor",
    "to": ["https://www.w3.org/ns/activitystreams#Public"],
    "cc": ["https://weather.example/ap/followers"],
    "published": "2026-07-11T12:00:00Z",
    "content": "<p>Heavy rain is expected across the region this evening.</p>",
    "url": "https://weather.example/updates/01JXYZ"
  }
}
```

Store the activity and note before delivery. Add the activity to the outbox,
deduplicate followers by shared inbox where safe, and enqueue signed deliveries
with bounded exponential retry. Public notes and activities must remain
dereferenceable at their stable IDs.

Public messages in this profile must not tag or address an individual as a way
to obtain a notification. A public app announcement can be followed normally;
an individualized alert uses the transactional flow below.

## 3. Declare transactional-message support

The v1 manifest accepts one immutable declaration:

```json
"activityPub": {
  "actorUrl": "https://weather.example/ap/actor",
  "publicNotes": true,
  "transactionalMentions": true
}
```

This is the currently implemented draft shape. The provenance/purpose revision
below replaces `transactionalMentions` with immutable `mentionPurposes`; the
legacy Boolean maps only to the transactional purpose.

`actorUrl` must be an HTTPS URL on the manifest's exact origin. Egregoros must
fetch it through the same SSRF-safe fetch boundary used for other mini-app
resources and verify that:

- the document is an `Application` or `Service` actor;
- its `id` exactly equals `actorUrl`;
- its public-key owner is that same actor;
- its inbox, outbox, followers, and key URLs are HTTPS and pass URL policy; and
- the declaration remains immutable for the app identity.

The complete machine-readable definition is
[`docs/schemas/fediverse-miniapp-manifest-v1.schema.json`](docs/schemas/fediverse-miniapp-manifest-v1.schema.json).
JSON Schema cannot compare URL origins, so the Egregoros parser remains
authoritative for exact-origin checks.

The declaration is persisted inactive. A unique background job fetches the
actor with public-DNS pinning, no redirects, a 64 KiB limit, and an
ActivityStreams JSON content type. It accepts only an `Application` or `Service`
with the exact declared ID, same-origin inbox/outbox/followers/key URLs, an exact
key owner, and a valid RSA public key of at least 2048 bits. A SHA-256
fingerprint of those security fields is then pinned; later declaration checks
do not silently refetch or repin it. Transactional permission and inbound
delivery remain disabled until activation succeeds.

### 3.1 Mini-app provenance and message purpose wire profile

> Design status: normative proposal for the next protocol revision; the current
> parser, manifest schema, SDK, permission storage, and endpoint do not
> implement this revision yet. The final namespace IRI must be assigned before
> release. Examples use the reserved `fediverse.example` domain as a
> placeholder.

An ActivityStreams object produced by a mini app carries an explicit mini-app
provenance marker. The marker is independent of whether the object is a direct
notification:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "fma": "https://fediverse.example/ns/miniapps#"
    }
  ],
  "fma:miniApp": {
    "id": "https://weather.example/.well-known/fediverse-miniapp.json"
  }
}
```

`fma:miniApp` identifies the app by its canonical well-known manifest URL, not
by display name, `homeUrl`, launch URL, or an arbitrary publisher URL. The
inline `fma` mapping is self-contained; it is not a remote context URL and
receivers must not fetch the namespace IRI while processing an activity.
The wire profile requires this exact prefix mapping. A conflicting `fma`
mapping, a remote context substituted for it, or a merely JSON-LD-equivalent
alternate spelling is invalid; this keeps validation deterministic for
ActivityPub implementations that process ordinary JSON.

The marker is a claim, not proof. Egregoros treats an object as app-produced
only when all of these independently agree:

- `fma:miniApp.id` is the exact canonical manifest URL for a persisted
  declaration;
- the activity and object actor are the exact actor declared by that manifest;
- the HTTP signature matches the declaration's activated key ID and key
  fingerprint;
- the manifest origin and actor remain permitted by current instance policy;
  and
- the `Create` and embedded object contain identical markers.

A third-party actor cannot become a mini app merely by copying the context or
marker. Missing, malformed, conflicting, array-valued, redirected, or
non-canonical markers fail closed for features that require mini-app
provenance.

For v1, Egregoros recognizes the marker on app-authored `Note` objects and
their enclosing `Create` activities. The vocabulary may later apply to other
ActivityStreams objects, but that does not automatically authorize new object
types or side effects. When a `Note` is dereferenced independently, its
standalone representation includes the same ActivityStreams and inline `fma`
context.

#### Explicit mini-app launch-link hint

An ordinary public `Note` may identify one exact visible link as a candidate
mini-app launch URL by adding `fma:miniAppLink`. This is a discovery hint, not
an authorship claim:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "fma": "https://fediverse.example/ns/miniapps#"
    }
  ],
  "id": "https://social.example/users/alice/statuses/01JLINK",
  "type": "Note",
  "attributedTo": "https://social.example/users/alice",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "content": "<p>Vote in <a href=\"https://polls.example/questions/42?round=final\">this poll</a>.</p>",
  "fma:miniAppLink": {
    "type": "Link",
    "href": "https://polls.example/questions/42?round=final",
    "rel": "https://fediverse.example/ns/miniapps#miniApp",
    "mediaType": "text/html",
    "name": "Open poll"
  }
}
```

The mini-app vocabulary and its eventual dereferenceable JSON-LD context
define `miniAppLink` with the expanded IRI
`https://fediverse.example/ns/miniapps#miniAppLink`. The wire representation
continues to carry the exact inline `fma` prefix mapping shown above, so
receivers never need to fetch a remote context while processing a delivery.
The namespace remains provisional until a permanent, controlled IRI and its
context document are published.

The dereferenceable namespace document serves an HTML vocabulary description
for browsers and, under `application/ld+json`, a stable context containing at
least these definitions (with the placeholder replaced by the permanent
namespace at publication):

```json
{
  "@context": {
    "fma": {
      "@id": "https://fediverse.example/ns/miniapps#",
      "@prefix": true
    },
    "miniApp": "fma:miniApp",
    "notificationPurpose": "fma:notificationPurpose",
    "miniAppLink": "fma:miniAppLink"
  }
}
```

The context establishes identifier expansion only. It cannot encode the
authorization, cardinality, closed-enum, exact-URL, or validation rules in this
profile; the human-readable vocabulary document and this specification remain
normative for those meanings. Publishing the context does not change the wire
rule: deliveries use the inline prefix and receivers do not dereference it in
the activity-processing path.

The two link-shaped mini-app properties have intentionally different meanings:

- `fma:miniApp` says the object itself claims to have been produced by the
  identified mini app. It is accepted only with the manifest, actor, signature,
  key pin, and policy checks above.
- `fma:miniAppLink` says only that the containing `Note` presents the identified
  URL as a candidate mini-app launch link. Any actor may share such a link; the
  actor does not become the app and need not control or sign for it.

For version 1, `fma:miniAppLink` is one object, never an array, with this closed
shape:

- `type` is exactly the ActivityStreams `Link` type;
- `href` is the exact HTTPS launch URL, including its path, query string, and
  non-default port when present;
- `rel` is exactly the full vocabulary IRI
  `https://fediverse.example/ns/miniapps#miniApp`, expressing the link's
  purpose within this `Note`;
- `mediaType` is exactly `text/html`; and
- optional `name` is a bounded, untrusted accessibility/display hint. It does
  not replace title or presentation metadata fetched from the app.

Unknown properties, arrays where scalars are required, duplicate JSON keys,
overlong values, or conflicting values make the hint invalid. The hint belongs
on the `Note`, not its enclosing `Create`, because `rel` describes the link's
relationship to its immediate containing object. The enclosing activity's
context may cover an embedded `Note`; a separately dereferenced `Note` includes
the ActivityStreams and inline `fma` contexts itself.

The full IRI is deliberate: the standard ActivityStreams context defines
`rel` as a literal value rather than an `@id`-coerced value, so a compact string
such as `fma:miniApp` would not expand during JSON-LD processing. The eventual
published mini-app JSON-LD context and vocabulary documentation therefore list
all three terms, while this wire profile uses prefixed property names and the
full IRI when a vocabulary term appears as a `rel` value:

| Term | Expanded IRI | Range and meaning |
| --- | --- | --- |
| `fma:miniApp` | `…#miniApp` | One canonical manifest identity object; app-production provenance. |
| `fma:notificationPurpose` | `…#notificationPurpose` | Optional scalar `transactional` or `promotional` classification. |
| `fma:miniAppLink` | `…#miniAppLink` | One ActivityStreams `Link`; exact candidate launch-link discovery hint. |

Here `…` abbreviates the provisional namespace base only in this explanatory
table; it is never legal wire syntax.

The hint is never proof that the target is a mini app, is controlled by the
sender, is safe, or should be framed. Before making any target-origin request,
a receiver validates all of the following:

- mini-app discovery is enabled and the `Note` is completely public;
- the exact inline namespace mapping and bounded `Link` shape are valid;
- `href` has an allowed HTTPS URL shape: no userinfo, fragment, IP literal,
  localhost name, or unsafe port;
- the exact `href` also occurs as a candidate derived from the sanitized note
  content, either as a parsed anchor destination or an otherwise eligible plain
  HTTPS URL; and
- current instance domain policy permits the target host.

For that comparison, exact means the content-derived URL after HTML entity
decoding but before URL normalization. A receiver must not replace it with the
app `homeUrl`, strip or reorder its query, assume `/`, substitute another
same-origin path, or follow a redirect to make it match. A direct link to
`/.well-known/fediverse-miniapp.json` does not qualify because `href` identifies
the HTML launch page. The receiver derives the exact URL origin and constructs
the fixed well-known manifest URL itself; the sender cannot nominate a
different manifest location.

A valid explicit hint receives priority within the ordinary rich-card discovery
algorithm; it does not create a second fetch allowance:

1. consider the valid `fma:miniAppLink.href` first;
2. consider the remaining eligible content URLs in document order;
3. deduplicate exact URLs;
4. apply the same existing per-note candidate limit to the combined sequence;
5. stop at the first independently validated mini app and render at most one
   mini-app card; and
6. count malformed or abusive hints against the same source and target rate
   controls rather than granting another discovery budget.

An invalid hint does not invalidate or hide the `Note`. The receiver ignores
the hint, may continue ordinary content scanning within the one shared budget,
and otherwise renders an ordinary link. Fetch scheduling also applies bounded
timeouts, circuit breakers, per-source/per-author/per-target-origin/global
limits, and negative caching for permanent failures. Duplicate metadata,
duplicate deliveries, and repeated candidate URLs must not multiply fetches.
An `Update` triggers rediscovery only when the exact candidate URL changed or
the cached result independently requires revalidation.

A supporting authoring server should emit this hint only after it has parsed
the exact visible link, completed its own mini-app validation, and shown the
resulting card to the author. If validation is incomplete or fails, it emits an
ordinary link without the hint. Downstream servers always repeat their own
validation; they do not transitively trust the authoring server's assertion.

#### Optional notification purpose

An app-produced object may additionally carry exactly one purpose label:

```json
"fma:notificationPurpose": "transactional"
```

or:

```json
"fma:notificationPurpose": "promotional"
```

The field is a scalar closed enum. It cannot contain an array, both values, a
custom value, or a default inferred from content. `Create` and embedded `Note`
must either both omit it or contain the same value.

The classifications are:

- `transactional`: caused by a user action, configured subscription, requested
  job, or necessary account/service event;
- `promotional`: intended to advertise, recommend, announce, re-engage, or
  drive a new action; and
- absent: app-produced content that is not a direct mini-app notification.

Content combining operational and promotional material must be labeled
`promotional`. Egregoros does not attempt to infer or verify this semantic
classification from prose. The label selects a permission and supplies
moderation evidence; user reports and instance policy determine whether a
sender is abusing it.

Purpose and addressing rules are strict:

- a public app-authored note with no individual recipient or `Mention` has the
  provenance marker and omits `fma:notificationPurpose`;
- a note with either purpose is non-public, has exactly one recipient and one
  matching `Mention`, and is delivered to that actor's personal inbox;
- a direct mini-app mention without a recognized purpose is suppressed;
- a public mini-app note containing an individual `Mention` is suppressed;
- transactional permission never implies promotional permission, and
  promotional permission never implies transactional permission; and
- following the app actor grants neither direct-message permission.

Complete public example:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "fma": "https://fediverse.example/ns/miniapps#"
    }
  ],
  "id": "https://weather.example/ap/activities/01JPUBLIC",
  "type": "Create",
  "actor": "https://weather.example/ap/actor",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://weather.example/ap/followers"],
  "fma:miniApp": {
    "id": "https://weather.example/.well-known/fediverse-miniapp.json"
  },
  "object": {
    "id": "https://weather.example/ap/notes/01JPUBLIC",
    "type": "Note",
    "attributedTo": "https://weather.example/ap/actor",
    "to": ["https://www.w3.org/ns/activitystreams#Public"],
    "cc": ["https://weather.example/ap/followers"],
    "fma:miniApp": {
      "id": "https://weather.example/.well-known/fediverse-miniapp.json"
    },
    "content": "<p>Heavy rain is expected across the region.</p>"
  }
}
```

Complete direct example:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "fma": "https://fediverse.example/ns/miniapps#"
    }
  ],
  "id": "https://weather.example/ap/activities/01JTXN",
  "type": "Create",
  "actor": "https://weather.example/ap/actor",
  "to": ["https://social.example/users/alice"],
  "fma:miniApp": {
    "id": "https://weather.example/.well-known/fediverse-miniapp.json"
  },
  "fma:notificationPurpose": "transactional",
  "object": {
    "id": "https://weather.example/ap/notes/01JTXN",
    "type": "Note",
    "attributedTo": "https://weather.example/ap/actor",
    "to": ["https://social.example/users/alice"],
    "fma:miniApp": {
      "id": "https://weather.example/.well-known/fediverse-miniapp.json"
    },
    "fma:notificationPurpose": "transactional",
    "content": "<p>Heavy rain is expected near you in 30 minutes.</p>",
    "tag": [{
      "type": "Mention",
      "href": "https://social.example/users/alice",
      "name": "@alice@social.example"
    }]
  }
}
```

The same shape with `promotional` requires the separate promotional grant.

#### Manifest declaration and permissions

The purpose split replaces the single-purpose Boolean in the next manifest
revision:

```json
"activityPub": {
  "actorUrl": "https://weather.example/ap/actor",
  "publicNotes": true,
  "mentionPurposes": ["transactional", "promotional"]
}
```

`mentionPurposes` is a de-duplicated immutable subset of the two known values.
An app cannot request or send a purpose it did not declare. Each declared
purpose has an independent SDK permission, backend permission check, stored
user decision, revocation control, operator override, and audit value. Delivery
audits record both the sender-declared purpose and the effective purpose after
any administrator override.

The permission API always takes an explicit purpose. Missing or unknown
purposes fail closed and never fall back to `transactional`. Existing draft
`transactionalMentions: true` data is equivalent only to
`mentionPurposes: ["transactional"]`; it never grants promotional permission.

## 4. Consent is a separate capability

Notification consent must not be inserted into `getContext()`. Launch context
describes the fully public note and exact URL that launched the app. Mixing a
user-specific permission into it would weaken that deliberately narrow data
boundary and would make unauthenticated context calls reveal account state.

The proposed SDK instead exposes a separate surface:

```ts
type NotificationPermissionState = "prompt" | "granted" | "denied"
type NotificationPurpose = "transactional" | "promotional"

sdk.notifications.getPermission({
  purpose: "transactional"
}): Promise<{
  state: NotificationPermissionState
  purpose: NotificationPurpose
  actorUrl: string
}>

sdk.notifications.requestPermission({
  purpose: "transactional"
}): Promise<{
  state: "granted" | "denied"
  purpose: NotificationPurpose
  actorUrl: string
}>
```

`getPermission()` also requires OAuth and the immutable actor declaration, but
does not require a user gesture and never opens a prompt. It returns `prompt`
when the user has not made a current choice, `granted` only for an active
grant, and `denied` after an explicit refusal. Before OAuth it fails with an
authentication-required error rather than revealing permission state.

`requestPermission()` requires all of the following:

- a currently authenticated mini-app OAuth grant;
- the requested purpose in the manifest's immutable `mentionPurposes`
  declaration;
- a current iframe user gesture;
- an active exact-origin broker channel; and
- a host-owned confirmation that names both the app domain and ActivityPub
  actor.

Each grant is stored by Egregoros against the local user, exact app origin,
exact declared actor URL, and exact purpose. Transactional and promotional
decisions are independent of each other and of launch-context, OAuth, compose,
and wallet consent. OAuth revocation, app-domain denial, actor-declaration
invalidation, or account deletion also disables both message permissions.
The SDK response intentionally contains no user actor URL, inbox URL, bearer
token, signing secret, or reusable proof. It is suitable for rendering iframe
UI, not for authorizing backend delivery.

## 5. Authoritative backend permission check

The app backend identifies the user through its existing OAuth `read` grant.
After the host-owned SDK confirmation, it calls the Egregoros endpoint
with that user's bearer token:

```http
GET /api/v1/mini-apps/notification-permission?purpose=transactional
Authorization: Bearer ACCESS_TOKEN
```

An authorized response is deliberately small:

```json
{
  "state": "granted",
  "purpose": "transactional",
  "recipientActor": "https://social.example/users/alice",
  "appActor": "https://weather.example/ap/actor"
}
```

The endpoint derives the app identity from the OAuth client registration; the
caller cannot select another mini-app origin or actor. It returns the requested
purpose and `state: "denied"` without a recipient actor when no current grant
exists. Missing or unknown purposes are invalid requests.

Before enqueueing a purpose-labeled message, the backend must have observed a
current `granted` result for that recipient and exact purpose. A short cache may
reduce requests, but it creates a revocation window; the receiving Egregoros
instance therefore enforces the grant again at inbox processing time. No
webhook or push token is required for the minimum design.

## 6. Purpose-labeled direct messages

A transactional or promotional message is a non-public `Create(Note)`
addressed to exactly one actor who granted that purpose. It includes exactly
one matching `Mention` tag. This example is transactional:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "fma": "https://fediverse.example/ns/miniapps#"
    }
  ],
  "id": "https://weather.example/ap/activities/01JTXN",
  "type": "Create",
  "actor": "https://weather.example/ap/actor",
  "to": ["https://social.example/users/alice"],
  "fma:miniApp": {
    "id": "https://weather.example/.well-known/fediverse-miniapp.json"
  },
  "fma:notificationPurpose": "transactional",
  "published": "2026-07-11T12:30:00Z",
  "object": {
    "id": "https://weather.example/ap/notes/01JTXN",
    "type": "Note",
    "attributedTo": "https://weather.example/ap/actor",
    "to": ["https://social.example/users/alice"],
    "fma:miniApp": {
      "id": "https://weather.example/.well-known/fediverse-miniapp.json"
    },
    "fma:notificationPurpose": "transactional",
    "published": "2026-07-11T12:30:00Z",
    "content": "<p><a href=\"https://social.example/@alice\">@alice</a> Heavy rain is expected near you in 30 minutes.</p>",
    "tag": [{
      "type": "Mention",
      "href": "https://social.example/users/alice",
      "name": "@alice@social.example"
    }]
  }
}
```

Direct-message constraints are strict:

- no ActivityStreams Public audience in `to`, `cc`, `bto`, or `bcc`;
- exactly one recipient and one matching mention;
- identical canonical mini-app marker and recognized purpose on `Create` and
  `Note`;
- the sender is the exact actor declared by the mini app;
- content and link targets are bounded and human-readable;
- the destination is the recipient's personal inbox, not a shared inbox;
- each logical event has one stable activity ID for retry deduplication; and
- the activity is never added to the public outbox, and its private activity
  and note IDs return no content to unauthenticated fetches.

The receiving Egregoros instance verifies the normal ActivityPub signature and
authorization rules, resolves the sender to a current mini-app declaration,
and checks both the local recipient's current notification consent and active
OAuth grant. For a declared actor, the HTTP signature key ID and RSA public-key
fingerprint must exactly match the activated pin; a later actor refetch or key
rotation cannot silently replace it. Without all checks it does not persist the
activity or note and therefore cannot create a notification or direct-message
timeline item. The inbound worker still returns a non-oracular success so
revocation does not become a remote account-state probe.

This receiver check is the decisive safety boundary: a stale or malicious app
cannot restore revoked user-visible notifications merely by continuing to send
signed mentions. Other Fediverse servers that do not implement this extension
will treat the activity as an ordinary direct mention and cannot provide the
same guarantee.

## 7. Delivery, abuse, and privacy requirements

The sender must:

- rediscover recipient actor/inbox URLs through an SSRF-safe client;
- sign deliveries with the declared app actor's backend-only key;
- use a durable bounded queue, idempotent IDs, timeouts, retry limits, and
  per-user/per-origin/global rate limits;
- send only template-controlled or strictly bounded content;
- never accept an arbitrary recipient or inbox from iframe input;
- stop enqueueing immediately after permission becomes denied;
- provide app-side notification categories and unsubscribe controls; and
- avoid putting OAuth tokens, private content, signing material, or recipient
  lists in URLs, logs, analytics, public outboxes, or public object endpoints.

The receiving host must apply normal federation signature, actor, content,
size, rate, block, and domain-policy checks before its consent check. Consent is
necessary but never sufficient to bypass moderation or abuse controls.

### Reporting mislabeled messages

Purpose is sender-declared and cannot be proven from message content. Every
accepted purpose-labeled message therefore exposes a **Report mini-app
message** action. A report contains the exact app origin, manifest URL, actor,
declared purpose, local object reference, user-selected reason, and optional
comment. Message content is shared with the local administrator only because
the user explicitly submits that report; it is never copied into automatic
notification audits.

Instances define their own classification and abuse rules. An administrator
may dismiss or record the report, disable one purpose, disable all direct
mentions, block the actor or app domain, or apply an origin-level override that
treats messages labeled `transactional` as `promotional`. That override is
monotonic: it may require the stronger/different promotional grant, but it must
never let a promotional message use transactional consent. Reports do not
automatically punish an app, and users may independently revoke either purpose
at any time.

## 8. Minimal implementation checklist

### Public-only producer

- [ ] Stable `Application` or `Service` actor and signing key.
- [ ] WebFinger, actor, inbox, outbox, followers, activity, and note routes.
- [ ] Verified `Follow`/`Undo` handling and signed `Accept` delivery.
- [ ] Public `Create(Note)` with stable IDs and consistent addressing.
- [ ] Durable signed delivery queue with retry and deduplication.
- [ ] Public activity and note dereferencing.
- [ ] Mute/block compatibility and operator contact information.

### Purpose-labeled mentions

- [ ] Everything required for the actor and signed delivery boundary above.
- [x] Immutable mini-app actor declaration and host-side actor activation.
- [ ] OAuth `read` grant used server-side to identify the recipient.
- [ ] Separate host-owned notification confirmation completed from a gesture.
- [ ] Authoritative backend permission check returns `granted` before enqueue.
- [ ] Independent transactional and promotional decisions and revocation.
- [ ] Exact mini-app provenance marker on `Create` and `Note`.
- [ ] Exact matching purpose on `Create` and `Note`.
- [ ] Exactly one non-public recipient and matching `Mention` tag.
- [ ] Delivery to the personal inbox only.
- [ ] Private activity/note IDs do not disclose content publicly.
- [ ] Sender-side unsubscribe and immediate enqueue suppression.
- [x] Receiver-side current-consent and OAuth enforcement with immediate revocation.
- [x] Adversarial tests for forged recipients, stale grants, replay, SSRF,
      signature failure, public-audience smuggling, rate abuse, and post-revoke
      delivery.

## 9. What remains to implement in Egregoros

The manifest declaration, actor activation and key pin, consent model, backend
permission check, receiver-side suppression, and notification-specific audit
events are implemented. The purpose revision extends audits with declared and
effective purpose. Audits otherwise contain only user ID, app origin, app
actor, event, bounded reason code, and time—never note content, activity/note
IDs, recipient actor URLs, OAuth data, or signing material.

Automated coverage exercises the complete signed personal-inbox path through
OAuth, consent, persistence, revocation, silent suppression, and audit output,
plus the SDK/broker browser boundary. Continued interoperability testing across
additional Fediverse implementations is release validation rather than a
missing protocol component.
