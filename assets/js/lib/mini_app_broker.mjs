import {validEvmWalletPayload} from "../wallet/injected_evm_wallet_adapter.mjs"

const protocolVersion = "1"

const validReadyMessage = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 3 &&
  message.type === "ready" &&
  message.version === protocolVersion &&
  message.launchId === launchId

const validContextRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 4 &&
  Object.keys(message).every(key => ["type", "version", "launchId", "requestId"].includes(key)) &&
  message.type === "getContext" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId)

const validRequestId = requestId =>
  typeof requestId === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(requestId)

const authRequestFields = new Set([
  "type",
  "version",
  "launchId",
  "requestId",
  "clientId",
  "redirectUri",
  "scopes",
  "state",
  "codeChallenge",
  "codeChallengeMethod",
  "handoffChallenge",
])

const boundedUrl = value => typeof value === "string" && value.length <= 2048
const base64UrlSha256 = value =>
  typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value)
const highEntropyState = value =>
  typeof value === "string" && /^[A-Za-z0-9_-]{43,256}$/.test(value)
const validScopes = scopes =>
  Array.isArray(scopes) &&
  scopes.length >= 1 &&
  scopes.length <= 32 &&
  new Set(scopes).size === scopes.length &&
  scopes.every(scope =>
    typeof scope === "string" && /^[A-Za-z][A-Za-z0-9:_-]{0,63}$/.test(scope)
  )

const validAuthRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).every(key => authRequestFields.has(key)) &&
  Object.keys(message).length === authRequestFields.size &&
  message.type === "requestAuth" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId) &&
  typeof message.clientId === "string" &&
  /^[A-Za-z0-9_-]{10,200}$/.test(message.clientId) &&
  boundedUrl(message.redirectUri) &&
  validScopes(message.scopes) &&
  highEntropyState(message.state) &&
  base64UrlSha256(message.codeChallenge) &&
  message.codeChallengeMethod === "S256" &&
  base64UrlSha256(message.handoffChallenge)

const composeDraftFields = new Set([
  "text",
  "spoilerText",
  "language",
  "visibility",
  "inReplyTo",
  "links",
])
const composeVisibilities = new Set(["public", "unlisted", "followers", "direct"])
const validOptionalString = (value, max) => value === undefined || (typeof value === "string" && value.length <= max)
const validHttpsUrl = value => {
  if (typeof value !== "string" || value.length > 2048) return false
  try {
    const url = new URL(value)
    return url.protocol === "https:" && !!url.hostname && !url.username && !url.password
  } catch (_error) {
    return false
  }
}
const validComposeDraft = draft =>
  !!draft &&
  typeof draft === "object" &&
  !Array.isArray(draft) &&
  Object.keys(draft).every(key => composeDraftFields.has(key)) &&
  validOptionalString(draft.text, 5000) &&
  validOptionalString(draft.spoilerText, 500) &&
  (draft.language === undefined ||
    draft.language === "" ||
    (typeof draft.language === "string" &&
      draft.language.length <= 35 &&
      /^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(draft.language))) &&
  (draft.visibility === undefined || composeVisibilities.has(draft.visibility)) &&
  (draft.inReplyTo === undefined || validHttpsUrl(draft.inReplyTo)) &&
  (draft.links === undefined ||
    (Array.isArray(draft.links) &&
      draft.links.length <= 8 &&
      draft.links.every(validHttpsUrl)))

const validComposeRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 5 &&
  Object.keys(message).every(key =>
    ["type", "version", "launchId", "callId", "draft"].includes(key)
  ) &&
  message.type === "composeNote" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.callId) &&
  validComposeDraft(message.draft)

const validCloseRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 4 &&
  Object.keys(message).every(key => ["type", "version", "launchId", "requestId"].includes(key)) &&
  message.type === "close" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId)

const validExternalRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 6 &&
  Object.keys(message).every(key =>
    ["type", "version", "launchId", "requestId", "url", "userActivation"].includes(key)
  ) &&
  message.type === "openExternal" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId) &&
  validHttpsUrl(message.url) &&
  message.userActivation === true

const validWalletRequest = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  !Array.isArray(message) &&
  Object.keys(message).length === 7 &&
  Object.keys(message).every(key =>
    ["type", "version", "launchId", "requestId", "method", "params", "userActivation"].includes(key)
  ) &&
  message.type === "walletRequest" &&
  message.version === protocolVersion &&
  message.launchId === launchId &&
  validRequestId(message.requestId) &&
  validEvmWalletPayload({method: message.method, params: message.params}) &&
  (!["eth_requestAccounts", "personal_sign", "eth_signTypedData_v4", "eth_sendTransaction"].includes(
    message.method
  ) || message.userActivation === true) &&
  typeof message.userActivation === "boolean"

export const createMiniAppBroker = ({
  iframe,
  appOrigin,
  hostOrigin,
  launchId,
  capabilities = [],
  onLoading,
  onReady,
  onContextRequest,
  onAuthRequest,
  onComposeRequest,
  onCloseRequest,
  onExternalRequest,
  onWalletRequest,
}) => {
  let hostPort = null
  let ready = false
  let seenRequests = new Set()

  const acceptOnce = key => {
    if (seenRequests.has(key)) return false
    seenRequests.add(key)
    return true
  }

  const closePort = () => {
    if (!hostPort) return
    hostPort.onmessage = null
    hostPort.close()
    hostPort = null
  }

  const start = () => {
    closePort()
    ready = false
    seenRequests = new Set()
    onLoading?.()

    const targetWindow = iframe?.contentWindow
    if (!targetWindow) return

    const channel = new MessageChannel()
    hostPort = channel.port1

    hostPort.onmessage = event => {
      const message = event?.data

      if (!ready && validReadyMessage(message, launchId)) {
        ready = true
        onReady?.()
        return
      }

      if (
        validContextRequest(message, launchId) &&
        acceptOnce(`context:${message.requestId}`)
      ) {
        onContextRequest?.(message.requestId)
        return
      }

      if (validAuthRequest(message, launchId) && acceptOnce(`auth:${message.requestId}`)) {
        onAuthRequest?.({
          requestId: message.requestId,
          clientId: message.clientId,
          redirectUri: message.redirectUri,
          scopes: [...message.scopes],
          state: message.state,
          codeChallenge: message.codeChallenge,
          codeChallengeMethod: message.codeChallengeMethod,
          handoffChallenge: message.handoffChallenge,
        })
        return
      }

      if (validComposeRequest(message, launchId) && acceptOnce(`compose:${message.callId}`)) {
        onComposeRequest?.({callId: message.callId, draft: {...message.draft}})
        return
      }

      if (validCloseRequest(message, launchId) && acceptOnce(`close:${message.requestId}`)) {
        onCloseRequest?.(message.requestId)
        return
      }

      if (validExternalRequest(message, launchId) && acceptOnce(`external:${message.requestId}`)) {
        onExternalRequest?.({requestId: message.requestId, url: message.url})
        return
      }

      if (
        capabilities.includes("wallet.evm") &&
        validWalletRequest(message, launchId) &&
        acceptOnce(`wallet:${message.requestId}`)
      ) {
        onWalletRequest?.({
          requestId: message.requestId,
          method: message.method,
          params: structuredClone(message.params),
        })
      }
    }

    hostPort.start?.()

    targetWindow.postMessage(
      {
        type: "fediverse-miniapp:bootstrap",
        version: protocolVersion,
        launchId,
        hostOrigin,
        issuer: hostOrigin,
        authorizationServerMetadata: `${hostOrigin}/.well-known/oauth-authorization-server`,
        capabilities: [...capabilities],
      },
      appOrigin,
      [channel.port2]
    )
  }

  iframe.addEventListener("load", start)

  return {
    send: message => hostPort?.postMessage(message),
    destroy: () => {
      iframe.removeEventListener("load", start)
      closePort()
    },
  }
}
