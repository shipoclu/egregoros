# Fediverse Miniapps, in brief

> **Mastodon API compatibility required.** Fediverse miniapps depend on the
> Mastodon-compatible API and OAuth flow at every level. They work only on
> Egregoros or another server that implements that API; they do **not** work on
> servers such as Misskey that lack Mastodon API compatibility.

Fediverse miniapps are small web applications that live on their own HTTPS
domains and can be opened from Mastodon-API-compatible Fediverse hosts such as
Egregoros.
They make ordinary public links more useful: a link can show a rich card in a
public post and open the linked app in a clearly labelled, user-controlled
panel.

They are not server plugins. The app stays on its own domain, runs in an
isolated iframe, and communicates with the host through a narrow, versioned
SDK. Its manifest declares who the app is, which URLs it may launch, its visual
identity, and the maximum host capabilities it may ask to use. Egregoros checks
that manifest at the app's exact HTTPS origin before launch.

## What a miniapp can do

A compatible app can provide a game, utility, event page, community tool, or
other interactive experience. Depending on what the app declares and the user
chooses to authorize, it can:

- show a verified rich link card for a public post and open a specific deep
  link;
- receive the public post's canonical ActivityPub ID and the exact app URL when
  opened from that public card;
- ask the host to open a user-owned compose draft for sharing—the user reviews,
  edits, and submits it in the host; this does not require OAuth because the
  host already has the signed-in user session and the app cannot submit;
- use OAuth with PKCE to ask for a narrowly declared identity grant, such as
  `identify`;
- feature-detect optional host extensions, such as an EVM wallet provider or
  consented ActivityPub transactional notifications; and
- operate its own ActivityPub actor for clearly app-authored public posts, if
  it declares and implements one.

The host owns sensitive actions. A miniapp cannot silently post as a user,
spend from a wallet, or turn a permission declaration into consent. Those
actions require the appropriate host UI, user gesture, and authorization.

## Privacy and trust

Opening a public miniapp card shares the public post's canonical ActivityPub ID
and the exact linked app URL with the app's domain. It does **not** share the
viewer’s identity by default. An app learns identity only after it requests an
OAuth grant and the user approves it.

The iframe boundary is deliberate: the app does not receive Egregoros cookies,
host storage, CSRF values, bearer tokens, host DOM access, or a general-purpose
`postMessage` channel. Each launch is bound to the app's verified origin and a
fresh, limited communication channel.

Still, a miniapp is an external service. Its publisher controls its own server,
privacy policy, retention, analytics, and any data it collects after launch.
Before granting identity, wallet, or notification-related permissions, users
should check the displayed app domain and decide whether they trust that
publisher. The manifest's domain is the primary trust signal; a display name or
publisher label alone is not proof of affiliation.

Apps that publish through their own ActivityPub actor are visibly app-authored,
not user-authored. Transactional mentions require separate, revocable user
consent and should be used only for specific game or app events—not general
marketing. Public app posts and already federated content may persist on other
servers even if the app later deletes its local copy.

For the exact protocol and security requirements, see
[`MINIAPPS.md`](MINIAPPS.md). For an app-building walkthrough, see
[`MINIAPP_IMPLEMENTER_GUIDE.md`](MINIAPP_IMPLEMENTER_GUIDE.md).
