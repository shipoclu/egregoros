import assert from "node:assert/strict"
import test from "node:test"

import {createInjectedEvmWalletAdapter} from "../js/wallet/injected_evm_wallet_adapter.mjs"
import {selectEvmWalletAdapter} from "../js/wallet/evm_wallet_adapter.mjs"

const account = "0x1111111111111111111111111111111111111111"
const recipient = "0x2222222222222222222222222222222222222222"

const typedData = overrides =>
  JSON.stringify({
    types: {
      EIP712Domain: [
        {name: "name", type: "string"},
        {name: "chainId", type: "uint256"},
        {name: "verifyingContract", type: "address"},
      ],
      Mail: [
        {name: "contents", type: "string"},
        {name: "amount", type: "uint256"},
      ],
    },
    primaryType: "Mail",
    domain: {name: "Example", chainId: "0x2105", verifyingContract: recipient},
    message: {contents: "hello", amount: "1"},
    ...overrides,
  })

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
        if (payload.method === "eth_accounts") return Promise.resolve([])
        if (payload.method === "eth_requestAccounts") return Promise.resolve([account])
        if (payload.method === "eth_chainId") return Promise.resolve("0x2105")
        if (payload.method === "eth_sendTransaction") {
          return Promise.resolve("0x" + "ab".repeat(32))
        }
        return Promise.resolve("0x" + "ab".repeat(65))
      },
    },
  })

  for (const payload of [
    {method: "eth_accounts", params: []},
    {method: "eth_requestAccounts", params: []},
    {method: "personal_sign", params: ["0x1234", "0x1111111111111111111111111111111111111111"]},
    {
      method: "eth_signTypedData_v4",
      params: [account, typedData()],
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
    await adapter.request(payload)
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

test("normalizes the exact payload before forwarding it to the injected provider", async () => {
  const calls = []
  const adapter = createInjectedEvmWalletAdapter({
    ethereum: {request: async payload => (calls.push(payload), "0x" + "ab".repeat(32))},
  })
  const transaction = Object.create(null)
  transaction.from = account.toUpperCase().replace("0X", "0x")
  transaction.to = recipient.toUpperCase().replace("0X", "0x")
  transaction.value = "0xA"
  transaction.data = "0xABCD"
  transaction.nonce = "0x0"
  transaction.accessList = [
    {address: recipient, storageKeys: ["0x" + "AB".repeat(32)]},
  ]

  await adapter.request({method: "eth_sendTransaction", params: [transaction]})

  assert.deepEqual(calls, [
    {
      method: "eth_sendTransaction",
      params: [
        {
          from: account,
          to: recipient,
          data: "0xabcd",
          value: "0xa",
          nonce: "0x0",
          accessList: [
            {address: recipient, storageKeys: ["0x" + "ab".repeat(32)]},
          ],
        },
      ],
    },
  ])
})

test("rejects payload smuggling through descriptors, prototypes, symbols, and sparse arrays", async () => {
  let calls = 0
  const adapter = createInjectedEvmWalletAdapter({ethereum: {request: async () => calls++}})
  const attempts = []

  attempts.push(Object.assign(Object.create({admin: true}), {method: "eth_chainId", params: []}))

  const hidden = {method: "eth_chainId", params: []}
  Object.defineProperty(hidden, "secret", {value: true})
  attempts.push(hidden)

  const symbol = {method: "eth_chainId", params: []}
  symbol[Symbol("secret")] = true
  attempts.push(symbol)

  let getterCalls = 0
  const accessor = {params: []}
  Object.defineProperty(accessor, "method", {
    enumerable: true,
    get: () => {
      getterCalls++
      return "eth_chainId"
    },
  })
  attempts.push(accessor)

  const custom = []
  custom.secret = true
  attempts.push({method: "eth_chainId", params: custom})

  const sparse = new Array(1)
  attempts.push({method: "eth_chainId", params: sparse})

  const tx = {from: account, to: recipient}
  Object.defineProperty(tx, "privateKey", {value: "secret"})
  attempts.push({method: "eth_sendTransaction", params: [tx]})

  for (const payload of attempts) {
    await assert.rejects(
      adapter.request(payload),
      error => error.code === -32602 && error.message === "Invalid wallet parameters"
    )
  }
  assert.equal(calls, 0)
  assert.equal(getterCalls, 0)
})

test("rejects noncanonical or oversized quantities and bounds access lists", async () => {
  let calls = 0
  const adapter = createInjectedEvmWalletAdapter({ethereum: {request: async () => calls++}})
  const invalidTransactions = [
    {from: account, to: recipient, value: "0x00"},
    {from: account, to: recipient, value: "0x" + "f".repeat(65)},
    {from: account, to: recipient, nonce: "0x" + "f".repeat(17)},
    {from: account, to: recipient, gas: "0x" + "f".repeat(17)},
    {from: account, to: recipient, type: "0x100"},
    {from: account, to: recipient, gasPrice: "0x1", maxFeePerGas: "0x2"},
    {from: account, to: recipient, maxFeePerGas: "0x1", maxPriorityFeePerGas: "0x2"},
    {
      from: account,
      to: recipient,
      accessList: Array.from({length: 129}, () => ({address: recipient, storageKeys: []})),
    },
    {
      from: account,
      to: recipient,
      accessList: [{address: recipient, storageKeys: ["0x12"]}],
    },
  ]

  for (const transaction of invalidTransactions) {
    await assert.rejects(
      adapter.request({method: "eth_sendTransaction", params: [transaction]}),
      error => error.code === -32602
    )
  }
  assert.equal(calls, 0)
})

test("parses typed data without duplicate keys or ambiguous numbers and validates its schema", async () => {
  let calls = 0
  const adapter = createInjectedEvmWalletAdapter({ethereum: {request: async () => (calls++, "0x")}})
  const invalidTypedData = [
    '{"types":{},"types":{},"primaryType":"Mail","domain":{},"message":{}}',
    typedData({extra: true}),
    typedData({primaryType: "Missing"}),
    typedData({message: {contents: "hello", amount: 1.5}}),
    typedData({message: {contents: "hello", amount: Number.MAX_SAFE_INTEGER + 1}}),
    typedData({message: {contents: "hello", amount: "01"}}),
    typedData().replace('"amount":"1"', '"amount":-0'),
    typedData({domain: {name: "Example", chainId: "0x00", verifyingContract: recipient}}),
    typedData({message: {contents: "hello", amount: "0x" + "f".repeat(65)}}),
  ]

  for (const encoded of invalidTypedData) {
    await assert.rejects(
      adapter.request({method: "eth_signTypedData_v4", params: [account, encoded]}),
      error => error.code === -32602
    )
  }
  assert.equal(calls, 0)
})

test("bounds and validates provider results before returning across the host boundary", async () => {
  const huge = "0x" + "ab".repeat(200_000)
  const invalidByMethod = new Map([
    ["eth_chainId", "0x00"],
    ["eth_accounts", Array.from({length: 17}, () => account)],
    ["personal_sign", huge],
    ["eth_signTypedData_v4", "0x12"],
    ["eth_sendTransaction", huge],
  ])

  for (const [method, result] of invalidByMethod) {
    const adapter = createInjectedEvmWalletAdapter({ethereum: {request: async () => result}})
    const params =
      method === "personal_sign"
        ? ["0x68656c6c6f", account]
        : method === "eth_signTypedData_v4"
          ? [account, typedData()]
          : method === "eth_sendTransaction"
            ? [{from: account, to: recipient}]
            : []
    await assert.rejects(
      adapter.request({method, params}),
      error => error.code === -32603 && error.message === "Invalid wallet response"
    )
  }
})

test("does not evaluate provider error accessors while bounding error output", async () => {
  let getterCalls = 0
  const error = {}
  Object.defineProperty(error, "code", {
    enumerable: true,
    get: () => {
      getterCalls++
      return 4001
    },
  })
  const adapter = createInjectedEvmWalletAdapter({
    ethereum: {request: async () => Promise.reject(error)},
  })

  await assert.rejects(
    adapter.request({method: "eth_chainId", params: []}),
    received => received.code === 4001 && received.message === "Wallet request failed"
  )
  assert.equal(getterCalls, 0)
})

test("rejects malformed allowlisted payloads before calling the provider", async () => {
  let calls = 0
  const adapter = createInjectedEvmWalletAdapter({
    ethereum: {request: () => calls++},
  })

  for (const payload of [
    {method: "eth_chainId", params: ["unexpected"]},
    {method: "personal_sign", params: ["message", account]},
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
  const calls = []
  const configuredAdapter = {
    kind: "jaw",
    available: () => true,
    request: async payload => (calls.push(payload), "0x2105"),
  }

  const selected = selectEvmWalletAdapter({configuredAdapter})
  assert.equal(selected.kind, "jaw")
  assert.notEqual(selected, configuredAdapter)
  assert.equal(selected.available(), true)
  assert.equal(
    selectEvmWalletAdapter({ethereum: {request: async () => []}}).kind,
    "injected"
  )
  assert.throws(
    () => selectEvmWalletAdapter({configuredAdapter: {kind: "jaw"}}),
    /Invalid EVM wallet adapter/
  )

  return selected.request({method: "eth_chainId"}).then(result => {
    assert.equal(result, "0x2105")
    assert.deepEqual(calls, [{method: "eth_chainId", params: []}])
  })
})
