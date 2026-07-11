import assert from "node:assert/strict"
import test from "node:test"

import {createFediverseMiniAppSDK} from "../js/lib/fediverse_miniapp_sdk.mjs"
import {createMiniAppBroker} from "../js/lib/mini_app_broker.mjs"
import {createMiniAppFrameRelay} from "../js/lib/mini_app_frame_relay.mjs"

const launchId = "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"

test("reference SDK and host broker interoperate over one private channel", async () => {
  const hostOrigin = "https://social.example"
  const appOrigin = "https://app.example"
  const hostWindow = {}
  const appListeners = new Map()
  const relayListeners = new Map()
  const outerFrameListeners = new Map()
  const innerFrameListeners = new Map()
  let random = 0

  const appWindow = {
    addEventListener: (name, callback) => appListeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (appListeners.get(name) === callback) appListeners.delete(name)
    },
  }
  const relayWindow = {
    parent: hostWindow,
    addEventListener: (name, callback) => relayListeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (relayListeners.get(name) === callback) relayListeners.delete(name)
    },
    postMessage: (message, targetOrigin, ports) => {
      if (targetOrigin !== hostOrigin) return
      queueMicrotask(() =>
        relayListeners.get("message")?.({
          data: message,
          origin: hostOrigin,
          source: hostWindow,
          ports,
        })
      )
    },
  }
  appWindow.parent = relayWindow
  appWindow.postMessage = (message, targetOrigin, ports) => {
      if (targetOrigin !== appOrigin) return
      queueMicrotask(() =>
        appListeners.get("message")?.({
          data: message,
          origin: hostOrigin,
          source: relayWindow,
          ports,
        })
      )
    }
  const innerIframe = {
    contentWindow: appWindow,
    addEventListener: (name, callback) => innerFrameListeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (innerFrameListeners.get(name) === callback) innerFrameListeners.delete(name)
    },
  }
  const iframe = {
    contentWindow: relayWindow,
    addEventListener: (name, callback) => outerFrameListeners.set(name, callback),
    removeEventListener: (name, callback) => {
      if (outerFrameListeners.get(name) === callback) outerFrameListeners.delete(name)
    },
  }
  const relay = createMiniAppFrameRelay({
    windowObject: relayWindow,
    parentWindow: hostWindow,
    iframe: innerIframe,
    hostOrigin,
    appOrigin,
  })
  let broker
  const events = []
  broker = createMiniAppBroker({
    iframe,
    appOrigin,
    hostOrigin,
    launchId,
    capabilities: ["notifications.activitypub", "wallet.evm"],
    onReady: () => events.push("ready"),
    onContextRequest: requestId =>
      broker.send({
        type: "contextResult",
        version: "1",
        launchId,
        requestId,
        status: "ok",
        context: {launchUrl: "https://app.example/chapter/2"},
      }),
    onExternalRequest: request =>
      broker.send({
        type: "openExternalResult",
        version: "1",
        launchId,
        requestId: request.requestId,
        status: "approved",
      }),
    onNotificationPermissionRequest: request =>
      broker.send({
        type: "notificationPermissionResult",
        version: "1",
        launchId,
        requestId: request.requestId,
        state: request.action === "request" ? "granted" : "prompt",
        actorUrl: "https://app.example/ap/actor",
      }),
    onWalletRequest: request =>
      broker.send({
        type: "walletResult",
        version: "1",
        launchId,
        requestId: request.requestId,
        result: "0x2105",
      }),
  })
  const sdk = createFediverseMiniAppSDK({
    windowObject: appWindow,
    parentWindow: relayWindow,
    navigatorObject: {userActivation: {isActive: true}},
    cryptoObject: {
      getRandomValues: bytes => {
        bytes.fill(++random)
        return bytes
      },
    },
    allowedHostOrigin: origin => origin === hostOrigin,
  })

  outerFrameListeners.get("load")()
  await new Promise(resolve => setImmediate(resolve))
  innerFrameListeners.get("load")()
  assert.equal((await sdk.connect()).issuer, hostOrigin)
  await sdk.ready()
  await new Promise(resolve => setImmediate(resolve))
  await new Promise(resolve => setImmediate(resolve))
  assert.deepEqual(events, ["ready"])
  assert.deepEqual(await sdk.getContext(), {launchUrl: "https://app.example/chapter/2"})
  assert.deepEqual(await sdk.openExternal("https://docs.example/chapter/2"), {
    status: "approved",
  })
  assert.deepEqual(await sdk.notifications.getPermission(), {
    state: "prompt",
    actorUrl: "https://app.example/ap/actor",
  })
  assert.deepEqual(await sdk.notifications.requestPermission(), {
    state: "granted",
    actorUrl: "https://app.example/ap/actor",
  })
  assert.equal(
    await sdk.wallet.getProvider().request({method: "eth_chainId", params: []}),
    "0x2105"
  )

  sdk.destroy()
  broker.destroy()
  relay.destroy()
})
