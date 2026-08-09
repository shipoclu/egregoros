import {
  createFediverseMiniAppSDK,
  type EvmAddress,
  type Hex,
  type MiniAppComposePublishedReceipt,
  type MiniAppNotificationPermission,
} from "@fediverse-miniapps/sdk"

const sdk = createFediverseMiniAppSDK({allowedHostOrigin: origin => origin === "https://social.example"})
const bootstrap = await sdk.connect()
const issuer: string = bootstrap.issuer
const launchInfo = await sdk.getLaunchInfo()
const sharedFrom: string = launchInfo.sourceNoteId
const context = await sdk.getContext()
const noteId: string = context.note.id
const provider = sdk.wallet.getProvider()
const chainId: Hex = await provider.request({method: "eth_chainId", params: []})
const accounts: EvmAddress[] = await provider.request({method: "eth_requestAccounts", params: []})
const signature: Hex = await provider.request({
  method: "personal_sign",
  params: ["0x68656c6c6f", accounts[0]],
})
const transactionHash: Hex = await provider.request({
  method: "eth_sendTransaction",
  params: [{
    from: accounts[0],
    to: "0x2222222222222222222222222222222222222222",
    type: "0x2",
    accessList: [{
      address: "0x2222222222222222222222222222222222222222",
      storageKeys: ["0x0000000000000000000000000000000000000000000000000000000000000000"],
    }],
  }],
})
const notificationPermission: MiniAppNotificationPermission =
  await sdk.notifications.getPermission()
const requestedNotificationPermission: MiniAppNotificationPermission =
  await sdk.notifications.requestPermission()
const browserAuthorization = await sdk.requestAuth({
  completionMode: "browser_code",
  clientId: "browser-client",
  redirectUri: "https://app.example/oauth/callback",
  scopes: ["identify"],
  state: "sssssssssssssssssssssssssssssssssssssssssss",
  codeChallenge: "ccccccccccccccccccccccccccccccccccccccccccc",
})
const authorizationCode: string = browserAuthorization.authorizationCode
const restored = await sdk.restoreSession({
  clientId: "miniapp-client",
  restoreChallenge: "rrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrrr",
})
if (restored.status === "success") {
  const restoreCode: string = restored.restoreCode
  void restoreCode
}

sdk.on("composeNotePublished", (receipt: MiniAppComposePublishedReceipt) => {
  const publishedId: string = receipt.id
  void publishedId
})

void issuer
void sharedFrom
void noteId
void chainId
void signature
void transactionHash
void notificationPermission
void requestedNotificationPermission
void authorizationCode
