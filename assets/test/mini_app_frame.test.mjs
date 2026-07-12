import assert from "node:assert/strict"
import test from "node:test"

import {mountMiniAppFrame} from "../js/mini_app_frame.js"

test("binds the relay before starting the remote app navigation", () => {
  const operations = []
  const attributes = new Map()
  const iframe = {
    dataset: {},
    set id(value) {
      attributes.set("id", value)
    },
    set title(value) {
      attributes.set("title", value)
    },
    set referrerPolicy(value) {
      attributes.set("referrerpolicy", value)
    },
    set src(value) {
      operations.push("navigate")
      attributes.set("src", value)
    },
    setAttribute: (name, value) => attributes.set(name, value),
  }
  const root = {
    dataset: {
      appOrigin: "https://app.example",
      launchUrl: "https://app.example/read/chapter-2",
      frameTitle: "Reader mini app",
    },
    replaceChildren: child => {
      assert.equal(child, iframe)
      operations.push("attach")
    },
  }
  const documentObject = {
    querySelector: selector => (selector === "#mini-app-frame-root" ? root : null),
    createElement: name => {
      assert.equal(name, "iframe")
      return iframe
    },
  }

  const mounted = mountMiniAppFrame({
    documentObject,
    windowObject: {location: {origin: "https://social.example"}},
    createRelay: options => {
      assert.equal(options.iframe, iframe)
      operations.push("bind")
    },
  })

  assert.equal(mounted, iframe)
  assert.deepEqual(operations, ["bind", "navigate", "attach"])
  assert.equal(attributes.get("src"), "https://app.example/read/chapter-2")
  assert.equal(attributes.get("sandbox"), "allow-scripts allow-forms allow-same-origin")
  assert.equal(attributes.get("referrerpolicy"), "no-referrer")
})
