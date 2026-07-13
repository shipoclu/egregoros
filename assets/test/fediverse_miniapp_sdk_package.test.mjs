import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const sdkRevision = "46ca9c113631daa519933c01f211cf7b13f6dbe6"
const sdkDependency = `github:shipoclu/fediverse-miniapp-sdk#${sdkRevision}`
const sdkResolved =
  `git+ssh://git@github.com/shipoclu/fediverse-miniapp-sdk.git#${sdkRevision}`

test("builds the public SDK from the pinned standalone package", async () => {
  const packageJson = JSON.parse(
    await readFile(new URL("../package.json", import.meta.url), "utf8")
  )
  const packageLock = JSON.parse(
    await readFile(new URL("../package-lock.json", import.meta.url), "utf8")
  )
  const entrypoint = await readFile(
    new URL("../js/lib/fediverse_miniapp_sdk.mjs", import.meta.url),
    "utf8"
  )

  assert.equal(packageJson.dependencies?.["@fediverse-miniapps/sdk"], sdkDependency)
  assert.equal(
    packageLock.packages?.["node_modules/@fediverse-miniapps/sdk"]?.resolved,
    sdkResolved
  )
  assert.equal(
    entrypoint.trim(),
    'export {createFediverseMiniAppSDK, miniAppError} from "@fediverse-miniapps/sdk"'
  )
})
