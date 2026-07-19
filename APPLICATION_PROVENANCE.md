# Federated Application Provenance (FAP)

> Status: experimental implementation; not yet advertised as a stable Egregoros
> extension. This vocabulary is deliberately general: it applies to any
> application that publishes through a user's home server, not only to
> Fediverse mini apps.

## Purpose

ActivityStreams already has `generator` for identifying the application that
created an object. It does not provide a compact, portable way to say what kind
of application the generator is, nor a general marker that a published object
is promotional.

Federated Application Provenance (**FAP**) adds only those two facts:

- `fap:kind` classifies a `generator` for filtering and presentation; and
- `fap:promotional` marks an ActivityStreams object as promotional.

FAP is provenance and moderation/filtering metadata. It grants no permission,
does not authorize an ActivityPub side effect, and does not prove the truth of
an application's claims.

## Stable identifiers and compact wire spelling

The intended hosted JSON-LD context and vocabulary namespace are:

```text
Context:    https://ns.fediverse.org/context/application-provenance/v1.jsonld
Vocabulary: https://ns.fediverse.org/vocab/application-provenance#
```

The exact compact prefix is **`fap`**, meaning **Fediverse Application
Provenance**. The compact field names are part of the wire profile because many
ActivityPub consumers inspect JSON directly rather than expanding JSON-LD:

```text
fap:kind
fap:promotional
```

The hosted context is the normative definition for JSON-LD consumers and human
implementers. Senders also include the matching inline prefix mapping, so a
receiver can validate and recognize the compact keys without fetching any remote
context:

```json
"@context": [
  "https://www.w3.org/ns/activitystreams",
  "https://ns.fediverse.org/context/application-provenance/v1.jsonld",
  {
    "fap": "https://ns.fediverse.org/vocab/application-provenance#"
  }
]
```

The hosted context must define the same `fap` prefix and document the two terms.
It is versioned and immutable once published. Receivers MUST NOT fetch it while
rendering a timeline or deciding whether an object is safe; the exact inline
mapping and compact keys are sufficient for recognition.

## `fap:kind` on `generator`

`fap:kind` is an immutable, server-derived lowercase ASCII token on an
ActivityStreams `Application` generator. It describes the publishing
application, not the author, the content, or a permission granted by the
receiver.

The initial defined value is:

```text
miniapp
```

Example user-attributed object:

```json
{
  "@context": [
    "https://www.w3.org/ns/activitystreams",
    "https://ns.fediverse.org/context/application-provenance/v1.jsonld",
    {
      "fap": "https://ns.fediverse.org/vocab/application-provenance#"
    }
  ],
  "id": "https://social.example/users/alice/statuses/01JPOST",
  "type": "Note",
  "attributedTo": "https://social.example/users/alice",
  "generator": {
    "type": "Application",
    "id": "https://openfarm.example/.well-known/fediverse-miniapp.json",
    "name": "Open Farm Game",
    "url": "https://openfarm.example/",
    "fap:kind": "miniapp"
  },
  "content": "<p>My tomatoes are ready.</p>"
}
```

For a `Create` with an embedded object, the `generator`, including
`fap:kind`, MUST be deep-equal on the activity and embedded object. A separately
dereferenced object retains its generator.

The home server derives the value from the authenticated application
registration. A client request, remote payload, or manifest display text cannot
choose or change it. A receiver may use a syntactically valid remote value for a
viewer-selected filter, but treats it only as an assertion by the origin server,
never as authorization or trusted application identity.

Mastodon-compatible APIs project the value additively:

```json
"application": {
  "name": "Open Farm Game",
  "website": "https://openfarm.example/",
  "kind": "miniapp"
}
```

This permits a client to filter a status with the simple direct-JSON check:

```js
status.application?.kind === "miniapp"
```

Servers should store and index the server-derived kind with the canonical
generator identity so timeline, notification, and streaming filters do not have
to parse ActivityPub JSON for every object.

## `fap:promotional` on objects

`fap:promotional` is an optional Boolean on an ActivityStreams object. Its only
defined affirmative value is `true`:

```json
{
  "type": "Note",
  "content": "<p>Plant spring crops this weekend and earn a bonus.</p>",
  "fap:promotional": true
}
```

The marker means the publisher classifies the object as promotional:
advertising, recommendation, re-engagement, or an attempt to drive a new user
action. A mixed operational/promotional object is promotional.

Absence means **unclassified**, not non-promotional. `false`, arrays, objects,
or duplicate values are invalid FAP encodings and must not be interpreted as a
negative assertion.

For a `Create` that embeds an object, the enclosing activity MUST carry the
same marker when the embedded object has one. This lets consumers filtering an
activity or a separately dereferenced object reach the same result. The marker
is immutable after publication; an edit cannot remove it.

`fap:promotional` is useful for viewer filters, moderation evidence, and clear
presentation. It does **not** itself require consent, justify direct delivery,
or grant an application permission to publish. The existing mini-app
`fma:notificationPurpose` proposal remains the stricter, mini-app-specific
mechanism for purpose-gated direct messages. A message labeled
`fma:notificationPurpose: "promotional"` MUST also carry
`fap:promotional: true`; the reverse does not create notification authority.

## Deliberate limits

FAP is not a generic metadata container. In particular, it does not define an
open `fap:data` object, caller-selected JSON-LD contexts, arbitrary application
claims, or event/action tuples. Those would create validation, interoperability,
and privacy burdens without a concrete shared consumer.

The two fields above have immediate, general uses:

- users can filter or mute posts generated by mini apps; and
- users and moderators can filter or label promotional objects.

Useful future candidates should be added only with a concrete receiver behavior
and a closed value set. `paid`/sponsorship disclosure is the strongest candidate,
but it should wait until its exact legal, display, and verification semantics
are designed. Automation, AI-generation, and other application kinds should
likewise wait until they have a stable, non-overlapping definition and a real
filtering or policy use.

## Egregoros adoption requirements

Before advertising FAP support, Egregoros must:

1. construct and persist FAP fields only at the common server-side publication
   boundary;
2. serialize them consistently in the object, enclosing activity, outbox, and
   federation delivery payload;
3. expose `application.kind` in Mastodon-compatible Status responses and
   streaming events;
4. add viewer controls and indexed filtering for application kind and
   promotional objects; and
5. preserve remote FAP data as untrusted federation input without allowing it
   to activate a capability, bypass moderation, or manufacture local
   attribution.
