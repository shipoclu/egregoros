import test from "node:test"
import assert from "node:assert/strict"

import {
  createWalletExecutionTracker,
  executeWalletRequest,
  normalizeWalletExecution,
  walletContextMatches,
} from "../js/wallet/wallet_execution_guard.mjs"

const launchId = "abcdefghijklmnopqrstuvwxyzABCDEFGH123456789"
const token = "ZYXWVUTSRQPONMLKJIHGFEDCBA9876543210abcdefg"
const account = "0x1111111111111111111111111111111111111111"
const recipient = "0x2222222222222222222222222222222222222222"

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

test("normalizes an exact execution envelope and binds transaction context", () => {
  assert.deepEqual(
    normalizeWalletExecution(
      {
        launch_id: launchId,
        request_id: "tx-1",
        execution_token: token,
        method: "eth_sendTransaction",
        params: [{from: account, to: recipient, value: "0xA", chainId: "0x2105"}],
        expected_chain_id: "0x2105",
        expected_accounts: [account],
      },
      launchId
    ),
    {
      launchId,
      requestId: "tx-1",
      executionToken: token,
      method: "eth_sendTransaction",
      params: [{from: account, to: recipient, value: "0xa", chainId: "0x2105"}],
      expectedChainId: "0x2105",
      expectedAccounts: [account],
    }
  )

  for (const mutation of [
    {execution_token: "short"},
    {launch_id: token},
    {expected_chain_id: "0x1"},
    {expected_accounts: [recipient]},
    {admin: true},
  ]) {
    assert.throws(
      () =>
        normalizeWalletExecution(
          {
            launch_id: launchId,
            request_id: "tx-1",
            execution_token: token,
            method: "eth_sendTransaction",
            params: [{from: account, to: recipient, value: "0xa", chainId: "0x2105"}],
            expected_chain_id: "0x2105",
            expected_accounts: [account],
            ...mutation,
          },
          launchId
        ),
      /Invalid wallet execution/
    )
  }
})

test("execution tokens are single-use and the replay set fails closed at its bound", () => {
  const tracker = createWalletExecutionTracker({maximum: 2})
  assert.equal(tracker.claim(token), true)
  assert.equal(tracker.claim(token), false)
  assert.equal(tracker.claim(launchId), true)
  assert.equal(tracker.claim("1234567890123456789012345678901234567890123"), false)
})

test("executes only the reviewed normalized payload once", async () => {
  const calls = []
  const adapter = {
    request: async payload => {
      calls.push(payload)
      if (payload.method === "eth_chainId") return "0x2105"
      if (payload.method === "eth_accounts") return [account]
      return "0x" + "ab".repeat(32)
    },
  }
  const tracker = createWalletExecutionTracker()
  const payload = {
    launch_id: launchId,
    request_id: "tx-1",
    execution_token: token,
    method: "eth_sendTransaction",
    params: [{from: account.toUpperCase().replace("0X", "0x"), to: recipient, value: "0xA"}],
    expected_chain_id: "0x2105",
    expected_accounts: [account],
  }

  assert.deepEqual(await executeWalletRequest(adapter, payload, launchId, tracker), {
    executionToken: token,
    method: "eth_sendTransaction",
    requestId: "tx-1",
    result: "0x" + "ab".repeat(32),
  })
  assert.deepEqual(calls.at(-1), {
    method: "eth_sendTransaction",
    params: [{from: account, to: recipient, value: "0xa"}],
  })
  await assert.rejects(
    executeWalletRequest(adapter, payload, launchId, tracker),
    error => error.code === 4100
  )
  assert.equal(calls.filter(call => call.method === "eth_sendTransaction").length, 1)
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
