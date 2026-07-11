import test from "node:test"
import assert from "node:assert/strict"

import {walletContextMatches} from "../js/wallet/wallet_execution_guard.mjs"

test("wallet execution requires the exact reviewed chain and account set", async () => {
  const requests = []
  const adapter = {
    request: async payload => {
      requests.push(payload)
      return payload.method === "eth_chainId"
        ? "0x2105"
        : ["0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
    },
  }

  assert.equal(
    await walletContextMatches(adapter, {
      chainId: "0x2105",
      accounts: ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    }),
    true
  )
  assert.equal(
    await walletContextMatches(adapter, {
      chainId: "0x1",
      accounts: ["0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
    }),
    false
  )
  assert.deepEqual(requests.slice(0, 2), [
    {method: "eth_chainId", params: []},
    {method: "eth_accounts", params: []},
  ])
})

test("wallet execution rejects account additions, removals, and malformed results", async () => {
  const adapter = {
    request: async ({method}) =>
      method === "eth_chainId"
        ? "0x2105"
        : [
            "0x1111111111111111111111111111111111111111",
            "0x2222222222222222222222222222222222222222",
          ],
  }

  assert.equal(
    await walletContextMatches(adapter, {
      chainId: "0x2105",
      accounts: ["0x1111111111111111111111111111111111111111"],
    }),
    false
  )

  assert.equal(
    await walletContextMatches(
      {request: async ({method}) => (method === "eth_chainId" ? "0x2105" : null)},
      {chainId: "0x2105", accounts: []}
    ),
    false
  )
})
