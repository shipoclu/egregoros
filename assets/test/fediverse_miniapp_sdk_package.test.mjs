import assert from "node:assert/strict"
import {readFile} from "node:fs/promises"
import test from "node:test"

const sdkRevision = "7323d6f08d021e08b23c73ed39e8426f9a0a4615"
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
  const sdkSource = await readFile(
    new URL("../node_modules/@fediverse-miniapps/sdk/index.js", import.meta.url),
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
  assert.match(sdkSource, /\["unavailable", "invalid_draft"\]/)
})
