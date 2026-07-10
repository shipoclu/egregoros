const allowedMethods = new Set([
  "eth_accounts",
  "eth_chainId",
  "eth_requestAccounts",
  "personal_sign",
  "eth_signTypedData_v4",
  "eth_sendTransaction",
])
const addressPattern = /^0x[0-9a-fA-F]{40}$/
const dataPattern = /^0x(?:[0-9a-fA-F]{2})*$/
const quantityPattern = /^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/
const transactionFields = new Set([
  "from",
  "to",
  "data",
  "value",
  "gas",
  "gasPrice",
  "maxFeePerGas",
  "maxPriorityFeePerGas",
  "nonce",
  "chainId",
])
const quantityFields = [
  "value",
  "gas",
  "gasPrice",
  "maxFeePerGas",
  "maxPriorityFeePerGas",
  "nonce",
  "chainId",
]

const walletError = (code, message) => Object.assign(new Error(message), {code})
const noParams = params => params === undefined || (Array.isArray(params) && params.length === 0)
const validAddress = value => typeof value === "string" && addressPattern.test(value)
const validMessage = value => typeof value === "string" && value.length <= 131072

const safeJsonValue = (value, depth = 0) => {
  if (depth > 16) return false
  if (value === null || typeof value === "string" || typeof value === "boolean") return true
  if (typeof value === "number") return Number.isFinite(value)
  if (Array.isArray(value)) return value.length <= 256 && value.every(item => safeJsonValue(item, depth + 1))
  if (!value || typeof value !== "object") return false

  const keys = Object.keys(value)
  return (
    keys.length <= 256 &&
    keys.every(key => !["__proto__", "constructor", "prototype"].includes(key)) &&
    keys.every(key => safeJsonValue(value[key], depth + 1))
  )
}

const validTypedData = value => {
  if (typeof value !== "string" || value.length > 131072) return false
  try {
    return safeJsonValue(JSON.parse(value))
  } catch (_error) {
    return false
  }
}

const validTransaction = transaction => {
  if (!transaction || typeof transaction !== "object" || Array.isArray(transaction)) return false
  const keys = Object.keys(transaction)
  if (!keys.every(key => transactionFields.has(key))) return false
  if (!validAddress(transaction.from)) return false
  if (transaction.to !== undefined && !validAddress(transaction.to)) return false
  if (transaction.data !== undefined && (!dataPattern.test(transaction.data) || transaction.data.length > 262146)) return false
  if (!quantityFields.every(field => transaction[field] === undefined || quantityPattern.test(transaction[field]))) return false
  return transaction.to !== undefined || transaction.data !== undefined
}

const validPayload = ({method, params}) => {
  if (["eth_accounts", "eth_chainId", "eth_requestAccounts"].includes(method)) return noParams(params)
  if (method === "personal_sign") {
    return Array.isArray(params) && params.length === 2 && validMessage(params[0]) && validAddress(params[1])
  }
  if (method === "eth_signTypedData_v4") {
    return Array.isArray(params) && params.length === 2 && validAddress(params[0]) && validTypedData(params[1])
  }
  if (method === "eth_sendTransaction") {
    return Array.isArray(params) && params.length === 1 && validTransaction(params[0])
  }
  return false
}

export const createInjectedEvmWalletAdapter = ({ethereum} = {}) => ({
  kind: "injected",
  available: () => !!ethereum && typeof ethereum.request === "function",
  request: async payload => {
    if (!ethereum || typeof ethereum.request !== "function") {
      throw walletError(4900, "Wallet unavailable")
    }
    if (!payload || !allowedMethods.has(payload.method)) {
      throw walletError(4200, "Unsupported wallet method")
    }
    if (!validPayload(payload)) {
      throw walletError(-32602, "Invalid wallet parameters")
    }
    return ethereum.request({method: payload.method, params: payload.params || []})
  },
})
