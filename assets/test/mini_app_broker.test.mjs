import assert from "node:assert/strict"
import test from "node:test"

import {createMiniAppBroker} from "../js/lib/mini_app_broker.mjs"

const tick = () => new Promise(resolve => setImmediate(resolve))
const markReady = async (appPort, launchId) => {
  appPort.postMessage({type: "ready", version: "1", launchId})
  await tick()
}

const iframeFixture = () => {
  const listeners = new Map()
  const posts = []

  return {
    posts,
    iframe: {
      contentWindow: {
        postMessage: (message, targetOrigin, transfer) =>
          posts.push({message, targetOrigin, transfer}),
      },
      addEventListener: (name, callback) => listeners.set(name, callback),
      removeEventListener: (name, callback) => {
        if (listeners.get(name) === callback) listeners.delete(name)
      },
    },
    load: () => listeners.get("load")?.(),
    hasLoadListener: () => listeners.has("load"),
  }
}

test("broker transfers one capability port only to the exact same-origin frame relay", () => {
  const fixture = iframeFixture()

  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    hostOrigin: "https://social.example",
    launchId: "launch-1",
    onReady: () => {},
  })

  fixture.load()

  assert.equal(fixture.posts.length, 1)
  assert.equal(fixture.posts[0].targetOrigin, "https://social.example")
  assert.equal(fixture.posts[0].transfer.length, 1)
  assert.deepEqual(fixture.posts[0].message, {
    type: "fediverse-miniapp:host-bootstrap",
    appOrigin: "https://app.example",
    bootstrap: {
      type: "fediverse-miniapp:bootstrap",
      version: "1",
      launchId: "launch-1",
      hostOrigin: "https://social.example",
      issuer: "https://social.example",
      authorizationServerMetadata:
        "https://social.example/.well-known/oauth-authorization-server",
      authorizationResultRelay: "https://social.example/mini-apps/oauth/relay",
      capabilities: [],
    },
  })
  assert.equal("context" in fixture.posts[0].message, false)
  assert.equal("user" in fixture.posts[0].message, false)

  broker.destroy()
  assert.equal(fixture.hasLoadListener(), false)
})

test("ready is accepted once through the transferred port for the active launch", async () => {
  const fixture = iframeFixture()
  let readyCount = 0

  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    launchId: "launch-2",
    onReady: () => readyCount++,
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]

  appPort.postMessage({type: "ready", version: "1", launchId: "launch-2"})
  appPort.postMessage({type: "ready", version: "1", launchId: "launch-2"})
  await tick()
  assert.equal(readyCount, 1)

  broker.destroy()
})

test("rejects every app request sent before the launch is ready", async () => {
  const fixture = iframeFixture()
  const requests = []
  const violations = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    hostOrigin: "https://social.example",
    launchId: "launch-not-ready",
    onContextRequest: requestId => requests.push(requestId),
    onProtocolViolation: reason => violations.push(reason),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  appPort.postMessage({
    type: "getContext",
    version: "1",
    launchId: "launch-not-ready",
    requestId: "ctx-before-ready",
  })
  await tick()

  assert.deepEqual(requests, [])
  assert.deepEqual(violations, ["ready_required"])
  broker.destroy()
})

test("closes a launch that exceeds message, request, outstanding, byte, or rate budgets", async () => {
  const scenarios = [
    {
      name: "message_count",
      limits: {maxMessages: 2, maxRequests: 8, maxOutstanding: 8, rateCapacity: 8},
      messages: launchId => [
        {type: "ready", version: "1", launchId},
        {type: "unknown", version: "1", launchId},
        {type: "unknown", version: "1", launchId},
      ],
    },
    {
      name: "request_count",
      limits: {maxMessages: 8, maxRequests: 1, maxOutstanding: 8, rateCapacity: 8},
      messages: launchId => [
        {type: "ready", version: "1", launchId},
        {type: "close", version: "1", launchId, requestId: "close-1"},
        {type: "close", version: "1", launchId, requestId: "close-2"},
      ],
    },
    {
      name: "outstanding",
      limits: {maxMessages: 8, maxRequests: 8, maxOutstanding: 1, rateCapacity: 8},
      messages: launchId => [
        {type: "ready", version: "1", launchId},
        {type: "getContext", version: "1", launchId, requestId: "ctx-1"},
        {type: "getContext", version: "1", launchId, requestId: "ctx-2"},
      ],
    },
    {
      name: "message_bytes",
      limits: {maxMessages: 8, maxRequests: 8, maxOutstanding: 8, maxMessageBytes: 128, rateCapacity: 8},
      messages: launchId => [
        {type: "ready", version: "1", launchId},
        {type: "unknown", version: "1", launchId, padding: "x".repeat(256)},
      ],
    },
    {
      name: "total_bytes",
      limits: {
        maxMessages: 8,
        maxRequests: 8,
        maxOutstanding: 8,
        maxMessageBytes: 256,
        maxTotalBytes: 180,
        rateCapacity: 8,
      },
      messages: launchId => [
        {type: "ready", version: "1", launchId},
        {type: "unknown", version: "1", launchId, padding: "x".repeat(80)},
      ],
    },
    {
      name: "rate_limit",
      limits: {maxMessages: 8, maxRequests: 8, maxOutstanding: 8, rateCapacity: 1, ratePerSecond: 0},
      messages: launchId => [
        {type: "ready", version: "1", launchId},
        {type: "unknown", version: "1", launchId},
      ],
    },
  ]

  for (const scenario of scenarios) {
    const fixture = iframeFixture()
    const violations = []
    const launchId = `launch-${scenario.name}`
    const broker = createMiniAppBroker({
      iframe: fixture.iframe,
      appOrigin: "https://app.example",
      hostOrigin: "https://social.example",
      launchId,
      limits: scenario.limits,
      onProtocolViolation: reason => violations.push(reason),
    })

    fixture.load()
    const appPort = fixture.posts[0].transfer[0]
    for (const message of scenario.messages(launchId)) appPort.postMessage(message)
    await tick()

    assert.deepEqual(violations, [scenario.name], scenario.name)
    broker.destroy()
  }
})

test("an iframe reload cannot reset or revive the active launch budget", async () => {
  const fixture = iframeFixture()
  const violations = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    hostOrigin: "https://social.example",
    launchId: "launch-reload-budget",
    limits: {maxMessages: 2, maxRequests: 8, maxOutstanding: 8, rateCapacity: 8},
    onProtocolViolation: reason => violations.push(reason),
  })

  fixture.load()
  const firstPort = fixture.posts[0].transfer[0]
  firstPort.postMessage({type: "ready", version: "1", launchId: "launch-reload-budget"})
  firstPort.postMessage({type: "unknown", version: "1", launchId: "launch-reload-budget"})
  await tick()

  fixture.load()
  const secondPort = fixture.posts[1].transfer[0]
  secondPort.postMessage({type: "ready", version: "1", launchId: "launch-reload-budget"})
  await tick()

  fixture.load()
  broker.destroy()

  assert.deepEqual(violations, ["message_count"])
  assert.equal(fixture.posts.length, 2)
})

test("releases outstanding capacity only for the exactly correlated host response", async () => {
  const fixture = iframeFixture()
  const violations = []
  const requests = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    hostOrigin: "https://social.example",
    launchId: "launch-outstanding",
    limits: {maxOutstanding: 1},
    onContextRequest: requestId => requests.push(requestId),
    onProtocolViolation: reason => violations.push(reason),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  const responses = []
  appPort.onmessage = event => responses.push(event.data)
  appPort.start?.()
  appPort.postMessage({type: "ready", version: "1", launchId: "launch-outstanding"})
  appPort.postMessage({
    type: "getContext",
    version: "1",
    launchId: "launch-outstanding",
    requestId: "ctx-1",
  })
  await tick()
  assert.equal(
    broker.send({
    type: "contextResult",
    version: "1",
    launchId: "launch-outstanding",
    requestId: "wrong",
    status: "unavailable",
    context: null,
    }),
    false,
  )
  assert.deepEqual(responses, [])
  appPort.postMessage({
    type: "getContext",
    version: "1",
    launchId: "launch-outstanding",
    requestId: "ctx-2",
  })
  await tick()

  assert.deepEqual(requests, ["ctx-1"])
  assert.deepEqual(violations, ["outstanding"])
  broker.destroy()
})

test("correlated host results are delivered at most once to an exact outstanding request", async () => {
  const fixture = iframeFixture()
  const responses = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    hostOrigin: "https://social.example",
    launchId: "launch-result-once",
    onContextRequest: () => {},
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  appPort.onmessage = event => responses.push(event.data)
  appPort.start?.()
  await markReady(appPort, "launch-result-once")
  appPort.postMessage({
    type: "getContext",
    version: "1",
    launchId: "launch-result-once",
    requestId: "ctx-once",
  })
  await tick()

  const result = {
    type: "contextResult",
    version: "1",
    launchId: "launch-result-once",
    requestId: "ctx-once",
    status: "unavailable",
    context: null,
  }
  assert.equal(broker.send({...result, launchId: "stale-launch"}), false)
  assert.equal(broker.send(result), true)
  assert.equal(broker.send(result), false)
  await tick()
  assert.deepEqual(responses, [result])

  broker.destroy()
})

test("context requests are correlated and host responses return through the private port", async () => {
  const fixture = iframeFixture()
  const requests = []
  const responses = []

  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    launchId: "launch-3",
    onReady: () => {},
    onContextRequest: requestId => requests.push(requestId),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  appPort.onmessage = event => responses.push(event.data)
  appPort.start?.()
  await markReady(appPort, "launch-3")

  appPort.postMessage({type: "getContext", version: "1", launchId: "wrong", requestId: "ctx-1"})
  appPort.postMessage({type: "getContext", version: "1", launchId: "launch-3", requestId: "bad request"})
  appPort.postMessage({type: "getContext", version: "1", launchId: "launch-3", requestId: "ctx-extra", extra: true})
  appPort.postMessage({type: "getContext", version: "1", launchId: "launch-3", requestId: "ctx-1"})
  await tick()
  assert.deepEqual(requests, ["ctx-1"])

  broker.send({
    type: "contextResult",
    launchId: "launch-3",
    requestId: "ctx-1",
    status: "ok",
    context: {version: "1"},
  })
  await tick()

  assert.deepEqual(responses, [
    {
      type: "contextResult",
      launchId: "launch-3",
      requestId: "ctx-1",
      status: "ok",
      context: {version: "1"},
    },
  ])

  broker.destroy()
})

test("auth requests require the active launch and a strict PKCE handoff schema", async () => {
  const fixture = iframeFixture()
  const requests = []

  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    launchId: "launch-auth",
    onAuthRequest: request => requests.push(request),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-auth")
  const valid = {
    type: "requestAuth",
    version: "1",
    launchId: "launch-auth",
    requestId: "auth-1",
    clientId: "client_1234567890",
    redirectUri: "https://app.example/oauth/callback",
    scopes: ["read", "write"],
    state: "s".repeat(43),
    codeChallenge: "c".repeat(43),
    codeChallengeMethod: "S256",
    handoffChallenge: "h".repeat(43),
    authorizationLifetimeSeconds: 86_400,
  }

  appPort.postMessage({...valid, launchId: "other"})
  appPort.postMessage({...valid, scopes: []})
  appPort.postMessage({...valid, state: "weak"})
  appPort.postMessage({...valid, codeChallengeMethod: "plain"})
  appPort.postMessage({...valid, accessToken: "must-not-enter-the-host"})
  appPort.postMessage({...valid, authorizationLifetimeSeconds: 86_401.5})
  await tick()
  assert.deepEqual(requests, [])

  appPort.postMessage(valid)
  await tick()
  assert.deepEqual(requests, [
    {
      requestId: "auth-1",
      clientId: "client_1234567890",
      redirectUri: "https://app.example/oauth/callback",
      scopes: ["read", "write"],
      state: "s".repeat(43),
      codeChallenge: "c".repeat(43),
      codeChallengeMethod: "S256",
      handoffChallenge: "h".repeat(43),
      authorizationLifetimeSeconds: 86_400,
    },
  ])

  broker.destroy()
})

test("rejects enumerable-property smuggling on schema arrays", async () => {
  const fixture = iframeFixture()
  const requests = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    launchId: "launch-array-smuggling",
    capabilities: ["wallet.evm"],
    onAuthRequest: request => requests.push(request),
    onComposeRequest: request => requests.push(request),
    onWalletRequest: request => requests.push(request),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-array-smuggling")

  const scopes = ["read"]
  scopes.accessToken = "smuggled"
  appPort.postMessage({
    type: "requestAuth",
    version: "1",
    launchId: "launch-array-smuggling",
    requestId: "auth-smuggle",
    clientId: "client_1234567890",
    redirectUri: "https://app.example/oauth/callback",
    scopes,
    state: "s".repeat(43),
    codeChallenge: "c".repeat(43),
    codeChallengeMethod: "S256",
    handoffChallenge: "h".repeat(43),
  })

  const links = ["https://app.example/result"]
  links.accessToken = "smuggled"
  appPort.postMessage({
    type: "composeNote",
    version: "1",
    launchId: "launch-array-smuggling",
    callId: "compose-smuggle",
    draft: {text: "hello", links},
  })

  const params = []
  params.accessToken = "smuggled"
  appPort.postMessage({
    type: "walletRequest",
    version: "1",
    launchId: "launch-array-smuggling",
    requestId: "wallet-smuggle",
    method: "eth_chainId",
    params,
    userActivation: false,
  })
  await tick()

  assert.deepEqual(requests, [])
  broker.destroy()
})

test("compose requests accept only the narrow draft schema on the active launch", async () => {
  const fixture = iframeFixture()
  const requests = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    launchId: "launch-compose",
    onComposeRequest: request => requests.push(request),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-compose")
  const valid = {
    type: "composeNote",
    version: "1",
    launchId: "launch-compose",
    callId: "compose-call-1",
    draft: {
      text: "I finished the chapter",
      spoilerText: "Chapter result",
      language: "en-GB",
      visibility: "unlisted",
      inReplyTo: "https://social.example/notes/launch",
      links: ["https://app.example/results/1"],
    },
  }

  appPort.postMessage({...valid, launchId: "wrong"})
  appPort.postMessage({...valid, draft: {...valid.draft, media: []}})
  appPort.postMessage({...valid, draft: {...valid.draft, visibility: "private"}})
  appPort.postMessage({...valid, draft: {...valid.draft, links: ["javascript:alert(1)"]}})
  await tick()
  assert.deepEqual(requests, [])

  appPort.postMessage(valid)
  appPort.postMessage(valid)
  await tick()
  assert.deepEqual(requests, [{callId: "compose-call-1", draft: valid.draft}])
  broker.destroy()
})

test("close and external navigation are launch-bound, replay-safe public actions", async () => {
  const fixture = iframeFixture()
  const closes = []
  const external = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    launchId: "launch-actions",
    onCloseRequest: requestId => closes.push(requestId),
    onExternalRequest: request => external.push(request),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-actions")

  appPort.postMessage({
    type: "openExternal",
    version: "1",
    launchId: "launch-actions",
    requestId: "external-1",
    url: "javascript:alert(1)",
    userActivation: true,
  })
  appPort.postMessage({
    type: "openExternal",
    version: "1",
    launchId: "launch-actions",
    requestId: "external-1",
    url: "https://docs.example/chapter/1",
    userActivation: false,
  })
  appPort.postMessage({
    type: "openExternal",
    version: "1",
    launchId: "launch-actions",
    requestId: "external-1",
    url: "https://docs.example/chapter/1",
    userActivation: true,
  })
  appPort.postMessage({
    type: "openExternal",
    version: "1",
    launchId: "launch-actions",
    requestId: "external-1",
    url: "https://docs.example/chapter/1",
    userActivation: true,
  })

  appPort.postMessage({
    type: "close",
    version: "1",
    launchId: "wrong",
    requestId: "close-1",
  })
  appPort.postMessage({
    type: "close",
    version: "1",
    launchId: "launch-actions",
    requestId: "close-1",
  })
  await tick()

  assert.deepEqual(external, [
    {requestId: "external-1", url: "https://docs.example/chapter/1"},
  ])
  assert.deepEqual(closes, ["close-1"])
  broker.destroy()
})

test("wallet discovery and connection requests use a strict, replay-safe schema", async () => {
  const fixture = iframeFixture()
  const requests = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://wallet.example",
    launchId: "launch-wallet",
    capabilities: ["wallet.evm"],
    onWalletRequest: request => requests.push(request),
  })

  fixture.load()
  assert.deepEqual(fixture.posts[0].message.bootstrap.capabilities, ["wallet.evm"])
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-wallet")

  appPort.postMessage({
    type: "walletRequest",
    version: "1",
    launchId: "launch-wallet",
    requestId: "wallet-chain",
    method: "eth_chainId",
    params: [],
    userActivation: false,
  })
  appPort.postMessage({
    type: "walletRequest",
    version: "1",
    launchId: "launch-wallet",
    requestId: "wallet-accounts",
    method: "eth_accounts",
    params: [],
    userActivation: false,
  })
  appPort.postMessage({
    type: "walletRequest",
    version: "1",
    launchId: "launch-wallet",
    requestId: "wallet-connect",
    method: "eth_requestAccounts",
    params: [],
    userActivation: false,
  })
  appPort.postMessage({
    type: "walletRequest",
    version: "1",
    launchId: "launch-wallet",
    requestId: "wallet-connect",
    method: "eth_requestAccounts",
    params: [],
    userActivation: true,
  })
  appPort.postMessage({
    type: "walletRequest",
    version: "1",
    launchId: "launch-wallet",
    requestId: "wallet-sign",
    method: "personal_sign",
    params: ["0x12", "0x1111111111111111111111111111111111111111"],
    userActivation: true,
  })
  await tick()

  assert.deepEqual(requests, [
    {requestId: "wallet-chain", method: "eth_chainId", params: []},
    {requestId: "wallet-accounts", method: "eth_accounts", params: []},
    {requestId: "wallet-connect", method: "eth_requestAccounts", params: []},
    {
      requestId: "wallet-sign",
      method: "personal_sign",
      params: ["0x12", "0x1111111111111111111111111111111111111111"],
    },
  ])
  broker.destroy()
})

test("privileged wallet methods require activation and exact bounded payloads", async () => {
  const fixture = iframeFixture()
  const requests = []
  const account = "0x1111111111111111111111111111111111111111"
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://wallet.example",
    launchId: "launch-sign",
    capabilities: ["wallet.evm"],
    onWalletRequest: request => requests.push(request),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-sign")
  const personal = {
    type: "walletRequest",
    version: "1",
    launchId: "launch-sign",
    requestId: "sign-1",
    method: "personal_sign",
    params: ["0x68656c6c6f", account],
    userActivation: true,
  }

  appPort.postMessage({...personal, userActivation: false})
  appPort.postMessage({...personal, method: "eth_sign"})
  appPort.postMessage({...personal, params: ["hello", "not-an-address"]})
  appPort.postMessage(personal)
  appPort.postMessage(personal)
  appPort.postMessage({
    ...personal,
    requestId: "typed-1",
    method: "eth_signTypedData_v4",
    params: [
      account,
      '{"types":{"EIP712Domain":[],"Mail":[]},"primaryType":"Mail","domain":{},"message":{}}',
    ],
  })
  appPort.postMessage({
    ...personal,
    requestId: "tx-1",
    method: "eth_sendTransaction",
    params: [
      {
        from: account.toUpperCase().replace("0X", "0x"),
        to: "0x2222222222222222222222222222222222222222",
        value: "0xA",
        data: "0xAB",
      },
    ],
  })
  await tick()

  assert.deepEqual(requests, [
    {requestId: "sign-1", method: "personal_sign", params: personal.params},
    {
      requestId: "typed-1",
      method: "eth_signTypedData_v4",
      params: [
        account,
        '{"domain":{},"message":{},"primaryType":"Mail","types":{"EIP712Domain":[],"Mail":[]}}',
      ],
    },
    {
      requestId: "tx-1",
      method: "eth_sendTransaction",
      params: [
        {
          from: account,
          to: "0x2222222222222222222222222222222222222222",
          data: "0xab",
          value: "0xa",
        },
      ],
    },
  ])
  broker.destroy()
})

test("notification permission requests are capability-gated, strict, and replay-safe", async () => {
  const fixture = iframeFixture()
  const requests = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    hostOrigin: "https://social.example",
    launchId: "launch-notifications",
    capabilities: ["notifications.activitypub"],
    onNotificationPermissionRequest: request => requests.push(request),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-notifications")
  const get = {
    type: "getNotificationPermission",
    version: "1",
    launchId: "launch-notifications",
    requestId: "notification-get",
  }
  const request = {
    type: "requestNotificationPermission",
    version: "1",
    launchId: "launch-notifications",
    requestId: "notification-request",
    userActivation: true,
  }

  appPort.postMessage({...get, launchId: "wrong"})
  appPort.postMessage({...get, extra: true})
  appPort.postMessage({...request, userActivation: false})
  appPort.postMessage(request)
  appPort.postMessage(request)
  appPort.postMessage(get)
  appPort.postMessage(get)
  await tick()

  assert.deepEqual(requests, [
    {requestId: "notification-request", action: "request"},
    {requestId: "notification-get", action: "get"},
  ])
  broker.destroy()
})

test("notification messages are rejected when the host omitted the capability", async () => {
  const fixture = iframeFixture()
  const requests = []
  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    hostOrigin: "https://social.example",
    launchId: "launch-no-notifications",
    capabilities: [],
    onNotificationPermissionRequest: request => requests.push(request),
  })

  fixture.load()
  const appPort = fixture.posts[0].transfer[0]
  await markReady(appPort, "launch-no-notifications")
  appPort.postMessage({
    type: "getNotificationPermission",
    version: "1",
    launchId: "launch-no-notifications",
    requestId: "notification-get",
  })
  await tick()
  assert.deepEqual(requests, [])
  broker.destroy()
})
