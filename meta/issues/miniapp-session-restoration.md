# Restore Miniapp backend sessions after iframe storage loss

## Summary

Cross-origin iframe storage may be partitioned, cleared, or unavailable even
while the user remains signed into Egregoros and the Miniapp backend retains a
valid OAuth session. Repeating OAuth consent is unnecessary and harms the user
experience.

## Requirements

- Implement the V1 `restoreSession` host action for an exact registered client.
- Issue a hashed, challenge-bound, single-use code only for an existing active
  `identify` grant belonging to the currently signed-in user.
- Advertise and implement the backend-only restore consume endpoint.
- Return only narrow identity claims and never return or extend OAuth tokens.
- Rate-limit, expire, redact, and atomically consume restore proofs.

## Acceptance Criteria

- Missing, expired, revoked, wrong-user, wrong-client, wrong-origin, malformed,
  replayed, and verifier-mismatched requests fail closed.
- Successful consumption returns issuer, sub, and acct, with optional profile
  fields only when the existing grant includes `profile`.
- The host returns `interaction_required` without prompting when no grant exists.
- Protocol, LiveView, controller, and persistence tests cover the security boundary.
