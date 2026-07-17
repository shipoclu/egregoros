import assert from "node:assert/strict"
import test from "node:test"

import {MAX_RECENT_MINI_APPS, recentEntries} from "../js/hooks/mini_app_library.js"

const entry = number => ({
  appOrigin: `https://app-${number}.example`,
  cardId: `card-${number}`,
  resolutionToken: `token-${number}`,
  name: `App ${number}`,
})

test("records the newest mini app once per app origin", () => {
  const entries = recentEntries([entry(1), entry(2)], {...entry(1), cardId: "card-new"})

  assert.deepEqual(entries.map(item => item.cardId), ["card-new", "card-2"])
})

test("limits the recent mini app tray", () => {
  const entries = Array.from({length: MAX_RECENT_MINI_APPS}, (_, index) => entry(index))
  const updated = recentEntries(entries, entry(MAX_RECENT_MINI_APPS))

  assert.equal(updated.length, MAX_RECENT_MINI_APPS)
  assert.equal(updated[0].appOrigin, `https://app-${MAX_RECENT_MINI_APPS}.example`)
})
