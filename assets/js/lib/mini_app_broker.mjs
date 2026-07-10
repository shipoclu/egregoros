const protocolVersion = "1"

const validReadyMessage = (message, launchId) =>
  !!message &&
  typeof message === "object" &&
  message.type === "ready" &&
  message.launchId === launchId

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

export const createMiniAppBroker = ({
  iframe,
  appOrigin,
  launchId,
  onLoading,
  onReady,
  onContextRequest,
  onAuthRequest,
}) => {
  let hostPort = null
  let ready = false

  const closePort = () => {
    if (!hostPort) return
    hostPort.onmessage = null
    hostPort.close()
    hostPort = null
  }

  const start = () => {
    closePort()
    ready = false
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
        message?.type === "getContext" &&
        message?.launchId === launchId &&
        validRequestId(message?.requestId)
      ) {
        onContextRequest?.(message.requestId)
        return
      }

      if (validAuthRequest(message, launchId)) {
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
      }
    }

    hostPort.start?.()

    targetWindow.postMessage(
      {
        type: "fediverse-miniapp:bootstrap",
        version: protocolVersion,
        launchId,
        capabilities: [],
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
