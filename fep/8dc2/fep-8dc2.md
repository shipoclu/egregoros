---
slug: "8dc2"
authors: "admin <admin@fediverse.org>"
status: DRAFT
dateReceived: 2026-07-19
trackingIssue: "-"
discussionsTo: "-"
relatedFeps: FEP-a4ed
---

# FEP-8dc2: Application provenance on ActivityStreams generators

## Summary

This proposal adds `fap:kind` to an ActivityStreams `Application` used as a
`generator`. It lets a client identify the kind of publishing application—for
example, a mini app—without confusing that application with the author.

The value is assigned by the authoring server, appears in the Mastodon API as
`application.kind`, and can be used for presentation and filtering.

## Implementations

[Egregoros](https://github.com/egregoros-social/egregoros) implements this proposal.

## Requirements language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** in
this document are to be interpreted as described in RFC 2119 and RFC 8174.

## Vocabulary

This proposal defines the **Fediverse Application Provenance** vocabulary:

```text
Context:    https://ns.fediverse.org/context/application-provenance/v1.jsonld
Vocabulary: https://ns.fediverse.org/vocab/application-provenance#
Prefix:     fap
```

Objects using this extension MUST include the ActivityStreams context, the FAP
context URL, and this inline mapping:

```json
"@context": [
  "https://www.w3.org/ns/activitystreams",
  "https://ns.fediverse.org/context/application-provenance/v1.jsonld",
  { "fap": "https://ns.fediverse.org/vocab/application-provenance#" }
]
```

The inline mapping is normative. Receivers MUST NOT fetch the FAP context to
recognize the extension.

## `fap:kind`

`fap:kind` is an immutable lowercase ASCII token on a `generator` whose type is
`Application`. It describes the publishing application, not the actor or the
object's contents.

The initial value is `miniapp`.

```json
"generator": {
  "type": "Application",
  "id": "https://openfarm.example/.well-known/fediverse-miniapp.json",
  "name": "Open Farm Game",
  "url": "https://openfarm.example/",
  "fap:kind": "miniapp"
}
```

If a `Create` embeds an object, the generators on the activity and embedded
object MUST be deep-equal. A dereferenced object MUST retain its generator.

The authoring server assigns the value from its application registration. It
MUST ignore or reject a caller-supplied `generator` or `fap:kind` on status
creation. Remote values are origin-server assertions only; they grant no
authority or capability.

## Mastodon API

Servers that support FAP MAY accept `fap:kind` during application registration:

```json
POST /api/v1/apps
{
  "client_name": "Open Farm Game",
  "redirect_uris": "https://openfarm.example/oauth/callback",
  "scopes": "read write",
  "website": "https://openfarm.example/",
  "fap:kind": "miniapp"
}
```

The server MUST validate the requested kind against local policy before storing
it. It MAY derive the value from a pinned mini-app manifest or other local
registration mechanism instead. The kind is immutable after registration.

`POST /api/v1/statuses` MUST NOT accept a caller-controlled kind. The server
uses the authenticated application's registered kind when constructing the
ActivityPub `generator`.

Status responses and streaming events expose a recognized kind additively:

```json
"application": {
  "name": "Open Farm Game",
  "website": "https://openfarm.example/",
  "kind": "miniapp"
}
```

The member is omitted when no recognized FAP kind exists. Clients can filter on
`status.application.kind`; servers SHOULD index locally assigned kinds for
server-side filters.

## Security considerations

FAP is provenance metadata. It is not a proof of identity and MUST NOT enable
OAuth, iframe access, delivery, or any other ActivityPub side effect.

## Copyright

To the extent possible under law, the author has waived all copyright and
related or neighboring rights to this work under the
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
Public Domain Dedication.
