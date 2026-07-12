import assert from "node:assert/strict"
import test from "node:test"

import {navigateMiniAppFrame} from "../js/lib/mini_app_frame_navigation.mjs"

const current =
  "https://social.example/mini-apps/broker/card-1?launch_id=abcdefghijklmnopqrstuvwxyzABCDEFGH123456789&resolution_token=9a58f30b-70ae-4285-938d-5afcd7556be1"

const frame = src => {
  const assignments = []
  return {
    assignments,
    frame: {
      get src() {
        return src
      },
      set src(value) {
        assignments.push(value)
        src = value
      },
    },
  }
}

test("does not reload an iframe when the server repeats its current broker URL", () => {
  const fixture = frame(current)

  assert.equal(
    navigateMiniAppFrame({
      frame: fixture.frame,
      frameSrc: current,
      hostOrigin: "https://social.example",
      launchId: "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789",
    }),
    false,
  )
  assert.deepEqual(fixture.assignments, [])
})

test("navigates once to an exact same-origin broker URL for a fresh launch", () => {
  const fixture = frame(current)
  const launchId = "bbcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
  const next =
    `https://social.example/mini-apps/broker/card-1?launch_id=${launchId}&resolution_token=9a58f30b-70ae-4285-938d-5afcd7556be1`

  assert.equal(
    navigateMiniAppFrame({
      frame: fixture.frame,
      frameSrc: next,
      hostOrigin: "https://social.example",
      launchId,
    }),
    true,
  )
  assert.deepEqual(fixture.assignments, [next])
})

test("rejects external, mismatched, credentialed, fragmented, and smuggled broker URLs", () => {
  for (const frameSrc of [
    current.replace("social.example", "evil.example"),
    current.replace("abcdefghijklmnopqrstuvwxyzABCDEFGH123456789", "wrong-launch"),
    current.replace("https://", "https://user:pass@"),
    `${current}#fragment`,
    `${current}&extra=value`,
    current.replace("/mini-apps/broker/card-1", "/oauth/authorize"),
  ]) {
    const fixture = frame(current)
    assert.equal(
      navigateMiniAppFrame({
        frame: fixture.frame,
        frameSrc,
        hostOrigin: "https://social.example",
        launchId: "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789",
      }),
      false,
    )
    assert.deepEqual(fixture.assignments, [])
  }
})
