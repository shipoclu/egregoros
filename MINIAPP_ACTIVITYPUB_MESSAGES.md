# Mini-app ActivityPub messages: implementer's guide

> Status: public ActivityPub publishing can be implemented independently today.
> Egregoros parses and immutably persists the mini-app actor declaration and
> notification-consent decisions. The SDK and broker implement the typed
> permission transport, and the host implements OAuth-gated state reads,
> confirmation, persistence, and revocation UI. The OAuth-authenticated backend
> permission endpoint, actor-document activation, and inbound
> transactional-message consent enforcement are available.
>
> User-attributed delegated publishing in section 4 is a normative proposal for
> a future protocol revision. Its narrow OAuth scope, endpoint, structured
> activity record, application attribution, visual disclosure, and application
> muting are not implemented yet.

This guide defines two mini-app messaging authorities and one reusable
third-party application publishing authority:

1. **Public messages** published by an app-owned actor for followers and the
   public Fediverse.
2. **Transactional messages** delivered as non-public notes that mention one
   user who explicitly consented to messages from that exact mini app and
   actor.
3. **User-attributed delegated application publishing** in which an
   OAuth-authorized application, including a mini app, asks the user's
   Egregoros server to publish a bounded, visibly app-attributed progress or
   event post as that user.

These authorities are not interchangeable:

| Publishing path | ActivityPub author | Per-post user action | Authority |
| --- | --- | --- | --- |
| Host-owned `composeNote` | The user | Required: the user reviews, may edit, and submits in Egregoros | `identify` plus the `compose_note` host capability |
| Delegated application activity | The user, through a named application | Not required after the time-bounded grant | Proposed `write:app_activities` OAuth scope |
| App-owned public or mention message | The declared `Application` or `Service` actor | Not required; follows and notification-purpose consent govern delivery | App actor key plus the relevant app-message permission |

`composeNote` is deliberately not delegated publishing. The mini app supplies
an editable draft, but Egregoros is the client that publishes only after the
user presses its submit control. Conversely, delegated publishing is the
FarmVille-style authority to publish bounded progress or event posts without a
confirmation for each event. App-owned messages remain authored by the app and
never impersonate the user.

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

User-attributed delegated publications do not satisfy this app-authored rule.
Their actor is the user, their HTTP signature is made by the user's home server,
and the application is identified with the standard ActivityStreams
`generator` property plus the structured `fma:appActivity` record defined
in section 4. They MUST NOT copy `fma:miniApp` merely to obtain app-authored
trust. Receivers therefore have two unambiguous provenance modes:

- `fma:miniApp` plus the declared app actor and pinned app key means **authored
  by the app**; and
- a home-server-authored object with a canonical application `generator` means
  **authored by the user through the identified app**.

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
    "miniAppLink": "fma:miniAppLink",
    "appActivity": "fma:appActivity",
    "verb": "fma:verb"
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
all five terms, while this wire profile uses prefixed property names and the
full IRI when a vocabulary term appears as a `rel` value:

| Term | Expanded IRI | Range and meaning |
| --- | --- | --- |
| `fma:miniApp` | `…#miniApp` | One canonical manifest identity object; app-production provenance. |
| `fma:notificationPurpose` | `…#notificationPurpose` | Optional scalar `transactional` or `promotional` classification. |
| `fma:miniAppLink` | `…#miniAppLink` | One ActivityStreams `Link`; exact candidate launch-link discovery hint. |
| `fma:appActivity` | `…#appActivity` | One embedded, inert Activity tuple describing a user event published through an application. |
| `fma:verb` | `…#verb` | One bounded plain-text display verb inside `fma:appActivity`; never an ActivityPub side-effect instruction. |

Here `…` abbreviates the provisional namespace base only in this explanatory
table; it is never legal wire syntax.

The namespace originated with mini apps, but `fma:appActivity` is intentionally
generic. A conventional OAuth application may use it through
`write:app_activities`; its presence does not claim that the application has a
manifest, iframe entry point, or any other mini-app capability.

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

## 4. User-attributed publishing through an application

> Design status: normative proposal for a future protocol revision. Nothing in
> this section grants authority in the current implementation. The manifest
> schema, OAuth server, publication endpoint, persistence model, ActivityPub
> serializer, REST renderer, timeline UI, and application-mute controls must all
> implement this section before the feature is advertised.

This section defines both the common attribution contract for publications
made through a third-party OAuth client and a narrow authority for unattended,
application-originated events. Mini apps are one client class that can use the
narrow authority; the scope and endpoint are deliberately not mini-app-only.

It includes:

- ordinary statuses created through the broad `write` scope;
- structured progress or event posts created through the proposed narrow
  `write:app_activities` scope; and
- any later allowlisted object or activity type that an application is
  permitted to publish as the user.

Application attribution follows the OAuth client identity, not the endpoint or
scope. An application cannot avoid attribution by requesting broad `write`,
using a generic status endpoint, omitting structured activity data, or
selecting a different supported object type. Every successful publication in
this class MUST carry the server-derived `generator` described below.

This rule does not apply to a `composeNote` draft that the user reviews and
submits through Egregoros. In that flow Egregoros is the publishing client and
the user performs the final per-post action. It also does not replace the
app-authored provenance rules above: an app-owned actor uses `fma:miniApp`,
whereas a user-attributed post uses the user's actor plus `generator`.

### 4.1 Authority and actor boundary

The resulting ActivityPub object belongs to the user:

- `actor` on the enclosing activity is the exact local user actor;
- `attributedTo` on a created object is the same local user actor;
- the object is stored in and delivered from that user's outbox;
- Egregoros assigns all IDs, timestamps, addressing, and signatures; and
- the mini app receives no user signing key, actor credential, inbox URL, or
  ability to submit directly to federation workers.

The application is the generator, not the actor or a co-actor. The user's home
server is authoritative for the claim that its user authorized that client. A remote
receiver may distrust the originating server as it could distrust any ordinary
user-authored post, but it must not reinterpret the generator as the author.

An application does not need an ActivityPub `Application` actor merely to
publish through this delegated path. A mini app uses its canonical manifest as
application identity; another OAuth client uses the pinned public identity
described in section 4.3. An app actor remains necessary only for app-owned
public messages or purpose-labeled mentions.

### 4.2 OAuth permission and consent

The proposed least-privilege scope is exactly:

```text
write:app_activities
```

It authorizes only the generic dedicated endpoint in section 4.4. It does not
authorize generic status creation, reads, media upload, replies, mentions, polls, edits,
deletes, follows, boosts, favourites, bookmarks, account changes, moderation
actions, notification changes, or any other `write` route. It does not imply
`read`. A mini-app grant still includes the normal `identify` baseline.

For a mini app, the immutable manifest maximum must declare the scope before it
can be requested. Another OAuth client must have the capability enabled in its
immutable server-side registration; dynamic registration does not gain it
merely by including the scope string. Its authorization lifetime participates
in the existing per-scope app/server/user minimum. Consent requires the same
second, server-enforced confirmation used for consequential write authority, but with narrower text
that states all of the following separately:

- the app may automatically publish progress or event posts as the user;
- individual posts will not receive another confirmation;
- every post will visibly name the application that generated it;
- the permission cannot read, edit, or delete the user's posts; and
- the user can revoke publishing authority independently at any time.

The grant stores a user-selected publication visibility. Initial permitted
values are `public`, `unlisted`, and `followers`; `direct` is forbidden. The
visibility is not supplied per event by the app. Changing it is a host-owned
setting and applies to later publications only. The consent and settings UI
must also show the app's current server-enforced rate limit and provide an
immediate pause/revoke control.

The authorization server MUST issue `write:app_activities` in a separate token
family from broad `write`. A delegated-publishing token contains `identify`
and `write:app_activities`, and no other scope. A client that also needs read
access or offers an interactive composer obtains a separate user-authorized
token family for that purpose. The server rejects a token that combines
`write:app_activities` with `read`, broad `write`, or any other additional
scope. Separate families preserve independent consent, duration, revocation,
audit meaning, and endpoint authorization; sharing an OAuth client registration
does not merge them.

Broad `write` represents an interactive client in which the user performs the
final publication action. `write:app_activities` represents software that may
originate an event without a per-post action. The server cannot mechanically
prove whether a broad-write client displayed a composer, so this distinction
is also a client conformance and abuse-policy rule. It is not a reason to omit
provenance: every successful route still receives server-derived application
attribution.

Broad `write` remains a separate, much stronger permission. When any OAuth
application uses broad `write` to publish an ordinary status or another
permitted object, Egregoros MUST still add generator attribution and visual
disclosure. Broad authority is never an attribution bypass. It does not add an
`fma:appActivity` tuple, and a conforming client does not use it for unattended
publishing. Conversely, the narrow scope must not be accepted by a generic
status endpoint.

### 4.3 Canonical generator identity

The canonical generator is constructed exclusively from the OAuth token's
server-side application registration. For a mini app, the registration uses
the manifest version pinned to it:

```json
{
  "type": "Application",
  "id": "https://openfarm.example/.well-known/fediverse-miniapp.json",
  "name": "OpenFarmGame",
  "url": "https://openfarm.example/"
}
```

The fields have these meanings and constraints:

- `type` is exactly `Application`;
- `id` is the stable canonical application identity used for equality and
  muting. For a mini app it is the exact canonical well-known manifest URL;
- `name` is the bounded plain-text application name obtained from the validated
  manifest or pinned OAuth registration, not from the publication request; and
- `url` is the exact validated manifest `homeUrl` or registered application
  website snapshot associated with the registration.

For a non-mini-app OAuth client, Egregoros assigns a stable, public HTTPS
application-record URI under its own origin and uses that URI as `generator.id`.
The record exposes only bounded public name and website metadata; it never
contains a client secret, access token, redirect URI, local numeric database
key, or user grant. A caller-supplied homepage is not an identity. Future
portable application metadata may replace the server-local record only through
an explicit versioned protocol; it must not silently change an existing ID.

That application-record URI is on the same origin as the authoring user's
ActivityPub actor and dereferences as `application/activity+json` to the same
bounded `Application` identity used in `generator`. It is public provenance,
not an OAuth management endpoint. The URI uses an unguessable public ID
separate from both `client_id` and the database primary key. It remains stable
after token expiry, client-secret rotation, or user revocation so historical
attribution and mute records remain meaningful.

Application names and home URLs are presentation data. They are non-unique and
may change, so no authorization, equality, reputation, or mute decision may key
on either one. A manifest name change cannot evade a mute because the canonical
manifest URL remains the identity.

The publication request MUST NOT accept `generator`, `application`, manifest
URL, app name, app URL, OAuth client ID, actor, or attribution fields. If the
server cannot derive one valid canonical generator from the authenticated
token, current registration, any required pinned manifest, and current policy,
the entire publication fails atomically.

The identical generator object MUST appear on the enclosing `Create` or other
activity and on every newly created embedded object. A separately dereferenced
object retains it. Missing, unequal, array-valued, caller-controlled, or
non-canonical generator data is a publication error.

### 4.4 Dedicated structured-activity endpoint

The narrow scope uses a dedicated endpoint rather than a raw ActivityPub outbox
or Mastodon status endpoint:

```http
POST /api/v1/app-activities
Authorization: Bearer ACCESS_TOKEN
Content-Type: application/json
Idempotency-Key: 01JGAMEEVENT7FC8N4HYP2WQ6D9A
```

The request is one closed generic verb tuple:

```json
{
  "verb": "harvested",
  "object": {
    "name": "50 ears of corn",
    "url": "https://openfarm.example/harvests/123"
  },
  "target": {
    "name": "Moonman's farm",
    "url": "https://openfarm.example/farms/moonman"
  },
  "result": {
    "name": "Level 12"
  },
  "language": "en"
}
```

`verb` and `object` are required. `target`, `result`, and `language` are
optional. No other top-level or nested properties are accepted. The request is
not ActivityStreams or JSON-LD and cannot nominate an ActivityPub type,
context, side effect, audience, or identifier.

For this initial profile:

- the decoded request body is at most 16 KiB;
- `verb` is plain text of 1 to 80 Unicode scalar values and at most 256 UTF-8
  bytes;
- each `name` is plain text of 1 to 200 Unicode scalar values and at most 1024
  UTF-8 bytes;
- strings are normalized to NFC and reject NUL, C0/C1 controls, line/paragraph
  separators, and explicit bidirectional formatting controls; renderers still
  isolate directionality with `bdi` or an equivalent primitive;
- app-supplied values contain no HTML, Markdown, mentions, hashtags, emoji
  shortcodes with side effects, or template syntax;
- each optional `url` is a credential-free HTTPS URL on the app's exact
  manifest origin and is never treated as trusted content merely because it is
  same-origin; and
- `language`, when present, is one syntactically valid BCP 47 tag.

The app may choose descriptive text and can therefore make false or abusive
claims. Attribution, rate controls, reporting, and revocation make the source
accountable; the server does not pretend to verify game state.

`Idempotency-Key` is mandatory, contains 16 to 128 visible ASCII characters,
and is bound to the user, canonical generator ID, token family, and normalized
request digest. Repeating the same key and digest returns the original success;
reusing it with different content fails with `409 Conflict`. Records survive
for at least the server's documented retry horizon and never less than 24
hours. The object transaction and idempotency record commit atomically.

### 4.5 Server construction and federated representation

Egregoros converts the closed request into an ordinary `Create(Note)` so
software with no mini-app vocabulary support still receives a normal timeline
post. It also embeds the generic verb tuple for supporting clients. The server,
not the app, constructs the human-readable fallback and every ActivityStreams
field:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    {
      "fma": "https://fediverse.example/ns/miniapps#"
    }
  ],
  "id": "https://social.example/users/alice/activities/01JGAME",
  "type": "Create",
  "actor": "https://social.example/users/alice",
  "to": ["https://www.w3.org/ns/activitystreams#Public"],
  "cc": ["https://social.example/users/alice/followers"],
  "published": "2026-07-14T12:00:00Z",
  "generator": {
    "type": "Application",
    "id": "https://openfarm.example/.well-known/fediverse-miniapp.json",
    "name": "OpenFarmGame",
    "url": "https://openfarm.example/"
  },
  "object": {
    "id": "https://social.example/users/alice/statuses/01JGAME",
    "type": "Note",
    "attributedTo": "https://social.example/users/alice",
    "to": ["https://www.w3.org/ns/activitystreams#Public"],
    "cc": ["https://social.example/users/alice/followers"],
    "published": "2026-07-14T12:00:00Z",
    "generator": {
      "type": "Application",
      "id": "https://openfarm.example/.well-known/fediverse-miniapp.json",
      "name": "OpenFarmGame",
      "url": "https://openfarm.example/"
    },
    "content": "<p>Alice harvested <a href=\"https://openfarm.example/harvests/123\">50 ears of corn</a> in <a href=\"https://openfarm.example/farms/moonman\">Moonman's farm</a> via <a href=\"https://openfarm.example/\">OpenFarmGame</a>.</p>",
    "fma:appActivity": {
      "type": "Activity",
      "actor": "https://social.example/users/alice",
      "fma:verb": "harvested",
      "object": {
        "type": "Object",
        "name": "50 ears of corn",
        "url": "https://openfarm.example/harvests/123"
      },
      "target": {
        "type": "Object",
        "name": "Moonman's farm",
        "url": "https://openfarm.example/farms/moonman"
      },
      "result": {
        "type": "Object",
        "name": "Level 12"
      },
      "instrument": {
        "type": "Application",
        "id": "https://openfarm.example/.well-known/fediverse-miniapp.json",
        "name": "OpenFarmGame",
        "url": "https://openfarm.example/"
      }
    }
  }
}
```

The fallback `content` is generated from a fixed server template. The server
supplies the user's current display name and the validated application name;
it escapes all app-supplied text and emits only links that passed exact-origin
validation. The application cannot submit HTML or replace the visible `via
OpenFarmGame` attribution. If a target or result is omitted, the host uses the
corresponding deterministic shorter template rather than accepting an app-owned
format string.

`fma:appActivity` is data, not an instruction to execute an ActivityPub
side effect. Its shape is closed:

- `type` is exactly `Activity`, never an app-defined type or array;
- `actor` is the exact user actor assigned by Egregoros;
- `fma:verb` is the normalized request verb and has no server-defined side
  effect;
- `object` is required and `target` and `result` are optional generic `Object`
  values containing only the validated `name` and optional `url`;
- `instrument` is deep-equal to the canonical generator; and
- no addressing, IDs, contexts, attachments, tags, mentions, or unknown
  properties occur inside the tuple.

This single generic tuple avoids creating an ActivityStreams class for every
game action. Values such as `harvested`, `completed`, `earned`, or `won` remain
bounded display verbs, not globally registered types. Receivers may render the
tuple but MUST NOT infer permissions, execute collection changes, or perform
any other side effect from it.

An ordinary status created by an application through broad `write` does not
contain `fma:appActivity`; it remains an ordinary `Create(Note)`. It MUST
still carry the identical server-derived `generator` on `Create` and `Note`,
and Egregoros MUST still display the application attribution. The same rule
applies to every later allowlisted activity or object type.

The special endpoint returns only server-owned publication facts:

```json
{
  "activityId": "https://social.example/users/alice/activities/01JGAME",
  "objectId": "https://social.example/users/alice/statuses/01JGAME",
  "url": "https://social.example/@alice/01JGAME",
  "visibility": "public",
  "application": {
    "manifestUrl": "https://openfarm.example/.well-known/fediverse-miniapp.json",
    "name": "OpenFarmGame",
    "website": "https://openfarm.example/"
  }
}
```

This receipt proves local persistence, not remote delivery or truth of the
event. Public and unlisted objects can be independently fetched at `objectId`.

### 4.6 Mastodon-compatible API representation

The Mastodon-compatible Status representation MUST expose the existing
`application` property for every status with a recognized generator:

```json
"application": {
  "name": "OpenFarmGame",
  "website": "https://openfarm.example/"
}
```

Egregoros derives this object from the stored generator; it never reconstructs
it from note prose. `application.name` is `generator.name`, and
`application.website` is `generator.url`. A status created by an OAuth
application MUST NOT serialize `application: null` merely because it arrived
through a generic status route or because it lacks `fma:appActivity`.

The compatible `application` hash does not contain a stable application
identity. Egregoros therefore persists `generator.id` independently and uses
it for UI actions, mute storage, filtering, and future versioned application
API fields. Clients and servers MUST NOT use the application name or website
as a mute key.

For remote objects, Egregoros preserves syntactically valid `generator` data as
untrusted federation input. It exposes `application` as recognized application
attribution only after the generator has passed the validation rules in
section 4.9. Unsupported or malformed remote generators do not become trusted
applications merely because they provide a familiar name.

### 4.7 Mandatory visual disclosure

Every Egregoros presentation of a user-attributed application publication MUST
show a persistent, human-readable application label equivalent to:

```text
via OpenFarmGame
```

The requirement applies to:

- home, local, public, list, and tag timelines;
- user profiles and individual status pages;
- search results, bookmarks, favourites, and notification previews;
- embedded or quoted status cards rendered by Egregoros; and
- the original status shown inside a boost.

The label is visible text, not only a tooltip, icon, color, hover state,
metadata panel, or API field. It is included in the accessible name or nearby
screen-reader text, preserves readable contrast, and remains visible in compact
and mobile layouts. App-controlled markup, CSS, bidirectional controls, and
overlong names cannot obscure it.

The displayed name comes from the stored validated generator. Selecting the
label opens a host-owned application-details surface containing the exact
canonical application ID, home URL, grant state, mute state, and controls. For
a mini app it also shows the manifest origin. It does not immediately launch
an iframe or navigate to the app; opening remote app code continues to require
the ordinary explicit **Open** action.

The fallback Note content also contains an explicit `via` phrase so followers
using software that ignores `generator` and the extension vocabulary still see
that the post was produced on the user's behalf by an application. Supporting
Egregoros clients may avoid visually repeating that phrase in a way that reads
awkwardly, but they MUST retain an equally prominent separate application
label and MUST NOT remove the phrase from the federated or dereferenceable
object.

When displaying a boost, the label belongs to the original generated object,
not to the person who boosted it. If a future application permission permits
creating an `Announce`, that `Announce` also carries its own generator and is
subject to a separately specified scope; `write:app_activities` does not
permit boosts.

### 4.8 Application muting

Application muting is a user-owned rendering and notification control keyed by
the exact canonical `generator.id`. A mute record contains at least the local
user ID, canonical application ID, creation time, and optional user-visible
reason. It does not key on the app name, home URL, OAuth client ID, app actor
URL, or current manifest fingerprint.

A current application mute suppresses, for that viewer:

- user-attributed objects whose recognized `generator.id` matches;
- those objects when reached through a boost, quote, search result, profile,
  bookmark, favourite, or notification;
- new notifications and live timeline insertions derived from matching
  objects; and
- for a mini app, app-authored messages carrying a fully verified
  `fma:miniApp.id` equal to the same manifest URL.

It does not suppress an ordinary user-authored post merely because it links to
the app or carries `fma:miniAppLink`. Sharing an app is not the same as content
being generated by it. It also does not silently block the human author, the
app's domain, or unrelated ActivityPub actors hosted on that domain.

Muted objects remain persisted for federation correctness, thread integrity,
moderation, and explicit user access. Normal timeline surfaces show either
nothing or a host-owned placeholder such as **Post hidden because it was
generated by a muted application**, according to the surface's established
filter UX. A deliberate per-object reveal does not remove the mute. Search,
notification counts, streaming updates, and server-rendered initial pages must
apply the same decision as the live client so there is no flash or alternate
unfiltered path.

Muting is independent of every other control:

- muting an app does not revoke the user's OAuth grant;
- revoking OAuth does not retroactively mute or delete existing posts;
- muting does not alter transactional/promotional consent records;
- blocking the app actor is not a substitute for muting user-attributed posts;
  and
- operator domain policy remains a stronger server-wide publication and launch
  gate.

The application-details surface provides **Mute application** and **Unmute
application** actions and explains these distinctions. A name or home-URL
change cannot evade the mute. A removed, unreachable, or later-invalid identity
document does not erase the stored mute key. Timeline filtering uses persisted
identity data and MUST NOT perform a network request in the rendering path.

### 4.9 Validation and trust boundary

For a local publication, the authoritative chain is:

```text
bearer token
  -> OAuth application
  -> exact immutable application registration
  -> pinned mini-app manifest or server-owned application record
  -> current scope and instance policy
  -> server-constructed generator
  -> stored object/activity
  -> REST, HTML, and ActivityPub renderers
```

The generator is stamped inside the common publication transaction after OAuth
authorization and before persistence, not added only by one controller or
serializer. Every route capable of creating content from an OAuth application
registration must use that boundary. A missing stamp, conflicting existing
value, stale/denied registration, or serialization loss aborts the publication
and produces no delivery job.

The stored canonical generator is the single source for:

- the ActivityPub `generator` fields;
- the Mastodon-compatible `application` hash;
- the visible `via` label and application-details action;
- application mute matching;
- audit records and publication receipts; and
- any future structured application API representation.

No layer reparses rendered HTML or trusts a caller-supplied name to recover this
identity. Outbox, object-dereference, status API, HTML, streaming, and delivery
serializers must agree. Tests must exercise every publication entry point and
fail if an application-created object can reach persistence without
attribution.

For an incoming remote object, `generator` is untrusted content. A receiver
recognizes it as application attribution only when:

- every supplied activity or object representation has exactly one generator;
- when an activity embeds an object, the two generator values are deep-equal,
  and a separately dereferenced counterpart matches any already stored value;
- `type` is exactly `Application`;
- `id` is a safe canonical HTTPS URL with no redirect, credentials, fragment,
  IP literal, unsafe port, or non-canonical spelling;
- `name` is bounded plain text passing the same control-character rules;
- `url`, when present, is a safe canonical HTTPS URL;
- the associated object actor and attribution satisfy normal ActivityPub origin
  and signature checks; and
- bounded asynchronous identity resolution confirms the claimed name/home
  presentation data without violating current instance domain policy.

Identity resolution accepts exactly two version-1 forms:

1. A mini-app identity is the exact well-known manifest URL. Its `url` is on
   the manifest's exact origin, and the existing manifest validator confirms
   the name and home URL.
2. A conventional application identity is on the exact origin of the remote
   user's actor. It dereferences without a redirect as
   `application/activity+json` to a bounded `Application` whose `id`, `name`,
   and optional `url` exactly match `generator`. This record is an assertion by
   the user's server, not by the app's external website.

An arbitrary external homepage, OAuth client ID, display name, or unknown
identity-document shape is not a recognized application identity.

Identity resolution follows the existing SSRF-safe fetch boundary, size and
redirect limits, negative caching, circuit breakers, and per-source/per-target
rate limits. Timeline rendering never blocks on it. Until resolution completes,
the receiver may show a neutral **via an unverified application on
example.example** label derived from the safe generator host, but it must not
display a claimed well-known application name as verified.

Remote recognition proves only that the generator refers to the stated
identity document and that the user's origin server delivered the claim. It
cannot prove that the remote server actually performed an OAuth exchange with
that app. A malicious origin server can lie about generator just as it can lie
in note content. The label is provenance asserted by the origin, not
cryptographic attestation from the app. In contrast, app-authored
`fma:miniApp` messages retain their separate app-key verification rules.

Invalid generator or `fma:appActivity` data does not invalidate an otherwise
valid ordinary remote Note. The receiver stores or renders the Note according
to normal federation policy, ignores the invalid extension for trusted
mini-app features, does not expose a verified app identity, and records bounded
diagnostic/moderation evidence. It never lets generator grant iframe, OAuth,
notification, wallet, fetching, or ActivityPub side-effect authority.

Parsers reject duplicate JSON keys before semantic validation and enforce depth,
member-count, string, URL, and total-payload limits. The embedded tuple is never
fed back into the inbox side-effect dispatcher. Names and URLs are escaped at
every HTML boundary, outbound links receive the normal safe-link attributes,
and application details never interpolate remote markup.

### 4.10 Edits, deletion, revocation, and audit

The generator of a created object is immutable provenance. A user may edit the
post through Egregoros, but the resulting `Update` and updated object retain the
original generator and visible attribution. A user edit does not make it false
that the object was initially generated by the app. Egregoros may additionally
display its ordinary edited indicator.

If broad `write` lets an application edit an object created by another client,
the new `Update` activity identifies that application as its generator while
the object retains its original creation generator, if any. An edit cannot
erase, replace, or manufacture the object's original generator. The narrow
`write:app_activities` scope cannot edit anything.

The user may delete a generated post through ordinary Egregoros controls. The
narrow scope cannot delete it. A `Delete` or `Tombstone` retains enough internal
canonical generator identity for audit and mute consistency without exposing
deleted content. Remote deletion retains ActivityPub's normal best-effort
semantics.

Revocation, grant expiry, account deletion, app-domain denial, manifest identity
failure, or token-family invalidation prevents new publications immediately and
before an idempotency lookup can disclose another user's result. Existing
objects remain attributed and user-controlled; revocation does not rewrite
federated history.

Each attempt produces a bounded security audit event containing:

- local user ID;
- OAuth application and token-family identifiers;
- canonical application ID and, for a mini app, app origin;
- requested operation class and scope;
- success/failure reason code;
- generated object/activity IDs only after successful commit;
- idempotency-key digest, never the raw key; and
- timestamp and applicable rate-limit bucket.

Audits do not copy verb/object prose, OAuth tokens, authorization codes, PKCE
values, private keys, raw request bodies, or remote delivery payloads. Ordinary
content moderation retains its separate object record. Publication receipts and
logs must not make a private/followers-only object dereferenceable to the app or
another user.

### 4.11 Delegated-publishing acceptance checklist

- [ ] A mini-app manifest maximum or immutable OAuth application registration
      accepts the exact narrow scope.
- [ ] The authorization server separates `write:app_activities` and broad
      `write` into different token families and rejects mixed tokens.
- [ ] Consent distinguishes automatic publishing from `composeNote` and broad
      `write`, including duration, visibility, attribution, and revocation.
- [ ] Dedicated endpoint accepts only the bounded closed tuple and mandatory
      idempotency key.
- [ ] Every OAuth application publication path, including ordinary
      broad-`write` statuses, stamps a server-derived canonical generator.
- [ ] `Create`/activity, embedded object, standalone dereference, outbox, and
      delivery representations agree exactly.
- [ ] Mastodon-compatible Status JSON emits non-null `application` data.
- [ ] Every Egregoros post surface renders accessible visible application
      attribution, including boosts and streaming insertion.
- [ ] Generic fallback content visibly says `via` the application.
- [ ] Structured tuples cannot select a top-level activity type or execute an
      ActivityPub side effect.
- [ ] User edits preserve creation attribution; the app cannot edit or delete
      through the narrow scope.
- [ ] Application mute uses canonical application identity, covers direct and
      boosted generated content, and ignores ordinary user-shared links.
- [ ] Local publication fails closed if attribution cannot be derived or stored.
- [ ] Remote generator handling is bounded, asynchronous, non-authoritative,
      SSRF-safe, and never enables another capability.
- [ ] Adversarial tests cover generator spoofing, omission, mismatch, duplicate
      keys, type/array confusion, overlong Unicode, bidi controls, URL smuggling,
      idempotency collision, stale grants, domain-policy change, edit stripping,
      serializer loss, mute bypass, boost bypass, and streaming/UI bypass.

## 5. Consent is a separate capability

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

## 6. Authoritative backend permission check

The app backend identifies the user through its existing OAuth `identify` grant.
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

## 7. Purpose-labeled direct messages

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

## 8. Delivery, abuse, and privacy requirements

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

## 9. Minimal implementation checklist

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
- [ ] OAuth `identify` grant used server-side to identify the recipient; broad
      `read` is not required merely to link the Fediverse account.
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

## 10. What remains to implement in Egregoros

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

User-attributed application publishing is separate future work. None of
section 4's `write:app_activities` scope, separated token family, generic
structured endpoint, canonical generator stamping, public application record,
Status `application` mapping, visible attribution, application muting, or
related validation and audit behavior is implemented. Egregoros MUST NOT
advertise this capability until the complete section 4.11 acceptance checklist
passes for ordinary broad-`write` publication routes as well as the narrow
endpoint.
