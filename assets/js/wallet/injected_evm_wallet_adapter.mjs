import {
  evmWalletErrorCode,
  normalizeEvmWalletPayload,
  normalizeEvmWalletResult,
  supportedEvmWalletMethod,
} from "./evm_wallet_schema.mjs"

export {validEvmWalletPayload} from "./evm_wallet_schema.mjs"

const walletError = (code, message) => Object.assign(new Error(message), {code})

const declaredMethod = payload => {
  try {
    const descriptor = Object.getOwnPropertyDescriptor(payload, "method")
    return descriptor && "value" in descriptor
      ? {valid: true, value: descriptor.value}
      : {valid: false}
  } catch (_error) {
    return {valid: false}
  }
}

export const createInjectedEvmWalletAdapter = ({ethereum} = {}) => ({
  kind: "injected",
  available: () => !!ethereum && typeof ethereum.request === "function",
  request: async payload => {
    if (!ethereum || typeof ethereum.request !== "function") {
      throw walletError(4900, "Wallet unavailable")
    }

    let normalized
    try {
      normalized = normalizeEvmWalletPayload(payload)
    } catch (_error) {
      const declaration = declaredMethod(payload)
      if (!declaration.valid || supportedEvmWalletMethod(declaration.value)) {
        throw walletError(-32602, "Invalid wallet parameters")
      }
      throw walletError(4200, "Unsupported wallet method")
    }

    try {
      const result = await ethereum.request(normalized)
      return normalizeEvmWalletResult(normalized.method, result)
    } catch (error) {
      if (error instanceof TypeError && error.message === "Invalid wallet parameters") {
        throw walletError(-32603, "Invalid wallet response")
      }
      throw walletError(evmWalletErrorCode(error), "Wallet request failed")
    }
  },
})
