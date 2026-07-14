import assert from "node:assert/strict"
import test from "node:test"

import {isCanonicalHttpsHostOrigin} from "../../examples/fediverse-miniapp/public/host_origin.mjs"

test("the public static example accepts different exact HTTPS Fediverse hosts", () => {
  assert.equal(isCanonicalHttpsHostOrigin("https://social.example"), true)
  assert.equal(isCanonicalHttpsHostOrigin("https://community.other"), true)
  assert.equal(isCanonicalHttpsHostOrigin("http://social.example"), false)
  assert.equal(isCanonicalHttpsHostOrigin("https://social.example/"), false)
  assert.equal(isCanonicalHttpsHostOrigin("https://social.example/path"), false)
  assert.equal(isCanonicalHttpsHostOrigin("https://user@social.example"), false)
  assert.equal(isCanonicalHttpsHostOrigin("not an origin"), false)
})
