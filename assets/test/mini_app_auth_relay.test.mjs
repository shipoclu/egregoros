import assert from "node:assert/strict"
import test from "node:test"

import {createMiniAppAuthRelay} from "../js/lib/mini_app_auth_relay.mjs"

const windowFixture = () => {
  const listeners = new Map()

  return {
    windowObject: {
      addEventListener: (name, callback) => listeners.set(name, callback),
      removeEventListener: (name, callback) => {
        if (listeners.get(name) === callback) listeners.delete(name)
      },
    },
    dispatch: event => listeners.get("message")?.(event),
    listening: () => listeners.has("message"),
  }
}

test("relays only a strict callback from the exact app origin and popup", () => {
  const fixture = windowFixture()
  const results = []
  const completed = []
  const popup = {}
  const relay = createMiniAppAuthRelay({
    windowObject: fixture.windowObject,
    sendResult: result => results.push(result),
    onComplete: result => completed.push(result),
  })

  relay.begin({
    popup,
    appOrigin: "https://app.example",
    launchId: "launch-1",
    requestId: "auth-1",
  })

  const valid = {
    type: "fediverse-miniapp:auth-callback",
    version: "1",
    launchId: "launch-1",
    requestId: "auth-1",
    status: "success",
    handoffCode: "handoff_code_1234567890",
  }

  fixture.dispatch({origin: "https://evil.example", source: popup, data: valid})
  fixture.dispatch({origin: "https://app.example", source: {}, data: valid})
  fixture.dispatch({origin: "https://app.example", source: popup, data: {...valid, accessToken: "x"}})
  fixture.dispatch({origin: "https://app.example", source: popup, data: {...valid, requestId: "other"}})
  assert.deepEqual(results, [])

  fixture.dispatch({origin: "https://app.example", source: popup, data: valid})

  assert.deepEqual(results, [
    {
      type: "authResult",
      version: "1",
      launchId: "launch-1",
      requestId: "auth-1",
      status: "success",
      handoffCode: "handoff_code_1234567890",
    },
  ])
  assert.deepEqual(completed, [{launchId: "launch-1", requestId: "auth-1", status: "success"}])

  fixture.dispatch({origin: "https://app.example", source: popup, data: valid})
  assert.equal(results.length, 1)

  relay.destroy()
  assert.equal(fixture.listening(), false)
})

test("accepts bounded failure callbacks without a handoff code", () => {
  const fixture = windowFixture()
  const results = []
  const popup = {}
  const relay = createMiniAppAuthRelay({
    windowObject: fixture.windowObject,
    sendResult: result => results.push(result),
  })

  relay.begin({
    popup,
    appOrigin: "https://app.example",
    launchId: "launch-2",
    requestId: "auth-2",
  })

  fixture.dispatch({
    origin: "https://app.example",
    source: popup,
    data: {
      type: "fediverse-miniapp:auth-callback",
      version: "1",
      launchId: "launch-2",
      requestId: "auth-2",
      status: "cancelled",
    },
  })

  assert.equal(results[0].status, "cancelled")
  assert.equal("handoffCode" in results[0], false)
  relay.destroy()
})
