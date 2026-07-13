import assert from "node:assert/strict"
import test from "node:test"

import {
  createMiniAppAuthCompletionRelay,
  createMiniAppAuthRelay,
  openMiniAppAuthWindow,
} from "../js/lib/mini_app_auth_relay.mjs"

const launchId = "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
const oauthState = "s".repeat(43)

const broadcastFixture = () => {
  const channels = new Map()

  const factory = name => {
    const channel = {
      name,
      onmessage: null,
      closed: false,
      postMessage: data => {
        for (const candidate of channels.get(name) || []) {
          if (candidate !== channel && !candidate.closed) candidate.onmessage?.({data})
        }
      },
      close: () => {
        channel.closed = true
      },
    }
    const existing = channels.get(name) || []
    existing.push(channel)
    channels.set(name, existing)
    return channel
  }

  return {factory, channels}
}

test("relays only a strict completion over a launch-secret same-origin channel", () => {
  const broadcasts = broadcastFixture()
  const results = []
  const completed = []
  let popupClosed = 0
  const relay = createMiniAppAuthRelay({
    broadcastChannelFactory: broadcasts.factory,
    sendResult: result => results.push(result),
    onComplete: result => completed.push(result),
  })

  relay.begin({
    launchId,
    requestId: "auth-1",
    state: oauthState,
    popup: {close: () => popupClosed++},
  })

  const valid = {
    type: "fediverse-miniapp:auth-completion",
    version: "1",
    launchId,
    state: oauthState,
    status: "success",
    handoffCode: "handoff_code_1234567890",
  }
  const publisher = broadcasts.factory(
    `fediverse-miniapp-auth:${launchId}:${oauthState}`
  )

  publisher.postMessage({...valid, accessToken: "x"})
  publisher.postMessage({...valid, launchId: "wrong"})
  publisher.postMessage({...valid, state: "x".repeat(43)})
  assert.deepEqual(results, [])

  publisher.postMessage(valid)

  assert.deepEqual(results, [
    {
      type: "authResult",
      version: "1",
      launchId,
      requestId: "auth-1",
      status: "success",
      handoffCode: "handoff_code_1234567890",
    },
  ])
  assert.deepEqual(completed, [
    {
      launchId,
      requestId: "auth-1",
      status: "success",
    },
  ])
  assert.equal(popupClosed, 1)

  publisher.postMessage(valid)
  assert.equal(results.length, 1)

  relay.destroy()
})

test("accepts bounded failure callbacks without a handoff code", () => {
  const broadcasts = broadcastFixture()
  const results = []
  const relay = createMiniAppAuthRelay({
    broadcastChannelFactory: broadcasts.factory,
    sendResult: result => results.push(result),
  })

  relay.begin({
    launchId,
    requestId: "auth-2",
    state: oauthState,
    popup: {close: () => {}},
  })

  const publisher = broadcasts.factory(
    `fediverse-miniapp-auth:${launchId}:${oauthState}`
  )
  publisher.postMessage({
    type: "fediverse-miniapp:auth-completion",
    version: "1",
    launchId,
    state: oauthState,
    status: "cancelled",
  })

  assert.equal(results[0].status, "cancelled")
  assert.equal("handoffCode" in results[0], false)
  relay.destroy()
})

test("completion page parses an exact fragment, broadcasts once, and never uses opener", () => {
  const broadcasts = broadcastFixture()
  let closed = 0
  const locationObject = {
    hash:
      `#version=1&launch_id=${launchId}&state=${oauthState}&status=success&handoff_code=handoff_code_1234567890`,
  }
  const listener = broadcasts.factory(
    `fediverse-miniapp-auth:${launchId}:${oauthState}`
  )
  const messages = []
  listener.onmessage = event => messages.push(event.data)

  const completed = createMiniAppAuthCompletionRelay({
    locationObject,
    broadcastChannelFactory: broadcasts.factory,
    schedule: callback => callback(),
    closeWindow: () => closed++,
  })

  assert.equal(completed, true)
  assert.deepEqual(messages, [
    {
      type: "fediverse-miniapp:auth-completion",
      version: "1",
      launchId,
      state: oauthState,
      status: "success",
      handoffCode: "handoff_code_1234567890",
    },
  ])
  assert.equal(closed, 1)
})

test("completion page rejects duplicate, oversized, and token-smuggling fragments", () => {
  const fragments = [
    `#version=1&version=1&launch_id=${launchId}&state=${oauthState}&status=cancelled`,
    `#version=1&launch_id=${launchId}&state=${oauthState}&status=cancelled&padding=${"x".repeat(1100)}`,
    `#version=1&launch_id=${launchId}&state=${oauthState}&status=success&handoff_code=handoff_code_1234567890&access_token=secret`,
    `#version=1&launch_id=${launchId}&state=weak&status=cancelled`,
  ]

  for (const hash of fragments) {
    const broadcasts = broadcastFixture()
    assert.equal(
      createMiniAppAuthCompletionRelay({
        locationObject: {hash},
        broadcastChannelFactory: broadcasts.factory,
        schedule: callback => callback(),
        closeWindow: () => {},
      }),
      false
    )
  }
})

test("authorization windows retain a host-close handle while clearing the popup opener", () => {
  const calls = []
  const popup = {opener: "must-not-be-retained"}
  const windowObject = {
    open: (...args) => {
      calls.push(args)
      return popup
    },
  }

  assert.equal(
    openMiniAppAuthWindow({
      windowObject,
      url: "/oauth/authorize?client_id=client",
      requestId: "auth-1",
    }),
    popup
  )
  assert.equal(popup.opener, null)
  assert.equal(calls.length, 1)
  assert.equal(calls[0][1], "fediverse-miniapp-auth-auth-1")
  assert.doesNotMatch(calls[0][2], /(?:^|,)noopener(?:,|$)/)
  assert.doesNotMatch(calls[0][2], /(?:^|,)noreferrer(?:,|$)/)
})
