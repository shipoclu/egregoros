import assert from "node:assert/strict"
import test from "node:test"

import {createMiniAppFrameRelay} from "../js/lib/mini_app_frame_relay.mjs"

const tick = () => new Promise(resolve => setImmediate(resolve))

test("relays one exact-host channel to one exact-origin sandboxed app frame", async () => {
  const listeners = new Map()
  const frameListeners = new Map()
  const appPosts = []
  const parentWindow = {}
  const iframe = {
    contentWindow: {
      postMessage: (message, targetOrigin, ports) =>
        appPosts.push({message, targetOrigin, ports}),
    },
    addEventListener: (name, callback) => frameListeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (frameListeners.get(name) === callback) frameListeners.delete(name)
    },
  }
  const windowObject = {
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (listeners.get(name) === callback) listeners.delete(name)
    },
  }
  const relay = createMiniAppFrameRelay({
    windowObject,
    parentWindow,
    iframe,
    hostOrigin: "https://social.example",
    appOrigin: "https://app.example",
  })
  const hostChannel = new MessageChannel()
  const bootstrap = {
    type: "fediverse-miniapp:bootstrap",
    version: "1",
    launchId: "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789",
    hostOrigin: "https://social.example",
    issuer: "https://social.example",
    authorizationServerMetadata:
      "https://social.example/.well-known/oauth-authorization-server",
    authorizationResultRelay: "https://social.example/mini-apps/oauth/relay",
    capabilities: [],
  }

  listeners.get("message")({
    origin: "https://evil.example",
    source: parentWindow,
    ports: [hostChannel.port2],
    data: {type: "fediverse-miniapp:host-bootstrap", appOrigin: "https://app.example", bootstrap},
  })
  assert.equal(appPosts.length, 0)
  frameListeners.get("load")()

  listeners.get("message")({
    origin: "https://social.example",
    source: parentWindow,
    ports: [hostChannel.port2],
    data: {type: "fediverse-miniapp:host-bootstrap", appOrigin: "https://app.example", bootstrap},
  })
  assert.equal(appPosts[0].targetOrigin, "https://app.example")
  assert.deepEqual(appPosts[0].message, bootstrap)

  const appPort = appPosts[0].ports[0]
  const fromApp = []
  hostChannel.port1.onmessage = event => fromApp.push(event.data)
  hostChannel.port1.start?.()
  appPort.postMessage({type: "ready", version: "1", launchId: bootstrap.launchId})
  await tick()
  await tick()
  assert.equal(fromApp[0].type, "ready")

  const fromHost = []
  appPort.onmessage = event => fromHost.push(event.data)
  appPort.start?.()
  hostChannel.port1.postMessage({type: "contextResult"})
  await tick()
  await tick()
  assert.equal(fromHost[0].type, "contextResult")

  relay.destroy()
  hostChannel.port1.close()
})
