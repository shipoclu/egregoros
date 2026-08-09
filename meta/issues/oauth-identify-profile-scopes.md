# Add least-privilege OAuth identity scopes

## Summary

Miniapps currently use a dedicated identity endpoint while the standard
Mastodon-compatible `verify_credentials` endpoint requires broad `read`
authority. Applications that only need to authenticate a Fediverse identity
should not receive email, account settings, timelines, or other private data.

## Requirements

- Support literal `identify` and optional additive `profile` OAuth scopes.
- Serve the narrow response from `GET /api/v1/accounts/verify_credentials`.
- Preserve the existing full response for clients with the normal broad read
  authority.
- Update the Miniapp flow to use the standard narrow endpoint and eliminate
  broad-read and Miniapp-specific identity fallbacks.

## Acceptance Criteria

- `identify` returns exactly canonical ActivityPub `sub` and fully-qualified
  `acct`, with no email or account settings.
- `identify profile` adds only the four specified public presentation fields.
- `profile` alone is rejected.
- Existing read-authorized clients receive their unchanged account response.
- Controller and Miniapp integration tests cover the privacy boundary.
