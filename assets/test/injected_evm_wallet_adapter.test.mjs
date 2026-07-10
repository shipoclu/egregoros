import assert from "node:assert/strict"
import test from "node:test"

import {createInjectedEvmWalletAdapter} from "../js/wallet/injected_evm_wallet_adapter.mjs"
import {selectEvmWalletAdapter} from "../js/wallet/evm_wallet_adapter.mjs"

test("reports injected-provider availability without exposing the provider", async () => {
  const calls = []
  const ethereum = {
    request: payload => {
      calls.push(payload)
      return Promise.resolve("0x2105")
    },
  }
  const adapter = createInjectedEvmWalletAdapter({ethereum})

  assert.equal(adapter.kind, "injected")
  assert.equal(adapter.available(), true)
  assert.equal("provider" in adapter, false)
  assert.equal(await adapter.request({method: "eth_chainId", params: []}), "0x2105")
  assert.deepEqual(calls, [{method: "eth_chainId", params: []}])

  const unavailable = createInjectedEvmWalletAdapter({ethereum: null})
  assert.equal(unavailable.available(), false)
  await assert.rejects(
    unavailable.request({method: "eth_chainId", params: []}),
    error => error.code === 4900 && error.message === "Wallet unavailable"
  )
})

test("forwards only the v1 EIP-1193 allowlist", async () => {
  const calls = []
  const adapter = createInjectedEvmWalletAdapter({
    ethereum: {
      request: payload => {
        calls.push(payload)
        return Promise.resolve("ok")
      },
    },
  })

  for (const payload of [
    {method: "eth_accounts", params: []},
    {method: "eth_requestAccounts", params: []},
    {method: "personal_sign", params: ["0x1234", "0x1111111111111111111111111111111111111111"]},
    {
      method: "eth_signTypedData_v4",
      params: ["0x1111111111111111111111111111111111111111", '{"types":{}}'],
    },
    {
      method: "eth_sendTransaction",
      params: [
        {
          from: "0x1111111111111111111111111111111111111111",
          to: "0x2222222222222222222222222222222222222222",
          value: "0x1",
        },
      ],
    },
  ]) {
    assert.equal(await adapter.request(payload), "ok")
  }

  for (const method of [
    "eth_sign",
    "eth_sendRawTransaction",
    "wallet_addEthereumChain",
    "wallet_sendCalls",
    "wallet_grantPermissions",
  ]) {
    await assert.rejects(
      adapter.request({method, params: []}),
      error => error.code === 4200 && error.message === "Unsupported wallet method"
    )
  }

  assert.equal(calls.length, 5)
})

test("rejects malformed allowlisted payloads before calling the provider", async () => {
  let calls = 0
  const adapter = createInjectedEvmWalletAdapter({
    ethereum: {request: () => calls++},
  })

  for (const payload of [
    {method: "eth_chainId", params: ["unexpected"]},
    {method: "personal_sign", params: ["message", "not-an-address"]},
    {method: "eth_signTypedData_v4", params: ["0x1111111111111111111111111111111111111111", "not-json"]},
    {method: "eth_sendTransaction", params: [{from: "0x1", data: "0xzz"}]},
    {method: "eth_sendTransaction", params: [{from: "0x1111111111111111111111111111111111111111", privateKey: "x"}]},
  ]) {
    await assert.rejects(
      adapter.request(payload),
      error => error.code === -32602 && error.message === "Invalid wallet parameters"
    )
  }

  assert.equal(calls, 0)
})

test("host adapter selection leaves room for an administrator-configured JAW adapter", () => {
  const configuredAdapter = {
    kind: "jaw",
    available: () => true,
    request: async () => "configured",
  }

  assert.equal(selectEvmWalletAdapter({configuredAdapter}), configuredAdapter)
  assert.equal(
    selectEvmWalletAdapter({ethereum: {request: async () => []}}).kind,
    "injected"
  )
  assert.throws(
    () => selectEvmWalletAdapter({configuredAdapter: {kind: "jaw"}}),
    /Invalid EVM wallet adapter/
  )
})
