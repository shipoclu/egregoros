import assert from "node:assert/strict"
import test from "node:test"

import {bindMiniAppBrokerFrame} from "../js/lib/mini_app_host_frame.mjs"

test("binds the broker before mounting and navigating its JS-owned iframe", () => {
  const operations = []
  const attributes = new Map()
  let src = ""
  const frame = {
    dataset: {},
    get src() {
      return src
    },
    set src(value) {
      operations.push("navigate")
      src = value
    },
    set id(value) {
      attributes.set("id", value)
    },
    set title(value) {
      attributes.set("title", value)
    },
    set referrerPolicy(value) {
      attributes.set("referrerpolicy", value)
    },
    set className(value) {
      attributes.set("class", value)
    },
  }
  const shell = {
    replaceChildren: child => {
      assert.equal(child, frame)
      operations.push("attach")
    },
  }
  const broker = {destroy: () => {}}

  const binding = bindMiniAppBrokerFrame({
    shell,
    documentObject: {
      createElement: name => {
        assert.equal(name, "iframe")
        return frame
      },
    },
    createBroker: options => {
      assert.equal(options.iframe, frame)
      operations.push("bind")
      return broker
    },
    brokerOptions: {},
    frameSrc:
      "/mini-apps/broker/card-1?launch_id=abcdefghijklmnopqrstuvwxyzABCDEFGH123456789&resolution_token=9a58f30b-70ae-4285-938d-5afcd7556be1",
    frameTitle: "Reader mini app",
    hostOrigin: "https://social.example",
    launchId: "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789",
  })

  assert.equal(binding.frame, frame)
  assert.equal(binding.broker, broker)
  assert.deepEqual(operations, ["bind", "navigate", "attach"])
  assert.equal(attributes.get("id"), "mini-app-frame")
  assert.equal(attributes.get("title"), "Reader mini app")
  assert.equal(attributes.get("referrerpolicy"), "no-referrer")
  assert.equal(attributes.get("class"), "h-full w-full border-0")
})

test("destroys the broker and clears the shell when its server URL is invalid", () => {
  let destroyed = 0
  let cleared = 0
  const frame = {
    src: "",
    setAttribute: () => {},
  }
  const shell = {
    replaceChildren: child => {
      assert.equal(child, undefined)
      cleared += 1
    },
  }

  const binding = bindMiniAppBrokerFrame({
    shell,
    documentObject: {createElement: () => frame},
    createBroker: () => ({destroy: () => (destroyed += 1)}),
    brokerOptions: {},
    frameSrc: "https://evil.example/mini-apps/broker/card-1",
    frameTitle: "Reader mini app",
    hostOrigin: "https://social.example",
    launchId: "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789",
  })

  assert.equal(binding, null)
  assert.equal(destroyed, 1)
  assert.equal(cleared, 1)
})
