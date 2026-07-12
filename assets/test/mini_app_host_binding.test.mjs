import assert from "node:assert/strict"
import test from "node:test"

import MiniAppHost from "../js/hooks/mini_app_host.js"

const launchId = "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
const resolutionToken = "9a58f30b-70ae-4285-938d-5afcd7556be1"

const frameDocument = () => {
  const frames = []

  return {
    frames,
    documentObject: {
      createElement: name => {
        assert.equal(name, "iframe")
        const listeners = new Map()
        let src = ""
        const frame = {
          contentWindow: {},
          addEventListener: (event, listener) => listeners.set(event, listener),
          removeEventListener: (event, listener) => {
            if (listeners.get(event) === listener) listeners.delete(event)
          },
          get src() {
            return src
          },
          set src(value) {
            src = value
          },
        }
        frames.push(frame)
        return frame
      },
    },
  }
}

const hookContext = ({documentObject, frameSrc}) => {
  let child = null
  let loading = 0
  const shell = {
    querySelector: selector => (selector === "#mini-app-frame" ? child : null),
    replaceChildren: replacement => {
      child = replacement || null
    },
  }
  const dataset = {
    appOrigin: "https://app.example",
    launchId,
    frameSrc,
    frameTitle: "Reader mini app",
    walletEnabled: "false",
    notificationsEnabled: "false",
  }

  return {
    documentObject,
    shell,
    loading: () => loading,
    value: {
      el: {
        dataset,
        querySelector: selector => (selector === "#mini-app-frame-shell" ? shell : null),
      },
      broker: null,
      frame: null,
      brokerKey: null,
      brokerFailedKey: null,
      walletAdapter: {available: () => false},
      walletCompatible: null,
      walletCheckPending: false,
      authRelay: {cancel: () => {}},
      readiness: {
        loading: () => (loading += 1),
        ready: () => {},
        destroy: () => {},
      },
      pushEvent: () => {},
      destroyBroker: MiniAppHost.destroyBroker,
    },
  }
}

const withDocument = async (documentObject, callback) => {
  const previousDocument = globalThis.document
  const previousWindow = globalThis.window
  globalThis.document = documentObject
  globalThis.window = {location: {origin: "https://social.example"}}

  try {
    await callback()
  } finally {
    globalThis.document = previousDocument
    globalThis.window = previousWindow
  }
}

test("unrelated LiveView patches preserve the exact broker iframe and deadline", async () => {
  const fixture = frameDocument()
  const frameSrc =
    `/mini-apps/broker/card-1?launch_id=${launchId}&resolution_token=${resolutionToken}`
  const hook = hookContext({documentObject: fixture.documentObject, frameSrc})

  await withDocument(fixture.documentObject, () => {
    MiniAppHost.bindFrame.call(hook.value)
    const mountedFrame = hook.value.frame

    MiniAppHost.bindFrame.call(hook.value)

    assert.equal(fixture.frames.length, 1)
    assert.equal(hook.value.frame, mountedFrame)
    assert.equal(hook.shell.querySelector("#mini-app-frame"), mountedFrame)
    assert.equal(hook.loading(), 1)
    hook.value.destroyBroker()
  })
})

test("an invalid broker binding fails once instead of retrying on every patch", async () => {
  const fixture = frameDocument()
  const hook = hookContext({
    documentObject: fixture.documentObject,
    frameSrc: "https://evil.example/mini-apps/broker/card-1",
  })

  await withDocument(fixture.documentObject, () => {
    MiniAppHost.bindFrame.call(hook.value)
    const failedKey = hook.value.brokerFailedKey

    MiniAppHost.bindFrame.call(hook.value)

    assert.equal(fixture.frames.length, 1)
    assert.equal(hook.value.frame, null)
    assert.equal(hook.value.broker, null)
    assert.equal(hook.value.brokerFailedKey, failedKey)
    assert.equal(hook.loading(), 1)
  })
})
