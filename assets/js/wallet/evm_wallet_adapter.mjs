import {createInjectedEvmWalletAdapter} from "./injected_evm_wallet_adapter.mjs"
import {
  evmWalletErrorCode,
  normalizeEvmWalletPayload,
  normalizeEvmWalletResult,
} from "./evm_wallet_schema.mjs"

const validAdapter = adapter =>
  !!adapter &&
  typeof adapter === "object" &&
  typeof adapter.kind === "string" &&
  adapter.kind.length > 0 &&
  typeof adapter.available === "function" &&
  typeof adapter.request === "function"

const walletError = (code, message) => Object.assign(new Error(message), {code})

const secureAdapter = adapter => ({
  kind: adapter.kind,
  available: () => adapter.available() === true,
  request: async payload => {
    let normalized
    try {
      normalized = normalizeEvmWalletPayload(payload)
    } catch (_error) {
      throw walletError(-32602, "Invalid wallet parameters")
    }

    try {
      const result = await adapter.request(normalized)
      return normalizeEvmWalletResult(normalized.method, result)
    } catch (error) {
      if (error instanceof TypeError && error.message === "Invalid wallet parameters") {
        throw walletError(-32603, "Invalid wallet response")
      }
      throw walletError(evmWalletErrorCode(error), "Wallet request failed")
    }
  },
})

export const selectEvmWalletAdapter = ({configuredAdapter, ethereum} = {}) => {
  if (configuredAdapter !== undefined) {
    if (!validAdapter(configuredAdapter)) throw new TypeError("Invalid EVM wallet adapter")
    return secureAdapter(configuredAdapter)
  }

  return createInjectedEvmWalletAdapter({ethereum})
}
