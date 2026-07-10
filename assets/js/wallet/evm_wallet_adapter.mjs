import {createInjectedEvmWalletAdapter} from "./injected_evm_wallet_adapter.mjs"

const validAdapter = adapter =>
  !!adapter &&
  typeof adapter === "object" &&
  typeof adapter.kind === "string" &&
  adapter.kind.length > 0 &&
  typeof adapter.available === "function" &&
  typeof adapter.request === "function"

export const selectEvmWalletAdapter = ({configuredAdapter, ethereum} = {}) => {
  if (configuredAdapter !== undefined) {
    if (!validAdapter(configuredAdapter)) throw new TypeError("Invalid EVM wallet adapter")
    return configuredAdapter
  }

  return createInjectedEvmWalletAdapter({ethereum})
}
