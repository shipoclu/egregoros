import {
  normalizeEvmQuantity,
  normalizeEvmWalletPayload,
  normalizeEvmWalletResult,
} from "./evm_wallet_schema.mjs"

const launchIdPattern = /^[A-Za-z0-9_-]{43}$/
const requestIdPattern = /^[A-Za-z0-9_-]{1,64}$/
const reviewedMethods = new Set(["personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"])

const invalid = () => {
  throw new TypeError("Invalid wallet execution")
}

const exactRecord = (value, fields) => {
  try {
    if (!value || typeof value !== "object" || Array.isArray(value)) invalid()
    const prototype = Object.getPrototypeOf(value)
    if (prototype !== Object.prototype && prototype !== null) invalid()
    const keys = Reflect.ownKeys(value)
    if (keys.length !== fields.length || keys.some(key => typeof key !== "string" || !fields.includes(key))) {
      invalid()
    }
    const descriptors = Object.getOwnPropertyDescriptors(value)
    for (const field of fields) {
      const descriptor = descriptors[field]
      if (!descriptor?.enumerable || !("value" in descriptor)) invalid()
    }
    return descriptors
  } catch (error) {
    if (error instanceof TypeError && error.message === "Invalid wallet execution") throw error
    invalid()
  }
}

const numericChainId = value => {
  try {
    return BigInt(value)
  } catch (_error) {
    invalid()
  }
}

export const normalizeWalletExecution = (value, activeLaunchId) => {
  const baseFields = ["launch_id", "request_id", "execution_token", "method", "params"]
  const candidateMethod = (() => {
    try {
      return Object.getOwnPropertyDescriptor(value, "method")?.value
    } catch (_error) {
      return null
    }
  })()
  const fields = reviewedMethods.has(candidateMethod)
    ? [...baseFields, "expected_chain_id", "expected_accounts"]
    : baseFields
  const descriptors = exactRecord(value, fields)
  const launchId = descriptors.launch_id.value
  const requestId = descriptors.request_id.value
  const executionToken = descriptors.execution_token.value
  if (
    launchId !== activeLaunchId ||
    !launchIdPattern.test(launchId || "") ||
    !requestIdPattern.test(requestId || "") ||
    !launchIdPattern.test(executionToken || "")
  ) {
    invalid()
  }

  let payload
  try {
    payload = normalizeEvmWalletPayload({
      method: descriptors.method.value,
      params: descriptors.params.value,
    })
  } catch (_error) {
    invalid()
  }

  const normalized = {
    launchId,
    requestId,
    executionToken,
    method: payload.method,
    params: payload.params,
  }
  if (!reviewedMethods.has(payload.method)) return normalized

  let expectedChainId
  let expectedAccounts
  try {
    expectedChainId = normalizeEvmQuantity(descriptors.expected_chain_id.value, 256)
    expectedAccounts = normalizeEvmWalletResult("eth_accounts", descriptors.expected_accounts.value)
  } catch (_error) {
    invalid()
  }
  if (expectedAccounts.length === 0) invalid()

  const requestAccount =
    payload.method === "personal_sign"
      ? payload.params[1]
      : payload.method === "eth_signTypedData_v4"
        ? payload.params[0]
        : payload.params[0].from
  if (!expectedAccounts.includes(requestAccount)) invalid()

  if (
    payload.method === "eth_sendTransaction" &&
    payload.params[0].chainId !== undefined &&
    numericChainId(payload.params[0].chainId) !== numericChainId(expectedChainId)
  ) {
    invalid()
  }
  if (payload.method === "eth_signTypedData_v4") {
    const domainChainId = JSON.parse(payload.params[1]).domain.chainId
    if (
      domainChainId !== undefined &&
      numericChainId(domainChainId) !== numericChainId(expectedChainId)
    ) {
      invalid()
    }
  }

  return {...normalized, expectedChainId, expectedAccounts}
}

const normalizeExpectedContext = expected => {
  const descriptors = exactRecord(expected, ["chainId", "accounts"])
  try {
    return {
      chainId: normalizeEvmQuantity(descriptors.chainId.value, 256),
      accounts: normalizeEvmWalletResult("eth_accounts", descriptors.accounts.value).sort(),
    }
  } catch (_error) {
    invalid()
  }
}

export const walletContextMatches = async (adapter, expected) => {
  let normalizedExpected
  try {
    normalizedExpected = normalizeExpectedContext(expected)
  } catch (_error) {
    return false
  }

  try {
    const [chainId, accounts] = await Promise.all([
      adapter.request({method: "eth_chainId", params: []}),
      adapter.request({method: "eth_accounts", params: []}),
    ])
    const normalizedChainId = normalizeEvmQuantity(chainId, 256)
    const normalizedAccounts = normalizeEvmWalletResult("eth_accounts", accounts).sort()
    return (
      normalizedChainId === normalizedExpected.chainId &&
      JSON.stringify(normalizedAccounts) === JSON.stringify(normalizedExpected.accounts)
    )
  } catch (_error) {
    return false
  }
}

export const createWalletExecutionTracker = ({maximum = 128} = {}) => {
  if (!Number.isInteger(maximum) || maximum < 1 || maximum > 128) {
    throw new TypeError("Invalid wallet execution tracker")
  }
  const claimed = new Set()
  return {
    claim: token => {
      if (!launchIdPattern.test(token || "") || claimed.has(token) || claimed.size >= maximum) {
        return false
      }
      claimed.add(token)
      return true
    },
  }
}

const executionError = (code, message) => Object.assign(new Error(message), {code})

export const executeWalletRequest = async (adapter, payload, activeLaunchId, tracker) => {
  const execution = normalizeWalletExecution(payload, activeLaunchId)
  if (!tracker?.claim(execution.executionToken)) {
    throw executionError(4100, "Wallet execution is stale or already used")
  }
  if (
    execution.expectedChainId &&
    !(await walletContextMatches(adapter, {
      chainId: execution.expectedChainId,
      accounts: execution.expectedAccounts,
    }))
  ) {
    throw executionError(4901, "Wallet account or chain changed")
  }

  const result = await adapter.request({method: execution.method, params: execution.params})
  try {
    return {
      executionToken: execution.executionToken,
      method: execution.method,
      requestId: execution.requestId,
      result: normalizeEvmWalletResult(execution.method, result),
    }
  } catch (_error) {
    throw executionError(-32603, "Invalid wallet response")
  }
}
