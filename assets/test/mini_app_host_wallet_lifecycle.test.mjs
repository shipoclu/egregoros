import assert from "node:assert/strict"
import test from "node:test"

import MiniAppHost from "../js/hooks/mini_app_host.js"

const deferred = () => {
  let resolve
  const promise = new Promise(resolvePromise => {
    resolve = resolvePromise
  })
  return {promise, resolve}
}

const tick = () => new Promise(resolve => setImmediate(resolve))

const context = pending => {
  const dataset = {
    launchId: "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789",
    walletEnabled: "true",
    walletRequired: "true",
    walletRequiredChains: '["eip155:8453"]',
  }
  const calls = {bind: 0, cancel: 0, destroy: 0, push: 0, clear: 0}
  const value = {
    dataset,
    calls,
    destroyedFlag: false,
    walletGeneration: 0,
    walletCheckPending: false,
    walletConfigKey: null,
    walletCompatible: null,
    walletAdapter: {
      available: () => true,
      request: () => pending.promise,
    },
    authRelay: {
      cancel: () => (calls.cancel += 1),
      destroy: () => {},
    },
    readiness: {destroy: () => {}},
    el: {
      dataset,
      querySelector: selector =>
        selector === "#mini-app-frame-shell"
          ? {replaceChildren: () => (calls.clear += 1)}
          : null,
      removeEventListener: () => {},
    },
    destroyBroker: () => (calls.destroy += 1),
    bindFrame: () => (calls.bind += 1),
    pushEvent: () => (calls.push += 1),
    walletConfigurationKey: MiniAppHost.walletConfigurationKey,
  }
  return value
}

test("a stale required-wallet check cannot block a later non-required launch", async () => {
  const pending = deferred()
  const hook = context(pending)

  MiniAppHost.initializeWallet.call(hook)
  assert.equal(hook.walletCheckPending, true)

  hook.dataset.launchId = "bbcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
  hook.dataset.walletRequired = "false"
  hook.dataset.walletRequiredChains = "[]"
  MiniAppHost.initializeWallet.call(hook)

  assert.equal(hook.walletCheckPending, false)
  assert.equal(hook.calls.bind, 1)
  pending.resolve("0x2105")
  await tick()
  assert.equal(hook.calls.bind, 1)
  assert.equal(hook.calls.push, 0)
})

test("destroying the hook invalidates a pending wallet check", async () => {
  const pending = deferred()
  const hook = context(pending)

  MiniAppHost.initializeWallet.call(hook)
  MiniAppHost.destroyed.call(hook)
  pending.resolve("0x2105")
  await tick()

  assert.equal(hook.destroyedFlag, true)
  assert.equal(hook.walletCheckPending, false)
  assert.equal(hook.calls.bind, 0)
  assert.equal(hook.calls.push, 0)
})
