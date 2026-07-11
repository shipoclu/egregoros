# Egregoros browser security headers

Egregoros owns its Content Security Policy. A reverse proxy must pass the
application's `Content-Security-Policy` and
`Content-Security-Policy-Report-Only` response headers through unchanged.
Never replace them with a static proxy policy and never append another CSP
field: browsers enforce multiple CSP fields together, so an apparently
harmless proxy policy can disable the mini-app broker or the LiveView UI.

## Required policies

For ordinary browser pages Egregoros emits a policy with these essential
boundaries:

```text
default-src 'self'
frame-src 'self'       # when mini apps are enabled; otherwise 'none'
frame-ancestors 'none'
object-src 'none'
base-uri 'self'
form-action 'self'
```

`frame-src 'self'` does **not** frame the remote app directly. It permits only
the trusted same-origin broker. Each broker response replaces the ordinary CSP
with a launch-specific policy whose `frame-src` is exactly the one validated
mini-app origin and whose `frame-ancestors` is `'self'`. Consequently, a proxy
must not broaden `frame-src` to `https:` or `*`, and it must not narrow the
broker to `frame-src 'self'`.

Egregoros also emits:

- `Permissions-Policy` denying camera, microphone, geolocation, payment, USB,
  serial, Bluetooth, HID, MIDI, and display capture. A mini app uses only the
  typed host capabilities and host-owned confirmations defined by the SDK.
- `Referrer-Policy: strict-origin-when-cross-origin` for normal pages and
  `no-referrer` for the data-free broker.
- `X-Content-Type-Options: nosniff`.
- `X-Permitted-Cross-Domain-Policies: none`.
- `Strict-Transport-Security: max-age=31536000; includeSubDomains` in production
  after Egregoros has recognized the request as HTTPS.

The broker additionally sends `Cache-Control: private, no-store, max-age=0`
and must never be cached by a reverse proxy or CDN.

Do not add `X-Frame-Options` at the proxy. `DENY` breaks the same-origin broker
and `SAMEORIGIN` is redundant with the more precise CSP. The external mini app
has its own, different framing requirements documented in
[`examples/fediverse-miniapp/DEPLOYMENT.md`](../examples/fediverse-miniapp/DEPLOYMENT.md).

## Forwarded scheme and TLS

Terminate TLS only at a trusted reverse proxy and keep the Phoenix port off the
public network. The proxy must overwrite—not append—these request headers:

```text
Host: original public host
X-Forwarded-Proto: https
X-Forwarded-For: trusted proxy chain
```

Set `EGREGOROS_TRUSTED_PROXIES` to only the proxy network. Egregoros uses the
trusted forwarded scheme to avoid redirect loops and to emit HSTS. Do not trust
forwarded headers from arbitrary internet clients.

Only use HSTS `includeSubDomains` when every subdomain is HTTPS-capable. The
supplied standalone topology serves its main, uploads, and frontend subdomains
over HTTPS and enables it. Remove `includeSubDomains` from both Egregoros'
`ForceSSL` configuration and the proxy if that is not true for a custom
deployment.

## Supplied Caddy deployment

[`docker/caddy/Caddyfile`](../docker/caddy/Caddyfile) applies common transport
headers to every supplied public origin while deliberately leaving CSP to
Egregoros. Caddy passes upstream response headers through by default. If you
customize it:

- retain the `security_headers` import on every public site;
- do not add, delete, or rewrite either CSP response-header name;
- do not cache `/mini-apps/broker/*`, `/mini-apps/oauth/relay`, OAuth callbacks,
  or authenticated HTML;
- keep `X-Forwarded-Proto` and `Host` accurate; and
- validate with `caddy validate --config /etc/caddy/Caddyfile` before reload.

## Example nginx reverse proxy

There is no supplied nginx configuration for the main Egregoros origin. A
minimal custom TLS proxy can use the following boundary. This example lets the
application supply CSP and all browser-policy headers; nginx supplies no
competing CSP or `X-Frame-Options`.

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name social.example;

    ssl_certificate     /etc/letsencrypt/live/social.example/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/social.example/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
    }
}
```

Do not use `proxy_hide_header` for CSP, Permissions Policy, Referrer Policy,
HSTS, or `X-Content-Type-Options`. If a CDN sits in front of nginx, apply the
same rules there and disable HTML/broker caching.

## Rollout and verification

`EGREGOROS_CSP_REPORT_ONLY=true` changes only the ordinary application policy
to `Content-Security-Policy-Report-Only` for compatibility diagnosis. Do not
leave it enabled as the final security posture. The launch-specific broker CSP
always remains enforced because it is a security boundary, not a compatibility
hint.

After deployment, inspect both an ordinary page and a real broker response:

```sh
curl --fail --silent --show-error --head https://social.example/
curl --fail --silent --show-error --head \
  'https://social.example/mini-apps/broker/CARD_ID?launch_id=LAUNCH_ID'
curl --fail --silent --show-error --head \
  'https://social.example/mini-apps/oauth/relay'
```

Confirm that the ordinary page has one enforced CSP, `frame-src 'self'` when
mini apps are enabled, and `frame-ancestors 'none'`. Confirm that the broker has
one enforced CSP containing the exact app origin, `frame-ancestors 'self'`,
`Referrer-Policy: no-referrer`, and `Cache-Control: private, no-store,
max-age=0`. Confirm neither response has `X-Frame-Options` and neither proxy nor
CDN rewrites these values. Confirm that the OAuth relay is no-store, has
`Cross-Origin-Opener-Policy: same-origin`, `Referrer-Policy: no-referrer`, and
an enforced CSP with `frame-ancestors 'none'` and only its same-origin script.
