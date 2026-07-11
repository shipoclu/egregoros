import assert from "node:assert/strict"
import test from "node:test"

import {createMiniAppReadiness} from "../js/lib/mini_app_readiness.mjs"

test("reports only the current launch when ready is not received in time", () => {
  const timers = []
  const timedOut = []
  const readiness = createMiniAppReadiness({
    timeoutMs: 10_000,
    setTimer: callback => {
      timers.push(callback)
      return timers.length
    },
    clearTimer: () => {},
    onTimeout: launchId => timedOut.push(launchId),
  })

  readiness.loading("launch-1")
  readiness.loading("launch-2")
  timers[0]()
  assert.deepEqual(timedOut, [])
  timers[1]()
  assert.deepEqual(timedOut, ["launch-2"])
})

test("ready and destroy cancel the pending timeout", () => {
  const timers = []
  const timedOut = []
  const readiness = createMiniAppReadiness({
    timeoutMs: 10_000,
    setTimer: callback => {
      timers.push(callback)
      return timers.length
    },
    clearTimer: () => {},
    onTimeout: launchId => timedOut.push(launchId),
  })

  readiness.loading("launch-ready")
  readiness.ready("launch-ready")
  timers[0]()
  readiness.loading("launch-destroyed")
  readiness.destroy()
  timers[1]()
  assert.deepEqual(timedOut, [])
})
