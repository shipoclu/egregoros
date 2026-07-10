import assert from "node:assert/strict"
import test from "node:test"

import {createMiniAppBroker} from "../js/lib/mini_app_broker.mjs"

const tick = () => new Promise(resolve => setImmediate(resolve))

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

test("broker transfers one capability port to the exact app origin", () => {
  const fixture = iframeFixture()

  const broker = createMiniAppBroker({
    iframe: fixture.iframe,
    appOrigin: "https://app.example",
    launchId: "launch-1",
    onReady: () => {},
  })

  fixture.load()

  assert.equal(fixture.posts.length, 1)
  assert.equal(fixture.posts[0].targetOrigin, "https://app.example")
  assert.equal(fixture.posts[0].transfer.length, 1)
  assert.deepEqual(fixture.posts[0].message, {
    type: "fediverse-miniapp:bootstrap",
    version: "1",
    launchId: "launch-1",
    capabilities: [],
  })
  assert.equal("context" in fixture.posts[0].message, false)
  assert.equal("user" in fixture.posts[0].message, false)

  broker.destroy()
  assert.equal(fixture.hasLoadListener(), false)
})

test("ready is accepted only through the transferred port for the active launch", async () => {
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

  appPort.postMessage({type: "ready", launchId: "wrong"})
  appPort.postMessage({type: "unknown", launchId: "launch-2"})
  await tick()
  assert.equal(readyCount, 0)

  appPort.postMessage({type: "ready", launchId: "launch-2"})
  appPort.postMessage({type: "ready", launchId: "launch-2"})
  await tick()
  assert.equal(readyCount, 1)

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

  appPort.postMessage({type: "getContext", launchId: "wrong", requestId: "ctx-1"})
  appPort.postMessage({type: "getContext", launchId: "launch-3", requestId: "bad request"})
  appPort.postMessage({type: "getContext", launchId: "launch-3", requestId: "ctx-1"})
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
  }

  appPort.postMessage({...valid, launchId: "other"})
  appPort.postMessage({...valid, scopes: []})
  appPort.postMessage({...valid, state: "weak"})
  appPort.postMessage({...valid, codeChallengeMethod: "plain"})
  appPort.postMessage({...valid, accessToken: "must-not-enter-the-host"})
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
    },
  ])

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
  assert.deepEqual(fixture.posts[0].message.capabilities, ["wallet.evm"])
  const appPort = fixture.posts[0].transfer[0]

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
  ])
  broker.destroy()
})
