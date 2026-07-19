---
slug: "a882"
authors: "admin <admin@fediverse.org>"
status: DRAFT
dateReceived: 2026-07-19
trackingIssue: "-"
discussionsTo: "-"
relatedFeps: FEP-a4ed, FEP-8dc2
---

# FEP-a882: Promotional markers for ActivityStreams objects

## Summary

This proposal defines `fap:promotional`, an optional Boolean marker for an
ActivityStreams object. It allows a publisher to label advertising,
recommendations, re-engagement, and other content intended to drive a new user
action. Clients and moderators can use the marker without classifying prose.

The marker is self-classification. It neither proves that content is promotional
nor means that an unmarked object is not promotional.

## Implementations

[Egregoros](https://github.com/egregoros-social/egregoros) implements this proposal.

## Requirements language

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** in
this document are to be interpreted as described in RFC 2119 and RFC 8174.

## Vocabulary

This proposal uses the FAP context and exact inline prefix mapping defined by
FEP-8dc2. Receivers MUST NOT fetch the context in order to recognize the
`fap:promotional` key.

## `fap:promotional`

`fap:promotional` is an optional Boolean property. The only affirmative form is
JSON Boolean `true`:

```json
{
  "type": "Note",
  "content": "<p>Plant spring crops this weekend and earn a bonus.</p>",
  "fap:promotional": true
}
```

A mixed operational and promotional object MUST be marked promotional. Omission
means unclassified. `false`, strings, numbers, arrays, objects, and duplicate
keys are invalid and MUST NOT be treated as a negative assertion.

If a `Create` embeds a marked object, the activity MUST carry the same marker.
A dereferenced object MUST retain it. An `Update` MUST NOT remove it.

## Mastodon API

`POST /api/v1/statuses` accepts the additive parameter `fap:promotional`:

```json
{
  "status": "Plant spring crops this weekend and earn a bonus.",
  "fap:promotional": true
}
```

JSON requests use Boolean `true`; form-encoded requests use `true`. A supplied
value other than `true` MUST receive `422 Unprocessable Content`. Omit the
parameter to make no classification.

On success, the server writes the marker to the ActivityPub object and enclosing
`Create`, and returns it as the same top-level member in Status fetches,
timelines, notifications, boosts that expose the original status, and streaming
events:

```json
{
  "id": "123",
  "content": "<p>Plant spring crops this weekend and earn a bonus.</p>",
  "fap:promotional": true
}
```

The member is omitted for an unclassified status. A server MAY apply additional
policy to unattended publishing, but MUST NOT infer the marker from content.

## Security and moderation considerations

The marker does not create consent, override recipients, authorize a
notification, or enable an ActivityPub side effect. Receiving instances remain
free to apply their own classification and moderation policy.

## Copyright

To the extent possible under law, the author has waived all copyright and
related or neighboring rights to this work under the
[CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)
Public Domain Dedication.
