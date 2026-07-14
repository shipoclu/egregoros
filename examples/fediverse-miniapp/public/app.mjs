import {createFediverseMiniAppSDK} from "./fediverse-miniapp-sdk-v1.js"
import {isCanonicalHttpsHostOrigin} from "./host_origin.mjs"

const output = document.querySelector("#output")
const show = value => {
  output.textContent = JSON.stringify(value, null, 2)
}
const showError = error => show({error: error?.message || "Unknown error", code: error?.code})

const sdk = createFediverseMiniAppSDK({
  allowedHostOrigin: isCanonicalHttpsHostOrigin,
})

try {
  const bootstrap = await sdk.connect()
  show({bootstrap})
  await sdk.ready()
} catch (error) {
  showError(error)
}

document.querySelector("#context").addEventListener("click", async () => {
  try {
    show({context: await sdk.getContext()})
  } catch (error) {
    showError(error)
  }
})

document.querySelector("#launch-info").addEventListener("click", async () => {
  try {
    show({launchInfo: await sdk.getLaunchInfo()})
  } catch (error) {
    showError(error)
  }
})

document.querySelector("#chain").addEventListener("click", async () => {
  try {
    const provider = sdk.wallet.getProvider()
    show({chainId: await provider.request({method: "eth_chainId", params: []})})
  } catch (error) {
    showError(error)
  }
})

document.querySelector("#connect").addEventListener("click", async () => {
  try {
    const provider = sdk.wallet.getProvider()
    show({accounts: await provider.request({method: "eth_requestAccounts", params: []})})
  } catch (error) {
    showError(error)
  }
})

document.querySelector("#external").addEventListener("click", async () => {
  try {
    show(await sdk.openExternal("https://www.w3.org/TR/activitypub/"))
  } catch (error) {
    showError(error)
  }
})

document.querySelector("#close").addEventListener("click", () => sdk.close().catch(showError))
