import assert from "node:assert/strict"
import test from "node:test"

import {createFediverseMiniAppSDK} from "../js/lib/fediverse_miniapp_sdk.mjs"

const launchId = "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"

const fixture = () => {
  const listeners = new Map()
  const parentWindow = {}
  let random = 0
  const windowObject = {
    parent: parentWindow,
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (listeners.get(name) === callback) listeners.delete(name)
    },
  }
  const cryptoObject = {
    getRandomValues: bytes => {
      bytes.fill(++random)
      return bytes
    },
  }

  return {
    parentWindow,
    windowObject,
    cryptoObject,
    bootstrap: ({origin = "https://social.example", source = parentWindow, message = {}} = {}) => {
      const channel = new MessageChannel()
      listeners.get("message")?.({
        origin,
        source,
        ports: [channel.port2],
        data: {
          type: "fediverse-miniapp:bootstrap",
          version: "1",
          launchId,
          hostOrigin: "https://social.example",
          issuer: "https://social.example",
          authorizationServerMetadata:
            "https://social.example/.well-known/oauth-authorization-server",
          authorizationResultRelay: "https://social.example/mini-apps/oauth/relay",
          capabilities: ["wallet.evm"],
          ...message,
        },
      })
      channel.port1.start?.()
      return channel.port1
    },
  }
}

const nextMessage = port =>
  new Promise(resolve => port.addEventListener("message", event => resolve(event.data), {once: true}))

test("pins the exact bootstrap origin and exposes immutable bootstrap data", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    allowedHostOrigin: origin => origin === "https://social.example",
  })

  f.bootstrap({origin: "https://evil.example"}).close()
  f.bootstrap({source: {}}).close()
  const hostPort = f.bootstrap()

  assert.deepEqual(await sdk.connect(), {
    version: "1",
    launchId,
    hostOrigin: "https://social.example",
    issuer: "https://social.example",
    authorizationServerMetadata:
      "https://social.example/.well-known/oauth-authorization-server",
    authorizationResultRelay: "https://social.example/mini-apps/oauth/relay",
    capabilities: ["wallet.evm"],
  })
  assert.equal(Object.isFrozen(sdk.bootstrap), true)

  const ready = nextMessage(hostPort)
  await sdk.ready()
  assert.deepEqual(await ready, {type: "ready", version: "1", launchId})
  sdk.destroy()
  hostPort.close()
})

test("gets immutable public launch info without using permissioned context", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    allowedHostOrigin: () => true,
  })
  const hostPort = f.bootstrap()
  await sdk.connect()

  const requestMessage = nextMessage(hostPort)
  const launchInfoPromise = sdk.getLaunchInfo()
  const request = await requestMessage
  assert.equal(request.type, "getLaunchInfo")
  hostPort.postMessage({
    type: "launchInfoResult",
    version: "1",
    launchId,
    requestId: request.requestId,
    launchInfo: {
      version: "1",
      launchUrl: "https://app.example/read?chapter=2",
      linkedUrl: "https://app.example/shared?chapter=2",
      sourceNoteId: "http://localhost:4000/notes/123",
    },
  })

  const launchInfo = await launchInfoPromise
  assert.deepEqual(launchInfo, {
    version: "1",
    launchUrl: "https://app.example/read?chapter=2",
    linkedUrl: "https://app.example/shared?chapter=2",
    sourceNoteId: "http://localhost:4000/notes/123",
  })
  assert.equal(Object.isFrozen(launchInfo), true)
  sdk.destroy()
  hostPort.close()
})

test("notification permission reports authentication and availability failures", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    navigatorObject: {userActivation: {isActive: true}},
    allowedHostOrigin: () => true,
  })
  const hostPort = f.bootstrap({message: {capabilities: ["notifications.activitypub"]}})
  await sdk.connect()

  const authMessage = nextMessage(hostPort)
  const authPromise = sdk.notifications.getPermission()
  const authRequest = await authMessage
  hostPort.postMessage({
    type: "notificationPermissionResult",
    version: "1",
    launchId,
    requestId: authRequest.requestId,
    status: "auth_required",
  })
  await assert.rejects(authPromise, error => error.code === "AUTH_REQUIRED")

  const unavailableMessage = nextMessage(hostPort)
  const unavailablePromise = sdk.notifications.getPermission()
  const unavailableRequest = await unavailableMessage
  hostPort.postMessage({
    type: "notificationPermissionResult",
    version: "1",
    launchId,
    requestId: unavailableRequest.requestId,
    status: "unavailable",
  })
  await assert.rejects(unavailablePromise, error => error.code === "CAPABILITY_UNAVAILABLE")

  sdk.destroy()
  hostPort.close()
})

test("browser-code OAuth returns only the PKCE authorization code", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    allowedHostOrigin: () => true,
  })
  const hostPort = f.bootstrap()
  await sdk.connect()

  const authMessage = nextMessage(hostPort)
  const authPromise = sdk.requestAuth({
    completionMode: "browser_code",
    clientId: "client_1234567890",
    redirectUri: "https://app.example/oauth/callback",
    scopes: ["identify"],
    state: "s".repeat(43),
    codeChallenge: "c".repeat(43),
  })
  const authRequest = await authMessage
  assert.equal(authRequest.completionMode, "browser_code")
  assert.equal("handoffChallenge" in authRequest, false)

  hostPort.postMessage({
    type: "authResult",
    version: "1",
    launchId,
    requestId: authRequest.requestId,
    status: "success",
    handoffCode: "wrong_completion_mode_1234",
  })
  hostPort.postMessage({
    type: "authResult",
    version: "1",
    launchId,
    requestId: authRequest.requestId,
    status: "success",
    authorizationCode: "a".repeat(43),
  })

  assert.deepEqual(await authPromise, {
    status: "success",
    authorizationCode: "a".repeat(43),
  })
  sdk.destroy()
  hostPort.close()
})

test("correlates context and external action promises over the private port", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    navigatorObject: {userActivation: {isActive: true}},
    allowedHostOrigin: () => true,
  })
  const hostPort = f.bootstrap()
  await sdk.connect()

  const contextMessage = nextMessage(hostPort)
  const contextPromise = sdk.getContext()
  const contextRequest = await contextMessage
  assert.equal(contextRequest.type, "getContext")
  assert.equal(contextRequest.version, "1")
  hostPort.postMessage({
    type: "contextResult",
    version: "1",
    launchId,
    requestId: contextRequest.requestId,
    status: "ok",
    context: {launchUrl: "https://evil.example"},
    accessToken: "must-be-rejected",
  })
  hostPort.postMessage({
    type: "contextResult",
    version: "1",
    launchId,
    requestId: contextRequest.requestId,
    status: "ok",
    context: {launchUrl: "https://app.example/page"},
  })
  assert.deepEqual(await contextPromise, {launchUrl: "https://app.example/page"})

  const externalMessage = nextMessage(hostPort)
  const externalPromise = sdk.openExternal("https://docs.example/page")
  const externalRequest = await externalMessage
  assert.equal(externalRequest.userActivation, true)
  hostPort.postMessage({
    type: "openExternalResult",
    version: "1",
    launchId,
    requestId: externalRequest.requestId,
    status: "approved",
  })
  assert.deepEqual(await externalPromise, {status: "approved"})
  sdk.destroy()
  hostPort.close()
})

test("provides OAuth, compose receipts, and an EIP-1193-compatible provider", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    navigatorObject: {userActivation: {isActive: true}},
    allowedHostOrigin: () => true,
  })
  const hostPort = f.bootstrap()
  await sdk.connect()

  const authMessage = nextMessage(hostPort)
  const authPromise = sdk.requestAuth({
    clientId: "client_1234567890",
    redirectUri: "https://app.example/oauth/callback",
    scopes: ["read"],
    state: "s".repeat(43),
    codeChallenge: "c".repeat(43),
    handoffChallenge: "h".repeat(43),
    authorizationLifetimeSeconds: 86_400,
  })
  const authRequest = await authMessage
  assert.equal(authRequest.authorizationLifetimeSeconds, 86_400)
  hostPort.postMessage({
    type: "authResult",
    version: "1",
    launchId,
    requestId: authRequest.requestId,
    status: "success",
    handoffCode: "handoff_code_1234567890",
  })
  assert.equal((await authPromise).handoffCode, "handoff_code_1234567890")

  const published = []
  sdk.on("composeNotePublished", receipt => published.push(receipt))
  const composeMessage = nextMessage(hostPort)
  const composePromise = sdk.composeNote({text: "hello", visibility: "public"})
  const composeRequest = await composeMessage
  hostPort.postMessage({
    type: "composeNoteResult",
    version: "1",
    launchId,
    callId: composeRequest.callId,
    requestId: "host-compose-1",
    status: "accepted",
  })
  assert.deepEqual(await composePromise, {status: "accepted", requestId: "host-compose-1"})
  hostPort.postMessage({
    type: "composeNotePublished",
    version: "1",
    launchId,
    requestId: "host-compose-1",
    id: "https://social.example/objects/1",
    scope: "public",
  })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(published[0].id, "https://social.example/objects/1")

  const walletMessage = nextMessage(hostPort)
  const walletPromise = sdk.wallet.getProvider().request({method: "eth_chainId", params: []})
  const walletRequest = await walletMessage
  hostPort.postMessage({
    type: "walletResult",
    version: "1",
    launchId,
    requestId: walletRequest.requestId,
    result: "0x2105",
  })
  assert.equal(await walletPromise, "0x2105")
  sdk.destroy()
  hostPort.close()
})

test("rejects unavailable capabilities, wallet errors, timeouts, and destroyed requests", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    navigatorObject: {userActivation: {isActive: true}},
    allowedHostOrigin: () => true,
    timeoutMs: 5,
  })
  const hostPort = f.bootstrap({message: {capabilities: []}})
  await sdk.connect()

  await assert.rejects(
    sdk.wallet.getProvider().request({method: "eth_chainId", params: []}),
    error => error.code === 4200
  )
  await assert.rejects(sdk.getContext(), error => error.code === "TIMEOUT")

  const pending = sdk.openExternal("https://docs.example")
  sdk.destroy()
  await assert.rejects(pending, error => error.code === "DESTROYED")
  hostPort.close()
})

test("requires a current user gesture before privileged host actions", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    navigatorObject: {userActivation: {isActive: false}},
    allowedHostOrigin: () => true,
  })
  const hostPort = f.bootstrap()
  await sdk.connect()

  await assert.rejects(
    sdk.openExternal("https://docs.example"),
    error => error.code === "USER_ACTIVATION_REQUIRED"
  )
  await assert.rejects(
    sdk.wallet.getProvider().request({method: "eth_requestAccounts", params: []}),
    error => error.code === "USER_ACTIVATION_REQUIRED"
  )
  sdk.destroy()
  hostPort.close()
})

test("normalizes wallet requests and rejects malformed wallet results without waiting for timeout", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    navigatorObject: {userActivation: {isActive: true}},
    allowedHostOrigin: () => true,
    timeoutMs: 1_000,
  })
  const hostPort = f.bootstrap()
  await sdk.connect()

  const account = "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  const recipient = "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
  const walletMessage = nextMessage(hostPort)
  const walletPromise = sdk.wallet.getProvider().request({
    method: "eth_sendTransaction",
    params: [{from: account, to: recipient, value: "0xA", data: "0xAB"}],
  })
  const request = await walletMessage
  assert.deepEqual(request.params, [
    {
      from: account.toLowerCase(),
      to: recipient.toLowerCase(),
      data: "0xab",
      value: "0xa",
    },
  ])

  hostPort.postMessage({
    type: "walletResult",
    version: "1",
    launchId,
    requestId: request.requestId,
    result: "0x" + "ab".repeat(200_000),
  })
  await assert.rejects(
    walletPromise,
    error => error.code === -32603 && error.message === "Invalid wallet response"
  )

  const chainMessage = nextMessage(hostPort)
  const chainPromise = sdk.wallet.getProvider().request({method: "eth_chainId", params: []})
  const chainRequest = await chainMessage
  hostPort.postMessage({
    type: "walletResult",
    version: "1",
    launchId,
    requestId: chainRequest.requestId,
    error: {code: 4001, message: "x".repeat(257)},
  })
  await assert.rejects(
    chainPromise,
    error => error.code === -32603 && error.message === "Invalid wallet response"
  )

  sdk.destroy()
  hostPort.close()
})

test("reads and requests ActivityPub notification permission through a typed capability", async () => {
  const f = fixture()
  const sdk = createFediverseMiniAppSDK({
    windowObject: f.windowObject,
    parentWindow: f.parentWindow,
    cryptoObject: f.cryptoObject,
    navigatorObject: {userActivation: {isActive: true}},
    allowedHostOrigin: () => true,
  })
  const hostPort = f.bootstrap({message: {capabilities: ["notifications.activitypub"]}})
  await sdk.connect()

  const getMessage = nextMessage(hostPort)
  const getPromise = sdk.notifications.getPermission()
  const getRequest = await getMessage
  assert.equal(getRequest.type, "getNotificationPermission")
  hostPort.postMessage({
    type: "notificationPermissionResult",
    version: "1",
    launchId,
    requestId: getRequest.requestId,
    status: "ok",
    state: "prompt",
    actorUrl: "https://app.example/ap/actor",
  })
  assert.deepEqual(await getPromise, {
    state: "prompt",
    actorUrl: "https://app.example/ap/actor",
  })

  const requestMessage = nextMessage(hostPort)
  const requestPromise = sdk.notifications.requestPermission()
  const permissionRequest = await requestMessage
  assert.equal(permissionRequest.type, "requestNotificationPermission")
  assert.equal(permissionRequest.userActivation, true)
  hostPort.postMessage({
    type: "notificationPermissionResult",
    version: "1",
    launchId,
    requestId: permissionRequest.requestId,
    status: "ok",
    state: "granted",
    actorUrl: "https://app.example/ap/actor",
  })
  assert.deepEqual(await requestPromise, {
    state: "granted",
    actorUrl: "https://app.example/ap/actor",
  })

  sdk.destroy()
  hostPort.close()
})

test("notification permission is capability-gated and prompting requires activation", async () => {
  const unavailable = fixture()
  const unavailableSdk = createFediverseMiniAppSDK({
    windowObject: unavailable.windowObject,
    parentWindow: unavailable.parentWindow,
    cryptoObject: unavailable.cryptoObject,
    navigatorObject: {userActivation: {isActive: true}},
    allowedHostOrigin: () => true,
  })
  const unavailablePort = unavailable.bootstrap({message: {capabilities: []}})
  await unavailableSdk.connect()
  await assert.rejects(
    unavailableSdk.notifications.getPermission(),
    error => error.code === "CAPABILITY_UNAVAILABLE"
  )
  unavailableSdk.destroy()
  unavailablePort.close()

  const inactive = fixture()
  const inactiveSdk = createFediverseMiniAppSDK({
    windowObject: inactive.windowObject,
    parentWindow: inactive.parentWindow,
    cryptoObject: inactive.cryptoObject,
    navigatorObject: {userActivation: {isActive: false}},
    allowedHostOrigin: () => true,
  })
  const inactivePort = inactive.bootstrap({
    message: {capabilities: ["notifications.activitypub"]},
  })
  await inactiveSdk.connect()
  await assert.rejects(
    inactiveSdk.notifications.requestPermission(),
    error => error.code === "USER_ACTIVATION_REQUIRED"
  )
  inactiveSdk.destroy()
  inactivePort.close()
})
