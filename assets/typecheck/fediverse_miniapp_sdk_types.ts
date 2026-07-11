import {
  createFediverseMiniAppSDK,
  type EvmAddress,
  type Hex,
  type MiniAppComposePublishedReceipt,
  type MiniAppNotificationPermission,
} from "../js/lib/fediverse_miniapp_sdk.d.ts"

const sdk = createFediverseMiniAppSDK({allowedHostOrigin: origin => origin === "https://social.example"})
const bootstrap = await sdk.connect()
const issuer: string = bootstrap.issuer
const context = await sdk.getContext()
const noteId: string = context.note.id
const provider = sdk.wallet.getProvider()
const chainId: Hex = await provider.request({method: "eth_chainId", params: []})
const accounts: EvmAddress[] = await provider.request({method: "eth_requestAccounts", params: []})
const signature: Hex = await provider.request({
  method: "personal_sign",
  params: ["hello", accounts[0]],
})
const notificationPermission: MiniAppNotificationPermission =
  await sdk.notifications.getPermission()
const requestedNotificationPermission: MiniAppNotificationPermission =
  await sdk.notifications.requestPermission()

sdk.on("composeNotePublished", (receipt: MiniAppComposePublishedReceipt) => {
  const publishedId: string = receipt.id
  void publishedId
})

void issuer
void noteId
void chainId
void signature
void notificationPermission
void requestedNotificationPermission
