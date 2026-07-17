import assert from "node:assert/strict"
import test from "node:test"

import {mediaWidthFor} from "../js/hooks/mini_app_card_media.js"

test("sizes mini-app media from the card height at a 3:2 ratio", () => {
  assert.equal(mediaWidthFor(188, 755), 282)
})

test("caps mini-app media before it crowds out the card content", () => {
  assert.equal(mediaWidthFor(500, 600), 270)
})
