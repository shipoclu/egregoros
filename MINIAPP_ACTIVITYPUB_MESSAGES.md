# Mini-app ActivityPub messages: implementer's guide

> Status: public ActivityPub publishing can be implemented independently today.
> Egregoros parses and immutably persists the mini-app actor declaration and
> notification-consent decisions. The SDK permission methods, actor-document
> activation, backend permission endpoint, and inbound consent enforcement are
> not yet implemented.

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

The declaration is accepted and pinned now, but does not enable transactional
delivery until the host and SDK permission extension ships. Applications may
publish ordinary public ActivityPub notes independently.

## 4. Consent is a separate capability

Notification consent must not be inserted into `getContext()`. Launch context
describes the fully public note and exact URL that launched the app. Mixing a
user-specific permission into it would weaken that deliberately narrow data
boundary and would make unauthenticated context calls reveal account state.

The proposed SDK instead exposes a separate surface:

```ts
type NotificationPermissionState = "prompt" | "granted" | "denied"

sdk.notifications.getPermission(): Promise<{
  state: NotificationPermissionState
  actorUrl: string
}>

sdk.notifications.requestPermission(): Promise<{
  state: "granted" | "denied"
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
- the manifest's immutable `transactionalMentions` declaration;
- a current iframe user gesture;
- an active exact-origin broker channel; and
- a host-owned confirmation that names both the app domain and ActivityPub
  actor.

The grant is stored by Egregoros against the local user, exact app origin, and
exact declared actor URL. It is independent of launch-context, OAuth, compose,
and wallet consent and has its own revoke control. OAuth revocation, app-domain
denial, actor-declaration invalidation, or account deletion also disables it.

The SDK response intentionally contains no user actor URL, inbox URL, bearer
token, signing secret, or reusable proof. It is suitable for rendering iframe
UI, not for authorizing backend delivery.

## 5. Authoritative backend permission check

The app backend identifies the user through its existing OAuth `read` grant.
After the host-owned SDK confirmation, it calls a proposed Egregoros endpoint
with that user's bearer token:

```http
GET /api/v1/mini-apps/notification-permission
Authorization: Bearer ACCESS_TOKEN
```

An authorized response is deliberately small:

```json
{
  "state": "granted",
  "recipientActor": "https://social.example/users/alice",
  "appActor": "https://weather.example/ap/actor"
}
```

The endpoint derives the app identity from the OAuth client registration; the
caller cannot select another mini-app origin or actor. It returns
`state: "denied"` without a recipient actor when no current grant exists.

Before enqueueing a transactional message, the backend must have observed a
current `granted` result for that recipient. A short cache may reduce requests,
but it creates a revocation window; the receiving Egregoros instance therefore
enforces the grant again at inbox processing time. No webhook or push token is
required for the minimum design.

## 6. Transactional messages

A transactional message is a non-public `Create(Note)` addressed to exactly
one consenting actor. It includes exactly one matching `Mention` tag:

```json
{
  "@context": "https://www.w3.org/ns/activitystreams",
  "id": "https://weather.example/ap/activities/01JTXN",
  "type": "Create",
  "actor": "https://weather.example/ap/actor",
  "to": ["https://social.example/users/alice"],
  "published": "2026-07-11T12:30:00Z",
  "object": {
    "id": "https://weather.example/ap/notes/01JTXN",
    "type": "Note",
    "attributedTo": "https://weather.example/ap/actor",
    "to": ["https://social.example/users/alice"],
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

Transactional constraints are strict:

- no ActivityStreams Public audience in `to`, `cc`, `bto`, or `bcc`;
- exactly one recipient and one matching mention;
- the sender is the exact actor declared by the mini app;
- content and link targets are bounded and human-readable;
- the destination is the recipient's personal inbox, not a shared inbox;
- each logical event has one stable activity ID for retry deduplication; and
- the activity is never added to the public outbox, and its private activity
  and note IDs return no content to unauthenticated fetches.

The receiving Egregoros instance verifies the normal ActivityPub signature and
authorization rules, resolves the sender to a current mini-app declaration,
and checks the local recipient's current consent. Without a matching grant it
must not create a notification or direct-message timeline item. It should
return a non-oracular success response after safe processing so revocation does
not become a remote account-state probe.

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

## 8. Minimal implementation checklist

### Public-only producer

- [ ] Stable `Application` or `Service` actor and signing key.
- [ ] WebFinger, actor, inbox, outbox, followers, activity, and note routes.
- [ ] Verified `Follow`/`Undo` handling and signed `Accept` delivery.
- [ ] Public `Create(Note)` with stable IDs and consistent addressing.
- [ ] Durable signed delivery queue with retry and deduplication.
- [ ] Public activity and note dereferencing.
- [ ] Mute/block compatibility and operator contact information.

### Transactional mentions

- [ ] Everything required for the actor and signed delivery boundary above.
- [ ] Future immutable mini-app actor declaration supported by host and SDK.
- [ ] OAuth `read` grant used server-side to identify the recipient.
- [ ] Separate host-owned notification confirmation completed from a gesture.
- [ ] Authoritative backend permission check returns `granted` before enqueue.
- [ ] Exactly one non-public recipient and matching `Mention` tag.
- [ ] Delivery to the personal inbox only.
- [ ] Private activity/note IDs do not disclose content publicly.
- [ ] Sender-side unsubscribe and immediate enqueue suppression.
- [ ] Receiver-side current-consent enforcement and immediate revocation.
- [ ] Adversarial tests for forged recipients, stale grants, replay, SSRF,
      signature failure, public-audience smuggling, rate abuse, and post-revoke
      delivery.

## 9. What remains to implement in Egregoros

The manifest declaration, immutable persistence, and consent decision data
model are implemented. A complete Egregoros flow still needs:

1. SSRF-safe actor-document validation before activating the declaration;
2. host-owned consent and revocation UI over the existing consent storage;
3. broker and SDK `getPermission`/`requestPermission` messages and TypeScript
   declarations;
4. the OAuth-authenticated backend permission endpoint;
5. inbound transactional-mention recognition and consent enforcement;
6. immediate cross-tab revocation behavior and audit events; and
7. protocol, federation, UI, SDK, security, and interoperability tests.

Until those pieces ship, an app may declare its actor and publish ordinary
public ActivityPub notes, but it must not claim Egregoros-enforced consent for
transactional mentions.
